package axium

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
    @(link_name = "system")
    libc_system :: proc(cmd: cstring) -> c.int ---
}

// --- C FFI ---

Translate_Engine :: struct {}

foreign {
    translate_engine_init  :: proc(num_workers: c.int) -> ^Translate_Engine ---
    translate_engine_free  :: proc(engine: ^Translate_Engine) ---
    translate_load_model   :: proc(engine: ^Translate_Engine, config_path: cstring) -> c.int ---
    translate_unload_model :: proc(engine: ^Translate_Engine) ---
    translate_text         :: proc(engine: ^Translate_Engine, text: cstring, html: c.int) ---
    translate_fd           :: proc(engine: ^Translate_Engine) -> c.int ---
    translate_poll         :: proc(engine: ^Translate_Engine, out_text: ^cstring, out_error: ^cstring) -> c.int ---
    translate_result_free  :: proc(str: cstring) ---
}

// --- State ---

Translate_State :: enum {
    Idle,
    Detecting,      // running JS to get page language
    Downloading,    // fetching model files
    Walking,        // DOM walker JS running
    Translating,    // bergamot processing current node
    Polling,        // viewport polling active
    Done,           // result injected
}

translate_state:        Translate_State
translate_engine:       ^Translate_Engine
translate_popup_anchor: ^lv_obj_t
translate_src_lang:     string
translate_tgt_lang:     string
translate_model_pair: string  // "src-tgt" of currently loaded model, "" if none

// Display mode for translations
Translate_Display :: enum {
    Dual,        // show original + translation
    Translation, // show only translation
    Hover,       // translation appears on hover
}

Translate_Theme :: enum {
    Default,     // italic + left border
    Underline,   // colored underline
    Highlight,   // yellow background
    Mask,        // blurred, reveal on hover
}

translate_display: Translate_Display
translate_theme:   Translate_Theme

// Per-node translation tracking
Translate_Node :: struct {
    id:   int,
    text: string,
}

translate_nodes:       [dynamic]Translate_Node
translate_node_idx:    int

// Server config (parsed from config.sjson)
Translate_Server :: struct {
    type_: string,    // "deepl", "libretranslate", or "google"
    url:   string,
    key:   string,
}

translate_server: Maybe(Translate_Server)

// Translation cache
translate_cache: map[u64]string

// Translated page tracking
translated_pages: [dynamic]u64

// Viewport polling
translate_poll_active:        bool
translate_mutation_installed: bool
translate_next_node_id:       int

// Auto-translate domains
translate_auto_domains: [dynamic]string

// Icon label (set from widgets.odin)
translate_icon_label: ^lv_obj_t

// --- Constants ---

translate_models_base: string  // lazily initialized from XDG_DATA_HOME

// Model registry struct — populated by auto-generated translate_models_gen.odin
// Fields are CDN attachment paths (prepend MODELS_CDN to get full URL)
// vocab is set for shared-vocab models; src_vocab+tgt_vocab for CJK/split-vocab models
Translate_Model_Entry :: struct {
    src:       string,
    tgt:       string,
    model:     string,     // attachment path for model.intgemm.alphas.bin
    lex:       string,     // attachment path for lex.50.50.s2t.bin
    vocab:     string,     // attachment path for shared vocab (or "")
    src_vocab: string,     // attachment path for srcvocab (or "")
    tgt_vocab: string,     // attachment path for trgvocab (or "")
}
// translate_registry and MODELS_CDN are defined in translate_models_gen.odin

// --- Init / Shutdown ---

translate_init :: proc() {
    if translate_tgt_lang == "" do translate_tgt_lang = "en"
}

translate_ensure_engine :: proc() -> bool {
    if translate_engine != nil do return true
    translate_engine = translate_engine_init(1)
    if translate_engine == nil do return false
    return true
}

translate_shutdown :: proc() {
    if translate_engine != nil {
        translate_engine_free(translate_engine)
        translate_engine = nil
    }
}

// --- Trigger (from widget click or keybinding) ---

translate_trigger :: proc() {
    if popup_is_active() {
        popup_dismiss()
        return
    }

    // Bergamot path needs engine — server path doesn't
    if _, ok := translate_server.?; !ok {
        if !translate_ensure_engine() {
            translate_popup_info("Translation engine not available.")
            return
        }
    }

    switch translate_state {
    case .Idle:
        translate_state = .Detecting
        translate_icon_set_active()
        translate_detect_language()
    case .Done, .Polling:
        translate_undo()
    case .Detecting, .Downloading, .Walking, .Translating:
        // Already in progress — no popup noise
    }
}

// --- Toggle translation visibility ---

translate_hidden: bool

translate_undo :: proc() {
    if !translate_hidden {
        translate_hidden = true
        engine_run_javascript(`document.documentElement.setAttribute('data-axium-translate-hidden','')`)
        translate_icon_clear_active()
    } else {
        translate_hidden = false
        engine_run_javascript(`document.documentElement.removeAttribute('data-axium-translate-hidden')`)
        translate_icon_set_active()
    }
    if popup_is_active() do popup_dismiss()
}

// --- Language detection via JS ---

translate_detect_language :: proc() {
    js :: `(function() {
    var lang = document.documentElement.lang || '';
    if (lang.indexOf('-') > 0) lang = lang.substring(0, lang.indexOf('-'));
    return JSON.stringify({lang: lang.toLowerCase()});
})()`

    engine_evaluate_javascript(
        strings.clone_to_cstring(js),
        proc "c" (result: cstring) {
            context = runtime.default_context()
            if result == nil {
                translate_state = .Idle
                translate_popup_info("Could not detect page language.")
                return
            }
            translate_on_lang_detected(string(result))
        },
    )
}

