// Axium Adblock Web Process Extension
//
// Loaded by WebKit's web process to intercept all network requests
// (scripts, images, CSS, XHR) via the send-request signal.
// Cosmetic filtering injects CSS/JS to hide ad containers and visual junk.
// Links against libaxium_adblock.so for filter matching.

#include <wpe/webkit-web-process-extension.h>
#include <jsc/jsc.h>
#include <gmodule.h>
#include <stdio.h>
#include <string.h>

// ---------------------------------------------------------------------------
// adblock-rust FFI declarations (from libaxium_adblock.so)
// ---------------------------------------------------------------------------

typedef struct AdblockEngine AdblockEngine;

typedef struct {
    _Bool        matched;
    _Bool        important;
    char*        redirect;
    char*        rewritten_url;
    char*        exception;
    char*        filter;
} AdblockResult;

typedef struct {
    char*  hide_selectors;      // CSS: "sel1,sel2{display:none!important}"
    char*  injected_script;     // ready-to-execute JS scriptlets
    char*  exceptions_json;     // JSON array for 2nd-pass filtering
    char*  procedural_actions;  // JSON array of procedural filter objects
    _Bool  generichide;         // skip generic rules if true
} CosmeticResources;

extern void              adblock_engine_free(AdblockEngine* engine);
extern AdblockResult     adblock_check_request(const AdblockEngine* engine,
                                               const char* url,
                                               const char* source_url,
                                               const char* request_type);
extern void              adblock_result_free(AdblockResult* result);
extern CosmeticResources adblock_url_cosmetic_resources(const AdblockEngine* engine,
                                                        const char* url);
extern char*             adblock_hidden_class_id_selectors(const AdblockEngine* engine,
                                                           const char* classes_json,
                                                           const char* ids_json,
                                                           const char* exceptions_json);
extern void              adblock_cosmetic_resources_free(CosmeticResources* result);
extern char*             adblock_get_csp_directives(const AdblockEngine* engine,
                                                     const char* url);
extern void              adblock_string_free(char* s);
extern _Bool             adblock_engine_load_resources_json(AdblockEngine* engine,
                                                             const unsigned char* json,
                                                             unsigned long json_len);
extern AdblockEngine*    adblock_engine_deserialize(const unsigned char* data,
                                                     unsigned long len);

// Embedded data symbols (provided by objcopy at build time, like pages)
extern const unsigned char _binary_engine_dat_start[];
extern const unsigned char _binary_engine_dat_end[];
extern const unsigned char _binary_resources_json_start[];
extern const unsigned char _binary_resources_json_end[];

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

static AdblockEngine* g_engine = NULL;
static gboolean g_disabled = FALSE;
static WebKitScriptWorld* g_adblock_world = NULL;

// ---------------------------------------------------------------------------
// Request type detection from URL extension
// ---------------------------------------------------------------------------

static const char*
detect_request_type(const char* url)
{
    // Find the path end (before ? or #)
    const char* path_end = url;
    const char* p;
    for (p = url; *p; p++) {
        if (*p == '?' || *p == '#')
            break;
        path_end = p + 1;
    }

    // Find last dot in the path portion
    const char* dot = NULL;
    for (p = url; p < path_end; p++) {
        if (*p == '.')
            dot = p;
        else if (*p == '/')
            dot = NULL;  // reset on path separator
    }

    if (!dot)
        return "other";

    const char* ext = dot + 1;
    size_t ext_len = (size_t)(path_end - ext);

    // Match extension (case-insensitive via lowercase check)
    #define EXT_IS(s) (ext_len == sizeof(s) - 1 && g_ascii_strncasecmp(ext, s, ext_len) == 0)

    if (EXT_IS("js") || EXT_IS("mjs"))
        return "script";
    if (EXT_IS("css"))
        return "stylesheet";
    if (EXT_IS("png") || EXT_IS("jpg") || EXT_IS("jpeg") || EXT_IS("gif") ||
        EXT_IS("webp") || EXT_IS("svg") || EXT_IS("ico") || EXT_IS("avif"))
        return "image";
    if (EXT_IS("woff") || EXT_IS("woff2") || EXT_IS("ttf") || EXT_IS("otf") || EXT_IS("eot"))
        return "font";
    if (EXT_IS("mp4") || EXT_IS("webm") || EXT_IS("ogg") || EXT_IS("mp3") || EXT_IS("m4a"))
        return "media";
    if (EXT_IS("html") || EXT_IS("htm"))
        return "subdocument";

    #undef EXT_IS

    return "other";
}

