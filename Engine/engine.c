// WPE2 Engine Shim - CPU-only SHM pixel output
// GObject subclasses for WPE2 + raw pixel extraction via SharedMemory path

#include <wpe/wpe-platform.h>
#include <wpe/webkit.h>

#include <sqlite3.h>
#include "pages.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*engine_js_result_fn)(const char* result);

// ---------------------------------------------------------------------------
// GType forward declarations
// ---------------------------------------------------------------------------
static GType axium_display_get_type(void);
static GType axium_view_get_type(void);
static GType axium_toplevel_get_type(void);
static GType axium_clipboard_get_type(void);
static GType axium_screen_get_type(void);

#define AXIUM_TYPE_DISPLAY   (axium_display_get_type())
#define AXIUM_TYPE_VIEW      (axium_view_get_type())
#define AXIUM_TYPE_TOPLEVEL  (axium_toplevel_get_type())
#define AXIUM_TYPE_CLIPBOARD (axium_clipboard_get_type())
#define AXIUM_TYPE_SCREEN    (axium_screen_get_type())
#define AXIUM_DISPLAY(obj)   (G_TYPE_CHECK_INSTANCE_CAST((obj), AXIUM_TYPE_DISPLAY, AxiumDisplay))
#define AXIUM_VIEW(obj)      (G_TYPE_CHECK_INSTANCE_CAST((obj), AXIUM_TYPE_VIEW, AxiumView))
#define AXIUM_TOPLEVEL(obj)  (G_TYPE_CHECK_INSTANCE_CAST((obj), AXIUM_TYPE_TOPLEVEL, AxiumToplevel))
#define AXIUM_CLIPBOARD(obj) (G_TYPE_CHECK_INSTANCE_CAST((obj), AXIUM_TYPE_CLIPBOARD, AxiumClipboard))

// ---------------------------------------------------------------------------
// Engine state
// ---------------------------------------------------------------------------
static WPEDisplay*    g_display  = NULL;
static WPEToplevel*   g_toplevel = NULL;
static WebKitWebView* g_active_view = NULL;
static WebKitNetworkSession* g_ephemeral_session = NULL;
static WebKitUserContentManager* g_content_manager = NULL;

// ---------------------------------------------------------------------------
// AxiumDisplay - CPU-only SHM (no EGL, no DRM, no DMA-BUF)
// ---------------------------------------------------------------------------
typedef struct {
    WPEDisplay parent_instance;
    WPEScreen* screen;
} AxiumDisplay;

typedef struct {
    WPEDisplayClass parent_class;
} AxiumDisplayClass;

G_DEFINE_TYPE(AxiumDisplay, axium_display, WPE_TYPE_DISPLAY)

static gboolean axium_display_connect(WPEDisplay* display, GError** error)
{
    // Pure CPU/SHM rendering — no EGL needed.
    // Skipping eglGetDisplay/eglInitialize avoids loading Mesa/LLVM (~43 MB).
    return TRUE;
}

static gpointer axium_display_get_egl_display(WPEDisplay* display, GError** error)
{
    g_set_error_literal(error, WPE_EGL_ERROR, WPE_EGL_ERROR_NOT_AVAILABLE,
                        "EGL not available (CPU-only SHM rendering)");
    return NULL;
}

static WPEView* axium_display_create_view(WPEDisplay* display)
{
    return WPE_VIEW(g_object_new(AXIUM_TYPE_VIEW, "display", display, NULL));
}

static WPEToplevel* axium_display_create_toplevel(WPEDisplay* display, guint max_views)
{
    WPEToplevel* tl = WPE_TOPLEVEL(g_object_new(AXIUM_TYPE_TOPLEVEL, "display", display, NULL));
    return tl;
}

static WPEDRMDevice* axium_display_get_drm_device(WPEDisplay* display)
{
    return NULL;  // Force SHM path
}

static WPEBufferFormats* axium_display_get_preferred_buffer_formats(WPEDisplay* display)
{
    return NULL;  // Force SHM path
}

static void axium_display_dispose(GObject* object)
{
    AxiumDisplay* self = AXIUM_DISPLAY(object);
    g_clear_object(&self->screen);
    G_OBJECT_CLASS(axium_display_parent_class)->dispose(object);
}

static WPEClipboard* g_clipboard_instance = NULL;

static WPEClipboard* axium_display_get_clipboard(WPEDisplay* display)
{
    if (!g_clipboard_instance)
        g_clipboard_instance = WPE_CLIPBOARD(g_object_new(AXIUM_TYPE_CLIPBOARD, "display", display, NULL));
    return g_clipboard_instance;
}

static guint axium_display_get_n_screens(WPEDisplay* display)
{
    AxiumDisplay* self = AXIUM_DISPLAY(display);
    return self->screen ? 1 : 0;
}

static WPEScreen* axium_display_get_screen(WPEDisplay* display, guint index)
{
    AxiumDisplay* self = AXIUM_DISPLAY(display);
    if (index == 0 && self->screen)
        return self->screen;
    return NULL;
}

static void axium_display_class_init(AxiumDisplayClass* klass)
{
    GObjectClass* object_class = G_OBJECT_CLASS(klass);
    object_class->dispose = axium_display_dispose;

    WPEDisplayClass* display_class = WPE_DISPLAY_CLASS(klass);
    display_class->connect = axium_display_connect;
    display_class->get_egl_display = axium_display_get_egl_display;
    display_class->create_view = axium_display_create_view;
    display_class->create_toplevel = axium_display_create_toplevel;
    display_class->get_drm_device = axium_display_get_drm_device;
    display_class->get_preferred_buffer_formats = axium_display_get_preferred_buffer_formats;
    display_class->get_clipboard = axium_display_get_clipboard;
    display_class->get_n_screens = axium_display_get_n_screens;
    display_class->get_screen = axium_display_get_screen;
}

static void axium_display_init(AxiumDisplay* self)
{
    self->screen = NULL;
}

// ---------------------------------------------------------------------------
// AxiumClipboard - bridges WPE clipboard <-> Display-Onix (X11)
// ---------------------------------------------------------------------------
typedef struct {
    WPEClipboard parent_instance;
} AxiumClipboard;

typedef struct {
    WPEClipboardClass parent_class;
} AxiumClipboardClass;

G_DEFINE_TYPE(AxiumClipboard, axium_clipboard, WPE_TYPE_CLIPBOARD)

extern bool on_clipboard_write(int count, const char** mimes,
                               const uint8_t** data, const int* sizes);
extern bool on_clipboard_read(const char* mime,
                              const uint8_t** out_data, int* out_size);

static GBytes* axium_clipboard_read(WPEClipboard* clipboard, const char* format)
{
    (void)clipboard;
    const uint8_t* data = NULL;
    int size = 0;
    if (!on_clipboard_read(format, &data, &size) || !data || size <= 0) {
        // "text/plain" is an alias for "text/plain;charset=utf-8" on X11
        if (format && strcmp(format, "text/plain") == 0)
            return axium_clipboard_read(clipboard, "text/plain;charset=utf-8");
        return NULL;
    }
    return g_bytes_new(data, size);
}

static void axium_clipboard_changed(WPEClipboard* clipboard, GPtrArray* formats,
                                     gboolean isLocal, WPEClipboardContent* content)
{
    if (isLocal && content && formats && formats->len > 0) {
        int n = (int)formats->len;
        const char** mimes = g_alloca(n * sizeof(char*));
        const uint8_t** datas = g_alloca(n * sizeof(uint8_t*));
        int* sizes = g_alloca(n * sizeof(int));
        int count = 0;

        for (int i = 0; i < n; i++) {
            const char* mime = g_ptr_array_index(formats, i);
            if (!mime) continue;

            if (strstr(mime, "text/")) {
                // WPE stores text content separately from binary buffers
                const char* text = wpe_clipboard_content_get_text(content);
                if (text && *text) {
                    mimes[count] = mime;
                    datas[count] = (const uint8_t*)text;
                    sizes[count] = (int)strlen(text);
                    count++;
                }
            } else {
                GBytes* bytes = wpe_clipboard_content_get_bytes(content, mime);
                if (!bytes) continue;
                gsize len = 0;
                const uint8_t* ptr = g_bytes_get_data(bytes, &len);
                if (ptr && len > 0) {
                    mimes[count] = mime;
                    datas[count] = ptr;
                    sizes[count] = (int)len;
                    count++;
                }
            }
        }

        if (count > 0)
            on_clipboard_write(count, mimes, datas, sizes);
    }
    WPE_CLIPBOARD_CLASS(axium_clipboard_parent_class)->changed(clipboard, formats, isLocal, content);
}

static void axium_clipboard_class_init(AxiumClipboardClass* klass)
{
    WPEClipboardClass* clipboard_class = WPE_CLIPBOARD_CLASS(klass);
    clipboard_class->read = axium_clipboard_read;
    clipboard_class->changed = axium_clipboard_changed;
}

static void axium_clipboard_init(AxiumClipboard* self)
{
    (void)self;
}