translate_on_lang_detected :: proc(result: string) {
    parsed, err := json.parse(transmute([]u8)result)
    if err != .None {
        translate_state = .Idle
        translate_popup_info("Could not detect language.")
        return
    }
    defer json.destroy_value(parsed)

    root := parsed.(json.Object) or_else nil
    if root == nil {
        translate_state = .Idle
        translate_popup_info("Could not detect language.")
        return
    }

    lang := root["lang"].(json.String) or_else ""
    if lang == "" || lang == translate_tgt_lang {
        translate_state = .Idle
        if lang == translate_tgt_lang {
            translate_popup_info("Page is already in target language.")
        } else {
            translate_popup_info("Could not detect page language.")
        }
        return
    }

    if translate_src_lang != "" do delete(translate_src_lang)
    translate_src_lang = strings.clone(lang)

    // Server path — skip model check, go straight to walk
    if _, ok := translate_server.?; ok {
        translate_inject_and_walk()
        return
    }

    // Bergamot path — check if model exists
    model_dir := translate_model_dir(translate_src_lang, translate_tgt_lang)
    defer delete(model_dir)

    config_path := strings.concatenate({model_dir, "/config.bergamot.yml"})
    defer delete(config_path)

    if os.exists(config_path) {
        translate_do_translate(config_path)
    } else {
        entry, found := translate_find_model(translate_src_lang, translate_tgt_lang)
        if found {
            translate_state = .Downloading
            translate_download_model(entry)
        } else {
            translate_state = .Idle
            translate_popup_info(fmt.tprintf("No model available for %s → %s", translate_src_lang, translate_tgt_lang))
        }
    }
}

// --- Model directory helpers ---

translate_get_models_base :: proc() -> string {
    if translate_models_base != "" do return translate_models_base
    translate_models_base = xdg_path(.Data, "translate/models")
    return translate_models_base
}

translate_model_dir :: proc(src, tgt: string) -> string {
    return strings.concatenate({translate_get_models_base(), "/", src, "-", tgt})
}

translate_find_model :: proc(src, tgt: string) -> (Translate_Model_Entry, bool) {
    for &entry in translate_registry {
        if entry.src == src && entry.tgt == tgt {
            return entry, true
        }
    }
    return {}, false
}

// --- Translation: shared ---

// Injects CSS + DOM walker. Used by both bergamot and server paths.
translate_inject_and_walk :: proc() {
    css_js :: `(function(){
  if(document.getElementById('axium-translate-style')) return;
  var s=document.createElement('style');
  s.id='axium-translate-style';
  s.textContent='.axium-translate{display:block;color:inherit;font-style:italic;margin:2px 0;word-break:break-word;border-left:2px solid rgba(128,128,128,0.3);padding-left:6px;opacity:0.8}[data-axium-translate-theme="underline"] .axium-translate{font-style:normal;border-left:none;padding-left:0;border-bottom:2px solid #72ece9;opacity:0.85}[data-axium-translate-theme="highlight"] .axium-translate{font-style:normal;border-left:none;padding-left:0;background:rgba(251,218,65,0.4);opacity:1}[data-axium-translate-theme="mask"] .axium-translate{font-style:normal;border-left:none;padding-left:0;filter:blur(5px);transition:filter 0.3s;opacity:1}[data-axium-translate-theme="mask"] .axium-translate:hover{filter:none}[data-axium-translate-mode="translation"] [data-axium-tid]:has(+.axium-translate){display:none}[data-axium-translate-mode="translation"] .axium-translate{opacity:1;font-style:normal;border-left:none;padding-left:0}[data-axium-translate-mode="hover"] .axium-translate{opacity:0!important;transition:opacity 0.2s}[data-axium-translate-mode="hover"] [data-axium-tid]:hover+.axium-translate,[data-axium-translate-mode="hover"] .axium-translate:hover{opacity:0.8!important}[data-axium-translate-hidden] .axium-translate{display:none!important}[data-axium-translate-hidden] [data-axium-tid]{display:revert!important}';
  document.head.appendChild(s);
})()`
    engine_run_javascript(css_js)
    translate_apply_display()

    translate_state = .Walking

    walker_js :: `(function(){
  var id=0;
  var skip={SCRIPT:1,STYLE:1,NOSCRIPT:1,IFRAME:1,INPUT:1,TEXTAREA:1,SELECT:1,CODE:1,PRE:1,SVG:1};
  window.__axiumVisibleNodes=[];
  window.__axiumTranslatedIds={};
  var walker=document.createTreeWalker(document.body,NodeFilter.SHOW_ELEMENT,{
    acceptNode:function(el){
      if(skip[el.tagName])return NodeFilter.FILTER_REJECT;
      if(el.getAttribute('translate')==='no')return NodeFilter.FILTER_REJECT;
      if(el.classList.contains('notranslate'))return NodeFilter.FILTER_REJECT;
      if(el.classList.contains('axium-translate'))return NodeFilter.FILTER_REJECT;
      for(var i=0;i<el.children.length;i++){
        if(el.children[i].textContent.trim())return NodeFilter.FILTER_SKIP;
      }
      if(el.innerText&&el.innerText.trim().length>1)return NodeFilter.FILTER_ACCEPT;
      return NodeFilter.FILTER_REJECT;
    }
  });
  var node;
  while(node=walker.nextNode()){
    node.setAttribute('data-axium-tid',id);
    id++;
  }
  window.__axiumNextId=id;
  window.__axiumObserver=new IntersectionObserver(function(entries){
    entries.forEach(function(e){
      if(!e.isIntersecting)return;
      var tid=parseInt(e.target.getAttribute('data-axium-tid'));
      if(window.__axiumTranslatedIds[tid])return;
      window.__axiumTranslatedIds[tid]=1;
      window.__axiumVisibleNodes.push({id:tid,text:e.target.innerText});
    });
  },{threshold:0.1});
  var tagged=document.querySelectorAll('[data-axium-tid]');
  for(var i=0;i<tagged.length;i++)window.__axiumObserver.observe(tagged[i]);
  return JSON.stringify({count:id});
})()`

    engine_evaluate_javascript(
        strings.clone_to_cstring(walker_js),
        proc "c" (result: cstring) {
            context = runtime.default_context()
            if result == nil {
                translate_state = .Idle
                translate_popup_info("Failed to scan page content.")
                return
            }
            translate_on_walk_complete(string(result))
        },
    )
}

