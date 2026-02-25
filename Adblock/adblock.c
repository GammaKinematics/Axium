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
    char*  hide_selectors;    // CSS: "sel1,sel2{display:none!important}"
    char*  injected_script;   // ready-to-execute JS scriptlets
    char*  exceptions_json;   // JSON array for 2nd-pass filtering
    _Bool  generichide;       // skip generic rules if true
} CosmeticResources;

extern AdblockEngine*    adblock_engine_from_filter_list(const char* filter_list);
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
extern void              adblock_string_free(char* s);

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

    adblock_result_free(&result);

    return block;
}

// ---------------------------------------------------------------------------
// Cosmetic filtering — document-loaded handler + MutationObserver
// ---------------------------------------------------------------------------

// Per-page data for the hidden_class_id_selectors callback
typedef struct {
    char* exceptions_json;
} PageCosmeticData;

static void
page_cosmetic_data_free(gpointer data)
{
    PageCosmeticData* d = (PageCosmeticData*)data;
    if (d) {
        g_free(d->exceptions_json);
        g_free(d);
    }
}

// JS callback: __axiumHiddenSelectors(classesJson, idsJson) → CSS string or null
static JSCValue*
on_hidden_selectors(GPtrArray* args, gpointer user_data)
{
    PageCosmeticData* data = (PageCosmeticData*)user_data;
    JSCContext* ctx = jsc_context_get_current();

    if (!g_engine || !data || !args || args->len < 2)
        return jsc_value_new_null(ctx);

    JSCValue* classes_val = g_ptr_array_index(args, 0);
    JSCValue* ids_val = g_ptr_array_index(args, 1);

    if (!jsc_value_is_string(classes_val) || !jsc_value_is_string(ids_val))
        return jsc_value_new_null(ctx);

    char* classes_json = jsc_value_to_string(classes_val);
    char* ids_json = jsc_value_to_string(ids_val);

    char* css = adblock_hidden_class_id_selectors(g_engine, classes_json, ids_json,
                                                   data->exceptions_json);

    if (css)
        fprintf(stderr, "[axium-cosmetic]   2nd-pass: %zu new bytes of CSS\n", strlen(css));

    g_free(classes_json);
    g_free(ids_json);

    if (!css)
        return jsc_value_new_null(ctx);

    JSCValue* result = jsc_value_new_string(ctx, css);
    adblock_string_free(css);
    return result;
}

// MutationObserver JS — initial scan + watch for new DOM elements
static const char MUTATION_OBSERVER_JS[] =
    "(function(){"
    "var s=document.getElementById('axium-cosmetic');"
    "if(!s)return;"
    "var seen=new Set();"
    "function scan(root){"
      "var cl=[],id=[];"
      "var els=[];"
      "if(root.nodeType===1)els.push(root);"
      "if(root.querySelectorAll){"
        "var a=root.querySelectorAll('[id],[class]');"
        "for(var i=0;i<a.length;i++)els.push(a[i]);"
      "}"
      "for(var i=0;i<els.length;i++){"
        "var e=els[i];"
        "if(e.id&&!seen.has('i'+e.id)){id.push(e.id);seen.add('i'+e.id);}"
        "if(e.classList)for(var j=0;j<e.classList.length;j++){"
          "var c=e.classList[j];"
          "if(!seen.has('c'+c)){cl.push(c);seen.add('c'+c);}"
        "}"
      "}"
      "return[cl,id];"
    "}"
    "function process(r){"
      "if(!r[0].length&&!r[1].length)return;"
      "var css=__axiumHiddenSelectors(JSON.stringify(r[0]),JSON.stringify(r[1]));"
      "if(css)s.textContent+=css;"
    "}"
    "process(scan(document.documentElement));"
    "new MutationObserver(function(ms){"
      "var cl=[],id=[];"
      "for(var i=0;i<ms.length;i++){"
        "var m=ms[i];"
        "if(m.addedNodes)for(var j=0;j<m.addedNodes.length;j++){"
          "var r=scan(m.addedNodes[j]);"
          "cl=cl.concat(r[0]);id=id.concat(r[1]);"
        "}"
        "if(m.type==='attributes'&&m.target.nodeType===1){"
          "var r=scan(m.target);"
          "cl=cl.concat(r[0]);id=id.concat(r[1]);"
        "}"
      "}"
      "if(cl.length||id.length){"
        "var css=__axiumHiddenSelectors(JSON.stringify(cl),JSON.stringify(id));"
        "if(css)s.textContent+=css;"
      "}"
    "}).observe(document.documentElement,{"
      "childList:true,subtree:true,attributes:true,attributeFilter:['class','id']"
    "});"
    "})()";

