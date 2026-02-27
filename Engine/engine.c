// WPE2 Engine Shim - CPU-only SHM pixel output
// GObject subclasses for WPE2 + raw pixel extraction via SharedMemory path

#include "engine.h"

#include <wpe/wpe-platform.h>
#include <wpe/webkit.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------------------
// Forward declarations
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
    return WPE_TOPLEVEL(g_object_new(AXIUM_TYPE_TOPLEVEL, "display", display, NULL));
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

static WPEClipboard* axium_display_get_clipboard(WPEDisplay* display)
{
    return WPE_CLIPBOARD(g_object_new(AXIUM_TYPE_CLIPBOARD, "display", display, NULL));
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
// AxiumClipboard - bridges WPE clipboard ↔ Display-Onix (X11)
// ---------------------------------------------------------------------------
typedef struct {
    WPEClipboard parent_instance;
} AxiumClipboard;

typedef struct {
    WPEClipboardClass parent_class;
} AxiumClipboardClass;

G_DEFINE_TYPE(AxiumClipboard, axium_clipboard, WPE_TYPE_CLIPBOARD)

static engine_clipboard_set_fn g_clipboard_set = NULL;
static engine_clipboard_get_fn g_clipboard_get = NULL;

static GBytes* axium_clipboard_read(WPEClipboard* clipboard, const char* format)
{
    (void)clipboard;
    if (!g_clipboard_get) return NULL;
    if (strcmp(format, "text/plain") != 0 &&
        strcmp(format, "text/plain;charset=utf-8") != 0)
        return NULL;

    const char* text = g_clipboard_get();
    if (!text || !*text) return NULL;

    return g_bytes_new(text, strlen(text));
}

static void axium_clipboard_changed(WPEClipboard* clipboard, GPtrArray* formats,
                                     gboolean isLocal, WPEClipboardContent* content)
{
    if (isLocal && content && g_clipboard_set) {
        const char* text = wpe_clipboard_content_get_text(content);
        if (text)
            g_clipboard_set(text);
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

    // Buffer lifecycle — two-stage: pending → committed
    WPEBuffer* committed_buffer;   // currently "on screen"
    WPEBuffer* pending_buffer;     // waiting to be promoted by idle cb
    guint      frame_source_id;    // idle source, 0 = not scheduled

} AxiumView;

typedef struct {
    WPEViewClass parent_class;
} AxiumViewClass;

G_DEFINE_TYPE(AxiumView, axium_view, WPE_TYPE_VIEW)

// Direct render target — set by Odin, written by render_buffer
static uint8_t* g_frame_target = NULL;
static int g_target_stride = 0;
static int g_target_x = 0, g_target_y = 0;
static int g_target_w = 0, g_target_h = 0;

// Deferred callback — runs on the next main-loop iteration, OUTSIDE the
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

    // Promote pending → committed
    self->committed_buffer = self->pending_buffer;
    self->pending_buffer = NULL;

    // Signal that the buffer was rendered — this sends FrameDone IPC to the
    // web process, allowing it to produce the next frame.
    wpe_view_buffer_rendered(view, self->committed_buffer);

    return G_SOURCE_REMOVE;
}

static gboolean axium_view_render_buffer(WPEView* view, WPEBuffer* buffer,
                                          const WPERectangle* damage_rects,
                                          guint n_damage_rects, GError** error)
{
    AxiumView* self = AXIUM_VIEW(view);

store_pending:
    // If a previous pending buffer was never processed, release it now
    if (self->pending_buffer) {
        wpe_view_buffer_released(view, self->pending_buffer);
        g_object_unref(self->pending_buffer);
    }

    // Store this buffer as pending — the idle callback will promote it
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

    // Set ACTIVE + focus AFTER view-toplevel connection exists
    wpe_toplevel_state_changed(toplevel, WPE_TOPLEVEL_STATE_ACTIVE);
    wpe_view_focus_in(view);
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

// Cursor — map CSS cursor names to integer codes exposed to Odin
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
        else if (name[1] == 'e' || name[1] == 'w') c = 2; // "ne-resize", "nw-resize" → crosshair
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
// AxiumScreen — concrete subclass of WPEScreen (which is abstract/derivable)
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

// ---------------------------------------------------------------------------
// Engine state
// ---------------------------------------------------------------------------
static WPEDisplay*    g_display  = NULL;

#define MAX_VIEWS 32
static WebKitWebView* g_views[MAX_VIEWS];
static int g_view_count = 0;
static int g_active_view = -1;

static engine_uri_changed_fn g_uri_changed_cb = NULL;
static engine_title_changed_fn g_title_changed_cb = NULL;

static WebKitWebView* active_web_view(void)
{
    if (g_active_view < 0 || g_active_view >= g_view_count) return NULL;
    return g_views[g_active_view];
}

static void on_uri_changed(WebKitWebView* view, GParamSpec* pspec, gpointer data)
{
    (void)pspec; (void)data;
    if (view == active_web_view() && g_uri_changed_cb)
        g_uri_changed_cb(webkit_web_view_get_uri(view));
}

static void on_title_changed(WebKitWebView* view, GParamSpec* pspec, gpointer data)
{
    (void)pspec; (void)data;
    if (view == active_web_view() && g_title_changed_cb)
        g_title_changed_cb(webkit_web_view_get_title(view));
}

static AxiumView* get_axium_view(void)
{
    WebKitWebView* wv = active_web_view();
    if (!wv) return NULL;
    WPEView* wpe_view = webkit_web_view_get_wpe_view(wv);
    if (!wpe_view) return NULL;
    if (!g_type_is_a(G_OBJECT_TYPE(wpe_view), AXIUM_TYPE_VIEW)) return NULL;
    return AXIUM_VIEW(wpe_view);
}

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

// ---------------------------------------------------------------------------
// Public API
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
    return true;
}

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
// Adblock web process extension setup
// ---------------------------------------------------------------------------

static char* g_adblock_dir = NULL;

static void on_initialize_web_process_extensions(WebKitWebContext* context,
                                                  gpointer data)
{
    (void)data;
    const char* ext_dir = (const char*)g_object_get_data(G_OBJECT(context), "axium-ext-dir");
    if (ext_dir)
        webkit_web_context_set_web_process_extensions_directory(context, ext_dir);
    if (g_adblock_dir)
        webkit_web_context_set_web_process_extensions_initialization_user_data(
            context, g_variant_new_string(g_adblock_dir));
}

void engine_init_adblock(const char* ext_dir, const char* adblock_dir)
{
    if (!ext_dir || !adblock_dir)
        return;

    g_adblock_dir = g_strdup(adblock_dir);

    WebKitWebContext* ctx = webkit_web_context_get_default();
    g_object_set_data_full(G_OBJECT(ctx), "axium-ext-dir",
                           g_strdup(ext_dir), g_free);
    g_signal_connect(ctx, "initialize-web-process-extensions",
                     G_CALLBACK(on_initialize_web_process_extensions), NULL);
}

int engine_create_view(int width, int height)
{
    if (!g_display || g_view_count >= MAX_VIEWS) return -1;

    WebKitWebView* wv;
    if (g_view_count > 0 && g_views[0]) {
        wv = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,
                                           "related-view", g_views[0],
                                           NULL));
    } else {
        wv = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,
                                           "display", g_display, NULL));
    }
    if (!wv)
        return -1;

    g_signal_connect(wv, "web-process-terminated",
                     G_CALLBACK(on_web_process_terminated), NULL);
    g_signal_connect(wv, "notify::uri",
                     G_CALLBACK(on_uri_changed), NULL);
    g_signal_connect(wv, "notify::title",
                     G_CALLBACK(on_title_changed), NULL);

    WPEView* wpe_view = webkit_web_view_get_wpe_view(wv);
    if (!wpe_view) {
        g_clear_object(&wv);
        return -1;
    }

    WPEToplevel* toplevel = wpe_view_get_toplevel(wpe_view);
    if (toplevel)
        wpe_toplevel_resize(toplevel, width, height);

    int idx = g_view_count;
    g_views[idx] = wv;
    g_view_count++;
    return idx;
}