// Inject a single translated text as a sibling span for the given node ID.
translate_inject_node :: proc(node_id: int, translated: string) {
    escaped := translate_js_escape(translated)
    defer delete(escaped)

    b := strings.builder_make()
    defer strings.builder_destroy(&b)
    strings.write_string(&b, `(function(){var n=document.querySelector('[data-axium-tid="`)
    strings.write_int(&b, node_id)
    strings.write_string(&b, `"]');if(!n)return;var s=document.createElement('font');s.className='axium-translate notranslate';s.setAttribute('translate','no');s.textContent="`)
    strings.write_string(&b, escaped)
    strings.write_string(&b, `";n.after(s)})()`)

    engine_run_javascript(strings.clone_to_cstring(strings.to_string(b)))
}

// Viewport-aware walk complete — replaces old translate_on_walker_done for viewport path
translate_on_walk_complete :: proc(result: string) {
    parsed, err := json.parse(transmute([]u8)result)
    if err != .None {
        translate_state = .Idle
        translate_popup_info("Failed to parse page content.")
        return
    }
    defer json.destroy_value(parsed)

    root := parsed.(json.Object) or_else nil
    if root == nil {
        translate_state = .Idle
        translate_popup_info("No translatable text found.")
        return
    }

    count_val := root["count"].(json.Float) or_else 0
    count := int(count_val)
    if count == 0 {
        translate_state = .Idle
        translate_popup_info("No translatable text found.")
        return
    }

    translate_next_node_id = count
    translate_state = .Polling
    translate_poll_active = true
    clear(&translate_nodes)
    popup_dismiss()

    // Install mutation observer for dynamic content
    translate_install_mutation_observer()
}

// --- Translation: bergamot ---

translate_do_translate :: proc(config_path: string) {
    pair := strings.concatenate({translate_src_lang, "-", translate_tgt_lang})
    defer delete(pair)

    if translate_model_pair != pair {
        if translate_model_pair != "" {
            translate_unload_model(translate_engine)
            delete(translate_model_pair)
        }
        cpath := strings.clone_to_cstring(config_path)
        defer delete(cpath)
        if translate_load_model(translate_engine, cpath) < 0 {
            translate_state = .Idle
            translate_model_pair = ""
            translate_popup_info("Failed to load translation model.")
            return
        }
        translate_model_pair = strings.clone(pair)
    }

    translate_inject_and_walk()
}

// Called from main loop when translate_fd() is readable
translate_on_result_ready :: proc() {
    out_text: cstring
    out_error: cstring

    if translate_poll(translate_engine, &out_text, &out_error) != 1 do return

    if out_error != nil {
        translate_state = .Idle
        translate_popup_info(fmt.tprintf("Translation error: %s", string(out_error)))
        translate_result_free(out_error)
        return
    }

    if out_text != nil {
        idx := translate_node_idx
        total := len(translate_nodes)

        translated := string(out_text)
        translate_inject_node(translate_nodes[idx].id, translated)
        translate_cache_store(translate_src_lang, translate_tgt_lang, translate_nodes[idx].text, translated)
        translate_result_free(out_text)

        translate_node_idx += 1
        if translate_node_idx >= total {
            if translate_poll_active {
                translate_state = .Polling
                clear(&translate_nodes)
            } else {
                translate_state = .Done
                translate_mark_page_translated()
                popup_dismiss()
            }
        } else {
            // Continue translating next node silently
            ctext := strings.clone_to_cstring(translate_nodes[translate_node_idx].text)
            defer delete(ctext)
            translate_text(translate_engine, ctext, 0)
        }
    }
}

translate_get_fd :: proc() -> c.int {
    if translate_engine == nil do return -1
    return translate_fd(translate_engine)
}

// --- Translation: server ---

translate_server_batch :: proc(server: Translate_Server) {
    translate_state = .Translating
    // Translate silently

    switch server.type_ {
    case "deepl":         translate_server_deepl(server)
    case "libretranslate": translate_server_libretranslate(server)
    case "google":        translate_server_google(server)
    case:
        translate_state = .Idle
        translate_popup_info(fmt.tprintf("Unknown server type: %s", server.type_))
    }
}

