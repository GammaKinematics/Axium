package axium

import "base:runtime"
import "core:c"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// --- State ---

Keepass_State :: enum {
    Disconnected,
    Connecting,         // key exchange in progress
    Associated,         // ready to make requests
    Waiting_Response,   // request sent, waiting for socket data
}

Keepass_Action :: enum {
    None,
    Associate,
    Test_Associate,
    Get_Logins,
    Set_Login,
    Generate_Password,
    Get_Database_Groups,
}

Keepass_Entry :: struct {
    login:    string,
    password: string,
}

Keepass_Group :: struct {
    name: string,
    uuid: string,
}

keepass_groups: [dynamic]Keepass_Group  // flattened groups from get-database-groups

keepass_state:          Keepass_State
keepass_assoc_id:       string
keepass_id_public:      [crypto_box_PUBLICKEYBYTES]u8
keepass_id_secret:      [crypto_box_SECRETKEYBYTES]u8
keepass_entries:        [dynamic]Keepass_Entry
keepass_pending_action: Keepass_Action
keepass_popup_anchor:   ^lv_obj_t   // widget button, anchor for popup positioning

// Generated password from last generate-password response
keepass_generated_pw:   string

// Stashed credentials for save confirmation callback
keepass_save_user:      string
keepass_save_pass:      string

// --- Init ---

keepass_init :: proc() {
    if sodium_init() < 0 {
        fmt.eprintln("[keepass] sodium_init failed")
        return
    }
    keepass_load_association()
}

// --- Main entry point (Ctrl+K or widget click) ---

keepass_trigger :: proc() {
    // Toggle popup off if active
    if popup_is_active() {
        popup_dismiss()
        return
    }

    switch keepass_state {
    case .Disconnected:
        if !keepass_connect() {
            keepass_popup_info("Cannot connect to KeePassXC.\nIs it running with browser integration enabled?")
            return
        }
        keepass_state = .Connecting
        if !keepass_exchange_keys() {
            keepass_disconnect()
            keepass_state = .Disconnected
            keepass_popup_info("Key exchange failed.")
            return
        }
        // Check if we have a stored association
        if keepass_assoc_id != "" {
            keepass_do_test_associate()
        } else {
            keepass_do_associate()
        }

    case .Connecting:
        keepass_popup_info("Connecting...")

    case .Associated:
        keepass_do_get_logins()

    case .Waiting_Response:
        keepass_popup_info("Waiting for KeePassXC...")
    }
}

// --- Protocol actions ---

keepass_do_associate :: proc() {
    // Generate identification keypair (persisted after successful association)
    crypto_box_keypair(&keepass_id_public[0], &keepass_id_secret[0])

    id_key_b64 := base64_encode(keepass_id_public[:])
    pk_b64 := base64_encode(client_public_key[:])
    defer delete(id_key_b64)
    defer delete(pk_b64)

    inner := fmt.tprintf(
        `{{"action":"associate","key":"%s","idKey":"%s"}}`,
        pk_b64, id_key_b64,
    )

    req := keepass_build_request("associate", inner)
    defer delete(req)

    keepass_send(req)
    keepass_pending_action = .Associate
    keepass_state = .Waiting_Response
    keepass_popup_info("Waiting for KeePassXC approval...")
}

keepass_do_test_associate :: proc() {
    id_key_b64 := base64_encode(keepass_id_public[:])
    defer delete(id_key_b64)

    inner := fmt.tprintf(
        `{{"action":"test-associate","id":"%s","key":"%s"}}`,
        keepass_assoc_id, id_key_b64,
    )

    req := keepass_build_request("test-associate", inner)
    defer delete(req)

    keepass_send(req)
    keepass_pending_action = .Test_Associate
    keepass_state = .Waiting_Response
    keepass_popup_info("Verifying association...")
}

keepass_do_get_logins :: proc() {
    uri := keepass_current_url()
    if uri == "" {
        keepass_popup_info("No URL loaded.")
        return
    }

    id_key_b64 := base64_encode(keepass_id_public[:])
    defer delete(id_key_b64)

    inner := fmt.tprintf(
        `{{"action":"get-logins","url":"%s","keys":[{{"id":"%s","key":"%s"}}]}}`,
        uri, keepass_assoc_id, id_key_b64,
    )

    req := keepass_build_request("get-logins", inner)
    defer delete(req)

    keepass_send(req)
    keepass_pending_action = .Get_Logins
    keepass_state = .Waiting_Response
    keepass_popup_info("Loading logins...")
}

