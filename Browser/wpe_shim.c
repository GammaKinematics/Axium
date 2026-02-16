// WPE2 Engine Shim - GObject subclasses + DMA-BUF import
// Provides a simple C API for the Odin browser to drive WebKit

#include "wpe_shim.h"

#include <wpe/wpe-platform.h>
#include <wpe/webkit.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/gl.h>

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <drm_fourcc.h>

// GL_OES_EGL_image extension
#ifndef GL_OES_EGL_image
typedef void* GLeglImageOES;
#endif
typedef void (*PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)(GLenum target, GLeglImageOES image);
static PFNGLEGLIMAGETARGETTEXTURE2DOESPROC pfn_glEGLImageTargetTexture2DOES = NULL;

// EGL extension function pointers for DRM device discovery and DMA-BUF format query
static PFNEGLQUERYDISPLAYATTRIBEXTPROC pfn_eglQueryDisplayAttribEXT = NULL;
static PFNEGLQUERYDEVICESTRINGEXTPROC pfn_eglQueryDeviceStringEXT = NULL;
static PFNEGLQUERYDMABUFFORMATSEXTPROC pfn_eglQueryDmaBufFormatsEXT = NULL;
static PFNEGLQUERYDMABUFMODIFIERSEXTPROC pfn_eglQueryDmaBufModifiersEXT = NULL;

// ---------------------------------------------------------------------------
// Forward declarations
// ---------------------------------------------------------------------------
static GType axium_display_get_type(void);
static GType axium_view_get_type(void);
static GType axium_toplevel_get_type(void);

#define AXIUM_TYPE_DISPLAY  (axium_display_get_type())
#define AXIUM_TYPE_VIEW     (axium_view_get_type())
#define AXIUM_TYPE_TOPLEVEL (axium_toplevel_get_type())
#define AXIUM_DISPLAY(obj)  (G_TYPE_CHECK_INSTANCE_CAST((obj), AXIUM_TYPE_DISPLAY, AxiumDisplay))
#define AXIUM_VIEW(obj)     (G_TYPE_CHECK_INSTANCE_CAST((obj), AXIUM_TYPE_VIEW, AxiumView))
#define AXIUM_TOPLEVEL(obj) (G_TYPE_CHECK_INSTANCE_CAST((obj), AXIUM_TYPE_TOPLEVEL, AxiumToplevel))

// ---------------------------------------------------------------------------
// Diagnostic: force SharedMemory mode (bypasses DMA-BUF entirely)
// When enabled, get_drm_device returns NULL and get_preferred_buffer_formats
// returns NULL. This forces the web process to use PlatformDisplaySurfaceless
// and SharedMemory SwapChain (glReadPixels path instead of GBM BOs).
// ---------------------------------------------------------------------------
#define FORCE_SHM_MODE 1

// ---------------------------------------------------------------------------
// Diagnostic state (declared early so GObject methods can use them)
// ---------------------------------------------------------------------------
static int              g_frame_count = 0;
static bool             g_page_loaded = false;
static int              g_pump_count = 0;
static int              g_first_content_frame = -1;

// ---------------------------------------------------------------------------
// AxiumDisplay
// ---------------------------------------------------------------------------
typedef struct _AxiumDisplay AxiumDisplay;
typedef struct _AxiumDisplayClass AxiumDisplayClass;

typedef struct {
    uint32_t fourcc;
    uint64_t modifier;
} DmaBufFormat;

struct _AxiumDisplay {
    WPEDisplay parent_instance;
    EGLDisplay egl_display;
    WPEDRMDevice *drm_device;
    DmaBufFormat *dmabuf_formats;
    int n_dmabuf_formats;
};

struct _AxiumDisplayClass {
    WPEDisplayClass parent_class;
};

G_DEFINE_TYPE(AxiumDisplay, axium_display, WPE_TYPE_DISPLAY)