translate_server_deepl :: proc(server: Translate_Server) {
    body := strings.builder_make()
    defer strings.builder_destroy(&body)

    strings.write_string(&body, `{"text":[`)
    for &node, i in translate_nodes {
        if i > 0 do strings.write_string(&body, ",")
        strings.write_byte(&body, '"')
        escaped := translate_json_escape(node.text)
        strings.write_string(&body, escaped)
        delete(escaped)
        strings.write_byte(&body, '"')
    }
    src_upper := translate_str_upper(translate_src_lang)
    defer delete(src_upper)
    tgt_upper := translate_str_upper(translate_tgt_lang)
    defer delete(tgt_upper)
    strings.write_string(&body, `],"source_lang":"`)
    strings.write_string(&body, src_upper)
    strings.write_string(&body, `","target_lang":"`)
    strings.write_string(&body, tgt_upper)
    strings.write_string(&body, `"}`)

    url := server.url if server.url != "" else "https://api-free.deepl.com/v2/translate"
    auth := fmt.tprintf("Authorization: DeepL-Auth-Key %s", server.key)
    resp, ok := translate_http_post(url, {auth, "Content-Type: application/json"}, strings.to_string(body))
    if !ok {
        translate_state = .Idle
        translate_popup_info("DeepL API request failed.")
        return
    }
    defer delete(resp)

    parsed, perr := json.parse(transmute([]u8)resp)
    if perr != .None {
        translate_state = .Idle
        translate_popup_info("Failed to parse DeepL response.")
        return
    }
    defer json.destroy_value(parsed)

    root := parsed.(json.Object) or_else nil
    translations := root["translations"].(json.Array) or_else nil if root != nil else nil
    if translations == nil {
        translate_state = .Idle
        translate_popup_info("DeepL returned unexpected response.")
        return
    }

    for trans, i in translations {
        if i >= len(translate_nodes) do break
        obj := trans.(json.Object) or_else nil
        if obj == nil do continue
        text := obj["text"].(json.String) or_else ""
        if text != "" {
            translate_inject_node(translate_nodes[i].id, text)
            translate_cache_store(translate_src_lang, translate_tgt_lang, translate_nodes[i].text, text)
        }
    }

    if translate_poll_active {
        translate_state = .Polling
        clear(&translate_nodes)
    } else {
        translate_state = .Done
        translate_mark_page_translated()
        popup_dismiss()
    }
}

translate_server_libretranslate :: proc(server: Translate_Server) {
    // Build JSON: {"q":["t1","t2",...], "source":"vi", "target":"en", "api_key":"..."}
    body := strings.builder_make()
    defer strings.builder_destroy(&body)

    strings.write_string(&body, `{"q":[`)
    for &node, i in translate_nodes {
        if i > 0 do strings.write_string(&body, ",")
        strings.write_byte(&body, '"')
        escaped := translate_json_escape(node.text)
        strings.write_string(&body, escaped)
        delete(escaped)
        strings.write_byte(&body, '"')
    }
    strings.write_string(&body, `],"source":"`)
    strings.write_string(&body, translate_src_lang)
    strings.write_string(&body, `","target":"`)
    strings.write_string(&body, translate_tgt_lang)
    strings.write_byte(&body, '"')
    if server.key != "" {
        strings.write_string(&body, `,"api_key":"`)
        strings.write_string(&body, server.key)
        strings.write_byte(&body, '"')
    }
    strings.write_byte(&body, '}')

    url := server.url if server.url != "" else "https://libretranslate.com/translate"
    resp, ok := translate_http_post(url, {"Content-Type: application/json"}, strings.to_string(body))
    if !ok {
        translate_state = .Idle
        translate_popup_info("LibreTranslate API request failed.")
        return
    }
    defer delete(resp)

    parsed, perr := json.parse(transmute([]u8)resp)
    if perr != .None {
        translate_state = .Idle
        translate_popup_info("Failed to parse LibreTranslate response.")
        return
    }
    defer json.destroy_value(parsed)

    root := parsed.(json.Object) or_else nil
    if root == nil {
        translate_state = .Idle
        translate_popup_info("LibreTranslate returned unexpected response.")
        return
    }

    // Response: {"translatedText": ["r1","r2",...]} (batch) or {"translatedText": "r1"} (single)
    translated_arr := root["translatedText"].(json.Array) or_else nil
    if translated_arr != nil {
        for text_val, i in translated_arr {
            if i >= len(translate_nodes) do break
            text := text_val.(json.String) or_else ""
            if text != "" {
                translate_inject_node(translate_nodes[i].id, text)
                translate_cache_store(translate_src_lang, translate_tgt_lang, translate_nodes[i].text, text)
            }
        }
    } else {
        // Single-text response — shouldn't happen with batch request, but handle gracefully
        text := root["translatedText"].(json.String) or_else ""
        if text != "" && len(translate_nodes) > 0 {
            translate_inject_node(translate_nodes[0].id, text)
            translate_cache_store(translate_src_lang, translate_tgt_lang, translate_nodes[0].text, text)
        }
    }

    if translate_poll_active {
        translate_state = .Polling
        clear(&translate_nodes)
    } else {
        translate_state = .Done
        translate_mark_page_translated()
        popup_dismiss()
    }
}

translate_server_google :: proc(server: Translate_Server) {
    // Build JSON: {"q":["t1","t2",...], "source":"vi", "target":"en", "format":"text"}
    body := strings.builder_make()
    defer strings.builder_destroy(&body)

    strings.write_string(&body, `{"q":[`)
    for &node, i in translate_nodes {
        if i > 0 do strings.write_string(&body, ",")
        strings.write_byte(&body, '"')
        escaped := translate_json_escape(node.text)
        strings.write_string(&body, escaped)
        delete(escaped)
        strings.write_byte(&body, '"')
    }
    strings.write_string(&body, `],"source":"`)
    strings.write_string(&body, translate_src_lang)
    strings.write_string(&body, `","target":"`)
    strings.write_string(&body, translate_tgt_lang)
    strings.write_string(&body, `","format":"text"}`)

    base_url := server.url if server.url != "" else "https://translation.googleapis.com/language/translate/v2"
    url := fmt.tprintf("%s?key=%s", base_url, server.key)

    resp, ok := translate_http_post(url, {"Content-Type: application/json"}, strings.to_string(body))
    if !ok {
        translate_state = .Idle
        translate_popup_info("Google Translate API request failed.")
        return
    }
    defer delete(resp)

    parsed, perr := json.parse(transmute([]u8)resp)
    if perr != .None {
        translate_state = .Idle
        translate_popup_info("Failed to parse Google response.")
        return
    }
    defer json.destroy_value(parsed)

    // Response: {"data":{"translations":[{"translatedText":"r1"},...]}}
    root := parsed.(json.Object) or_else nil
    data := root["data"].(json.Object) or_else nil if root != nil else nil
    translations := data["translations"].(json.Array) or_else nil if data != nil else nil
    if translations == nil {
        translate_state = .Idle
        translate_popup_info("Google returned unexpected response.")
        return
    }

    for trans, i in translations {
        if i >= len(translate_nodes) do break
        obj := trans.(json.Object) or_else nil
        if obj == nil do continue
        text := obj["translatedText"].(json.String) or_else ""
        if text != "" {
            translate_inject_node(translate_nodes[i].id, text)
            translate_cache_store(translate_src_lang, translate_tgt_lang, translate_nodes[i].text, text)
        }
    }

    if translate_poll_active {
        translate_state = .Polling
        clear(&translate_nodes)
    } else {
        translate_state = .Done
        translate_mark_page_translated()
        popup_dismiss()
    }
}