// --- Response handler (called from main loop when socket readable) ---

keepass_on_response_ready :: proc() {
    data, ok := keepass_recv()
    if !ok {
        // Socket error — connection lost
        keepass_disconnect()
        keepass_state = .Disconnected
        keepass_popup_info("Connection to KeePassXC lost.")
        return
    }

    keepass_on_response(data)
}

keepass_on_response :: proc(data: string) {
    // Parse outer envelope
    parsed, err := json.parse(transmute([]u8)data)
    if err != .None {
        keepass_state = .Associated if keepass_assoc_id != "" else .Disconnected
        keepass_popup_info("Invalid response from KeePassXC.")
        return
    }
    defer json.destroy_value(parsed)

    root := parsed.(json.Object) or_else nil
    if root == nil {
        keepass_state = .Associated if keepass_assoc_id != "" else .Disconnected
        keepass_popup_info("Invalid response format.")
        return
    }

    action := keepass_pending_action
    keepass_pending_action = .None

    // Check for error
    if error_msg, has_error := root["error"]; has_error {
        error_str := error_msg.(json.String) or_else "Unknown error"

        // "No logins found" is not a real error — show main popup with Save/Generate
        if action == .Get_Logins {
            keepass_state = .Associated
            keepass_clear_entries()
            keepass_popup_main()
            return
        }

        keepass_disconnect()
        keepass_state = .Disconnected
        keepass_popup_info(fmt.tprintf("KeePassXC: %s", error_str))
        return
    }

    // Decrypt inner message if present
    encrypted_msg := root["message"].(json.String) or_else ""
    nonce_b64 := root["nonce"].(json.String) or_else ""
    _ = nonce_b64  // nonce is managed internally

    inner_str: string
    inner_ok: bool
    if encrypted_msg != "" {
        inner_str, inner_ok = keepass_decrypt(encrypted_msg)
        if !inner_ok {
            keepass_state = .Associated if keepass_assoc_id != "" else .Disconnected
            keepass_popup_info("Failed to decrypt response.")
            return
        }
    }
    defer if inner_ok do delete(transmute([]u8)inner_str)

    // Parse inner message
    inner_parsed: json.Value
    inner_root: json.Object
    if inner_ok && inner_str != "" {
        inner_parsed, err = json.parse(transmute([]u8)inner_str)
        if err == .None {
            inner_root = inner_parsed.(json.Object) or_else nil
        }
    }
    defer if inner_root != nil do json.destroy_value(inner_parsed)

    switch action {
    case .Associate:
        keepass_handle_associate(inner_root)
    case .Test_Associate:
        keepass_handle_test_associate(inner_root)
    case .Get_Logins:
        keepass_handle_get_logins(inner_root)
    case .Set_Login:
        keepass_state = .Associated
        keepass_popup_info("Credentials saved.")
    case .Generate_Password:
        keepass_handle_generate_password(inner_root)
    case .Get_Database_Groups:
        keepass_handle_get_groups(inner_root)
    case .None:
        // Unexpected response
    }
}

// --- Response handlers ---

keepass_handle_associate :: proc(inner: json.Object) {
    if inner == nil {
        keepass_state = .Disconnected
        keepass_popup_info("Association failed.")
        return
    }

    success := inner["success"].(json.String) or_else ""
    if success != "true" {
        keepass_state = .Disconnected
        keepass_popup_info("Association denied by KeePassXC.")
        return
    }

    id := inner["id"].(json.String) or_else ""
    if id == "" {
        keepass_state = .Disconnected
        keepass_popup_info("No association ID received.")
        return
    }

    if keepass_assoc_id != "" do delete(keepass_assoc_id)
    keepass_assoc_id = strings.clone(id)
    keepass_state = .Associated
    keepass_save_association()

    // Now fetch logins for current page
    keepass_do_get_logins()
}