static gboolean axium_display_connect(WPEDisplay* display, GError** error)
{
    AxiumDisplay* self = AXIUM_DISPLAY(display);

    // Use GLFW's EGL display (must be current on this thread)
    self->egl_display = eglGetCurrentDisplay();
    if (self->egl_display == EGL_NO_DISPLAY) {
        g_set_error_literal(error, WPE_DISPLAY_ERROR, WPE_DISPLAY_ERROR_CONNECTION_FAILED,
                            "No current EGL display (GLFW context not active?)");
        return FALSE;
    }

    fprintf(stderr, "[axium-engine] Using GLFW's EGL display (%p): %s\n",
            self->egl_display, eglQueryString(self->egl_display, EGL_VERSION));

    const char* egl_exts = eglQueryString(self->egl_display, EGL_EXTENSIONS);
    int has_dmabuf = egl_exts && strstr(egl_exts, "EGL_EXT_image_dma_buf_import") != NULL;
    int has_image_base = egl_exts && strstr(egl_exts, "EGL_KHR_image_base") != NULL;
    int has_device_query = egl_exts && strstr(egl_exts, "EGL_EXT_device_query") != NULL;
    int has_dmabuf_modifiers = egl_exts && strstr(egl_exts, "EGL_EXT_image_dma_buf_import_modifiers") != NULL;
    fprintf(stderr, "[axium-engine] EGL extensions: dma_buf_import=%d, image_base=%d, device_query=%d, dmabuf_modifiers=%d\n",
            has_dmabuf, has_image_base, has_device_query, has_dmabuf_modifiers);

    // Discover DRM device from EGL (following WPEDisplayWayland pattern)
    if (has_device_query && pfn_eglQueryDisplayAttribEXT && pfn_eglQueryDeviceStringEXT) {
        EGLAttrib egl_device = 0;
        if (pfn_eglQueryDisplayAttribEXT(self->egl_display, EGL_DEVICE_EXT, &egl_device) && egl_device) {
            const char* primary_node = pfn_eglQueryDeviceStringEXT((EGLDeviceEXT)egl_device, EGL_DRM_DEVICE_FILE_EXT);
            const char* render_node = pfn_eglQueryDeviceStringEXT((EGLDeviceEXT)egl_device, EGL_DRM_RENDER_NODE_FILE_EXT);
            fprintf(stderr, "[axium-engine] DRM nodes: primary=%s, render=%s\n",
                    primary_node ? primary_node : "(none)",
                    render_node ? render_node : "(none)");

            if (primary_node || render_node) {
                self->drm_device = wpe_drm_device_new(
                    primary_node ? primary_node : "",
                    render_node ? render_node : "");
            }
        } else {
            fprintf(stderr, "[axium-engine] Failed to query EGL device\n");
        }
    }

    // Fallback: discover DRM render node from /dev/dri/ if EGL device query unavailable
    if (!self->drm_device) {
        const char* render_path = "/dev/dri/renderD128";
        if (g_file_test(render_path, G_FILE_TEST_EXISTS)) {
            self->drm_device = wpe_drm_device_new("", render_path);
            fprintf(stderr, "[axium-engine] DRM device from filesystem: %s\n", render_path);
        } else {
            fprintf(stderr, "[axium-engine] No DRM render node found at %s\n", render_path);
        }
    }

    // Query supported DMA-BUF formats from EGL
    if (self->drm_device && has_dmabuf_modifiers &&
        pfn_eglQueryDmaBufFormatsEXT && pfn_eglQueryDmaBufModifiersEXT) {

        EGLint n_formats = 0;
        if (pfn_eglQueryDmaBufFormatsEXT(self->egl_display, 0, NULL, &n_formats) && n_formats > 0) {
            EGLint* formats = g_new(EGLint, n_formats);
            if (pfn_eglQueryDmaBufFormatsEXT(self->egl_display, n_formats, formats, &n_formats)) {
                fprintf(stderr, "[axium-engine] EGL reports %d DMA-BUF formats\n", n_formats);

                GArray* pairs = g_array_new(FALSE, FALSE, sizeof(DmaBufFormat));

                for (int i = 0; i < n_formats; i++) {
                    // Use INVALID modifier: tells web process to skip
                    // gbm_bo_create_with_modifiers and use plain gbm_bo_create
                    // instead. Combined with MAPPING usage, this forces LINEAR
                    // layout which we can reliably import across EGL contexts.
                    DmaBufFormat fmt = { .fourcc = formats[i], .modifier = DRM_FORMAT_MOD_INVALID };
                    g_array_append_val(pairs, fmt);
                }

                self->n_dmabuf_formats = pairs->len;
                self->dmabuf_formats = (DmaBufFormat*)g_array_free(pairs, FALSE);
                fprintf(stderr, "[axium-engine] Collected %d DMA-BUF format/modifier pairs\n",
                        self->n_dmabuf_formats);
            }
            g_free(formats);
        }
    }

    return TRUE;
}