// document-loaded handler — inject cosmetic filters
static void
on_document_loaded(WebKitWebPage *page, gpointer data)
{
    (void)data;

    if (!g_engine) return;

    const char* page_url = webkit_web_page_get_uri(page);
    if (!page_url) return;

    CosmeticResources resources = adblock_url_cosmetic_resources(g_engine, page_url);

    fprintf(stderr, "[axium-cosmetic] %s — selectors:%s script:%s generichide:%d\n",
            page_url,
            resources.hide_selectors ? "yes" : "no",
            resources.injected_script ? "yes" : "no",
            resources.generichide);

    // Nothing to do?
    if (!resources.hide_selectors && !resources.injected_script && resources.generichide) {
        adblock_cosmetic_resources_free(&resources);
        return;
    }

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

    // 1. Create <style id="axium-cosmetic"> and set hide_selectors
    JSCValue* style_elem = jsc_context_evaluate(ctx,
        "var _s=document.createElement('style');"
        "_s.id='axium-cosmetic';"
        "(document.head||document.documentElement).appendChild(_s);"
        "_s", -1);

    if (resources.hide_selectors && style_elem && jsc_value_is_object(style_elem)) {
        JSCValue* css_val = jsc_value_new_string(ctx, resources.hide_selectors);
        jsc_value_object_set_property(style_elem, "textContent", css_val);
        g_object_unref(css_val);
        fprintf(stderr, "[axium-cosmetic]   injected %zu bytes of hide CSS\n",
                strlen(resources.hide_selectors));
    }
    g_clear_object(&style_elem);

    // 2. Inject scriptlets
    if (resources.injected_script) {
        JSCValue* r = jsc_context_evaluate(ctx, resources.injected_script, -1);
        g_clear_object(&r);
        fprintf(stderr, "[axium-cosmetic]   injected %zu bytes of scriptlets\n",
                strlen(resources.injected_script));
    }

    // 3. Set up MutationObserver for 2nd-pass generic hide rules
    if (!resources.generichide) {
        fprintf(stderr, "[axium-cosmetic]   installing MutationObserver for 2nd-pass\n");
        PageCosmeticData* cosmetic_data = g_new0(PageCosmeticData, 1);
        cosmetic_data->exceptions_json = resources.exceptions_json
            ? g_strdup(resources.exceptions_json) : NULL;

        JSCValue* callback = jsc_value_new_function_variadic(ctx,
            "__axiumHiddenSelectors",
            G_CALLBACK(on_hidden_selectors),
            cosmetic_data,
            page_cosmetic_data_free,
            JSC_TYPE_VALUE);
        jsc_context_set_value(ctx, "__axiumHiddenSelectors", callback);
        g_object_unref(callback);

        JSCValue* r = jsc_context_evaluate(ctx, MUTATION_OBSERVER_JS, -1);
        g_clear_object(&r);
    }

    g_object_unref(ctx);
    adblock_cosmetic_resources_free(&resources);
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

    g_signal_connect(page, "send-request",
                     G_CALLBACK(on_send_request), NULL);
    g_signal_connect(page, "document-loaded",
                     G_CALLBACK(on_document_loaded), NULL);
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