keepass_handle_test_associate :: proc(inner: json.Object) {
    if inner == nil {
        // Association invalid — re-associate
        if keepass_assoc_id != "" do delete(keepass_assoc_id)
        keepass_assoc_id = ""
        keepass_do_associate()
        return
    }

    success := inner["success"].(json.String) or_else ""
    if success != "true" {
        if keepass_assoc_id != "" do delete(keepass_assoc_id)
        keepass_assoc_id = ""
        keepass_do_associate()
        return
    }

    keepass_state = .Associated
    keepass_do_get_logins()
}

keepass_handle_get_logins :: proc(inner: json.Object) {
    keepass_state = .Associated

    if inner == nil {
        keepass_popup_info("Failed to get logins.")
        return
    }

    success := inner["success"].(json.String) or_else ""
    if success != "true" {
        keepass_popup_info("Get logins failed.")
        return
    }

    // Clear old entries
    keepass_clear_entries()

    entries := inner["entries"].(json.Array) or_else nil
    if entries == nil || len(entries) == 0 {
        keepass_popup_main()
        return
    }

    for entry_val in entries {
        entry_obj := entry_val.(json.Object) or_else nil
        if entry_obj == nil do continue

        e: Keepass_Entry
        e.login    = strings.clone(entry_obj["login"].(json.String) or_else "")
        e.password = strings.clone(entry_obj["password"].(json.String) or_else "")
        append(&keepass_entries, e)
    }

    keepass_popup_main()
}

keepass_handle_generate_password :: proc(inner: json.Object) {
    if inner == nil {
        // Initial empty response — KeePassXC opened the generator dialog.
        // Keep waiting for the async password response.
        keepass_pending_action = .Generate_Password
        return
    }

    keepass_state = .Associated

    // KeePassXC sends password as a direct field in the async response
    pw := inner["password"].(json.String) or_else ""
    if pw == "" {
        keepass_popup_info("No password generated.")
        return
    }

    if keepass_generated_pw != "" do delete(keepass_generated_pw)
    keepass_generated_pw = strings.clone(pw)
    keepass_fill_generated()
}

// --- Get database groups ---

keepass_do_get_groups :: proc() {
    inner := `{"action":"get-database-groups"}`

    req := keepass_build_request("get-database-groups", inner)
    defer delete(req)

    keepass_send(req)
    keepass_pending_action = .Get_Database_Groups
    keepass_state = .Waiting_Response
    keepass_popup_info("Loading groups...")
}

keepass_handle_get_groups :: proc(inner: json.Object) {
    keepass_state = .Associated

    keepass_clear_groups()

    if inner != nil {
        groups := inner["groups"].(json.Object) or_else nil
        if groups != nil {
            group_list := groups["groups"].(json.Array) or_else nil
            if group_list != nil {
                for g in group_list {
                    keepass_flatten_groups(g, "")
                }
            }
        }
    }

    // Show save confirm with the groups we found (or empty list)
    keepass_popup_save_confirm()
}

keepass_flatten_groups :: proc(val: json.Value, prefix: string) {
    obj := val.(json.Object) or_else nil
    if obj == nil do return

    name := obj["name"].(json.String) or_else ""
    uuid := obj["uuid"].(json.String) or_else ""
    if name == "" do return

    path := prefix == "" ? strings.clone(name) : strings.clone(strings.concatenate({prefix, "/", name}))
    append(&keepass_groups, Keepass_Group{name = path, uuid = strings.clone(uuid)})

    children := obj["children"].(json.Array) or_else nil
    if children != nil {
        for child in children {
            keepass_flatten_groups(child, path)
        }
    }
}

// --- Save credentials flow ---

keepass_save_trigger :: proc() {
    uri := keepass_current_url()
    if uri == "" do return

    // Inject JS to read form fields — result handled via callback
    js := `(function() {
    var pw = document.querySelector('input[type=password]');
    if (!pw || !pw.value) return JSON.stringify({error: "no password field"});
    var form = pw.form || document;
    var inputs = Array.from(form.querySelectorAll('input:not([type=hidden])'));
    var pi = inputs.indexOf(pw);
    var un = "";
    for (var i = pi - 1; i >= 0; i--) {
        if (inputs[i].type !== 'password') { un = inputs[i].value; break; }
    }
    return JSON.stringify({user: un, pass: pw.value});
})()`

    engine_evaluate_javascript(nil,
        strings.clone_to_cstring(js),
        proc "c" (result: cstring) {
            context = runtime.default_context()
            if result == nil do return
            keepass_on_save_js_result(string(result))
        },
    )
}