// --- Display mode toggle ---

DISPLAY_MODE_NAMES := [Translate_Display]string{
    .Dual        = "dual",
    .Translation = "translation",
    .Hover       = "hover",
}

THEME_NAMES := [Translate_Theme]string{
    .Default   = "default",
    .Underline = "underline",
    .Highlight = "highlight",
    .Mask      = "mask",
}

translate_toggle :: proc() {
    translate_display = Translate_Display((int(translate_display) + 1) % 3)
    translate_apply_display()
    translate_popup_info(fmt.tprintf("Display: %s", DISPLAY_MODE_NAMES[translate_display]))
}

translate_toggle_theme :: proc() {
    translate_theme = Translate_Theme((int(translate_theme) + 1) % 4)
    translate_apply_display()
    translate_popup_info(fmt.tprintf("Theme: %s", THEME_NAMES[translate_theme]))
}

translate_apply_display :: proc() {
    b := strings.builder_make()
    defer strings.builder_destroy(&b)
    strings.write_string(&b, `(function(){var d=document.documentElement;d.setAttribute('data-axium-translate-mode','`)
    strings.write_string(&b, DISPLAY_MODE_NAMES[translate_display])
    strings.write_string(&b, `');d.setAttribute('data-axium-translate-theme','`)
    strings.write_string(&b, THEME_NAMES[translate_theme])
    strings.write_string(&b, `')})()`)
    engine_run_javascript(strings.clone_to_cstring(strings.to_string(b)))
}

// --- Model download ---

translate_download_model :: proc(entry: Translate_Model_Entry) {
    model_dir := translate_model_dir(entry.src, entry.tgt)
    defer delete(model_dir)

    translate_mkdir_p(model_dir)

    model_path := strings.concatenate({model_dir, "/model.intgemm.alphas.bin"})
    defer delete(model_path)
    model_url := strings.concatenate({MODELS_CDN, entry.model})
    defer delete(model_url)
    if !translate_http_download(model_url, model_path) {
        translate_state = .Idle
        translate_popup_info("Failed to download model.")
        return
    }

    lex_path := strings.concatenate({model_dir, "/lex.50.50.s2t.bin"})
    defer delete(lex_path)
    lex_url := strings.concatenate({MODELS_CDN, entry.lex})
    defer delete(lex_url)
    if !translate_http_download(lex_url, lex_path) {
        translate_state = .Idle
        translate_popup_info("Failed to download lexicon.")
        return
    }

    if entry.vocab != "" {
        vocab_path := strings.concatenate({model_dir, "/vocab.spm"})
        defer delete(vocab_path)
        vocab_url := strings.concatenate({MODELS_CDN, entry.vocab})
        defer delete(vocab_url)
        if !translate_http_download(vocab_url, vocab_path) {
            translate_state = .Idle
            translate_popup_info("Failed to download vocabulary.")
            return
        }
    } else {
        src_path := strings.concatenate({model_dir, "/srcvocab.spm"})
        defer delete(src_path)
        src_url := strings.concatenate({MODELS_CDN, entry.src_vocab})
        defer delete(src_url)
        if !translate_http_download(src_url, src_path) {
            translate_state = .Idle
            translate_popup_info("Failed to download source vocabulary.")
            return
        }
        tgt_path := strings.concatenate({model_dir, "/trgvocab.spm"})
        defer delete(tgt_path)
        tgt_url := strings.concatenate({MODELS_CDN, entry.tgt_vocab})
        defer delete(tgt_url)
        if !translate_http_download(tgt_url, tgt_path) {
            translate_state = .Idle
            translate_popup_info("Failed to download target vocabulary.")
            return
        }
    }

    translate_generate_config(model_dir, entry)

    config_path := strings.concatenate({model_dir, "/config.bergamot.yml"})
    defer delete(config_path)
    translate_do_translate(config_path)
}

translate_generate_config :: proc(model_dir: string, entry: Translate_Model_Entry) {
    src_vocab, tgt_vocab: string
    if entry.vocab != "" {
        src_vocab = strings.concatenate({model_dir, "/vocab.spm"})
        tgt_vocab = strings.concatenate({model_dir, "/vocab.spm"})
    } else {
        src_vocab = strings.concatenate({model_dir, "/srcvocab.spm"})
        tgt_vocab = strings.concatenate({model_dir, "/trgvocab.spm"})
    }
    defer delete(src_vocab)
    defer delete(tgt_vocab)

    config := fmt.tprintf(
`beam-size: 1
normalize: 1.0
word-penalty: 0
max-length-break: 128
mini-batch-words: 1024
workspace: 128
max-length-factor: 2.0
skip-cost: true
cpu-threads: 0
quiet: true
quiet-translation: true
gemm-precision: int8shiftAlphaAll
alignment: soft
models:
  - %s/model.intgemm.alphas.bin
vocabs:
  - %s
  - %s
shortlist:
  - %s/lex.50.50.s2t.bin
  - false`,
        model_dir, src_vocab, tgt_vocab, model_dir,
    )

    config_path := strings.concatenate({model_dir, "/config.bergamot.yml"})
    defer delete(config_path)
    os.write_entire_file(config_path, transmute([]u8)config)
}