void engine_clipboard_notify_external(const char** formats, int count)
{
    // Ensure clipboard instance exists (lazy-created on first get_clipboard call)
    if (!g_clipboard_instance && g_display)
        wpe_display_get_clipboard(g_display);
    if (!g_clipboard_instance) return;
    GPtrArray* arr = g_ptr_array_new();
    gboolean has_text_plain = FALSE;
    gboolean has_text_plain_utf8 = FALSE;
    for (int i = 0; i < count; i++) {
        g_ptr_array_add(arr, (gpointer)g_intern_string(formats[i]));
        if (strcmp(formats[i], "text/plain") == 0)
            has_text_plain = TRUE;
        if (strcmp(formats[i], "text/plain;charset=utf-8") == 0)
            has_text_plain_utf8 = TRUE;
    }
    // WebKit normalizes to "text/plain" in pasteboardItemInfoFromFormats but
    // wpe_clipboard_read_bytes does exact match -- add alias so reads succeed.
    if (has_text_plain_utf8 && !has_text_plain)
        g_ptr_array_add(arr, (gpointer)g_intern_string("text/plain"));
    g_ptr_array_add(arr, NULL);
    WPE_CLIPBOARD_GET_CLASS(g_clipboard_instance)->changed(
        g_clipboard_instance, arr, FALSE, NULL);
    g_ptr_array_unref(arr);
}

// ---------------------------------------------------------------------------
// AxiumView - deferred buffer lifecycle (matches WPE2 reference backends)
//
// Key invariant: buffer_rendered / buffer_released are NEVER called inside
// render_buffer.  They are deferred to a GLib idle callback that runs on
// the next main-loop iteration, avoiding re-entrant IPC dispatch inside
// AcceleratedBackingStore::renderPendingBuffer.
// ---------------------------------------------------------------------------
typedef struct {
    WPEView parent_instance;

    // Buffer lifecycle -- two-stage: pending -> committed
    WPEBuffer* committed_buffer;   // currently "on screen"
    WPEBuffer* pending_buffer;     // waiting to be promoted by idle cb
    guint      frame_source_id;    // idle source, 0 = not scheduled

} AxiumView;

typedef struct {
    WPEViewClass parent_class;
} AxiumViewClass;

G_DEFINE_TYPE(AxiumView, axium_view, WPE_TYPE_VIEW)

// Direct render target -- set by Odin, written by render_buffer
static uint8_t* g_frame_target = NULL;
static int g_target_stride = 0;
static int g_target_x = 0, g_target_y = 0;
static int g_target_w = 0, g_target_h = 0;

// Deferred callback -- runs on the next main-loop iteration, OUTSIDE the
// IPC dispatch that triggered render_buffer.
static gboolean frame_complete_cb(gpointer data)
{
    AxiumView* self = AXIUM_VIEW(data);
    WPEView* view = WPE_VIEW(self);

    self->frame_source_id = 0;

    if (!self->pending_buffer)
        return G_SOURCE_REMOVE;

    // Release the previously committed buffer (we no longer need its backing)
    if (self->committed_buffer) {
        wpe_view_buffer_released(view, self->committed_buffer);
        g_object_unref(self->committed_buffer);
    }

    // Promote pending -> committed
    self->committed_buffer = self->pending_buffer;
    self->pending_buffer = NULL;

    // Signal that the buffer was rendered -- this sends FrameDone IPC to the
    // web process, allowing it to produce the next frame.
    wpe_view_buffer_rendered(view, self->committed_buffer);

    return G_SOURCE_REMOVE;
}

static gboolean axium_view_render_buffer(WPEView* view, WPEBuffer* buffer,
                                          const WPERectangle* damage_rects,
                                          guint n_damage_rects, GError** error)
{
    AxiumView* self = AXIUM_VIEW(view);

    // If a previous pending buffer was never processed, release it now
    if (self->pending_buffer) {
        wpe_view_buffer_released(view, self->pending_buffer);
        g_object_unref(self->pending_buffer);
    }

    // Store this buffer as pending -- the idle callback will promote it
    self->pending_buffer = g_object_ref(buffer);

    // Schedule deferred completion on next main-loop iteration
    if (self->frame_source_id == 0) {
        self->frame_source_id = g_idle_add(frame_complete_cb, self);
    }

    return TRUE;
}

static void on_toplevel_changed(WPEView* view, GParamSpec* pspec, gpointer data)
{
    WPEToplevel* toplevel = wpe_view_get_toplevel(view);
    if (!toplevel) {
        wpe_view_unmap(view);
        return;
    }

    int width, height;
    wpe_toplevel_get_size(toplevel, &width, &height);
    if (width && height)
        wpe_view_resized(view, width, height);

    wpe_view_map(view);
    wpe_toplevel_state_changed(toplevel, WPE_TOPLEVEL_STATE_ACTIVE);
}

static void axium_view_constructed(GObject* object)
{
    G_OBJECT_CLASS(axium_view_parent_class)->constructed(object);
    g_signal_connect(WPE_VIEW(object), "notify::toplevel",
                     G_CALLBACK(on_toplevel_changed), NULL);
}

static void axium_view_dispose(GObject* object)
{
    AxiumView* self = AXIUM_VIEW(object);

    // Cancel pending idle source
    if (self->frame_source_id) {
        g_source_remove(self->frame_source_id);
        self->frame_source_id = 0;
    }

    if (self->pending_buffer) {
        wpe_view_buffer_released(WPE_VIEW(self), self->pending_buffer);
        g_clear_object(&self->pending_buffer);
    }
    if (self->committed_buffer) {
        wpe_view_buffer_released(WPE_VIEW(self), self->committed_buffer);
        g_clear_object(&self->committed_buffer);
    }
    G_OBJECT_CLASS(axium_view_parent_class)->dispose(object);
}

// Cursor -- map CSS cursor names to integer codes exposed to Odin
static int g_cursor = 0;      // current cursor code
static int g_cursor_prev = 0;  // last cursor code seen by Odin

static void axium_view_set_cursor_from_name(WPEView* view, const char* name)
{
    int c = 0; // Arrow/default
    if (!name) return;
    switch (name[0]) {
    case 't': c = 1; break; // "text"
    case 'c': c = 2; break; // "crosshair", "col-resize", "cell", "context-menu", "copy"
    case 'p':
        if (name[1] == 'o') c = 3; // "pointer"
        break;
    case 'e':
        if (name[1] == 'w') c = 4; // "ew-resize"
        else c = 4;                 // "e-resize"
        break;
    case 'w': c = 4; break;         // "w-resize"
    case 'n':
        if (name[1] == 's' || (name[1] == '-')) c = 5; // "ns-resize", "n-resize"
        else if (name[1] == 'e' || name[1] == 'w') c = 2; // "ne-resize", "nw-resize"
        else c = 5;
        break;
    case 's':
        if (name[1] == '-' || (name[1] == 'e' && name[2] == '-') || (name[1] == 'w' && name[2] == '-'))
            c = 5; // "s-resize", "se-resize", "sw-resize"
        break;
    case 'r':
        if (name[1] == 'o') c = 5; // "row-resize"
        break;
    }
    g_cursor = c;
}

static void axium_view_class_init(AxiumViewClass* klass)
{
    GObjectClass* object_class = G_OBJECT_CLASS(klass);
    object_class->constructed = axium_view_constructed;
    object_class->dispose = axium_view_dispose;

    WPEViewClass* view_class = WPE_VIEW_CLASS(klass);
    view_class->render_buffer = axium_view_render_buffer;
    view_class->set_cursor_from_name = axium_view_set_cursor_from_name;
}

static void axium_view_init(AxiumView* self)
{
    self->committed_buffer = NULL;
    self->pending_buffer = NULL;
    self->frame_source_id = 0;
}

// ---------------------------------------------------------------------------
// AxiumScreen
// ---------------------------------------------------------------------------
typedef struct {
    WPEScreen parent_instance;
} AxiumScreen;

typedef struct {
    WPEScreenClass parent_class;
} AxiumScreenClass;

G_DEFINE_TYPE(AxiumScreen, axium_screen, WPE_TYPE_SCREEN)

static void axium_screen_class_init(AxiumScreenClass* klass) {}
static void axium_screen_init(AxiumScreen* self) {}

// ---------------------------------------------------------------------------
// AxiumToplevel
// ---------------------------------------------------------------------------
typedef struct {
    WPEToplevel parent_instance;
} AxiumToplevel;

typedef struct {
    WPEToplevelClass parent_class;
} AxiumToplevelClass;

G_DEFINE_TYPE(AxiumToplevel, axium_toplevel, WPE_TYPE_TOPLEVEL)

static gboolean resize_view_cb(WPEToplevel* tl, WPEView* view, gpointer data)
{
    int w, h;
    wpe_toplevel_get_size(tl, &w, &h);
    wpe_view_resized(view, w, h);
    return FALSE;
}

static gboolean axium_toplevel_resize(WPEToplevel* toplevel, int width, int height)
{
    wpe_toplevel_resized(toplevel, width, height);
    wpe_toplevel_foreach_view(toplevel, resize_view_cb, NULL);
    return TRUE;
}

static void axium_toplevel_class_init(AxiumToplevelClass* klass)
{
    WPEToplevelClass* toplevel_class = WPE_TOPLEVEL_CLASS(klass);
    toplevel_class->resize = axium_toplevel_resize;
}

static void axium_toplevel_init(AxiumToplevel* self) {}

static char* g_page_theme = NULL;
static uint32_t g_bg_rgb = 0;
static int      g_bg_opacity = 255;
static bool     g_bg_color_set = false;
static char* g_tls_allowed_hosts[64];
static int g_tls_allowed_count = 0;

