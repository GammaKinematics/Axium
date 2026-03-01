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
extern _Bool             adblock_engine_load_resources(AdblockEngine* engine,
                                                        const char* resource_dir,
                                                        const char* redirect_resources,
                                                        const char* scriptlets);
extern AdblockEngine*    adblock_engine_deserialize(const unsigned char* data,
                                                     unsigned long len);

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

static AdblockEngine* g_engine = NULL;
static gboolean g_disabled = FALSE;

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

// Procedural cosmetic filter JS engine
// Handles: css-selector, has-text, matches-css/-before/-after, upward, xpath,
//          min-text-length, matches-attr, matches-path
// Actions: null (hide), remove, style, remove-attr, remove-class
static const char PROCEDURAL_ENGINE_JS[] =
    "function __axiumRunProcedural(json){"
      "try{var filters=JSON.parse(json);}catch(e){return;}"
      "function applyFilter(f){"
        "var els=null;"
        "for(var i=0;i<f.selector.length;i++){"
          "var step=f.selector[i],t=step.type,a=step.arg;"
          "if(t==='css-selector'){"
            "if(els===null){"
              "els=Array.from(document.querySelectorAll(a));"
            "}else{"
              "var next=[];"
              "for(var j=0;j<els.length;j++){"
                "var sub=els[j].querySelectorAll(a);"
                "for(var k=0;k<sub.length;k++)next.push(sub[k]);"
              "}"
              "els=next;"
            "}"
          "}else if(t==='has-text'){"
            "if(els===null)els=Array.from(document.querySelectorAll('*'));"
            "var re;"
            "try{"
              "if(a.charAt(0)==='/'&&a.lastIndexOf('/')>0){"
                "var li=a.lastIndexOf('/');"
                "re=new RegExp(a.substring(1,li),a.substring(li+1));"
              "}else{re=new RegExp(a);}"
            "}catch(e){return;}"
            "els=els.filter(function(el){return re.test(el.textContent);});"
          "}else if(t==='matches-css'||t==='matches-css-before'||t==='matches-css-after'){"
            "if(els===null)els=Array.from(document.querySelectorAll('*'));"
            "var pseudo=t==='matches-css-before'?'::before':t==='matches-css-after'?'::after':null;"
            "var ci=a.indexOf(':');"
            "if(ci<0)continue;"
            "var prop=a.substring(0,ci).trim(),valPat=a.substring(ci+1).trim();"
            "var valRe;"
            "try{"
              "if(valPat.charAt(0)==='/'&&valPat.lastIndexOf('/')>0){"
                "var vli=valPat.lastIndexOf('/');"
                "valRe=new RegExp(valPat.substring(1,vli),valPat.substring(vli+1));"
              "}else{valRe=new RegExp(valPat);}"
            "}catch(e){return;}"
            "els=els.filter(function(el){"
              "var cs=getComputedStyle(el,pseudo);"
              "return valRe.test(cs.getPropertyValue(prop));"
            "});"
          "}else if(t==='upward'){"
            "if(els===null)els=[];"
            "var n=parseInt(a,10);"
            "if(!isNaN(n)&&n>0){"
              "els=els.map(function(el){"
                "for(var u=0;u<n&&el;u++)el=el.parentElement;"
                "return el;"
              "}).filter(Boolean);"
            "}else{"
              "els=els.map(function(el){return el.closest(a);}).filter(Boolean);"
            "}"
          "}else if(t==='xpath'){"
            "if(els===null){"
              "var xr=document.evaluate(a,document,null,XPathResult.ORDERED_NODE_SNAPSHOT_TYPE,null);"
              "els=[];for(var xi=0;xi<xr.snapshotLength;xi++){"
                "var xn=xr.snapshotItem(xi);"
                "if(xn.nodeType===1)els.push(xn);"
              "}"
            "}else{"
              "var next=[];"
              "for(var j=0;j<els.length;j++){"
                "var xr=document.evaluate(a,els[j],null,XPathResult.ORDERED_NODE_SNAPSHOT_TYPE,null);"
                "for(var xi=0;xi<xr.snapshotLength;xi++){"
                  "var xn=xr.snapshotItem(xi);"
                  "if(xn.nodeType===1)next.push(xn);"
                "}"
              "}"
              "els=next;"
            "}"
          "}else if(t==='min-text-length'){"
            "if(els===null)els=Array.from(document.querySelectorAll('*'));"
            "var minLen=parseInt(a,10)||0;"
            "els=els.filter(function(el){return el.textContent.length>=minLen;});"
          "}else if(t==='matches-attr'){"
            "if(els===null)els=Array.from(document.querySelectorAll('*'));"
            "var eqi=a.indexOf('=');"
            "var attrPat,valPat2;"
            "if(eqi>=0){attrPat=a.substring(0,eqi);valPat2=a.substring(eqi+1);}"
            "else{attrPat=a;valPat2='';}"
            "function mkRe(s){"
              "s=s.replace(/^\"/,'').replace(/\"$/,'');"
              "if(s.charAt(0)==='/'&&s.lastIndexOf('/')>0){"
                "var li=s.lastIndexOf('/');return new RegExp(s.substring(1,li),s.substring(li+1));"
              "}return new RegExp('^'+s.replace(/[.*+?^${}()|[\\]\\\\]/g,'\\\\$&').replace(/\\\\\\*/g,'.*')+'$');"
            "}"
            "try{var attrRe=mkRe(attrPat),valRe2=mkRe(valPat2);}catch(e){return;}"
            "els=els.filter(function(el){"
              "for(var ai=0;ai<el.attributes.length;ai++){"
                "var at=el.attributes[ai];"
                "if(attrRe.test(at.name)&&valRe2.test(at.value))return true;"
              "}return false;"
            "});"
          "}else if(t==='matches-path'){"
            "try{"
              "var pathRe=new RegExp(a);"
              "if(!pathRe.test(location.pathname+location.search))return;"
            "}catch(e){return;}"
          "}"
        "}"
        "if(!els||!els.length)return;"
        "var act=f.action;"
        "for(var i=0;i<els.length;i++){"
          "var el=els[i];"
          "if(!act){"
            "el.style.setProperty('display','none','important');"
          "}else if(act.type==='remove'){"
            "el.remove();"
          "}else if(act.type==='style'){"
            "var pairs=act.arg.split(';');"
            "for(var p=0;p<pairs.length;p++){"
              "var kv=pairs[p].split(':');"
              "if(kv.length>=2){"
                "var k=kv[0].trim(),v=kv.slice(1).join(':').trim();"
                "var imp=v.indexOf('!important')>=0;"
                "if(imp)v=v.replace('!important','').trim();"
                "el.style.setProperty(k,v,imp?'important':'');"
              "}"
            "}"
          "}else if(act.type==='remove-attr'){"
            "el.removeAttribute(act.arg);"
          "}else if(act.type==='remove-class'){"
            "el.classList.remove(act.arg);"
          "}"
        "}"
      "}"
      "function run(){"
        "for(var i=0;i<filters.length;i++){"
          "try{applyFilter(filters[i]);}catch(e){}"
        "}"
      "}"
      "run();"
      "new MutationObserver(function(){run();}).observe("
        "document.documentElement,{childList:true,subtree:true}"
      ");"
    "}";