// --- HTTP helpers ---

translate_http_download :: proc(url_str, dest_path: string) -> bool {
    cmd := fmt.tprintf("curl -sL -o '%s' '%s'", dest_path, url_str)
    ccmd := strings.clone_to_cstring(cmd)
    defer delete(ccmd)
    return libc_system(ccmd) == 0
}

TRANSLATE_REQ_PATH  :: "/tmp/axium-translate-req.json"
TRANSLATE_RESP_PATH :: "/tmp/axium-translate-resp.json"

translate_http_post :: proc(url: string, headers: []string, body: string) -> (string, bool) {
    // Write body to temp file to avoid shell escaping issues
    os.write_entire_file(TRANSLATE_REQ_PATH, transmute([]u8)body)

    b := strings.builder_make()
    defer strings.builder_destroy(&b)

    strings.write_string(&b, "curl -s -X POST ")
    for h in headers {
        strings.write_string(&b, `-H '`)
        strings.write_string(&b, h)
        strings.write_string(&b, `' `)
    }
    strings.write_string(&b, "-d @")
    strings.write_string(&b, TRANSLATE_REQ_PATH)
    strings.write_string(&b, " -o ")
    strings.write_string(&b, TRANSLATE_RESP_PATH)
    strings.write_string(&b, ` '`)
    strings.write_string(&b, url)
    strings.write_byte(&b, '\'')

    cmd := strings.clone_to_cstring(strings.to_string(b))
    defer delete(cmd)

    if libc_system(cmd) != 0 {
        return "", false
    }

    resp, ok := os.read_entire_file(TRANSLATE_RESP_PATH)
    if !ok do return "", false

    return string(resp), true
}

translate_mkdir_p :: proc(path: string) {
    parts := strings.split(path, "/")
    defer delete(parts)

    current := strings.builder_make()
    defer strings.builder_destroy(&current)

    for part in parts {
        if part == "" {
            strings.write_byte(&current, '/')
            continue
        }
        if strings.builder_len(current) > 0 && current.buf[strings.builder_len(current)-1] != '/' {
            strings.write_byte(&current, '/')
        }
        strings.write_string(&current, part)
        dir := strings.to_string(current)
        os.make_directory(dir)
    }
}

// --- Popup UI ---

translate_popup_info :: proc(msg: string) {
    if popup_is_active() do popup_dismiss()

    panel := lv_obj_create(lv_layer_top())
    lv_obj_set_size(panel, LV_SIZE_CONTENT, LV_SIZE_CONTENT)
    lv_obj_set_style_bg_color(panel, lv_color_hex(theme_bg_prim), 0)
    lv_obj_set_style_bg_opa(panel, u8(theme_bg_opacity), 0)
    lv_obj_set_style_text_color(panel, lv_color_hex(theme_text_pri), 0)
    lv_obj_set_style_radius(panel, 12, 0)
    lv_obj_set_style_pad_top(panel, theme_padding, 0)
    lv_obj_set_style_pad_bottom(panel, theme_padding, 0)
    lv_obj_set_style_pad_left(panel, theme_padding, 0)
    lv_obj_set_style_pad_right(panel, theme_padding, 0)
    lv_obj_remove_flag(panel, .LV_OBJ_FLAG_SCROLLABLE)

    lbl := lv_label_create(panel)
    lv_label_set_text(lbl, strings.clone_to_cstring(msg))

    if translate_popup_anchor != nil {
        popup_show(panel, translate_popup_anchor)
    }
}

// --- Helpers ---

@(private)
translate_js_escape :: proc(s: string) -> string {
    b := strings.builder_make()
    for ch in s {
        switch ch {
        case 0:        // skip null bytes
        case '\\':     strings.write_string(&b, "\\\\")
        case '"':      strings.write_string(&b, "\\\"")
        case '\n':     strings.write_string(&b, "\\n")
        case '\r':     strings.write_string(&b, "\\r")
        case '\t':     strings.write_string(&b, "\\t")
        case '\u2028': strings.write_string(&b, "\\u2028")
        case '\u2029': strings.write_string(&b, "\\u2029")
        case:          strings.write_rune(&b, ch)
        }
    }
    return strings.to_string(b)
}

@(private)
translate_json_escape :: proc(s: string) -> string {
    b := strings.builder_make()
    for ch in s {
        switch ch {
        case '\\': strings.write_string(&b, "\\\\")
        case '"':  strings.write_string(&b, "\\\"")
        case '\n': strings.write_string(&b, "\\n")
        case '\r': strings.write_string(&b, "\\r")
        case '\t': strings.write_string(&b, "\\t")
        case:      strings.write_rune(&b, ch)
        }
    }
    return strings.to_string(b)
}

@(private)
translate_str_upper :: proc(s: string) -> string {
    b := strings.builder_make()
    for ch in s {
        if ch >= 'a' && ch <= 'z' {
            strings.write_byte(&b, u8(ch - 'a' + 'A'))
        } else {
            strings.write_rune(&b, ch)
        }
    }
    return strings.to_string(b)
}

// --- Translation cache ---

translate_cache_key :: proc(src, tgt, text: string) -> u64 {
    input := strings.concatenate({src, ":", tgt, ":", text})
    defer delete(input)
    return hash.murmur64a(transmute([]byte)input)
}

