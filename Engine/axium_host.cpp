// Axium WebProcess Extension Host
//
// Compiled as part of WebKit. Bridges page JS ↔ extension executables
// over socketpair fds passed via WebProcessCreationParameters.
//
// - Receives fds at WebProcess startup
// - Queries extensions for content scripts, injects via addUserScript/addUserStyleSheet
// - Intercepts didPostMessage for extension-bound messages
// - Watches extension fds on GLib main loop for responses and push events

#include "config.h"
#include "InjectedBundleScriptWorld.h"
#include "JavaScriptEvaluationResult.h"
#include "WebUserContentController.h"
#include <WebCore/DOMWrapperWorld.h>
#include <WebCore/LocalFrame.h>
#include <WebCore/Page.h>
#include <WebCore/ScriptController.h>
#include <WebCore/UserScript.h>
#include <WebCore/UserStyleSheet.h>
#include <JavaScriptCore/APICast.h>
#include <JavaScriptCore/JSContextRef.h>
#include <JavaScriptCore/JSObjectRef.h>
#include <JavaScriptCore/JSRetainPtr.h>
#include <JavaScriptCore/JSStringRef.h>
#include <JavaScriptCore/JSValueRef.h>
#include <wtf/JSONValues.h>
#include <wtf/text/MakeString.h>
#include <JavaScriptCore/parser/SourceTaintedOrigin.h>
#include <glib-unix.h>
#include <glib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