// document-loaded handler — inject cosmetic filters
static void
on_document_loaded(WebKitWebPage *page, gpointer data)
{
    (void)data;

    if (!g_engine) return;
    if (g_disabled) return;

    const char* page_url = webkit_web_page_get_uri(page);
    if (!page_url) return;

    CosmeticResources resources = adblock_url_cosmetic_resources(g_engine, page_url);

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
    }
    g_clear_object(&style_elem);

    // 2. Inject scriptlets
    if (resources.injected_script) {
        JSCValue* r = jsc_context_evaluate(ctx, resources.injected_script, -1);
        g_clear_object(&r);
    }

    // 3. CSP directive injection via <meta> tag
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

    // 4. Procedural cosmetic filters
    if (resources.procedural_actions) {
        // Define the procedural engine
        JSCValue* r = jsc_context_evaluate(ctx, PROCEDURAL_ENGINE_JS, -1);
        g_clear_object(&r);

        // Pass JSON safely via JSC property (avoids string escaping issues)
        JSCValue* json_val = jsc_value_new_string(ctx, resources.procedural_actions);
        jsc_context_set_value(ctx, "__axiumProceduralJSON", json_val);
        g_object_unref(json_val);

        r = jsc_context_evaluate(ctx,
            "__axiumRunProcedural(__axiumProceduralJSON);", -1);
        g_clear_object(&r);
    }

    // 5. Set up MutationObserver for 2nd-pass generic hide rules
    if (!resources.generichide) {
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
// user-message-received handler — honor adblock disable flag from UI process
// ---------------------------------------------------------------------------

static gboolean
on_user_message_received(WebKitWebPage    *page,
                         WebKitUserMessage *message,
                         gpointer          data)
{
    (void)page;
    (void)data;

    const char* name = webkit_user_message_get_name(message);
    if (g_strcmp0(name, "adblock-set-disabled") != 0)
        return FALSE;

    GVariant* params = webkit_user_message_get_parameters(message);
    if (params && g_variant_is_of_type(params, G_VARIANT_TYPE_BOOLEAN))
        g_disabled = g_variant_get_boolean(params);

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
}

// ---------------------------------------------------------------------------
// Entry point — called by WebKit when loading the extension .so
// ---------------------------------------------------------------------------

G_MODULE_EXPORT void
webkit_web_process_extension_initialize_with_user_data(
    WebKitWebProcessExtension *extension,
    const GVariant            *user_data)
{
    // user_data contains the adblock data directory path as a string
    if (!user_data || !g_variant_is_of_type((GVariant*)user_data, G_VARIANT_TYPE_STRING)) {
        fprintf(stderr, "[axium-adblock] no adblock dir provided, adblock disabled\n");
        return;
    }

    const char* dir = g_variant_get_string((GVariant*)user_data, NULL);
    if (!dir || !*dir) {
        fprintf(stderr, "[axium-adblock] empty adblock dir, adblock disabled\n");
        return;
    }

    char* dat_path = g_build_filename(dir, "engine.dat", NULL);
    char* resource_dir = g_build_filename(dir, "resources", NULL);
    char* redirect_res = g_build_filename(dir, "redirect-resources.js", NULL);
    char* scriptlets_path = g_build_filename(dir, "scriptlets.js", NULL);

    // Deserialize pre-compiled engine
    char* dat_data = NULL;
    gsize dat_len = 0;
    if (!g_file_get_contents(dat_path, &dat_data, &dat_len, NULL)) {
        fprintf(stderr, "[axium-adblock] failed to read %s, adblock disabled\n", dat_path);
        goto cleanup;
    }

    g_engine = adblock_engine_deserialize((const unsigned char*)dat_data, dat_len);
    g_free(dat_data);

    if (!g_engine) {
        fprintf(stderr, "[axium-adblock] failed to deserialize engine from %s\n", dat_path);
        goto cleanup;
    }

    // Load redirect resources + scriptlets
    {
        const char* scriptlets_arg = g_file_test(scriptlets_path, G_FILE_TEST_EXISTS)
            ? scriptlets_path : NULL;

        if (g_file_test(resource_dir, G_FILE_TEST_IS_DIR) &&
            g_file_test(redirect_res, G_FILE_TEST_EXISTS))
            adblock_engine_load_resources(g_engine, resource_dir, redirect_res, scriptlets_arg);
    }

cleanup:
    g_free(dat_path);
    g_free(resource_dir);
    g_free(redirect_res);
    g_free(scriptlets_path);

    if (!g_engine)
        return;

    // Connect to page-created signal
    g_signal_connect(extension, "page-created",
                     G_CALLBACK(on_page_created), NULL);

    // Clean up engine when extension is destroyed
    g_object_weak_ref(G_OBJECT(extension), on_extension_destroyed, NULL);
}