static gpointer axium_display_get_egl_display(WPEDisplay* display, GError** error)
{
    AxiumDisplay* self = AXIUM_DISPLAY(display);
    if (self->egl_display == EGL_NO_DISPLAY) {
        g_set_error_literal(error, WPE_EGL_ERROR, WPE_EGL_ERROR_NOT_AVAILABLE,
                            "EGL display not available");
        return NULL;
    }
    return self->egl_display;
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
#if FORCE_SHM_MODE
    fprintf(stderr, "[axium-engine] FORCE_SHM_MODE: returning NULL DRM device\n");
    return NULL;
#else
    return AXIUM_DISPLAY(display)->drm_device;
#endif
}

static WPEBufferFormats* axium_display_get_preferred_buffer_formats(WPEDisplay* display)
{
#if FORCE_SHM_MODE
    fprintf(stderr, "[axium-engine] FORCE_SHM_MODE: returning NULL preferred buffer formats\n");
    return NULL;
#endif
    AxiumDisplay* self = AXIUM_DISPLAY(display);

    if (!self->drm_device || self->n_dmabuf_formats == 0) {
        fprintf(stderr, "[axium-engine] No DRM device or DMA-BUF formats available\n");
        return NULL;
    }

    WPEBufferFormatsBuilder* builder = wpe_buffer_formats_builder_new(self->drm_device);
    // MAPPING usage causes the web process to add GBM_BO_USE_LINEAR flag,
    // ensuring LINEAR layout that we can import across EGL contexts.
    wpe_buffer_formats_builder_append_group(builder, NULL, WPE_BUFFER_FORMAT_USAGE_MAPPING);

    for (int i = 0; i < self->n_dmabuf_formats; i++) {
        wpe_buffer_formats_builder_append_format(builder,
            self->dmabuf_formats[i].fourcc,
            self->dmabuf_formats[i].modifier);
    }

    WPEBufferFormats* formats = wpe_buffer_formats_builder_end(builder);
    fprintf(stderr, "[axium-engine] Built WPEBufferFormats with %d format/modifier pairs\n",
            self->n_dmabuf_formats);
    return formats;
}

static void axium_display_dispose(GObject* object)
{
    AxiumDisplay* self = AXIUM_DISPLAY(object);
    // Clean up DRM device and format list
    if (self->drm_device) {
        wpe_drm_device_unref(self->drm_device);
        self->drm_device = NULL;
    }
    g_free(self->dmabuf_formats);
    self->dmabuf_formats = NULL;
    self->n_dmabuf_formats = 0;

    // Don't eglTerminate — GLFW owns the display
    self->egl_display = EGL_NO_DISPLAY;
    G_OBJECT_CLASS(axium_display_parent_class)->dispose(object);
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
}

static void axium_display_init(AxiumDisplay* self)
{
    self->egl_display = EGL_NO_DISPLAY;
    self->drm_device = NULL;
    self->dmabuf_formats = NULL;
    self->n_dmabuf_formats = 0;
}

// ---------------------------------------------------------------------------
// AxiumView
// ---------------------------------------------------------------------------
typedef struct _AxiumView AxiumView;
typedef struct _AxiumViewClass AxiumViewClass;

struct _AxiumView {
    WPEView parent_instance;
    WPEBuffer* pending_buffer;
    WPEBuffer* committed_buffer;
    bool has_new_frame;
};

struct _AxiumViewClass {
    WPEViewClass parent_class;
};

G_DEFINE_TYPE(AxiumView, axium_view, WPE_TYPE_VIEW)

static gboolean axium_view_render_buffer(WPEView* view, WPEBuffer* buffer,
                                          const WPERectangle* damage_rects,
                                          guint n_damage_rects, GError** error)
{
    AxiumView* self = AXIUM_VIEW(view);
    g_frame_count++;

    int w = wpe_buffer_get_width(buffer);
    int h = wpe_buffer_get_height(buffer);
    fprintf(stderr, "[axium-engine] render_buffer #%d: %dx%d, %u damage rects, page_loaded=%d\n",
            g_frame_count, w, h, n_damage_rects, g_page_loaded);

    // Store new pending buffer
    if (self->pending_buffer)
        g_object_unref(self->pending_buffer);
    self->pending_buffer = g_object_ref(buffer);
    self->has_new_frame = true;

    return TRUE;
}