// ---------------------------------------------------------------------------
// JavaScript
// ---------------------------------------------------------------------------

void engine_run_javascript(const char* script)
{
    WebKitWebView* wv = g_active_view;
    if (!wv || !script) return;
    webkit_web_view_evaluate_javascript(wv, script, -1, NULL, NULL, NULL, NULL, NULL);
}

static void js_eval_finished(GObject* source, GAsyncResult* result, gpointer user_data)
{
    engine_js_result_fn callback = (engine_js_result_fn)user_data;
    GError* error = NULL;
    JSCValue* value = webkit_web_view_evaluate_javascript_finish(
        WEBKIT_WEB_VIEW(source), result, &error);

    if (error) {
        g_clear_error(&error);
        if (callback) callback(NULL);
        return;
    }

    if (value && jsc_value_is_string(value)) {
        char* str = jsc_value_to_string(value);
        if (callback) callback(str);
        g_free(str);
    } else {
        if (callback) callback(NULL);
    }

    if (value) g_object_unref(value);
}

void engine_evaluate_javascript(const char* script, engine_js_result_fn callback)
{
    WebKitWebView* wv = g_active_view;
    if (!wv || !script) {
        if (callback) callback(NULL);
        return;
    }
    webkit_web_view_evaluate_javascript(wv, script, -1, NULL, NULL, NULL,
                                        js_eval_finished, (gpointer)callback);
}

// ---------------------------------------------------------------------------
// Privacy, Permissions, TLS, Adblock
// ---------------------------------------------------------------------------

static WebKitCookieAcceptPolicy cookie_policy_to_webkit(int policy)
{
    switch (policy) {
    case 0:  return WEBKIT_COOKIE_POLICY_ACCEPT_ALWAYS;
    case 1:  return WEBKIT_COOKIE_POLICY_ACCEPT_NO_THIRD_PARTY;
    case 2:  return WEBKIT_COOKIE_POLICY_ACCEPT_NEVER;
    default: return WEBKIT_COOKIE_POLICY_ACCEPT_NO_THIRD_PARTY;
    }
}

void engine_configure_privacy(int cookie_policy, bool itp_enabled,
                               bool tls_strict, bool credential_persistence)
{
    WebKitNetworkSession* session = webkit_network_session_get_default();

    // Cookie policy + persistent storage
    WebKitCookieManager* cm = webkit_network_session_get_cookie_manager(session);
    webkit_cookie_manager_set_accept_policy(cm, cookie_policy_to_webkit(cookie_policy));

    // Set up persistent cookie storage
    const char* home = g_get_home_dir();
    char* cookie_path = g_strdup_printf("%s/.local/share/axium/cookies.db", home);
    char* cookie_dir = g_path_get_dirname(cookie_path);
    g_mkdir_with_parents(cookie_dir, 0755);
    webkit_cookie_manager_set_persistent_storage(cm, cookie_path,
        WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE);
    g_free(cookie_path);
    g_free(cookie_dir);

    // ITP (Intelligent Tracking Prevention)
    webkit_network_session_set_itp_enabled(session, itp_enabled);

    // TLS certificate errors policy
    webkit_network_session_set_tls_errors_policy(session,
        tls_strict ? WEBKIT_TLS_ERRORS_POLICY_FAIL : WEBKIT_TLS_ERRORS_POLICY_IGNORE);

    // Persistent credential storage
    webkit_network_session_set_persistent_credential_storage_enabled(session, credential_persistence);
}

static int webkit_data_types_from_bitmask(int mask)
{
    WebKitWebsiteDataTypes types = 0;
    if (mask & 1)   types |= WEBKIT_WEBSITE_DATA_COOKIES;
    if (mask & 2)   types |= WEBKIT_WEBSITE_DATA_DISK_CACHE;
    if (mask & 4)   types |= WEBKIT_WEBSITE_DATA_LOCAL_STORAGE;
    if (mask & 8)   types |= WEBKIT_WEBSITE_DATA_INDEXEDDB_DATABASES;
    if (mask & 16)  types |= WEBKIT_WEBSITE_DATA_SERVICE_WORKER_REGISTRATIONS;
    if (mask & 32)  types |= WEBKIT_WEBSITE_DATA_HSTS_CACHE;
    if (mask & 64)  types |= WEBKIT_WEBSITE_DATA_SESSION_STORAGE;
    if (mask & 128) types |= WEBKIT_WEBSITE_DATA_DOM_CACHE;
    return types;
}

void engine_clear_website_data(int data_types, int64_t since_timestamp)
{
    WebKitNetworkSession* session = webkit_network_session_get_default();
    WebKitWebsiteDataManager* dm = webkit_network_session_get_website_data_manager(session);
    WebKitWebsiteDataTypes types = webkit_data_types_from_bitmask(data_types);

    // GTimeSpan is microseconds. 0 = clear all data regardless of age.
    GTimeSpan timespan = 0;
    if (since_timestamp > 0) {
        // Convert seconds-since-epoch to "age in microseconds"
        GDateTime* now = g_date_time_new_now_utc();
        int64_t now_unix = g_date_time_to_unix(now);
        g_date_time_unref(now);
        timespan = (now_unix - since_timestamp) * G_USEC_PER_SEC;
        if (timespan < 0) timespan = 0;
    }
    webkit_website_data_manager_clear(dm, types, timespan, NULL, NULL, NULL);
}

typedef struct {
    char domain[256];
    WebKitWebsiteDataTypes types;
    WebKitWebsiteDataManager* dm;
} DomainClearCtx;

static void on_fetch_for_domain_clear(GObject* source, GAsyncResult* result, gpointer user_data)
{
    DomainClearCtx* ctx = (DomainClearCtx*)user_data;
    GList* data_list = webkit_website_data_manager_fetch_finish(
        ctx->dm, result, NULL);

    if (!data_list) {
        g_free(ctx);
        return;
    }

    // Filter: collect entries matching the target domain
    GList* to_remove = NULL;
    for (GList* l = data_list; l; l = l->next) {
        WebKitWebsiteData* data = (WebKitWebsiteData*)l->data;
        const char* name = webkit_website_data_get_name(data);
        if (!name) continue;

        // Match exact domain or subdomain (name ends with .domain)
        if (strcmp(name, ctx->domain) == 0) {
            to_remove = g_list_prepend(to_remove, webkit_website_data_ref(data));
        } else {
            size_t nlen = strlen(name);
            size_t dlen = strlen(ctx->domain);
            if (nlen > dlen + 1 &&
                name[nlen - dlen - 1] == '.' &&
                strcmp(name + nlen - dlen, ctx->domain) == 0) {
                to_remove = g_list_prepend(to_remove, webkit_website_data_ref(data));
            }
        }
    }

    if (to_remove) {
        webkit_website_data_manager_remove(ctx->dm, ctx->types, to_remove,
                                            NULL, NULL, NULL);
        g_list_free_full(to_remove, (GDestroyNotify)webkit_website_data_unref);
    }

    g_list_free_full(data_list, (GDestroyNotify)webkit_website_data_unref);
    g_free(ctx);
}

void engine_clear_website_data_for_domain(const char* domain, int data_types)
{
    if (!domain || !*domain) return;

    WebKitNetworkSession* session = webkit_network_session_get_default();
    WebKitWebsiteDataManager* dm = webkit_network_session_get_website_data_manager(session);
    WebKitWebsiteDataTypes types = webkit_data_types_from_bitmask(data_types);

    DomainClearCtx* ctx = g_new0(DomainClearCtx, 1);
    strncpy(ctx->domain, domain, sizeof(ctx->domain) - 1);
    ctx->types = types;
    ctx->dm = dm;

    webkit_website_data_manager_fetch(dm, types, NULL,
                                       on_fetch_for_domain_clear, ctx);
}

void engine_configure_proxy(int mode, const char* url, const char* ignore_hosts)
{
    WebKitNetworkSession* session = webkit_network_session_get_default();
    WebKitNetworkProxyMode wk_mode;
    switch (mode) {
    case 1:  wk_mode = WEBKIT_NETWORK_PROXY_MODE_NO_PROXY; break;
    case 2:  wk_mode = WEBKIT_NETWORK_PROXY_MODE_CUSTOM; break;
    default: wk_mode = WEBKIT_NETWORK_PROXY_MODE_DEFAULT; break;
    }
    if (wk_mode == WEBKIT_NETWORK_PROXY_MODE_CUSTOM && url && url[0]) {
        const char* ignore_array[64] = {0};
        int count = 0;
        if (ignore_hosts && ignore_hosts[0]) {
            static char ignore_buf[2048];
            strncpy(ignore_buf, ignore_hosts, sizeof(ignore_buf) - 1);
            ignore_buf[sizeof(ignore_buf) - 1] = '\0';
            char* tok = strtok(ignore_buf, ",");
            while (tok && count < 63) {
                while (*tok == ' ') tok++;
                ignore_array[count++] = tok;
                tok = strtok(NULL, ",");
            }
            ignore_array[count] = NULL;
        }
        WebKitNetworkProxySettings* ps = webkit_network_proxy_settings_new(url, ignore_array);
        webkit_network_session_set_proxy_settings(session, wk_mode, ps);
        webkit_network_proxy_settings_free(ps);
    } else {
        webkit_network_session_set_proxy_settings(session, wk_mode, NULL);
    }
}