translate_cache_lookup :: proc(src, tgt, text: string) -> (string, bool) {
    key := translate_cache_key(src, tgt, text)
    if result, ok := translate_cache[key]; ok {
        return result, true
    }
    return "", false
}

translate_cache_store :: proc(src, tgt, text, result: string) {
    key := translate_cache_key(src, tgt, text)
    translate_cache[key] = strings.clone(result)
}

// --- Translated page tracking ---

translate_url_hash :: proc() -> u64 {
    if active_tab < 0 || active_tab >= tab_count do return 0
    url := tab_entries[active_tab].uri
    if len(url) == 0 do return 0
    return hash.murmur64a(transmute([]byte)url)
}

translate_page_is_translated :: proc(url_hash: u64) -> bool {
    for h in translated_pages {
        if h == url_hash do return true
    }
    return false
}

translate_mark_page_translated :: proc() {
    h := translate_url_hash()
    if h != 0 && !translate_page_is_translated(h) {
        append(&translated_pages, h)
    }
}

// --- Icon accent ---

translate_icon_set_active :: proc() {
    if translate_icon_label != nil {
        lv_obj_set_style_text_color(translate_icon_label, lv_color_hex(theme_accent), 0)
    }
}

translate_icon_clear_active :: proc() {
    if translate_icon_label != nil {
        lv_obj_set_style_text_color(translate_icon_label, lv_color_hex(theme_text_pri), 0)
    }
}

// --- Navigation hook ---

translate_extract_domain :: proc(url: string) -> string {
    rest := url
    if idx := strings.index(url, "://"); idx >= 0 do rest = url[idx+3:]
    if idx := strings.index_byte(rest, '/'); idx >= 0 do rest = rest[:idx]
    if idx := strings.index_byte(rest, ':'); idx >= 0 do rest = rest[:idx]
    return rest
}

translate_should_auto :: proc(url: string) -> bool {
    domain := translate_extract_domain(url)
    for d in translate_auto_domains {
        if domain == d do return true
        suffix := strings.concatenate({".", d})
        defer delete(suffix)
        if strings.has_suffix(domain, suffix) do return true
    }
    return false
}

translate_on_navigation :: proc(uri: string) {
    translate_icon_clear_active()

    // Reset state on new page
    translate_hidden = false
    if translate_src_lang != "" {
        delete(translate_src_lang)
        translate_src_lang = ""
    }
    if translate_state != .Idle {
        translate_state = .Idle
        translate_poll_active = false
        translate_mutation_installed = false
        if popup_is_active() do popup_dismiss()
    }

    // Auto-translate check
    h := translate_url_hash()
    if !translate_page_is_translated(h) && translate_should_auto(uri) {
        translate_trigger()
    }
}

// --- Viewport polling ---

translate_poll_visible :: proc() {
    if !translate_poll_active || translate_hidden do return

    js :: `(function(){
  var n=window.__axiumVisibleNodes||[];
  window.__axiumVisibleNodes=[];
  return JSON.stringify(n);
})()`

    engine_evaluate_javascript(
        strings.clone_to_cstring(js),
        proc "c" (result: cstring) {
            context = runtime.default_context()
            if result == nil do return
            translate_on_visible_nodes(string(result))
        },
    )
}

translate_on_visible_nodes :: proc(result: string) {
    parsed, err := json.parse(transmute([]u8)result)
    if err != .None do return
    defer json.destroy_value(parsed)

    arr := parsed.(json.Array) or_else nil
    if arr == nil || len(arr) == 0 do return

    uncached: [dynamic]Translate_Node
    defer delete(uncached)

    for item in arr {
        obj := item.(json.Object) or_else nil
        if obj == nil do continue
        id_val := obj["id"].(json.Float) or_else -1
        text_val := obj["text"].(json.String) or_else ""
        if id_val < 0 || text_val == "" do continue

        node_id := int(id_val)

        // Check cache first
        if cached, ok := translate_cache_lookup(translate_src_lang, translate_tgt_lang, text_val); ok {
            translate_inject_node(node_id, cached)
        } else {
            append(&uncached, Translate_Node{id = node_id, text = strings.clone(text_val)})
        }
    }

    if len(uncached) == 0 do return

    // Server path — batch all uncached visible nodes
    if server, ok := translate_server.?; ok {
        clear(&translate_nodes)
        for &node in uncached {
            append(&translate_nodes, node)
        }
        translate_state = .Translating
        translate_server_batch(server)
        return
    }

    // Bergamot path — queue uncached nodes, submit one at a time
    for &node in uncached {
        append(&translate_nodes, node)
    }
    if translate_state != .Translating {
        translate_state = .Translating
        translate_node_idx = 0
        ctext := strings.clone_to_cstring(translate_nodes[0].text)
        defer delete(ctext)
        translate_text(translate_engine, ctext, 0)
    }
}

// --- Block translate ---

translate_block_trigger :: proc() {
    js := fmt.tprintf(`(function(){
  var sel=window.getSelection();
  if(sel&&sel.toString().trim()){
    return JSON.stringify({type:"selection",id:-1,text:sel.toString().trim()});
  }
  var mx=%d,my=%d;
  var el=document.elementFromPoint(mx,my);
  if(!el)return JSON.stringify({type:"none"});
  while(el&&el.children&&el.children.length>0){
    var found=false;
    for(var i=0;i<el.children.length;i++){
      var r=el.children[i].getBoundingClientRect();
      if(mx>=r.left&&mx<=r.right&&my>=r.top&&my<=r.bottom){el=el.children[i];found=true;break;}
    }
    if(!found)break;
  }
  var text=el.innerText||el.textContent||'';
  if(!text.trim())return JSON.stringify({type:"none"});
  var tid=el.getAttribute('data-axium-tid');
  if(!tid){
    var nid=window.__axiumNextId||0;
    el.setAttribute('data-axium-tid',nid);
    tid=nid;
    window.__axiumNextId=nid+1;
  }
  return JSON.stringify({type:"element",id:parseInt(tid),text:text.trim()});
})()`, mouse_screen_x - content_area.x, mouse_screen_y - content_area.y)

    engine_evaluate_javascript(
        strings.clone_to_cstring(js),
        proc "c" (result: cstring) {
            context = runtime.default_context()
            if result == nil do return
            translate_on_block_result(string(result))
        },
    )
}