namespace WebKit {
using namespace WebCore;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

#define MAX_MSG_LEN    (16 * 1024 * 1024)

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

struct HostExt {
    char     name[64];
    int      fd = -1;
    guint    watchId = 0;
    RefPtr<InjectedBundleScriptWorld> world;
    // Incremental read state
    uint8_t  hdr[4];
    int      hdrPos = 0;
    uint8_t *payload = nullptr;
    int      payloadPos = 0;
    uint32_t payloadLen = 0;
};

struct ReplyHandle {
    WTF::Function<void(JSC::JSValue, const String&)> handler;
    JSRetainPtr<JSGlobalContextRef> context;
};

static Vector<HostExt> g_exts;

// ---------------------------------------------------------------------------
// Wire protocol
// ---------------------------------------------------------------------------

static int writeFrame(int fd, const char *json, int len)
{
    uint32_t hdr = GUINT32_TO_LE((uint32_t)len);
    int written = 0;
    while (written < 4) {
        ssize_t n = write(fd, (const char *)&hdr + written, 4 - written);
        if (n <= 0) return -1;
        written += n;
    }
    written = 0;
    while (written < len) {
        ssize_t n = write(fd, json + written, len - written);
        if (n <= 0) return -1;
        written += n;
    }
    return 0;
}

static char *readFrameBlocking(int fd, int *outLen)
{
    uint8_t hdr[4];
    int pos = 0;
    while (pos < 4) {
        ssize_t n = read(fd, hdr + pos, 4 - pos);
        if (n <= 0) return nullptr;
        pos += n;
    }
    uint32_t len = (uint32_t)hdr[0] | ((uint32_t)hdr[1] << 8) |
                   ((uint32_t)hdr[2] << 16) | ((uint32_t)hdr[3] << 24);
    if (len == 0 || len > MAX_MSG_LEN) return nullptr;

    char *buf = (char *)g_malloc(len + 1);
    pos = 0;
    while (pos < (int)len) {
        ssize_t n = read(fd, buf + pos, len - pos);
        if (n <= 0) { g_free(buf); return nullptr; }
        pos += n;
    }
    buf[len] = '\0';
    if (outLen) *outLen = (int)len;
    return buf;
}

// ---------------------------------------------------------------------------
// Content script/style injection
// ---------------------------------------------------------------------------

static WebUserContentController* getController()
{
    WebUserContentController* ctrl = nullptr;
    Page::forEachPage([&](auto& page) {
        if (!ctrl)
            ctrl = &static_cast<WebUserContentController&>(page.userContentProviderForFrame());
    });
    return ctrl;
}

static void injectScript(InjectedBundleScriptWorld& world, String&& source,
                         Vector<String>&& allow, UserScriptInjectionTime time,
                         UserContentInjectedFrames frames)
{
    if (auto* ctrl = getController()) {
        UserScript script(WTF::move(source), { }, WTF::move(allow), { }, time, frames);
        ctrl->addUserScript(world, WTF::move(script));
    }
}

static void injectStyle(InjectedBundleScriptWorld& world, const String& source,
                        Vector<String>&& allow, UserContentInjectedFrames frames)
{
    if (auto* ctrl = getController()) {
        UserStyleSheet sheet(source, { }, WTF::move(allow), { }, frames);
        ctrl->addUserStyleSheet(world, WTF::move(sheet));
    }
}

// ---------------------------------------------------------------------------
// Parse extension's get_scripts response and register scripts/styles
// ---------------------------------------------------------------------------

static void registerScripts(InjectedBundleScriptWorld& world, const char *json)
{
    auto root = JSON::Value::parseJSON(String::fromUTF8(json));
    if (!root)
        return;
    auto obj = root->asObject();
    if (!obj)
        return;

    auto processArray = [&](const String& key, bool isStyle) {
        auto arr = obj->getArray(key);
        if (!arr)
            return;

        for (size_t i = 0; i < arr->length(); i++) {
            auto entry = arr->get(i)->asObject();
            if (!entry)
                continue;

            String source = entry->getString("source"_s);
            if (source.isEmpty())
                continue;

            Vector<String> allow;
            if (auto matches = entry->getArray("matches"_s)) {
                for (size_t j = 0; j < matches->length(); j++)
                    allow.append(matches->get(j)->asString());
            }

            bool allFrames = entry->getBoolean("all_frames"_s).value_or(false);
            auto frames = allFrames
                ? UserContentInjectedFrames::InjectInAllFrames
                : UserContentInjectedFrames::InjectInTopFrameOnly;

            if (isStyle) {
                injectStyle(world, source, WTF::move(allow), frames);
            } else {
                String runAt = entry->getString("run_at"_s);
                auto time = runAt.contains("end"_s)
                    ? UserScriptInjectionTime::DocumentEnd
                    : UserScriptInjectionTime::DocumentStart;
                injectScript(world, WTF::move(source), WTF::move(allow), time, frames);
            }
        }
    };

    processArray("scripts"_s, false);
    processArray("styles"_s, true);
}

// ---------------------------------------------------------------------------
// Message dispatch
// ---------------------------------------------------------------------------

static void dispatchMessage(int extIdx, char *json, int len)
{
    auto parsed = JSON::Value::parseJSON(String::fromUTF8(std::span(json, len)));
    if (!parsed) return;
    auto obj = parsed->asObject();
    if (!obj) return;

    auto h = obj->getDouble("h"_s);
    if (h) {
        // Response — recover the stashed reply handle
        auto *rh = (ReplyHandle *)(uintptr_t)*h;
        String error = obj->getString("error"_s);
        if (!error.isEmpty()) {
            rh->handler(JSC::jsUndefined(), error);
        } else {
            auto str = adopt(JSStringCreateWithUTF8CString(json));
            auto val = JSValueMakeFromJSONString(rh->context.get(), str.get());
            rh->handler(
                toJS(toJS(rh->context.get()), val ? val : JSValueMakeNull(rh->context.get())), { });
        }
        rh->~ReplyHandle();
        WTF::fastFree(rh);
    } else if (!obj->getString("event"_s).isEmpty()) {
        // Push — evaluate in extension's own world
        auto& ext = g_exts[extIdx];
        if (!ext.world) return;
        auto script = makeString("window.__axium_dispatch&&window.__axium_dispatch("_s,
            String::fromUTF8(std::span(json, len)), ")"_s);
        Page::forEachPage([&](auto& page) {
            if (auto* frame = page.localMainFrame())
                frame->script().executeScriptInWorldIgnoringException(
                    ext.world->coreWorld(), script, JSC::SourceTaintedOrigin::Untainted);
        });
    }
}

// ---------------------------------------------------------------------------
// GLib fd watch
// ---------------------------------------------------------------------------

static gboolean onExtFdReady(gint fd, GIOCondition cond, gpointer data)
{
    int idx = GPOINTER_TO_INT(data);
    if (idx < 0 || idx >= (int)g_exts.size() || g_exts[idx].fd < 0)
        return G_SOURCE_REMOVE;

    auto& ext = g_exts[idx];

    if (cond & (G_IO_HUP | G_IO_ERR)) {
        fprintf(stderr, "[axium-host] ext '%s': disconnected\n", ext.name);
        close(ext.fd); ext.fd = -1;
        g_free(ext.payload); ext.payload = nullptr;
        return G_SOURCE_REMOVE;
    }

    for (;;) {
        if (ext.hdrPos < 4) {
            ssize_t n = read(fd, ext.hdr + ext.hdrPos, 4 - ext.hdrPos);
            if (n < 0 && (errno == EAGAIN || errno == EINTR))
                return G_SOURCE_CONTINUE;
            if (n <= 0) { close(ext.fd); ext.fd = -1; return G_SOURCE_REMOVE; }
            ext.hdrPos += n;
            if (ext.hdrPos < 4) return G_SOURCE_CONTINUE;

            ext.payloadLen = (uint32_t)ext.hdr[0] | ((uint32_t)ext.hdr[1] << 8) |
                             ((uint32_t)ext.hdr[2] << 16) | ((uint32_t)ext.hdr[3] << 24);
            if (ext.payloadLen == 0 || ext.payloadLen > MAX_MSG_LEN) {
                close(ext.fd); ext.fd = -1;
                return G_SOURCE_REMOVE;
            }
            ext.payload = (uint8_t *)g_malloc(ext.payloadLen + 1);
            ext.payloadPos = 0;
        }

        ssize_t n = read(fd, ext.payload + ext.payloadPos,
                         ext.payloadLen - ext.payloadPos);
        if (n < 0 && (errno == EAGAIN || errno == EINTR))
            return G_SOURCE_CONTINUE;
        if (n <= 0) { close(ext.fd); ext.fd = -1; return G_SOURCE_REMOVE; }
        ext.payloadPos += n;

        if ((uint32_t)ext.payloadPos < ext.payloadLen)
            return G_SOURCE_CONTINUE;

        ext.payload[ext.payloadLen] = '\0';
        dispatchMessage(idx, (char *)ext.payload, ext.payloadLen);

        g_free(ext.payload);
        ext.payload = nullptr;
        ext.hdrPos = 0;
        ext.payloadPos = 0;
        ext.payloadLen = 0;
    }
}

// ---------------------------------------------------------------------------
// Dispatch user script (push listener)
// ---------------------------------------------------------------------------

static const char DISPATCH_JS[] =
    "(function(){"
        "var _l=[];"
        "window.__axium_dispatch=function(data){"
            "for(var i=0;i<_l.length;i++)_l[i](data);"
        "};"
        "window.__axium_on=function(fn){"
            "_l.push(fn);"
        "};"
    "})();";

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// Find extension by name. Returns index or -1.
int axium_host_find_ext(const char *name)
{
    if (!name) return -1;
    for (int i = 0; i < (int)g_exts.size(); i++)
        if (strcmp(g_exts[i].name, name) == 0 && g_exts[i].fd >= 0)
            return i;
    return -1;
}

// Send message to extension. Returns true on success.
static bool axiumHostSend(int extIdx, const char *json,
    WTF::Function<void(JSC::JSValue, const String&)>&& handler,
    JSRetainPtr<JSGlobalContextRef> context)
{
    if (extIdx < 0 || extIdx >= (int)g_exts.size() || g_exts[extIdx].fd < 0)
        return false;

    auto *rh = static_cast<ReplyHandle*>(WTF::fastMalloc(sizeof(ReplyHandle)));
    new (rh) ReplyHandle { WTF::move(handler), WTF::move(context) };
    auto h = (uintptr_t)rh;

    char *frame = g_strdup_printf("{\"h\":%lu,\"type\":\"message\",\"data\":%s}", h, json);
    if (writeFrame(g_exts[extIdx].fd, frame, strlen(frame)) < 0) {
        g_free(frame);
        rh->~ReplyHandle();
        WTF::fastFree(rh);
        return false;
    }
    g_free(frame);
    return true;
}

// Try to handle a postMessage as an extension message. Returns true if handled.
bool axiumTryHandleExtension(JSGlobalContextRef ctx,
    JavaScriptEvaluationResult& message,
    WTF::Function<void(JSC::JSValue, const String&)>& completionHandler)
{
    auto jsVal = message.toJS(ctx);
    if (!jsVal.get() || !JSValueIsObject(ctx, jsVal.get()))
        return false;

    // Quick check: does this message have an _ext routing field?
    auto jsObj = JSValueToObject(ctx, jsVal.get(), nullptr);
    if (!jsObj) return false;

    auto extKey = adopt(JSStringCreateWithUTF8CString("_ext"));
    auto extVal = JSObjectGetProperty(ctx, jsObj, extKey.get(), nullptr);
    if (!extVal || !JSValueIsString(ctx, extVal))
        return false;

    auto extStr = adopt(JSValueToStringCopy(ctx, extVal, nullptr));
    size_t nameLen = JSStringGetMaximumUTF8CStringSize(extStr.get());
    if (nameLen > 64) return false;
    char extName[64];
    JSStringGetUTF8CString(extStr.get(), extName, sizeof(extName));

    int extIdx = axium_host_find_ext(extName);
    if (extIdx < 0) return false;

    // Only serialize to JSON if we're actually routing to an extension
    auto jsonRef = adopt(JSValueCreateJSONString(ctx, jsVal.get(), 0, nullptr));
    if (!jsonRef) return false;

    size_t maxLen = JSStringGetMaximumUTF8CStringSize(jsonRef.get());
    char *buf = static_cast<char*>(g_malloc(maxLen));
    JSStringGetUTF8CString(jsonRef.get(), buf, maxLen);

    bool sent = axiumHostSend(extIdx, buf,
        WTF::move(completionHandler), JSRetainPtr { ctx });
    g_free(buf);
    return sent;
}

// Init — called from platformInitializeWebProcess
void axium_host_init(int count, int *fds)
{
    if (count <= 0) return;

    fprintf(stderr, "[axium-host] init with %d extension(s)\n", count);
    g_exts.resize(count);

    for (int i = 0; i < count; i++) {
        auto& ext = g_exts[i];
        ext.fd = fds[i];

        // Query content scripts (blocking at startup)
        char req[128];
        snprintf(req, sizeof(req), "{\"id\":%d,\"type\":\"get_scripts\"}", i);
        if (writeFrame(ext.fd, req, strlen(req)) < 0) {
            fprintf(stderr, "[axium-host] ext %d: get_scripts write failed\n", i);
            close(ext.fd); ext.fd = -1;
            continue;
        }

        int respLen = 0;
        char *resp = readFrameBlocking(ext.fd, &respLen);
        if (!resp) {
            fprintf(stderr, "[axium-host] ext %d: get_scripts read failed\n", i);
            close(ext.fd); ext.fd = -1;
            continue;
        }

        auto respParsed = JSON::Value::parseJSON(String::fromUTF8(resp));
        auto respObj = respParsed ? respParsed->asObject() : nullptr;
        if (!respObj || respObj->getInteger("id"_s).value_or(-1) != i) {
            fprintf(stderr, "[axium-host] ext %d: get_scripts response invalid\n", i);
            g_free(resp); close(ext.fd); ext.fd = -1;
            continue;
        }

        String name = respObj->getString("name"_s);
        if (name.isEmpty()) {
            fprintf(stderr, "[axium-host] ext %d: no name in response\n", i);
            g_free(resp); close(ext.fd); ext.fd = -1;
            continue;
        }
        snprintf(ext.name, sizeof(ext.name), "%s", name.utf8().data());

        ext.world = InjectedBundleScriptWorld::create(
            ContentWorldIdentifier::generate(), makeString("axium-"_s, name));

        registerScripts(*ext.world, resp);
        g_free(resp);

        // Inject dispatch listener into this extension's world
        injectScript(*ext.world, String::fromUTF8(DISPATCH_JS),
            Vector<String> { "<all_urls>"_s },
            UserScriptInjectionTime::DocumentStart,
            UserContentInjectedFrames::InjectInAllFrames);

        fprintf(stderr, "[axium-host] ext '%s': scripts registered\n", ext.name);
    }

    // Start fd watches
    for (int i = 0; i < (int)g_exts.size(); i++) {
        if (g_exts[i].fd < 0) continue;
        g_exts[i].watchId = g_unix_fd_add(g_exts[i].fd,
            static_cast<GIOCondition>(G_IO_IN | G_IO_HUP | G_IO_ERR),
            onExtFdReady, GINT_TO_POINTER(i));
    }

    fprintf(stderr, "[axium-host] ready\n");
}

} // namespace WebKit