keepass_on_save_js_result :: proc(result: string) {
    parsed, err := json.parse(transmute([]u8)result)
    if err != .None {
        keepass_popup_info("Could not read form fields.")
        return
    }
    defer json.destroy_value(parsed)

    root := parsed.(json.Object) or_else nil
    if root == nil do return

    if _, has_error := root["error"]; has_error {
        keepass_popup_info("No password field found on page.")
        return
    }

    user := root["user"].(json.String) or_else ""
    pass := root["pass"].(json.String) or_else ""

    if pass == "" {
        keepass_popup_info("Password field is empty.")
        return
    }

    // Stash credentials, then fetch groups for the save recap
    if keepass_save_user != "" do delete(keepass_save_user)
    if keepass_save_pass != "" do delete(keepass_save_pass)
    keepass_save_user = strings.clone(user)
    keepass_save_pass = strings.clone(pass)

    keepass_do_get_groups()
}

keepass_do_save_login :: proc(user, pass, group, group_uuid: string) {
    uri := keepass_current_url()
    if uri == "" do return

    nonce_b64 := base64_encode(current_nonce[:])
    defer delete(nonce_b64)

    inner: string
    if group != "" && group_uuid != "" {
        inner = fmt.tprintf(
            `{{"action":"set-login","url":"%s","submitUrl":"%s","id":"%s","nonce":"%s","login":"%s","password":"%s","group":"%s","groupUuid":"%s"}}`,
            uri, uri, keepass_assoc_id,
            nonce_b64,
            user, pass, group, group_uuid,
        )
    } else {
        inner = fmt.tprintf(
            `{{"action":"set-login","url":"%s","submitUrl":"%s","id":"%s","nonce":"%s","login":"%s","password":"%s"}}`,
            uri, uri, keepass_assoc_id,
            nonce_b64,
            user, pass,
        )
    }

    req := keepass_build_request("set-login", inner)
    defer delete(req)

    keepass_send(req)
    keepass_pending_action = .Set_Login
    keepass_state = .Waiting_Response
    popup_dismiss()
}

// --- Generate password flow ---

keepass_generate_trigger :: proc() {
    if keepass_state != .Associated do return

    inner := `{"action":"generate-password"}`

    req := keepass_build_request("generate-password", inner)
    defer delete(req)

    keepass_send(req)
    keepass_pending_action = .Generate_Password
    keepass_state = .Waiting_Response
    keepass_popup_info("Generating password...")
}

// --- Fill credentials ---

keepass_fill :: proc(entry: Keepass_Entry) {
    popup_dismiss()

    // Escape JS string characters
    user_escaped := js_escape(entry.login)
    pass_escaped := js_escape(entry.password)
    defer delete(user_escaped)
    defer delete(pass_escaped)

    js := fmt.tprintf(
        `(function(u, p) {{
    function fill(el, val) {{
        if (!el) return;
        el.focus();
        el.dispatchEvent(new FocusEvent('focusin', {{bubbles:true}}));
        el.dispatchEvent(new KeyboardEvent('keydown', {{bubbles:true, key:val}}));
        el.value = val;
        el.dispatchEvent(new Event('input', {{bubbles:true}}));
        el.dispatchEvent(new Event('change', {{bubbles:true}}));
    }}
    var pw = document.querySelector('input[type=password]');
    if (!pw) return;
    var form = pw.form || document;
    var inputs = Array.from(form.querySelectorAll('input:not([type=hidden])'));
    var pi = inputs.indexOf(pw);
    var un = null;
    for (var i = pi - 1; i >= 0; i--) {{
        if (inputs[i].type !== 'password') {{ un = inputs[i]; break; }}
    }}
    fill(un, u);
    fill(pw, p);
}})("%s", "%s")`,
        user_escaped, pass_escaped,
    )

    engine_run_javascript(nil,strings.clone_to_cstring(js))
}

// --- Fill generated password ---

