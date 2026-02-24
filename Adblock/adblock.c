// Axium Adblock Web Process Extension
//
// Loaded by WebKit's web process to intercept all network requests
// (scripts, images, CSS, XHR) via the send-request signal.
// Links against libaxium_adblock.so for filter matching.

#include <wpe/webkit-web-process-extension.h>
#include <gmodule.h>
#include <stdio.h>

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

extern AdblockEngine* adblock_engine_from_filter_list(const char* filter_list);
extern void           adblock_engine_free(AdblockEngine* engine);
extern AdblockResult  adblock_check_request(const AdblockEngine* engine,
                                            const char* url,
                                            const char* source_url,
                                            const char* request_type);
extern void           adblock_result_free(AdblockResult* result);

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

static AdblockEngine* g_engine = NULL;

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

    const char* url = webkit_uri_request_get_uri(request);
    const char* page_url = webkit_web_page_get_uri(page);
    if (!url || !page_url)
        return FALSE;

    AdblockResult result = adblock_check_request(g_engine, url, page_url, "other");
    gboolean block = result.matched && !result.exception;

    if (block)
        fprintf(stderr, "[axium-adblock] BLOCKED %s\n", url);

    adblock_result_free(&result);

    return block;
}

// ---------------------------------------------------------------------------
// page-created handler — connect send-request on each new page
// ---------------------------------------------------------------------------

static void
on_page_created(WebKitWebProcessExtension *ext,
                WebKitWebPage             *page,
                gpointer                   data)
{
    (void)ext;
    (void)data;

    g_signal_connect(page, "send-request",
                     G_CALLBACK(on_send_request), NULL);
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
}

// ---------------------------------------------------------------------------
// Entry point — called by WebKit when loading the extension .so
// ---------------------------------------------------------------------------

G_MODULE_EXPORT void
webkit_web_process_extension_initialize_with_user_data(
    WebKitWebProcessExtension *extension,
    const GVariant            *user_data)
{
    // user_data contains the filter file path as a string
    if (!user_data || !g_variant_is_of_type((GVariant*)user_data, G_VARIANT_TYPE_STRING)) {
        fprintf(stderr, "[axium-adblock] no filter path provided, adblock disabled\n");
        return;
    }

    const char* filter_path = g_variant_get_string((GVariant*)user_data, NULL);
    if (!filter_path || !*filter_path) {
        fprintf(stderr, "[axium-adblock] empty filter path, adblock disabled\n");
        return;
    }

    // Read filter list from file
    char*  contents = NULL;
    gsize  len = 0;
    GError* error = NULL;
    if (!g_file_get_contents(filter_path, &contents, &len, &error)) {
        fprintf(stderr, "[axium-adblock] failed to read %s: %s\n",
                filter_path, error ? error->message : "unknown error");
        g_clear_error(&error);
        return;
    }

    // Create adblock engine from filter list
    g_engine = adblock_engine_from_filter_list(contents);
    g_free(contents);

    if (!g_engine) {
        fprintf(stderr, "[axium-adblock] failed to create engine\n");
        return;
    }

    fprintf(stderr, "[axium-adblock] engine loaded from %s\n", filter_path);

    // Connect to page-created signal
    g_signal_connect(extension, "page-created",
                     G_CALLBACK(on_page_created), NULL);

    // Clean up engine when extension is destroyed
    g_object_weak_ref(G_OBJECT(extension), on_extension_destroyed, NULL);
}