// ---------------------------------------------------------------------------
// send-request handler — return TRUE to block the request
// ---------------------------------------------------------------------------

static gboolean
on_send_request(WebKitWebPage    *page,
                WebKitURIRequest *request,
                WebKitURIResponse *redirected_response,
                gpointer          data)
{
    (void)redirected_response;
    (void)data;

    if (!g_engine)
        return FALSE;

    if (g_disabled)
        return FALSE;

    const char* url = webkit_uri_request_get_uri(request);
    const char* page_url = webkit_web_page_get_uri(page);
    if (!url || !page_url)
        return FALSE;

    const char* request_type = detect_request_type(url);
    AdblockResult result = adblock_check_request(g_engine, url, page_url, request_type);

    if (result.redirect) {
        webkit_uri_request_set_uri(request, result.redirect);
        adblock_result_free(&result);
        return FALSE;
    }

    if (result.rewritten_url) {
        webkit_uri_request_set_uri(request, result.rewritten_url);
        adblock_result_free(&result);
        return FALSE;
    }

    gboolean block = result.matched && (result.important || !result.exception);
    adblock_result_free(&result);

    return block;
}

// ---------------------------------------------------------------------------
// Cosmetic filtering — document-loaded handler + MutationObserver
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// JSC callbacks for isolated world (registered via window-object-cleared)
// ---------------------------------------------------------------------------

// __axiumHiddenSelectors(classesJson, idsJson, exceptionsJson) → CSS string
static JSCValue*
on_hidden_selectors(GPtrArray* args, gpointer user_data)
{
    (void)user_data;
    JSCContext* ctx = jsc_context_get_current();

    if (!g_engine || !args || args->len < 3)
        return jsc_value_new_null(ctx);

    JSCValue* classes_val = g_ptr_array_index(args, 0);
    JSCValue* ids_val = g_ptr_array_index(args, 1);
    JSCValue* exceptions_val = g_ptr_array_index(args, 2);

    if (!jsc_value_is_string(classes_val) || !jsc_value_is_string(ids_val) ||
        !jsc_value_is_string(exceptions_val))
        return jsc_value_new_null(ctx);

    char* classes_json = jsc_value_to_string(classes_val);
    char* ids_json = jsc_value_to_string(ids_val);
    char* exceptions_json = jsc_value_to_string(exceptions_val);

    char* css = adblock_hidden_class_id_selectors(g_engine, classes_json, ids_json,
                                                   exceptions_json);
    g_free(classes_json);
    g_free(ids_json);
    g_free(exceptions_json);

    if (!css)
        return jsc_value_new_null(ctx);

    JSCValue* result = jsc_value_new_string(ctx, css);
    adblock_string_free(css);
    return result;
}

// __axiumCosmeticFull(url) → JSON string with exceptions, procedural, generichide
static JSCValue*
on_cosmetic_full(GPtrArray* args, gpointer user_data)
{
    (void)user_data;
    JSCContext* ctx = jsc_context_get_current();

    if (!g_engine || !args || args->len < 1)
        return jsc_value_new_null(ctx);

    JSCValue* url_val = g_ptr_array_index(args, 0);
    if (!jsc_value_is_string(url_val))
        return jsc_value_new_null(ctx);

    char* url = jsc_value_to_string(url_val);
    CosmeticResources res = adblock_url_cosmetic_resources(g_engine, url);
    g_free(url);

    GString* json = g_string_sized_new(4096);
    g_string_append_printf(json, "{\"generichide\":%s", res.generichide ? "true" : "false");
    if (res.exceptions_json) {
        g_string_append(json, ",\"exceptions\":");
        g_string_append(json, res.exceptions_json);
    }
    if (res.procedural_actions) {
        g_string_append(json, ",\"procedural\":");
        g_string_append(json, res.procedural_actions);
    }
    g_string_append_c(json, '}');

    JSCValue* result = jsc_value_new_string(ctx, json->str);
    g_string_free(json, TRUE);
    adblock_cosmetic_resources_free(&res);
    return result;
}