void engine_set_tls_allowed_hosts(const char** hosts, int count)
{
    for (int i = 0; i < g_tls_allowed_count; i++)
        g_free(g_tls_allowed_hosts[i]);

    g_tls_allowed_count = count < 64 ? count : 64;
    for (int i = 0; i < g_tls_allowed_count; i++)
        g_tls_allowed_hosts[i] = g_strdup(hosts[i]);
}

static gboolean on_tls_error(WebKitWebView* view, const char* uri,
                              GTlsCertificate* cert, GTlsCertificateFlags errors,
                              gpointer data)
{
    if (!uri || g_tls_allowed_count == 0) return FALSE;

    const char* start = strstr(uri, "://");
    if (start) start += 3; else start = uri;
    char host[256];
    int i = 0;
    while (start[i] && start[i] != '/' && start[i] != ':' && i < 255) {
        host[i] = start[i];
        i++;
    }
    host[i] = '\0';

    for (int j = 0; j < g_tls_allowed_count; j++) {
        if (strcmp(host, g_tls_allowed_hosts[j]) == 0) {
            WebKitNetworkSession* session = webkit_network_session_get_default();
            webkit_network_session_allow_tls_certificate_for_host(session, cert, host);
            webkit_web_view_reload(view);
            return TRUE;
        }
    }
    return FALSE;
}

extern int permission_query(const char* origin, int permission_type);

static gboolean on_permission_request(WebKitWebView* web_view,
                                       WebKitPermissionRequest* request,
                                       gpointer user_data)
{
    const char* uri = webkit_web_view_get_uri(web_view);
    int perm_type = -1;

    if (WEBKIT_IS_GEOLOCATION_PERMISSION_REQUEST(request))
        perm_type = 0;
    else if (WEBKIT_IS_NOTIFICATION_PERMISSION_REQUEST(request))
        perm_type = 1;
    else if (WEBKIT_IS_USER_MEDIA_PERMISSION_REQUEST(request)) {
        WebKitUserMediaPermissionRequest* um = WEBKIT_USER_MEDIA_PERMISSION_REQUEST(request);
        if (webkit_user_media_permission_is_for_video_device(um))
            perm_type = 2;  // camera
        else if (webkit_user_media_permission_is_for_audio_device(um))
            perm_type = 3;  // microphone
    // Clipboard (type 4): WPE lacks WebKitClipboardPermissionRequest (GTK-only, FIXME in WPE).
    // Clipboard access is unguarded on WPE. query-permission-state still reports stored state.
    } else if (WEBKIT_IS_DEVICE_INFO_PERMISSION_REQUEST(request))
        perm_type = 5;
    else if (WEBKIT_IS_MEDIA_KEY_SYSTEM_PERMISSION_REQUEST(request))
        perm_type = 6;
    else if (WEBKIT_IS_WEBSITE_DATA_ACCESS_PERMISSION_REQUEST(request))
        perm_type = 7;

    if (perm_type < 0) {
        webkit_permission_request_deny(request);
        return TRUE;
    }

    int result = permission_query(uri, perm_type);
    if (result == 1)
        webkit_permission_request_allow(request);
    else
        webkit_permission_request_deny(request);
    return TRUE;
}

static gboolean on_query_permission_state(WebKitWebView* view,
                                           WebKitPermissionStateQuery* query,
                                           gpointer data)
{
    const char* name = webkit_permission_state_query_get_name(query);
    WebKitSecurityOrigin* origin = webkit_permission_state_query_get_security_origin(query);
    const char* host = webkit_security_origin_get_host(origin);

    int perm_type = -1;
    if      (strcmp(name, "geolocation") == 0)     perm_type = 0;
    else if (strcmp(name, "notifications") == 0)   perm_type = 1;
    else if (strcmp(name, "clipboard-read") == 0 || strcmp(name, "clipboard-write") == 0) perm_type = 4;

    if (perm_type < 0) return FALSE;

    int result = permission_query(host, perm_type);
    if (result == 1)
        webkit_permission_state_query_finish(query, WEBKIT_PERMISSION_STATE_GRANTED);
    else if (result == -1)
        webkit_permission_state_query_finish(query, WEBKIT_PERMISSION_STATE_DENIED);
    else
        webkit_permission_state_query_finish(query, WEBKIT_PERMISSION_STATE_PROMPT);
    return TRUE;
}

static char* g_adblock_dir = NULL;

static void on_initialize_web_process_extensions(WebKitWebContext* context,
                                                  gpointer data)
{
    (void)data;
    if (g_adblock_dir)
        webkit_web_context_set_web_process_extensions_initialization_user_data(
            context, g_variant_new_string(g_adblock_dir));
}

void engine_init_adblock(const char* adblock_dir)
{
    if (!adblock_dir)
        return;

    g_adblock_dir = g_strdup(adblock_dir);

    WebKitWebContext* ctx = webkit_web_context_get_default();
    g_signal_connect(ctx, "initialize-web-process-extensions",
                     G_CALLBACK(on_initialize_web_process_extensions), NULL);
}

void engine_adblock_set_disabled(bool disabled)
{
    WebKitWebView* wv = g_active_view;
    if (!wv) return;

    WebKitUserMessage* msg = webkit_user_message_new(
        "adblock-set-disabled",
        g_variant_new_boolean(disabled));
    webkit_web_view_send_message_to_page(wv, msg, NULL, NULL, NULL);
}

// ---------------------------------------------------------------------------
// Downloads
// ---------------------------------------------------------------------------

extern void download_started(const char* uri, const char* filename);
extern void download_progress(const char* uri, double progress, double elapsed, uint64_t received);
extern void download_finished(const char* uri, uint64_t total);
extern void download_failed(const char* uri, const char* error);

static char* g_download_dir = NULL;

#define MAX_DOWNLOADS 32
static WebKitDownload* g_downloads[MAX_DOWNLOADS];
static int g_download_count = 0;

static void dl_track(WebKitDownload* dl)
{
    if (g_download_count < MAX_DOWNLOADS)
        g_downloads[g_download_count++] = dl;
}

static void dl_untrack(WebKitDownload* dl)
{
    for (int i = 0; i < g_download_count; i++) {
        if (g_downloads[i] == dl) {
            g_downloads[i] = g_downloads[g_download_count - 1];
            g_downloads[g_download_count - 1] = NULL;
            g_download_count--;
            return;
        }
    }
}

static const char* dl_get_uri(WebKitDownload* dl)
{
    WebKitURIRequest* req = webkit_download_get_request(dl);
    return req ? webkit_uri_request_get_uri(req) : NULL;
}

static const char* dl_split_ext(const char* filename)
{
    const char* dot = strrchr(filename, '.');
    if (!dot || dot == filename) return NULL;
    return dot;
}

static gboolean on_decide_destination(WebKitDownload* dl,
                                       const char* suggested_filename,
                                       gpointer data)
{
    if (!g_download_dir || !suggested_filename) return FALSE;

    char* path = g_strdup_printf("%s/%s", g_download_dir, suggested_filename);
    if (g_file_test(path, G_FILE_TEST_EXISTS)) {
        const char* ext = dl_split_ext(suggested_filename);
        int name_len = ext ? (int)(ext - suggested_filename) : (int)strlen(suggested_filename);
        const char* ext_str = ext ? ext : "";

        for (int n = 1; n < 1000; n++) {
            g_free(path);
            path = g_strdup_printf("%s/%.*s (%d)%s", g_download_dir, name_len, suggested_filename, n, ext_str);
            if (!g_file_test(path, G_FILE_TEST_EXISTS)) break;
        }
    }

    webkit_download_set_destination(dl, path);

    const char* uri = dl_get_uri(dl);
    const char* final_name = strrchr(path, '/');
    final_name = final_name ? final_name + 1 : path;
    if (uri)
        download_started(uri, final_name);

    g_free(path);
    return TRUE;
}

static void on_download_received_data(WebKitDownload* dl,
                                       guint64 data_length,
                                       gpointer user_data)
{
    const char* uri = dl_get_uri(dl);
    if (!uri) return;
    double progress = webkit_download_get_estimated_progress(dl);
    double elapsed  = webkit_download_get_elapsed_time(dl);
    guint64 received = webkit_download_get_received_data_length(dl);
    download_progress(uri, progress, elapsed, received);
}

static void on_download_finished(WebKitDownload* dl, gpointer data)
{
    const char* uri = dl_get_uri(dl);
    guint64 total = webkit_download_get_received_data_length(dl);
    dl_untrack(dl);
    if (uri)
        download_finished(uri, total);
}

static void on_download_failed(WebKitDownload* dl,
                                GError* error,
                                gpointer data)
{
    const char* uri = dl_get_uri(dl);
    dl_untrack(dl);
    if (uri)
        download_failed(uri, error ? error->message : "Unknown error");
}

static void on_download_started(WebKitNetworkSession* session,
                                 WebKitDownload* dl,
                                 gpointer data)
{
    dl_track(dl);

    g_signal_connect(dl, "decide-destination",
                     G_CALLBACK(on_decide_destination), NULL);
    g_signal_connect(dl, "received-data",
                     G_CALLBACK(on_download_received_data), NULL);
    g_signal_connect(dl, "finished",
                     G_CALLBACK(on_download_finished), NULL);
    g_signal_connect(dl, "failed",
                     G_CALLBACK(on_download_failed), NULL);
}