static void on_toplevel_changed(WPEView* view, GParamSpec* pspec, gpointer data)
{
    WPEToplevel* toplevel = wpe_view_get_toplevel(view);
    if (!toplevel) {
        fprintf(stderr, "[axium-engine] toplevel changed: NULL, unmapping view\n");
        wpe_view_unmap(view);
        return;
    }

    int width, height;
    wpe_toplevel_get_size(toplevel, &width, &height);
    fprintf(stderr, "[axium-engine] toplevel changed: %dx%d, setting up view\n", width, height);
    if (width && height)
        wpe_view_resized(view, width, height);

    // Map the view (sets IsVisible via notify::mapped → ViewPlatform)
    wpe_view_map(view);
    fprintf(stderr, "[axium-engine] view mapped: %d\n", wpe_view_get_mapped(view));

    // Now that the view IS attached to the toplevel, set the ACTIVE state.
    // This fires toplevel-state-changed on the view, which ViewPlatform catches
    // to set WindowIsActive in the ActivityState. This must happen AFTER the
    // view-toplevel connection exists, otherwise the signal never reaches the view.
    wpe_toplevel_state_changed(toplevel, WPE_TOPLEVEL_STATE_ACTIVE);
    fprintf(stderr, "[axium-engine] toplevel state set to ACTIVE\n");

    // Set focus on the view (sets IsFocused via notify::has-focus → ViewPlatform)
    wpe_view_focus_in(view);
    fprintf(stderr, "[axium-engine] view focused: %d\n", wpe_view_get_has_focus(view));
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

    g_clear_object(&self->pending_buffer);
    g_clear_object(&self->committed_buffer);

    G_OBJECT_CLASS(axium_view_parent_class)->dispose(object);
}

static void axium_view_class_init(AxiumViewClass* klass)
{
    GObjectClass* object_class = G_OBJECT_CLASS(klass);
    object_class->constructed = axium_view_constructed;
    object_class->dispose = axium_view_dispose;

    WPEViewClass* view_class = WPE_VIEW_CLASS(klass);
    view_class->render_buffer = axium_view_render_buffer;
}

static void axium_view_init(AxiumView* self)
{
    self->pending_buffer = NULL;
    self->committed_buffer = NULL;
    self->has_new_frame = false;
}

// ---------------------------------------------------------------------------
// AxiumToplevel
// ---------------------------------------------------------------------------
typedef struct _AxiumToplevel AxiumToplevel;
typedef struct _AxiumToplevelClass AxiumToplevelClass;

struct _AxiumToplevel {
    WPEToplevel parent_instance;
};

struct _AxiumToplevelClass {
    WPEToplevelClass parent_class;
};

G_DEFINE_TYPE(AxiumToplevel, axium_toplevel, WPE_TYPE_TOPLEVEL)

static gboolean resize_view_cb(WPEToplevel* tl, WPEView* view, gpointer data)
{
    int w, h;
    wpe_toplevel_get_size(tl, &w, &h);
    wpe_view_resized(view, w, h);
    return FALSE; // continue iteration
}

static gboolean axium_toplevel_resize(WPEToplevel* toplevel, int width, int height)
{
    wpe_toplevel_resized(toplevel, width, height);
    wpe_toplevel_foreach_view(toplevel, resize_view_cb, NULL);
    return TRUE;
}

static void axium_toplevel_constructed(GObject* object)
{
    G_OBJECT_CLASS(axium_toplevel_parent_class)->constructed(object);
    // Don't set ACTIVE here — the view isn't attached yet.
    // The toplevel-state-changed signal on the view only fires when the view
    // has a toplevel. Setting state here means the view never sees the change.
    // Instead, we set ACTIVE in on_toplevel_changed() after the view is connected.
}

static void axium_toplevel_class_init(AxiumToplevelClass* klass)
{
    GObjectClass* object_class = G_OBJECT_CLASS(klass);
    object_class->constructed = axium_toplevel_constructed;

    WPEToplevelClass* toplevel_class = WPE_TOPLEVEL_CLASS(klass);
    toplevel_class->resize = axium_toplevel_resize;
}

static void axium_toplevel_init(AxiumToplevel* self)
{
}