// Register JSC callbacks in the isolated world when a new page/frame is created
static void
on_world_window_cleared(WebKitScriptWorld *world,
                         WebKitWebPage     *page,
                         WebKitFrame       *frame,
                         gpointer           data)
{
    (void)page; (void)data;
    if (!g_engine || g_disabled) {
        fprintf(stderr, "[adblock] window-object-cleared: skipped (engine=%p disabled=%d)\n",
                (void*)g_engine, g_disabled);
        return;
    }

    fprintf(stderr, "[adblock] window-object-cleared: registering JSC callbacks\n");

    JSCContext* ctx = webkit_frame_get_js_context_for_script_world(frame, world);
    if (!ctx) { fprintf(stderr, "[adblock] window-object-cleared: no JSC context!\n"); return; }

    JSCValue* hs_fn = jsc_value_new_function_variadic(ctx,
        "__axiumHiddenSelectors",
        G_CALLBACK(on_hidden_selectors), NULL, NULL,
        JSC_TYPE_VALUE);
    jsc_context_set_value(ctx, "__axiumHiddenSelectors", hs_fn);
    g_object_unref(hs_fn);

    JSCValue* cf_fn = jsc_value_new_function_variadic(ctx,
        "__axiumCosmeticFull",
        G_CALLBACK(on_cosmetic_full), NULL, NULL,
        JSC_TYPE_VALUE);
    jsc_context_set_value(ctx, "__axiumCosmeticFull", cf_fn);
    g_object_unref(cf_fn);

    g_object_unref(ctx);
}

// document-loaded handler — inject cosmetic filters
static void
on_document_loaded(WebKitWebPage *page, gpointer data)
{
    (void)data;

    if (!g_engine) { fprintf(stderr, "[adblock] document-loaded: no engine\n"); return; }
    if (g_disabled) { fprintf(stderr, "[adblock] document-loaded: disabled\n"); return; }

    const char* page_url = webkit_web_page_get_uri(page);
    if (!page_url) return;
    fprintf(stderr, "[adblock] document-loaded: %s\n", page_url);

    CosmeticResources resources = adblock_url_cosmetic_resources(g_engine, page_url);
    fprintf(stderr, "[adblock]   hide_selectors: %s\n",
            resources.hide_selectors ? "yes" : "none");
    fprintf(stderr, "[adblock]   injected_script: %s\n",
            resources.injected_script ? "yes" : "none");
    fprintf(stderr, "[adblock]   procedural: %s\n",
            resources.procedural_actions ? "yes" : "none");
    fprintf(stderr, "[adblock]   generichide: %s\n",
            resources.generichide ? "true" : "false");

    WebKitFrame* frame = webkit_web_page_get_main_frame(page);
    if (!frame) {
        adblock_cosmetic_resources_free(&resources);
        return;
    }

    JSCContext* ctx = webkit_frame_get_js_context(frame);
    if (!ctx) {
        adblock_cosmetic_resources_free(&resources);
        return;
    }

    // 1. Create <style id="axium-cosmetic"> and set hide_selectors (default world)
    JSCValue* style_elem = jsc_context_evaluate(ctx,
        "var _s=document.getElementById('axium-cosmetic');"
        "if(!_s){_s=document.createElement('style');_s.id='axium-cosmetic';"
        "(document.head||document.documentElement).appendChild(_s);}_s", -1);

    if (resources.hide_selectors && style_elem && jsc_value_is_object(style_elem)) {
        JSCValue* css_val = jsc_value_new_string(ctx, resources.hide_selectors);
        jsc_value_object_set_property(style_elem, "textContent", css_val);
        g_object_unref(css_val);
    }
    g_clear_object(&style_elem);

    // 2. Inject scriptlets (default world — they modify page behavior)
    if (resources.injected_script) {
        JSCValue* r = jsc_context_evaluate(ctx, resources.injected_script, -1);
        g_clear_object(&r);
    }

    // 3. CSP directive injection via <meta> tag (default world)
    {
        char* csp = adblock_get_csp_directives(g_engine, page_url);
        if (csp) {
            JSCValue* meta = jsc_context_evaluate(ctx,
                "var _m=document.createElement('meta');"
                "_m.httpEquiv='Content-Security-Policy';"
                "(document.head||document.documentElement).appendChild(_m);"
                "_m", -1);
            if (meta && jsc_value_is_object(meta)) {
                JSCValue* csp_val = jsc_value_new_string(ctx, csp);
                jsc_value_object_set_property(meta, "content", csp_val);
                g_object_unref(csp_val);
            }
            g_clear_object(&meta);
            adblock_string_free(csp);
        }
    }

    // Procedural filters + MutationObserver 2nd-pass are handled by the
    // content script (adblock.js) running in the isolated "adblock" world.
    // It calls __axiumCosmeticFull() and __axiumHiddenSelectors() which are
    // registered via on_world_window_cleared above.

    g_object_unref(ctx);
    adblock_cosmetic_resources_free(&resources);
}