void engine_set_download_dir(const char* dir)
{
    g_free(g_download_dir);
    g_download_dir = g_strdup(dir);
}

void engine_download_cancel(const char* uri)
{
    if (!uri) return;
    for (int i = 0; i < g_download_count; i++) {
        if (!g_downloads[i]) continue;
        WebKitURIRequest* req = webkit_download_get_request(g_downloads[i]);
        if (req && strcmp(webkit_uri_request_get_uri(req), uri) == 0) {
            webkit_download_cancel(g_downloads[i]);
            return;
        }
    }
}

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------
static sqlite3* g_history_db = NULL;

static void history_record(const char* url, const char* title)
{
    if (!g_history_db || !url || !*url) return;
    if (strncmp(url, "about:", 6) == 0) return;
    if (strncmp(url, "axium:", 6) == 0) return;

    const char* sql = "INSERT INTO history (url, title, timestamp) VALUES (?, ?, strftime('%s','now'))";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(g_history_db, sql, -1, &stmt, NULL) != SQLITE_OK) return;
    sqlite3_bind_text(stmt, 1, url, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, title ? title : "", -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

static void history_update_title(const char* url, const char* title)
{
    if (!g_history_db || !url || !*url || !title || !*title) return;

    const char* sql = "UPDATE history SET title = ? WHERE rowid = ("
                      "SELECT rowid FROM history WHERE url = ? "
                      "ORDER BY timestamp DESC LIMIT 1)";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(g_history_db, sql, -1, &stmt, NULL) != SQLITE_OK) return;
    sqlite3_bind_text(stmt, 1, title, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, url, -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

static void history_close(void)
{
    if (g_history_db) {
        sqlite3_close(g_history_db);
        g_history_db = NULL;
    }
}

// JSON-escape a string into dst, returns bytes written (excluding NUL).
static int json_escape(char* dst, int dst_size, const char* src)
{
    int o = 0;
    for (int i = 0; src[i] && o < dst_size - 2; i++) {
        unsigned char ch = (unsigned char)src[i];
        if (ch == '"')       { dst[o++] = '\\'; dst[o++] = '"';  }
        else if (ch == '\\') { dst[o++] = '\\'; dst[o++] = '\\'; }
        else if (ch == '\n') { dst[o++] = '\\'; dst[o++] = 'n';  }
        else if (ch == '\r') { dst[o++] = '\\'; dst[o++] = 'r';  }
        else if (ch == '\t') { dst[o++] = '\\'; dst[o++] = 't';  }
        else if (ch < 0x20)  { o += snprintf(dst + o, dst_size - o, "\\u%04x", ch); }
        else                 { dst[o++] = ch; }
    }
    dst[o] = '\0';
    return o;
}

static char* history_list(void)
{
    GString* json = g_string_sized_new(4096);
    g_string_append_c(json, '[');
    if (g_history_db) {
        const char* sql =
            "SELECT id, url, title, timestamp FROM history ORDER BY timestamp DESC LIMIT 5000";
        sqlite3_stmt* stmt;
        if (sqlite3_prepare_v2(g_history_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
            int first = 1;
            char esc_url[4096], esc_title[4096];
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                int64_t id = sqlite3_column_int64(stmt, 0);
                const char* url = (const char*)sqlite3_column_text(stmt, 1);
                const char* title = (const char*)sqlite3_column_text(stmt, 2);
                int64_t ts = sqlite3_column_int64(stmt, 3);
                if (!url) url = "";
                if (!title) title = "";
                json_escape(esc_url, sizeof(esc_url), url);
                json_escape(esc_title, sizeof(esc_title), title);
                g_string_append_printf(json, "%s{\"id\":%lld,\"url\":\"%s\",\"title\":\"%s\",\"ts\":%lld}",
                    first ? "" : ",", (long long)id, esc_url, esc_title, (long long)ts);
                first = 0;
            }
            sqlite3_finalize(stmt);
        }
    }
    g_string_append_c(json, ']');
    return g_string_free(json, FALSE);
}

static char* history_delete(const char* json)
{
    if (!g_history_db) return g_strdup("{\"ok\":false}");

    const char* id_str = strstr(json, "\"id\"");
    if (!id_str) return g_strdup("{\"ok\":false}");
    id_str += 4;
    while (*id_str && (*id_str == ' ' || *id_str == ':' || *id_str == '\t')) id_str++;
    int64_t id = strtoll(id_str, NULL, 10);
    if (id <= 0) return g_strdup("{\"ok\":false}");

    const char* sql = "DELETE FROM history WHERE id = ?";
    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(g_history_db, sql, -1, &stmt, NULL) != SQLITE_OK)
        return g_strdup("{\"ok\":false}");
    sqlite3_bind_int64(stmt, 1, id);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return g_strdup("{\"ok\":true}");
}

static char* history_clear(void)
{
    if (!g_history_db) return g_strdup("{\"ok\":false}");
    sqlite3_exec(g_history_db, "DELETE FROM history", NULL, NULL, NULL);
    return g_strdup("{\"ok\":true}");
}

static char* history_handle_message(const char* json)
{
    const char* action = strstr(json, "\"action\"");
    if (!action) return NULL;

    if (strstr(action, "\"history-list\""))
        return history_list();
    if (strstr(action, "\"history-delete\""))
        return history_delete(json);
    if (strstr(action, "\"history-clear\""))
        return history_clear();

    return NULL;
}

void engine_history_init(const char* db_path)
{
    if (!db_path) return;

    if (sqlite3_open(db_path, &g_history_db) != SQLITE_OK) {
        fprintf(stderr, "[axium] failed to open history db: %s\n",
                sqlite3_errmsg(g_history_db));
        g_history_db = NULL;
        return;
    }

    const char* create_sql =
        "CREATE TABLE IF NOT EXISTS history ("
        "  id INTEGER PRIMARY KEY,"
        "  url TEXT NOT NULL,"
        "  title TEXT,"
        "  timestamp INTEGER NOT NULL"
        ");"
        "CREATE INDEX IF NOT EXISTS idx_history_ts ON history(timestamp DESC);";
    char* err_msg = NULL;
    if (sqlite3_exec(g_history_db, create_sql, NULL, NULL, &err_msg) != SQLITE_OK) {
        fprintf(stderr, "[axium] history schema error: %s\n", err_msg);
        sqlite3_free(err_msg);
    }
}

// ---------------------------------------------------------------------------
// Pages (axium:// scheme, data handlers, script message dispatch)
// ---------------------------------------------------------------------------

typedef struct {
    WebKitScriptMessageReply* reply;
    JSCContext* ctx;
} DataListCtx;

static void on_data_list_fetched(GObject* source, GAsyncResult* result, gpointer user_data)
{
    DataListCtx* ctx = (DataListCtx*)user_data;
    WebKitWebsiteDataManager* dm = WEBKIT_WEBSITE_DATA_MANAGER(source);
    GList* data_list = webkit_website_data_manager_fetch_finish(dm, result, NULL);

    GString* json = g_string_sized_new(4096);
    g_string_append_c(json, '[');
    int first = 1;
    for (GList* l = data_list; l; l = l->next) {
        WebKitWebsiteData* data = (WebKitWebsiteData*)l->data;
        const char* name = webkit_website_data_get_name(data);
        if (!name || !*name) continue;
        WebKitWebsiteDataTypes types = webkit_website_data_get_types(data);
        guint64 size = webkit_website_data_get_size(data, types);
        char esc_name[2048];
        json_escape(esc_name, sizeof(esc_name), name);
        g_string_append_printf(json, "%s{\"name\":\"%s\",\"types\":%u,\"size\":%" G_GUINT64_FORMAT "}",
            first ? "" : ",", esc_name, types, size);
        first = 0;
    }
    g_string_append_c(json, ']');

    if (data_list) g_list_free_full(data_list, (GDestroyNotify)webkit_website_data_unref);

    JSCValue* rv = jsc_value_new_string(ctx->ctx, json->str);
    webkit_script_message_reply_return_value(ctx->reply, rv);
    g_object_unref(rv);
    g_string_free(json, TRUE);

    webkit_script_message_reply_unref(ctx->reply);
    g_object_unref(ctx->ctx);
    g_free(ctx);
}

static bool data_handle_message_async(const char* json, JSCContext* ctx,
                                       WebKitScriptMessageReply* reply)
{
    const char* action = strstr(json, "\"action\"");
    if (!action) return false;
    if (!strstr(action, "\"data-list\"")) return false;

    DataListCtx* dlc = g_new0(DataListCtx, 1);
    dlc->reply = webkit_script_message_reply_ref(reply);
    dlc->ctx = (JSCContext*)g_object_ref(ctx);

    WebKitNetworkSession* session = webkit_network_session_get_default();
    WebKitWebsiteDataManager* dm = webkit_network_session_get_website_data_manager(session);
    webkit_website_data_manager_fetch(dm,
        WEBKIT_WEBSITE_DATA_COOKIES |
        WEBKIT_WEBSITE_DATA_DISK_CACHE |
        WEBKIT_WEBSITE_DATA_LOCAL_STORAGE |
        WEBKIT_WEBSITE_DATA_INDEXEDDB_DATABASES |
        WEBKIT_WEBSITE_DATA_SERVICE_WORKER_REGISTRATIONS |
        WEBKIT_WEBSITE_DATA_HSTS_CACHE |
        WEBKIT_WEBSITE_DATA_SESSION_STORAGE |
        WEBKIT_WEBSITE_DATA_DOM_CACHE,
        NULL, on_data_list_fetched, dlc);
    return true;
}

static char* data_handle_message_sync(const char* json)
{
    const char* action = strstr(json, "\"action\"");
    if (!action) return NULL;
    if (!strstr(action, "\"data-clear\"")) return NULL;

    int types = 0xFF;
    int64_t since = 0;

    const char* t_ptr = strstr(json, "\"types\"");
    if (t_ptr) {
        t_ptr += 7;
        while (*t_ptr && (*t_ptr == ' ' || *t_ptr == ':' || *t_ptr == '\t')) t_ptr++;
        types = (int)strtol(t_ptr, NULL, 10);
    }

    const char* s_ptr = strstr(json, "\"since\"");
    if (s_ptr) {
        s_ptr += 7;
        while (*s_ptr && (*s_ptr == ' ' || *s_ptr == ':' || *s_ptr == '\t')) s_ptr++;
        since = strtoll(s_ptr, NULL, 10);
    }

    const char* d_ptr = strstr(json, "\"domains\"");
    int has_domains = 0;
    if (d_ptr) {
        const char* arr = strchr(d_ptr + 9, '[');
        if (arr) {
            const char* arr_end = strchr(arr, ']');
            if (arr_end) {
                const char* p = arr + 1;
                while (p < arr_end) {
                    const char* q1 = strchr(p, '"');
                    if (!q1 || q1 >= arr_end) break;
                    q1++;
                    const char* q2 = strchr(q1, '"');
                    if (!q2 || q2 >= arr_end) break;
                    int dlen = (int)(q2 - q1);
                    if (dlen > 0 && dlen < 256) {
                        char domain[256] = {0};
                        memcpy(domain, q1, dlen);
                        engine_clear_website_data_for_domain(domain, types);
                        has_domains = 1;
                    }
                    p = q2 + 1;
                }
            }
        }
    }

    if (!has_domains) {
        engine_clear_website_data(types, since);
    }

    return g_strdup("{\"ok\":true}");
}

extern const char* setting_handle_message(const char* json);

static gboolean on_script_message(
    WebKitUserContentManager* manager,
    JSCValue* message,
    WebKitScriptMessageReply* reply,
    gpointer user_data)
{
    (void)manager; (void)user_data;

    JSCContext* ctx = jsc_value_get_context(message);
    JSCValue* json_fn = jsc_context_evaluate(ctx, "JSON.stringify", -1);
    JSCValue* json_val = jsc_value_function_call(json_fn, JSC_TYPE_VALUE, message, G_TYPE_NONE);
    char* json = jsc_value_to_string(json_val);
    g_object_unref(json_val);
    g_object_unref(json_fn);

    // 1. Try sync C handlers (history, data-clear)
    char* c_result = json ? history_handle_message(json) : NULL;
    if (!c_result && json)
        c_result = data_handle_message_sync(json);
    const char* result = c_result;

    // 2. Try async C handlers (data-list)
    if (!result && json && data_handle_message_async(json, ctx, reply)) {
        g_free(json);
        return TRUE;
    }

    // 3. Fall through to Odin handler
    if (!result && json)
        result = setting_handle_message(json);

    // 4. Sync reply
    JSCValue* rv = result
        ? jsc_value_new_string(ctx, result)
        : jsc_value_new_null(ctx);
    webkit_script_message_reply_return_value(reply, rv);
    g_object_unref(rv);
    g_free(c_result);
    g_free(json);
    return TRUE;
}

static bool serve_page_file(WebKitURISchemeRequest* request, const char* name)
{
    if (!name || !name[0]) return false;

    char lookup[256];
    if (strchr(name, '.'))
        snprintf(lookup, sizeof(lookup), "%s", name);
    else
        snprintf(lookup, sizeof(lookup), "%s/%s.html", name, name);

    const PageFile* pf = NULL;
    for (int i = 0; i < g_pages_count; i++) {
        if (strcmp(g_pages[i].path, lookup) == 0) { pf = &g_pages[i]; break; }
    }
    if (!pf) return false;

    size_t size = (size_t)(pf->end - pf->start);
    bool is_html = (strstr(pf->mime, "text/html") != NULL);

    if (is_html && g_page_theme) {
        size_t theme_len = strlen(g_page_theme);
        size_t prefix_len = 7 + theme_len + 8;
        size_t total = prefix_len + size;
        char* buf = (char*)g_malloc(total);
        memcpy(buf, "<style>", 7);
        memcpy(buf + 7, g_page_theme, theme_len);
        memcpy(buf + 7 + theme_len, "</style>", 8);
        memcpy(buf + prefix_len, pf->start, size);
        GInputStream* s = g_memory_input_stream_new_from_data(buf, total, g_free);
        webkit_uri_scheme_request_finish(request, s, total, pf->mime);
        g_object_unref(s);
    } else {
        char* copy = (char*)g_malloc(size);
        memcpy(copy, pf->start, size);
        GInputStream* s = g_memory_input_stream_new_from_data(copy, size, g_free);
        webkit_uri_scheme_request_finish(request, s, size, pf->mime);
        g_object_unref(s);
    }
    return true;
}

static void on_axium_uri_scheme(WebKitURISchemeRequest* request, gpointer data)
{
    (void)data;
    const char* uri = webkit_uri_scheme_request_get_uri(request);
    if (!uri) return;

    const char* page_path = uri + 8;

    if (serve_page_file(request, page_path))
        return;

    const char* msg = "<html><body><h1>Not Found</h1></body></html>";
    GInputStream* s = g_memory_input_stream_new_from_data(g_strdup(msg), -1, g_free);
    webkit_uri_scheme_request_finish(request, s, -1, "text/html");
    g_object_unref(s);
}

void engine_set_page_theme(const char* css_vars)
{
    free(g_page_theme);
    g_page_theme = css_vars ? strdup(css_vars) : NULL;
}

// ---------------------------------------------------------------------------
// Navigation
// ---------------------------------------------------------------------------

typedef struct {
    const char* user_agent;
    uint8_t flags;
} engine_nav_response;

extern engine_nav_response tab_on_uri(void* view, const char* uri);
extern void tab_on_title(void* view, const char* title);

static void on_uri_changed(WebKitWebView* view, GParamSpec* pspec, gpointer data)
{
    (void)pspec; (void)data;

    const char* uri = webkit_web_view_get_uri(view);
    engine_nav_response resp = tab_on_uri((void*)view, uri);

    // Record history for non-ephemeral views
    WebKitNetworkSession* session = webkit_web_view_get_network_session(view);
    if (!webkit_network_session_is_ephemeral(session))
        history_record(uri, webkit_web_view_get_title(view));

    // Apply per-view settings from the returned struct
    WebKitSettings* settings = webkit_web_view_get_settings(view);
    webkit_settings_set_enable_javascript(settings, (resp.flags & (1 << 0)) != 0);
    webkit_settings_set_javascript_can_open_windows_automatically(settings, (resp.flags & (1 << 1)) != 0);
    webkit_settings_set_enable_webrtc(settings, (resp.flags & (1 << 2)) != 0);
    webkit_settings_set_enable_webgl(settings, (resp.flags & (1 << 3)) != 0);
    webkit_settings_set_enable_media_stream(settings, (resp.flags & (1 << 4)) != 0);

    int autoplay = (resp.flags >> 6) & 3;
    webkit_settings_set_media_playback_requires_user_gesture(settings, autoplay < 2);

    if (resp.user_agent && resp.user_agent[0])
        webkit_settings_set_user_agent(settings, resp.user_agent);

    // Adblock -- send enable/disable to web process extension
    bool adblock = (resp.flags & (1 << 5)) != 0;
    WebKitUserMessage* msg = webkit_user_message_new(
        "adblock-set-disabled", g_variant_new_boolean(!adblock));
    webkit_web_view_send_message_to_page(view, msg, NULL, NULL, NULL);
}

static void on_title_changed(WebKitWebView* view, GParamSpec* pspec, gpointer data)
{
    (void)pspec; (void)data;
    const char* uri = webkit_web_view_get_uri(view);
    const char* title = webkit_web_view_get_title(view);

    WebKitNetworkSession* session = webkit_web_view_get_network_session(view);
    if (!webkit_network_session_is_ephemeral(session))
        history_update_title(uri, title);

    tab_on_title((void*)view, title);
}

void engine_go_back(void)
{
    if (g_active_view && webkit_web_view_can_go_back(g_active_view))
        webkit_web_view_go_back(g_active_view);
}

void engine_go_forward(void)
{
    if (g_active_view && webkit_web_view_can_go_forward(g_active_view))
        webkit_web_view_go_forward(g_active_view);
}

void engine_reload(void)
{
    if (g_active_view)
        webkit_web_view_reload(g_active_view);
}

// ---------------------------------------------------------------------------
// Input events
// ---------------------------------------------------------------------------

static WPEView* get_wpe_view(void)
{
    if (!g_active_view) return NULL;
    return webkit_web_view_get_wpe_view(g_active_view);
}

static guint32 now_ms(void)
{
    return (guint32)(g_get_monotonic_time() / 1000);
}

static WPEModifiers g_modifiers = 0;

void engine_send_key(uint32_t keyval, bool pressed)
{
    WPEView* view = get_wpe_view();
    if (!view) return;

    WPEModifiers flag = 0;
    switch (keyval) {
    case 0xffe1: case 0xffe2: flag = WPE_MODIFIER_KEYBOARD_SHIFT;   break;
    case 0xffe3: case 0xffe4: flag = WPE_MODIFIER_KEYBOARD_CONTROL; break;
    case 0xffe9: case 0xffea: flag = WPE_MODIFIER_KEYBOARD_ALT;     break;
    case 0xffeb: case 0xffec: flag = WPE_MODIFIER_KEYBOARD_META;    break;
    }
    if (flag) {
        if (pressed) g_modifiers |= flag;
        else         g_modifiers &= ~flag;
    }

    WPEEvent* event = wpe_event_keyboard_new(
        pressed ? WPE_EVENT_KEYBOARD_KEY_DOWN : WPE_EVENT_KEYBOARD_KEY_UP,
        view,
        WPE_INPUT_SOURCE_KEYBOARD,
        now_ms(),
        g_modifiers,
        0,
        keyval);
    wpe_view_event(view, event);
    wpe_event_unref(event);
}

void engine_send_mouse_button(uint32_t button, bool pressed, double x, double y)
{
    WPEView* view = get_wpe_view();
    if (!view) return;

    guint32 ts = now_ms();
    guint press_count = pressed ? wpe_view_compute_press_count(view, x, y, button, ts) : 0;

    WPEEvent* event = wpe_event_pointer_button_new(
        pressed ? WPE_EVENT_POINTER_DOWN : WPE_EVENT_POINTER_UP,
        view,
        WPE_INPUT_SOURCE_MOUSE,
        ts,
        g_modifiers,
        button,
        x, y,
        press_count);
    wpe_view_event(view, event);
    wpe_event_unref(event);

    WPEModifiers flag = 0;
    switch (button) {
    case 1: flag = WPE_MODIFIER_POINTER_BUTTON1; break;
    case 2: flag = WPE_MODIFIER_POINTER_BUTTON2; break;
    case 3: flag = WPE_MODIFIER_POINTER_BUTTON3; break;
    }
    if (flag) {
        if (pressed) g_modifiers |= flag;
        else         g_modifiers &= ~flag;
    }
}

static double g_last_x = 0, g_last_y = 0;

void engine_send_mouse_move(double x, double y)
{
    WPEView* view = get_wpe_view();
    if (!view) return;

    double dx = x - g_last_x;
    double dy = y - g_last_y;
    g_last_x = x;
    g_last_y = y;

    WPEEvent* event = wpe_event_pointer_move_new(
        WPE_EVENT_POINTER_MOVE,
        view,
        WPE_INPUT_SOURCE_MOUSE,
        now_ms(),
        g_modifiers,
        x, y,
        dx, dy);
    wpe_view_event(view, event);
    wpe_event_unref(event);
}

void engine_send_scroll(double x, double y, double delta_x, double delta_y)
{
    WPEView* view = get_wpe_view();
    if (!view) return;

    WPEEvent* event = wpe_event_scroll_new(
        view,
        WPE_INPUT_SOURCE_MOUSE,
        now_ms(),
        g_modifiers,
        delta_x,
        delta_y,
        FALSE,
        FALSE,
        x, y);
    wpe_view_event(view, event);
    wpe_event_unref(event);
}

void engine_send_focus(bool focused)
{
    WPEView* view = get_wpe_view();
    if (!view) return;

    if (focused)
        wpe_view_focus_in(view);
    else
        wpe_view_focus_out(view);
}

int engine_get_cursor(void)
{
    if (g_cursor == g_cursor_prev)
        return -1;
    g_cursor_prev = g_cursor;
    return g_cursor;
}

void engine_editing_command(const char* command, const char* argument)
{
    WebKitWebView* wv = g_active_view;
    if (!wv || !command) return;
    if (argument)
        webkit_web_view_execute_editing_command_with_argument(wv, command, argument);
    else
        webkit_web_view_execute_editing_command(wv, command);
}

// ---------------------------------------------------------------------------
// Context menu
// ---------------------------------------------------------------------------

#define CTX_ACTION_SLOTS (WEBKIT_CONTEXT_MENU_ACTION_DOWNLOAD_AUDIO_TO_DISK + 1)
static GAction* g_ctx_actions[CTX_ACTION_SLOTS];
static uint64_t g_ctx_available = 0;

extern void on_context_menu_event(uint64_t actions, int x, int y);

static gboolean on_context_menu(WebKitWebView* web_view,
                                 WebKitContextMenu* menu,
                                 WebKitHitTestResult* hit,
                                 gpointer user_data)
{
    for (int i = 0; i < CTX_ACTION_SLOTS; i++) {
        if (g_ctx_actions[i]) {
            g_object_unref(g_ctx_actions[i]);
            g_ctx_actions[i] = NULL;
        }
    }
    g_ctx_available = 0;

    GList* items = webkit_context_menu_get_items(menu);
    for (GList* l = items; l; l = l->next) {
        WebKitContextMenuItem* it = (WebKitContextMenuItem*)l->data;
        int idx = (int)webkit_context_menu_item_get_stock_action(it);
        if (idx <= 0 || idx >= CTX_ACTION_SLOTS) continue;
        GAction* ga = webkit_context_menu_item_get_gaction(it);
        if (!ga) continue;
        g_ctx_actions[idx] = (GAction*)g_object_ref(ga);
        g_ctx_available |= (1ULL << idx);
    }

    on_context_menu_event(g_ctx_available,
                          (int)g_last_x + g_target_x,
                          (int)g_last_y + g_target_y);
    return TRUE;
}

void engine_context_menu_activate(int action)
{
    if (action >= 0 && action < CTX_ACTION_SLOTS && g_ctx_actions[action])
        g_action_activate(g_ctx_actions[action], NULL);
}

// ---------------------------------------------------------------------------
// View management
// ---------------------------------------------------------------------------

static void on_web_process_terminated(WebKitWebView* view,
                                       WebKitWebProcessTerminationReason reason,
                                       gpointer user_data)
{
    (void)view; (void)user_data;
    const char* reason_str = (reason == WEBKIT_WEB_PROCESS_CRASHED) ? "CRASHED" :
                             (reason == WEBKIT_WEB_PROCESS_EXCEEDED_MEMORY_LIMIT) ? "OOM" :
                             (reason == WEBKIT_WEB_PROCESS_TERMINATED_BY_API) ? "API" : "UNKNOWN";
    fprintf(stderr, "[axium] web process terminated: %s\n", reason_str);
}

static gboolean on_decide_policy(WebKitWebView* view,
                                  WebKitPolicyDecision* decision,
                                  WebKitPolicyDecisionType type,
                                  gpointer data)
{
    if (type != WEBKIT_POLICY_DECISION_TYPE_RESPONSE)
        return FALSE;

    WebKitResponsePolicyDecision* resp = WEBKIT_RESPONSE_POLICY_DECISION(decision);
    if (!webkit_response_policy_decision_is_mime_type_supported(resp)) {
        webkit_policy_decision_download(decision);
        return TRUE;
    }
    return FALSE;
}

void* engine_create_view(int width, int height, bool ephemeral, void* related_view)
{
    if (!g_display) return NULL;

    WebKitWebView* wv;
    if (ephemeral) {
        if (!g_ephemeral_session) {
            g_ephemeral_session = webkit_network_session_new_ephemeral();
            WebKitCookieManager* cm = webkit_network_session_get_cookie_manager(g_ephemeral_session);
            webkit_cookie_manager_set_accept_policy(cm, WEBKIT_COOKIE_POLICY_ACCEPT_NO_THIRD_PARTY);
            webkit_network_session_set_itp_enabled(g_ephemeral_session, true);
            g_signal_connect(g_ephemeral_session, "download-started",
                             G_CALLBACK(on_download_started), NULL);
        }
        wv = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,
                                           "display", g_display,
                                           "network-session", g_ephemeral_session,
                                           "user-content-manager", g_content_manager,
                                           NULL));
    } else if (related_view) {
        wv = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,
                                           "related-view", (WebKitWebView*)related_view,
                                           "user-content-manager", g_content_manager,
                                           NULL));
    } else {
        wv = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,
                                           "display", g_display,
                                           "user-content-manager", g_content_manager,
                                           NULL));
    }
    if (!wv)
        return NULL;

    if (g_bg_color_set) {
        WebKitColor color;
        color.red   = ((g_bg_rgb >> 16) & 0xFF) / 255.0;
        color.green = ((g_bg_rgb >>  8) & 0xFF) / 255.0;
        color.blue  = ( g_bg_rgb        & 0xFF) / 255.0;
        color.alpha = g_bg_opacity / 255.0;
        webkit_web_view_set_background_color(wv, &color);
    }
    g_signal_connect(wv, "decide-policy",
                     G_CALLBACK(on_decide_policy), NULL);
    g_signal_connect(wv, "web-process-terminated",
                     G_CALLBACK(on_web_process_terminated), NULL);
    g_signal_connect(wv, "notify::uri",
                     G_CALLBACK(on_uri_changed), NULL);
    g_signal_connect(wv, "notify::title",
                     G_CALLBACK(on_title_changed), NULL);
    g_signal_connect(wv, "permission-request",
                     G_CALLBACK(on_permission_request), NULL);
    g_signal_connect(wv, "query-permission-state",
                     G_CALLBACK(on_query_permission_state), NULL);
    g_signal_connect(wv, "load-failed-with-tls-errors",
                     G_CALLBACK(on_tls_error), NULL);
    g_signal_connect(wv, "context-menu",
                     G_CALLBACK(on_context_menu), NULL);

    WPEView* wpe_view = webkit_web_view_get_wpe_view(wv);
    if (!wpe_view) {
        g_clear_object(&wv);
        return NULL;
    }

    wpe_view_set_toplevel(wpe_view, g_toplevel);
    wpe_view_set_visible(wpe_view, FALSE);

    return (void*)wv;
}