// ---------------------------------------------------------------------------
// Engine state
// ---------------------------------------------------------------------------
static WPEDisplay*      g_display  = NULL;
static WebKitWebView*   g_web_view = NULL;
static unsigned int      g_gl_texture = 0;

// Get our custom view from the WebKitWebView
static AxiumView* get_axium_view(void)
{
    if (!g_web_view) return NULL;
    WPEView* wpe_view = webkit_web_view_get_wpe_view(g_web_view);
    if (!wpe_view) return NULL;
    if (!g_type_is_a(G_OBJECT_TYPE(wpe_view), AXIUM_TYPE_VIEW)) return NULL;
    return AXIUM_VIEW(wpe_view);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

bool axium_engine_init(void)
{
    // Load GL/EGL extension function pointers
    pfn_glEGLImageTargetTexture2DOES = (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)
        eglGetProcAddress("glEGLImageTargetTexture2DOES");
    pfn_eglQueryDisplayAttribEXT = (PFNEGLQUERYDISPLAYATTRIBEXTPROC)
        eglGetProcAddress("eglQueryDisplayAttribEXT");
    pfn_eglQueryDeviceStringEXT = (PFNEGLQUERYDEVICESTRINGEXTPROC)
        eglGetProcAddress("eglQueryDeviceStringEXT");
    pfn_eglQueryDmaBufFormatsEXT = (PFNEGLQUERYDMABUFFORMATSEXTPROC)
        eglGetProcAddress("eglQueryDmaBufFormatsEXT");
    pfn_eglQueryDmaBufModifiersEXT = (PFNEGLQUERYDMABUFMODIFIERSEXTPROC)
        eglGetProcAddress("eglQueryDmaBufModifiersEXT");

    // Create and connect our custom display
    g_display = WPE_DISPLAY(g_object_new(AXIUM_TYPE_DISPLAY, NULL));
    GError* error = NULL;
    if (!wpe_display_connect(g_display, &error)) {
        fprintf(stderr, "[axium-engine] Failed to connect display: %s\n",
                error ? error->message : "unknown");
        g_clear_error(&error);
        g_clear_object(&g_display);
        return false;
    }

    fprintf(stderr, "[axium-engine] Display connected\n");
    return true;
}

static void on_load_changed(WebKitWebView* wv, WebKitLoadEvent event, gpointer data)
{
    (void)data;
    const char* names[] = {"STARTED", "REDIRECTED", "COMMITTED", "FINISHED"};
    fprintf(stderr, "[axium-engine] load-changed: %s (uri: %s) [frames_so_far=%d]\n",
            event < 4 ? names[event] : "UNKNOWN",
            webkit_web_view_get_uri(wv), g_frame_count);
    if (event == WEBKIT_LOAD_FINISHED)
        g_page_loaded = true;
}

bool axium_engine_create_view(int width, int height)
{
    if (!g_display) return false;

    // Create WebKitWebView — pass our display explicitly so WebKit uses it
    // (wpe_display_get_default() uses GIO extension points, not our custom display)
    g_web_view = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,
                                               "display", g_display, NULL));
    if (!g_web_view) {
        fprintf(stderr, "[axium-engine] Failed to create WebKitWebView\n");
        return false;
    }

    // Monitor page load status
    g_signal_connect(g_web_view, "load-changed",
        G_CALLBACK(on_load_changed), NULL);

    // Get the WPE view (created through our display's create_view)
    WPEView* wpe_view = webkit_web_view_get_wpe_view(g_web_view);
    if (!wpe_view) {
        fprintf(stderr, "[axium-engine] No WPE view on WebKitWebView\n");
        g_clear_object(&g_web_view);
        return false;
    }

    // Resize the toplevel which propagates to the view
    WPEToplevel* toplevel = wpe_view_get_toplevel(wpe_view);
    if (toplevel)
        wpe_toplevel_resize(toplevel, width, height);

    // Log view state
    fprintf(stderr, "[axium-engine] View state: mapped=%d, visible=%d, size=%dx%d\n",
            wpe_view_get_mapped(wpe_view),
            wpe_view_get_visible(wpe_view),
            wpe_view_get_width(wpe_view),
            wpe_view_get_height(wpe_view));
    if (toplevel) {
        int tw, th;
        wpe_toplevel_get_size(toplevel, &tw, &th);
        fprintf(stderr, "[axium-engine] Toplevel size: %dx%d\n", tw, th);
    }

    fprintf(stderr, "[axium-engine] WebView created (%dx%d)\n", width, height);
    return true;
}