keepass_fill_generated :: proc() {
    if keepass_generated_pw == "" do return
    popup_dismiss()

    pass_escaped := js_escape(keepass_generated_pw)
    defer delete(pass_escaped)

    js := fmt.tprintf(
        `(function(p) {{
    function fill(el, val) {{
        if (!el) return;
        el.focus();
        el.dispatchEvent(new FocusEvent('focusin', {{bubbles:true}}));
        el.value = val;
        el.dispatchEvent(new Event('input', {{bubbles:true}}));
        el.dispatchEvent(new Event('change', {{bubbles:true}}));
    }}
    var pws = document.querySelectorAll('input[type=password]');
    for (var i = 0; i < pws.length; i++) fill(pws[i], p);
}})("%s")`,
        pass_escaped,
    )

    engine_run_javascript(nil,strings.clone_to_cstring(js))
}

// --- Popup UI ---

// 1. Info popup: just a label
keepass_popup_info :: proc(msg: string) {
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

    if keepass_popup_anchor != nil {
        popup_show(panel, keepass_popup_anchor)
    }
}

// 2. Main popup: pull section (entries or "no logins") + actions (Save, Generate)
keepass_popup_main :: proc() {
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
    lv_obj_set_style_pad_column(panel, theme_gap, 0)
    lv_obj_set_style_pad_row(panel, theme_gap, 0)
    lv_obj_set_style_max_height(panel, 400, 0)
    lv_obj_set_flex_flow(panel, .LV_FLEX_FLOW_COLUMN)
    lv_obj_set_flex_align(panel, .LV_FLEX_ALIGN_START, .LV_FLEX_ALIGN_CENTER, .LV_FLEX_ALIGN_CENTER)

    // Pull section
    if len(keepass_entries) > 0 {
        for &entry, i in keepass_entries {
            btn := lv_button_create(panel)
            lv_obj_add_event_cb(btn, on_entry_click, .LV_EVENT_CLICKED, rawptr(uintptr(i)))
            lbl := lv_label_create(btn)
            lv_label_set_text(lbl, strings.clone_to_cstring(entry.login))
        }
    } else {
        lbl := lv_label_create(panel)
        lv_label_set_text(lbl, icons[.ban])
        if icon_font != nil { lv_obj_set_style_text_font(lbl, icon_font, 0) }
    }

    // Actions
    save_btn := lv_button_create(panel)
    lv_obj_add_event_cb(save_btn, on_save_click, .LV_EVENT_CLICKED, nil)
    save_lbl := lv_label_create(save_btn)
    lv_label_set_text(save_lbl, icons[.save])
    if icon_font != nil { lv_obj_set_style_text_font(save_lbl, icon_font, 0) }

    gen_btn := lv_button_create(panel)
    lv_obj_add_event_cb(gen_btn, on_generate_click, .LV_EVENT_CLICKED, nil)
    gen_lbl := lv_label_create(gen_btn)
    lv_label_set_text(gen_lbl, icons[.shuffle])
    if icon_font != nil { lv_obj_set_style_text_font(gen_lbl, icon_font, 0) }

    if keepass_popup_anchor != nil {
        popup_show(panel, keepass_popup_anchor)
    }
}

// Save recap: user/pass labels + group buttons. Click a group to save there.
keepass_popup_save_confirm :: proc() {
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
    lv_obj_set_style_pad_column(panel, theme_gap, 0)
    lv_obj_set_style_pad_row(panel, theme_gap, 0)
    lv_obj_set_style_max_height(panel, 400, 0)
    lv_obj_set_flex_flow(panel, .LV_FLEX_FLOW_COLUMN)
    lv_obj_set_flex_align(panel, .LV_FLEX_ALIGN_START, .LV_FLEX_ALIGN_CENTER, .LV_FLEX_ALIGN_CENTER)

    user_lbl := lv_label_create(panel)
    lv_label_set_text(user_lbl, strings.clone_to_cstring(fmt.tprintf("User: %s", keepass_save_user)))

    pass_lbl := lv_label_create(panel)
    lv_label_set_text(pass_lbl, strings.clone_to_cstring(
        fmt.tprintf("Pass: %s", strings.repeat("*", min(len(keepass_save_pass), 20))),
    ))

    // Group buttons — root shown as-is, children with root prefix stripped
    root_prefix := len(keepass_groups) > 0 ? strings.concatenate({keepass_groups[0].name, "/"}) : ""
    defer if root_prefix != "" do delete(root_prefix)

    for &group, i in keepass_groups {
        btn := lv_button_create(panel)
        lv_obj_add_event_cb(btn, on_group_click, .LV_EVENT_CLICKED, rawptr(uintptr(i)))
        lbl := lv_label_create(btn)

        display := group.name
        if i > 0 && root_prefix != "" && strings.has_prefix(group.name, root_prefix) {
            display = group.name[len(root_prefix):]
        }
        lv_label_set_text(lbl, strings.clone_to_cstring(display))
    }

    if keepass_popup_anchor != nil {
        popup_show(panel, keepass_popup_anchor)
    }
}