void engine_destroy_view(void* view)
{
    if (!view) return;
    WebKitWebView* wv = (WebKitWebView*)view;
    if (g_active_view == wv)
        g_active_view = NULL;
    g_object_unref(wv);
}

void engine_set_active_view(void* view)
{
    if (!view) return;
    WebKitWebView* nv = (WebKitWebView*)view;

    if (g_active_view && g_active_view != nv) {
        WPEView* ov = webkit_web_view_get_wpe_view(g_active_view);
        if (ov) {
            wpe_view_focus_out(ov);
            wpe_view_set_visible(ov, FALSE);
        }
    }

    g_active_view = nv;

    WPEView* v = webkit_web_view_get_wpe_view(nv);
    if (v) {
        wpe_view_set_visible(v, TRUE);
        wpe_view_focus_in(v);
    }
}

void engine_view_go_to(void* view, const char* uri)
{
    if (!view || !uri) return;
    webkit_web_view_load_uri((WebKitWebView*)view, uri);
}

void engine_resize(int width, int height)
{
    if (g_toplevel)
        wpe_toplevel_resize(g_toplevel, width, height);
}

// ---------------------------------------------------------------------------
// Frame — pump GLib, blit WebKit buffer into framebuffer
// ---------------------------------------------------------------------------

static AxiumView* get_axium_view(void)
{
    if (!g_active_view) return NULL;
    WPEView* wpe_view = webkit_web_view_get_wpe_view(g_active_view);
    if (!wpe_view) return NULL;
    if (!g_type_is_a(G_OBJECT_TYPE(wpe_view), AXIUM_TYPE_VIEW)) return NULL;
    return AXIUM_VIEW(wpe_view);
}