// ---------------------------------------------------------------------------
// user-message-received handler — honor adblock enable/disable from UI process
// ---------------------------------------------------------------------------

static gboolean
on_user_message_received(WebKitWebPage    *page,
                         WebKitUserMessage *message,
                         gpointer          data)
{
    (void)page;
    (void)data;

    const char* name = webkit_user_message_get_name(message);
    fprintf(stderr, "[adblock] user-message: %s\n", name ?: "(null)");
    if (g_strcmp0(name, "adblock-set-enabled") != 0)
        return FALSE;

    GVariant* params = webkit_user_message_get_parameters(message);
    if (params && g_variant_is_of_type(params, G_VARIANT_TYPE_BOOLEAN)) {
        gboolean enabled = g_variant_get_boolean(params);
        g_disabled = !enabled;
        fprintf(stderr, "[adblock] set enabled=%d -> g_disabled=%d\n", enabled, g_disabled);
    }

    return TRUE;
}

// ---------------------------------------------------------------------------
// page-created handler — connect signals on each new page
// ---------------------------------------------------------------------------

static void
on_page_created(WebKitWebProcessExtension *ext,
                WebKitWebPage             *page,
                gpointer                   data)
{
    (void)ext;
    (void)data;

    guint64 pid = webkit_web_page_get_id(page);
    fprintf(stderr, "[adblock] page-created: id=%lu uri=%s\n",
            (unsigned long)pid, webkit_web_page_get_uri(page) ?: "(null)");

    g_signal_connect(page, "send-request",
                     G_CALLBACK(on_send_request), NULL);
    g_signal_connect(page, "document-loaded",
                     G_CALLBACK(on_document_loaded), NULL);
    g_signal_connect(page, "user-message-received",
                     G_CALLBACK(on_user_message_received), NULL);
}

// ---------------------------------------------------------------------------
// Cleanup — free engine when extension object is destroyed
// ---------------------------------------------------------------------------

static void
on_extension_destroyed(gpointer data, GObject *ext)
{
    (void)data;
    (void)ext;

    if (g_engine) {
        adblock_engine_free(g_engine);
        g_engine = NULL;
    }
    g_clear_object(&g_adblock_world);
}

// ---------------------------------------------------------------------------
// Entry point — called by WebKit when loading the extension
// ---------------------------------------------------------------------------

G_MODULE_EXPORT void
webkit_web_process_extension_initialize_with_user_data(
    WebKitWebProcessExtension *extension,
    const GVariant            *user_data)
{
    (void)user_data;

    // Deserialize pre-compiled engine from embedded data
    unsigned long dat_len = (unsigned long)(_binary_engine_dat_end - _binary_engine_dat_start);
    fprintf(stderr, "[adblock] engine data: %lu bytes\n", dat_len);
    g_engine = adblock_engine_deserialize(_binary_engine_dat_start, dat_len);
    if (!g_engine) {
        fprintf(stderr, "[adblock] FAILED to deserialize embedded engine data\n");
        return;
    }
    fprintf(stderr, "[adblock] engine deserialized OK\n");

    // Load redirect resources + scriptlets from embedded JSON
    unsigned long res_len = (unsigned long)(_binary_resources_json_end - _binary_resources_json_start);
    fprintf(stderr, "[adblock] resources JSON: %lu bytes\n", res_len);
    if (res_len > 0)
        adblock_engine_load_resources_json(g_engine, _binary_resources_json_start, res_len);

    // Create isolated script world for content script JSC callbacks
    g_adblock_world = webkit_script_world_new_with_name("adblock");
    g_signal_connect(g_adblock_world, "window-object-cleared",
                     G_CALLBACK(on_world_window_cleared), NULL);
    fprintf(stderr, "[adblock] script world 'adblock' created\n");

    // Connect to page-created signal
    g_signal_connect(extension, "page-created",
                     G_CALLBACK(on_page_created), NULL);
    fprintf(stderr, "[adblock] init complete\n");

    // Clean up engine when extension is destroyed
    g_object_weak_ref(G_OBJECT(extension), on_extension_destroyed, NULL);
}