// --- LVGL event callbacks ---

on_entry_click :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    idx := int(uintptr(lv_event_get_user_data(e)))
    if idx >= 0 && idx < len(keepass_entries) {
        keepass_fill(keepass_entries[idx])
    }
}

on_save_click :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    keepass_save_trigger()
}

on_generate_click :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    keepass_generate_trigger()
}

on_group_click :: proc "c" (e: ^lv_event_t) {
    context = runtime.default_context()
    idx := int(uintptr(lv_event_get_user_data(e)))
    if idx >= 0 && idx < len(keepass_groups) {
        keepass_do_save_login(
            keepass_save_user, keepass_save_pass,
            keepass_groups[idx].name, keepass_groups[idx].uuid,
        )
    }
}



// --- Association persistence ---

keepass_load_association :: proc() {
    path := xdg_path(.Data, "keepass.json")

    file, ok := os.read_entire_file(path)
    if !ok do return
    defer delete(file)

    parsed, err := json.parse(file)
    if err != .None do return
    defer json.destroy_value(parsed)

    root := parsed.(json.Object) or_else nil
    if root == nil do return

    id := root["id"].(json.String) or_else ""
    id_key_b64 := root["idKey"].(json.String) or_else ""
    id_secret_b64 := root["idSecret"].(json.String) or_else ""

    if id == "" || id_key_b64 == "" || id_secret_b64 == "" do return

    id_key, id_key_ok := base64_decode(id_key_b64)
    if !id_key_ok do return
    defer delete(id_key)
    id_secret, id_secret_ok := base64_decode(id_secret_b64)
    if !id_secret_ok do return
    defer delete(id_secret)

    if len(id_key) != crypto_box_PUBLICKEYBYTES do return
    if len(id_secret) != crypto_box_SECRETKEYBYTES do return

    keepass_assoc_id = strings.clone(id)
    mem.copy(&keepass_id_public[0], raw_data(id_key), crypto_box_PUBLICKEYBYTES)
    mem.copy(&keepass_id_secret[0], raw_data(id_secret), crypto_box_SECRETKEYBYTES)
}

keepass_save_association :: proc() {
    path := xdg_path(.Data, "keepass.json")
    dir := path[:strings.last_index_byte(path, '/')]
    os.make_directory(dir)

    id_key_b64 := base64_encode(keepass_id_public[:])
    id_secret_b64 := base64_encode(keepass_id_secret[:])
    defer delete(id_key_b64)
    defer delete(id_secret_b64)

    content := fmt.tprintf(
        `{{"id":"%s","idKey":"%s","idSecret":"%s"}}`,
        keepass_assoc_id, id_key_b64, id_secret_b64,
    )

    os.write_entire_file(path, transmute([]u8)content)
}

// --- Helpers ---

keepass_current_url :: proc() -> string {
    if active_tab < 0 || active_tab >= tab_count do return ""
    return tab_entries[active_tab].uri
}

keepass_clear_entries :: proc() {
    for &e in keepass_entries {
        delete(e.login)
        delete(e.password)
    }
    clear(&keepass_entries)
}

keepass_clear_groups :: proc() {
    for &g in keepass_groups {
        delete(g.name)
        delete(g.uuid)
    }
    clear(&keepass_groups)
}

@(private)
js_escape :: proc(s: string) -> string {
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