void engine_pump(void)
{
    while (g_main_context_iteration(NULL, FALSE)) {}
}

void engine_grab_frame(void)
{
    AxiumView* view = get_axium_view();
    if (!view || !view->committed_buffer || !g_frame_target) return;

    WPEBuffer* buffer = view->committed_buffer;
    int w = wpe_buffer_get_width(buffer);
    int h = wpe_buffer_get_height(buffer);

    GError* err = NULL;
    GBytes* pix = wpe_buffer_import_to_pixels(buffer, &err);
    if (!pix) { g_clear_error(&err); return; }

    int src_stride;
    if (WPE_IS_BUFFER_SHM(buffer)) {
        src_stride = (int)wpe_buffer_shm_get_stride(WPE_BUFFER_SHM(buffer));
    } else {
        gsize sz = g_bytes_get_size(pix);
        src_stride = (h > 0) ? (int)(sz / h) : w * 4;
    }

    gsize pix_size = 0;
    const uint8_t* src = (const uint8_t*)g_bytes_get_data(pix, &pix_size);
    if (!src || w <= 0 || h <= 0) return;

    int copy_w = (w < g_target_w ? w : g_target_w) * 4;
    int copy_h = h < g_target_h ? h : g_target_h;

    for (int y = 0; y < copy_h; y++) {
        const uint8_t* s = src + y * src_stride;
        uint8_t* d = g_frame_target + (g_target_y + y) * g_target_stride + g_target_x * 4;
        memcpy(d, s, copy_w);
    }
}