translate_on_block_result :: proc(result: string) {
    parsed, err := json.parse(transmute([]u8)result)
    if err != .None do return
    defer json.destroy_value(parsed)

    root := parsed.(json.Object) or_else nil
    if root == nil do return

    type_ := root["type"].(json.String) or_else "none"
    if type_ == "none" do return

    text := root["text"].(json.String) or_else ""
    if text == "" do return

    id_val := root["id"].(json.Float) or_else -1
    node_id := int(id_val)

    // Check cache
    if cached, ok := translate_cache_lookup(translate_src_lang, translate_tgt_lang, text); ok {
        if type_ == "selection" {
            translate_popup_info(cached)
        } else {
            translate_inject_node(node_id, cached)
        }
        return
    }

    // Need to detect language first if not already known
    if translate_src_lang == "" {
        translate_popup_info("Press translate first to detect language.")
        return
    }

    // Server path
    if server, ok := translate_server.?; ok {
        clear(&translate_nodes)
        append(&translate_nodes, Translate_Node{id = node_id, text = strings.clone(text)})
        translate_server_batch(server)
        if type_ == "selection" && len(translate_nodes) > 0 {
            // Server batch already injected, but for selection show popup
            // (handled by translate_inject_node for element type)
        }
        return
    }

    // Bergamot path
    if !translate_ensure_engine() {
        translate_popup_info("Translation engine not available.")
        return
    }
    if translate_model_pair == "" {
        translate_popup_info("Load a model first (translate the page).")
        return
    }

    clear(&translate_nodes)
    append(&translate_nodes, Translate_Node{id = node_id, text = strings.clone(text)})
    translate_node_idx = 0
    // Don't change page-level translate_state for block translate
    ctext := strings.clone_to_cstring(text)
    defer delete(ctext)
    translate_text(translate_engine, ctext, 0)
}

// --- Mutation observer ---

translate_install_mutation_observer :: proc() {
    if translate_mutation_installed do return
    translate_mutation_installed = true

    js :: `(function(){
  if(window.__axiumMutationObs) return;
  var skip={SCRIPT:1,STYLE:1,NOSCRIPT:1,IFRAME:1,INPUT:1,TEXTAREA:1,SELECT:1,CODE:1,PRE:1,SVG:1};
  window.__axiumMutationObs=new MutationObserver(function(mutations){
    mutations.forEach(function(m){
      m.addedNodes.forEach(function(n){
        if(n.nodeType!==1)return;
        if(n.classList&&n.classList.contains('axium-translate'))return;
        if(skip[n.tagName])return;
        var walker=document.createTreeWalker(n,NodeFilter.SHOW_ELEMENT,{
          acceptNode:function(el){
            if(skip[el.tagName])return NodeFilter.FILTER_REJECT;
            if(el.getAttribute('translate')==='no')return NodeFilter.FILTER_REJECT;
            if(el.classList.contains('notranslate'))return NodeFilter.FILTER_REJECT;
            if(el.classList.contains('axium-translate'))return NodeFilter.FILTER_REJECT;
            if(el.getAttribute('data-axium-tid')!==null)return NodeFilter.FILTER_REJECT;
            for(var i=0;i<el.children.length;i++){
              if(el.children[i].textContent.trim())return NodeFilter.FILTER_SKIP;
            }
            if(el.innerText&&el.innerText.trim().length>1)return NodeFilter.FILTER_ACCEPT;
            return NodeFilter.FILTER_REJECT;
          }
        });
        var node;
        while(node=walker.nextNode()){
          var nid=window.__axiumNextId||0;
          node.setAttribute('data-axium-tid',nid);
          window.__axiumNextId=nid+1;
          if(window.__axiumObserver)window.__axiumObserver.observe(node);
        }
      });
    });
  });
  window.__axiumMutationObs.observe(document.body,{childList:true,subtree:true});
})()`

    engine_run_javascript(strings.clone_to_cstring(js))
}

// --- Config parsing ---

translate_parse_config :: proc(obj: json.Object) {
    if obj == nil do return

    if tgt, ok := obj["target"].(json.String); ok {
        translate_tgt_lang = strings.clone(tgt)
    }

    if display, ok := obj["display"].(json.String); ok {
        switch display {
        case "dual":        translate_display = .Dual
        case "translation": translate_display = .Translation
        case "hover":       translate_display = .Hover
        }
    }

    if theme, ok := obj["theme"].(json.String); ok {
        switch theme {
        case "default":   translate_theme = .Default
        case "underline": translate_theme = .Underline
        case "highlight": translate_theme = .Highlight
        case "mask":      translate_theme = .Mask
        }
    }

    server_obj, has_server := obj["server"].(json.Object)
    if has_server && server_obj != nil {
        server: Translate_Server
        server.type_ = strings.clone(server_obj["type"].(json.String) or_else "")
        server.url   = strings.clone(server_obj["url"].(json.String) or_else "")
        server.key   = strings.clone(server_obj["key"].(json.String) or_else "")
        translate_server = server
    }

    if auto_arr, ok := obj["auto_translate"].(json.Array); ok {
        for item in auto_arr {
            domain := item.(json.String) or_else ""
            if domain != "" do append(&translate_auto_domains, strings.clone(domain))
        }
    }
}