void axium_engine_load_uri(const char* uri)
{
    if (!g_web_view) return;
    webkit_web_view_load_uri(g_web_view, uri);
    fprintf(stderr, "[axium-engine] Loading: %s\n", uri);
}

void axium_engine_resize(int width, int height)
{
    if (!g_web_view) return;
    WPEView* wpe_view = webkit_web_view_get_wpe_view(g_web_view);
    if (!wpe_view) return;
    WPEToplevel* toplevel = wpe_view_get_toplevel(wpe_view);
    if (toplevel)
        wpe_toplevel_resize(toplevel, width, height);
}

void axium_engine_pump(void)
{
    // Drain all pending GLib events — WebKit needs many iterations
    // for IPC, web process startup, rendering, etc.
    while (g_main_context_iteration(NULL, FALSE)) {
        // keep draining
    }

    g_pump_count++;
    // Periodic status every ~5 seconds (300 pumps at 60fps)
    if (g_pump_count % 300 == 0) {
        fprintf(stderr, "[axium-engine] STATUS: pump=%d frames=%d page_loaded=%d first_content=#%d\n",
                g_pump_count, g_frame_count, g_page_loaded, g_first_content_frame);
    }
}

bool axium_engine_has_new_frame(void)
{
    AxiumView* view = get_axium_view();
    return view && view->has_new_frame;
}