void engine_set_frame_target(uint8_t* buffer, int buf_stride,
                              int x, int y, int w, int h)
{
    g_frame_target = buffer;
    g_target_stride = buf_stride;
    g_target_x = x;
    g_target_y = y;
    g_target_w = w;
    g_target_h = h;
}

// ---------------------------------------------------------------------------
// Background color + opacity
// ---------------------------------------------------------------------------

void engine_set_bg(uint32_t rgb, int opacity)
{
    g_bg_rgb = rgb;
    g_bg_opacity = opacity;
    g_bg_color_set = true;

    // Inject page background opacity script if not fully opaque
    if (opacity < 255 && g_content_manager) {
        float alpha = opacity / 255.0f;
        char script[1024];
        snprintf(script, sizeof(script),
            "(function(A){"
              "function p(e){"
                "var b=getComputedStyle(e).backgroundColor;"
                "if(!b||b==='transparent'||b==='rgba(0, 0, 0, 0)')return;"
                "var m=b.match(/rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)/);"
                "if(m)e.style.backgroundColor='rgba('+m[1]+','+m[2]+','+m[3]+','+A+')';"
              "}"
              "function r(){"
                "if(document.documentElement)p(document.documentElement);"
                "if(document.body)p(document.body);"
              "}"
              "r();"
              "new MutationObserver(r).observe(document.documentElement,"
                "{attributes:true,attributeFilter:['style','class'],childList:true});"
            "})(%.4f);", alpha);

        WebKitUserScript* us = webkit_user_script_new(
            script,
            WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES,
            WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END,
            NULL, NULL);
        webkit_user_content_manager_add_script(g_content_manager, us);
        webkit_user_script_unref(us);
    }
}

// ---------------------------------------------------------------------------
// Screen info
// ---------------------------------------------------------------------------

void engine_set_screen_info(int width, int height,
                            int phys_w_mm, int phys_h_mm,
                            int refresh_rate_mhz, double scale)
{
    if (!g_display) return;
    AxiumDisplay* self = AXIUM_DISPLAY(g_display);

    WPEScreen* scr = WPE_SCREEN(g_object_new(AXIUM_TYPE_SCREEN, "id", 1, NULL));
    wpe_screen_set_size(scr, width, height);
    wpe_screen_set_physical_size(scr, phys_w_mm, phys_h_mm);
    if (refresh_rate_mhz > 0)
        wpe_screen_set_refresh_rate(scr, refresh_rate_mhz);
    wpe_screen_set_scale(scr, scale);

    self->screen = scr;
    wpe_display_screen_added(g_display, scr);
}

// ---------------------------------------------------------------------------
// Init / Shutdown
// ---------------------------------------------------------------------------

bool engine_init(void)
{
    g_display = WPE_DISPLAY(g_object_new(AXIUM_TYPE_DISPLAY, NULL));
    GError* error = NULL;
    if (!wpe_display_connect(g_display, &error)) {
        g_clear_error(&error);
        g_clear_object(&g_display);
        return false;
    }

    // Single shared toplevel for all views (tabbed browser)
    WPESettings* settings = wpe_display_get_settings(g_display);
    wpe_settings_set_boolean(settings, WPE_SETTING_CREATE_VIEWS_WITH_A_TOPLEVEL, FALSE, WPE_SETTINGS_SOURCE_APPLICATION, NULL);
    g_toplevel = WPE_TOPLEVEL(g_object_new(AXIUM_TYPE_TOPLEVEL, "display", g_display, "max-views", 0, NULL));

    // Connect download handler to default session
    WebKitNetworkSession* session = webkit_network_session_get_default();
    g_signal_connect(session, "download-started",
                     G_CALLBACK(on_download_started), NULL);

    // Content manager (script message handlers)
    g_content_manager = webkit_user_content_manager_new();
    webkit_user_content_manager_register_script_message_handler_with_reply(
        g_content_manager, "axium", NULL);
    g_signal_connect(g_content_manager,
        "script-message-with-reply-received::axium",
        G_CALLBACK(on_script_message), NULL);

    // Register axium:// URI scheme
    WebKitWebContext* ctx = webkit_web_context_get_default();
    webkit_web_context_register_uri_scheme(ctx, "axium", on_axium_uri_scheme, NULL, NULL);
    WebKitSecurityManager* sec = webkit_web_context_get_security_manager(ctx);
    webkit_security_manager_register_uri_scheme_as_local(sec, "axium");
    webkit_security_manager_register_uri_scheme_as_secure(sec, "axium");

    return true;
}

void engine_shutdown(void)
{
    history_close();
    g_active_view = NULL;
    g_clear_object(&g_ephemeral_session);
    g_clear_object(&g_display);
    g_free(g_adblock_dir);
    g_adblock_dir = NULL;
    g_free(g_download_dir);
    g_download_dir = NULL;
    g_download_count = 0;
    for (int i = 0; i < g_tls_allowed_count; i++)
        g_free(g_tls_allowed_hosts[i]);
    g_tls_allowed_count = 0;
    free(g_page_theme);
    g_page_theme = NULL;
    g_clear_object(&g_content_manager);
}