void engine_destroy_view(int index)
{
    if (index < 0 || index >= g_view_count) return;

    g_clear_object(&g_views[index]);

    // Compact array
    for (int i = index; i < g_view_count - 1; i++)
        g_views[i] = g_views[i + 1];
    g_views[g_view_count - 1] = NULL;
    g_view_count--;

    // Adjust active index
    if (g_active_view == index)
        g_active_view = -1;
    else if (g_active_view > index)
        g_active_view--;
}

void engine_set_active_view(int index)
{
    if (index < 0 || index >= g_view_count) return;

    // Focus out old view
    if (g_active_view >= 0 && g_active_view < g_view_count && g_active_view != index) {
        WebKitWebView* old = g_views[g_active_view];
        if (old) {
            WPEView* ov = webkit_web_view_get_wpe_view(old);
            if (ov) wpe_view_focus_out(ov);
        }
    }

    g_active_view = index;

    // Focus in new view
    WebKitWebView* nv = g_views[index];
    if (nv) {
        WPEView* v = webkit_web_view_get_wpe_view(nv);
        if (v) wpe_view_focus_in(v);

        // Notify Odin of new tab's URI and title
        if (g_uri_changed_cb)
            g_uri_changed_cb(webkit_web_view_get_uri(nv));
        if (g_title_changed_cb)
            g_title_changed_cb(webkit_web_view_get_title(nv));
    }
}

void engine_view_get_uri(int index, const char** uri)
{
    *uri = NULL;
    if (index >= 0 && index < g_view_count && g_views[index])
        *uri = webkit_web_view_get_uri(g_views[index]);
}