unsigned int axium_engine_get_texture_id(void)
{
    AxiumView* view = get_axium_view();
    if (!view || !view->pending_buffer)
        return g_gl_texture;

    WPEBuffer* buffer = view->pending_buffer;
    int w = wpe_buffer_get_width(buffer);
    int h = wpe_buffer_get_height(buffer);

    // Log buffer details with hex format for precise identification
    if (WPE_IS_BUFFER_DMA_BUF(buffer)) {
        WPEBufferDMABuf* dmabuf = WPE_BUFFER_DMA_BUF(buffer);
        guint32 fmt = wpe_buffer_dma_buf_get_format(dmabuf);
        guint64 mod = wpe_buffer_dma_buf_get_modifier(dmabuf);
        fprintf(stderr, "[axium-engine] Frame #%d: DMA-BUF %dx%d fmt=0x%08x(%c%c%c%c) mod=0x%016llx page_loaded=%d\n",
                g_frame_count, w, h,
                fmt, fmt & 0xff, (fmt >> 8) & 0xff, (fmt >> 16) & 0xff, (fmt >> 24) & 0xff,
                (unsigned long long)mod, g_page_loaded);
    } else {
        fprintf(stderr, "[axium-engine] Frame #%d: %s (SHM?) %dx%d page_loaded=%d\n",
                g_frame_count, G_OBJECT_TYPE_NAME(buffer), w, h, g_page_loaded);
    }

    // Helper: check first N bytes for non-zero content
    #define CHECK_CONTENT(data, size, label) do { \
        int _nz = 0; \
        for (int _i = 0; _i < (int)(size) && _i < 4096; _i++) { \
            if (((const uint8_t*)(data))[_i]) { _nz = 1; break; } \
        } \
        const uint8_t* _p = (const uint8_t*)(data); \
        fprintf(stderr, "[axium-engine]   %s: %02x%02x%02x%02x %02x%02x%02x%02x → %s\n", \
                label, _p[0], _p[1], _p[2], _p[3], _p[4], _p[5], _p[6], _p[7], \
                _nz ? "HAS DATA" : "ALL ZEROS"); \
        if (_nz && g_first_content_frame < 0) { \
            g_first_content_frame = g_frame_count; \
            fprintf(stderr, "[axium-engine] *** FIRST NON-ZERO FRAME: #%d ***\n", g_frame_count); \
        } \
    } while(0)

    // Try zero-copy: DMA-BUF → EGLImage → GL texture
    GError* error = NULL;
    EGLImageKHR egl_image = (EGLImageKHR)wpe_buffer_import_to_egl_image(buffer, &error);

    if (egl_image && pfn_glEGLImageTargetTexture2DOES) {
        if (!g_gl_texture)
            glGenTextures(1, &g_gl_texture);
        glBindTexture(GL_TEXTURE_2D, g_gl_texture);
        pfn_glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, (GLeglImageOES)egl_image);
        GLenum gl_err = glGetError();
        if (gl_err != GL_NO_ERROR)
            fprintf(stderr, "[axium-engine] glEGLImageTargetTexture2DOES error: 0x%04x\n", gl_err);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

        // Force GPU sync before readback
        glFinish();

        // Readback texture to check content
        {
            uint8_t* rb = g_new(uint8_t, w * h * 4);
            glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, rb);
            GLenum rb_err = glGetError();
            if (rb_err != GL_NO_ERROR)
                fprintf(stderr, "[axium-engine] glGetTexImage error: 0x%04x\n", rb_err);
            else
                CHECK_CONTENT(rb, w * h * 4, "GL readback");
            g_free(rb);
        }

        // Also try CPU path for cross-validation
        {
            GError* pix_err = NULL;
            GBytes* pix = wpe_buffer_import_to_pixels(buffer, &pix_err);
            if (pix) {
                gsize pix_size = 0;
                const uint8_t* pix_data = g_bytes_get_data(pix, &pix_size);
                CHECK_CONTENT(pix_data, pix_size, "CPU pixels");
                g_bytes_unref(pix);
            } else {
                fprintf(stderr, "[axium-engine]   CPU pixels: failed (%s)\n",
                        pix_err ? pix_err->message : "unknown");
                g_clear_error(&pix_err);
            }
        }
    } else {
        // Fallback: pixel copy (SHM or DMA-BUF CPU path)
        if (error)
            fprintf(stderr, "[axium-engine] EGLImage import failed: %s (trying pixel path)\n", error->message);
        else
            fprintf(stderr, "[axium-engine] EGLImage import returned NULL (trying pixel path)\n");
        g_clear_error(&error);

        GBytes* pixels = wpe_buffer_import_to_pixels(buffer, &error);
        if (pixels) {
            gsize pixel_size = 0;
            const uint8_t* pixel_data = g_bytes_get_data(pixels, &pixel_size);
            fprintf(stderr, "[axium-engine]   pixel data: %zu bytes for %dx%d\n", pixel_size, w, h);
            CHECK_CONTENT(pixel_data, pixel_size, "CPU/SHM pixels");

            if (!g_gl_texture)
                glGenTextures(1, &g_gl_texture);
            glBindTexture(GL_TEXTURE_2D, g_gl_texture);
            // SHM buffers from WebKit use BGRA byte order (GL_BGRA)
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0,
                         GL_BGRA, GL_UNSIGNED_BYTE, pixel_data);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            GLenum upload_err = glGetError();
            if (upload_err != GL_NO_ERROR)
                fprintf(stderr, "[axium-engine] glTexImage2D error: 0x%04x\n", upload_err);

            g_bytes_unref(pixels);
        } else {
            fprintf(stderr, "[axium-engine] pixel import failed: %s\n",
                    error ? error->message : "unknown");
        }
        g_clear_error(&error);
    }

    #undef CHECK_CONTENT

    // Release old committed buffer, promote pending
    if (view->committed_buffer) {
        wpe_view_buffer_released(WPE_VIEW(view), view->committed_buffer);
        g_object_unref(view->committed_buffer);
    }
    view->committed_buffer = view->pending_buffer;
    view->pending_buffer = NULL;
    view->has_new_frame = false;

    // Tell WebKit we displayed this buffer
    wpe_view_buffer_rendered(WPE_VIEW(view), view->committed_buffer);

    return g_gl_texture;
}

void axium_engine_get_frame_size(int* width, int* height)
{
    *width = 0;
    *height = 0;
    if (!g_web_view) return;
    WPEView* wpe_view = webkit_web_view_get_wpe_view(g_web_view);
    if (!wpe_view) return;
    *width = wpe_view_get_width(wpe_view);
    *height = wpe_view_get_height(wpe_view);
}

void axium_engine_shutdown(void)
{
    if (g_gl_texture) {
        glDeleteTextures(1, &g_gl_texture);
        g_gl_texture = 0;
    }

    AxiumView* view = get_axium_view();
    if (view) {
        g_clear_object(&view->pending_buffer);
        if (view->committed_buffer) {
            wpe_view_buffer_released(WPE_VIEW(view), view->committed_buffer);
            g_clear_object(&view->committed_buffer);
        }
    }

    g_clear_object(&g_web_view);
    g_clear_object(&g_display);

    fprintf(stderr, "[axium-engine] Shutdown complete\n");
}