void engine_view_get_title(int index, const char** title)
{
    *title = NULL;
    if (index >= 0 && index < g_view_count && g_views[index])
        *title = webkit_web_view_get_title(g_views[index]);
}

int engine_view_count(void)
{
    return g_view_count;
}

int engine_active_view(void)
{
    return g_active_view;
}

void engine_load_uri(const char* uri)
{
    WebKitWebView* wv = active_web_view();
    if (wv)
        webkit_web_view_load_uri(wv, uri);
}

void engine_resize(int width, int height)
{
    WebKitWebView* wv = active_web_view();
    if (!wv) return;
    WPEView* wpe_view = webkit_web_view_get_wpe_view(wv);
    if (!wpe_view) return;
    WPEToplevel* toplevel = wpe_view_get_toplevel(wpe_view);
    if (toplevel)
        wpe_toplevel_resize(toplevel, width, height);
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
// Input events — modifier state tracked internally
// ---------------------------------------------------------------------------

static WPEView* get_wpe_view(void)
{
    WebKitWebView* wv = active_web_view();
    if (!wv) return NULL;
    return webkit_web_view_get_wpe_view(wv);
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

    // Update keyboard modifier state based on keysym
    WPEModifiers flag = 0;
    switch (keyval) {
    case 0xffe1: case 0xffe2: flag = WPE_MODIFIER_KEYBOARD_SHIFT;   break; // Shift_L/R
    case 0xffe3: case 0xffe4: flag = WPE_MODIFIER_KEYBOARD_CONTROL; break; // Ctrl_L/R
    case 0xffe9: case 0xffea: flag = WPE_MODIFIER_KEYBOARD_ALT;     break; // Alt_L/R
    case 0xffeb: case 0xffec: flag = WPE_MODIFIER_KEYBOARD_META;    break; // Super_L/R
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
        0,        // hardware keycode — not available from Display-Onix
        keyval);  // X11 keysym
    wpe_view_event(view, event);
    wpe_event_unref(event);
}

void engine_send_mouse_button(uint32_t button, bool pressed, double x, double y)
{
    WPEView* view = get_wpe_view();
    if (!view) return;

    guint32 ts = now_ms();
    guint press_count = pressed ? wpe_view_compute_press_count(view, x, y, button, ts) : 0;

    // Send event with pre-press/release modifier state
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

    // Update button modifier state AFTER sending the event
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
        FALSE,          // not precise (discrete scroll wheel)
        FALSE,          // not a stop event
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
    WebKitWebView* wv = active_web_view();
    if (!wv || !command) return;
    if (argument)
        webkit_web_view_execute_editing_command_with_argument(wv, command, argument);
    else
        webkit_web_view_execute_editing_command(wv, command);
}

void engine_set_clipboard_callbacks(engine_clipboard_set_fn set_fn,
                                           engine_clipboard_get_fn get_fn)
{
    g_clipboard_set = set_fn;
    g_clipboard_get = get_fn;
}

void engine_set_navigation_callbacks(engine_uri_changed_fn uri_fn,
                                     engine_title_changed_fn title_fn)
{
    g_uri_changed_cb = uri_fn;
    g_title_changed_cb = title_fn;
}

void engine_go_back(void)
{
    WebKitWebView* wv = active_web_view();
    if (wv && webkit_web_view_can_go_back(wv))
        webkit_web_view_go_back(wv);
}

void engine_go_forward(void)
{
    WebKitWebView* wv = active_web_view();
    if (wv && webkit_web_view_can_go_forward(wv))
        webkit_web_view_go_forward(wv);
}

void engine_reload(void)
{
    WebKitWebView* wv = active_web_view();
    if (wv)
        webkit_web_view_reload(wv);
}

void engine_get_uri(const char** uri)
{
    *uri = NULL;
    WebKitWebView* wv = active_web_view();
    if (wv)
        *uri = webkit_web_view_get_uri(wv);
}

void engine_get_title(const char** title)
{
    *title = NULL;
    WebKitWebView* wv = active_web_view();
    if (wv)
        *title = webkit_web_view_get_title(wv);
}

void engine_run_javascript(const char* script)
{
    WebKitWebView* wv = active_web_view();
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
    WebKitWebView* wv = active_web_view();
    if (!wv || !script) {
        if (callback) callback(NULL);
        return;
    }
    webkit_web_view_evaluate_javascript(wv, script, -1, NULL, NULL, NULL,
                                        js_eval_finished, (gpointer)callback);
}

void engine_shutdown(void)
{
    for (int i = 0; i < g_view_count; i++)
        g_clear_object(&g_views[i]);
    g_view_count = 0;
    g_active_view = -1;
    g_clear_object(&g_display);
    g_free(g_adblock_dir);
    g_adblock_dir = NULL;
}
