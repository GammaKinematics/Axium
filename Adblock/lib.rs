//! C FFI wrapper for adblock-rust
//!
//! Exposes adblock-rust functionality via C-compatible API for use from Odin.

use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;
use adblock::Engine;
use std::collections::HashSet;
use std::ffi::{c_char, CStr, CString};
use std::ptr;

/// Opaque handle to an adblock engine
pub struct AdblockEngine {
    engine: Engine,
}

/// Result of checking a network request
#[repr(C)]
pub struct AdblockResult {
    /// Should the request be blocked?
    pub matched: bool,
    /// Is this an important rule (overrides exceptions)?
    pub important: bool,
    /// Redirect URL if applicable (null if none)
    pub redirect: *mut c_char,
    /// Rewritten URL from $removeparam rules (null if none)
    pub rewritten_url: *mut c_char,
    /// Matched exception rule (null if none)
    pub exception: *mut c_char,
    /// Matching filter for debugging (null if none)
    pub filter: *mut c_char,
}

/// Create a new adblock engine with default (empty) rules
#[no_mangle]
pub extern "C" fn adblock_engine_new() -> *mut AdblockEngine {
    let engine = Box::new(AdblockEngine {
        engine: Engine::default(),
    });
    Box::into_raw(engine)
}

/// Create an adblock engine from a list of rules
///
/// # Safety
/// `rules` must be a valid pointer to an array of `count` null-terminated C strings
#[no_mangle]
pub unsafe extern "C" fn adblock_engine_from_rules(
    rules: *const *const c_char,
    count: usize,
) -> *mut AdblockEngine {
    if rules.is_null() {
        return adblock_engine_new();
    }

    let rules_slice = std::slice::from_raw_parts(rules, count);
    let rules_vec: Vec<String> = rules_slice
        .iter()
        .filter_map(|&rule_ptr| {
            if rule_ptr.is_null() {
                None
            } else {
                CStr::from_ptr(rule_ptr).to_str().ok().map(String::from)
            }
        })
        .collect();

    let engine = Engine::from_rules(rules_vec, ParseOptions::default());
    let wrapper = Box::new(AdblockEngine { engine });
    Box::into_raw(wrapper)
}

/// Free an adblock engine
///
/// # Safety
/// `engine` must be a valid pointer returned by `adblock_engine_new` or `adblock_engine_from_rules`
#[no_mangle]
pub unsafe extern "C" fn adblock_engine_free(engine: *mut AdblockEngine) {
    if !engine.is_null() {
        drop(Box::from_raw(engine));
    }
}

/// Check if a network request should be blocked
///
/// # Safety
/// - `engine` must be a valid pointer to an AdblockEngine
/// - `url`, `source_url`, and `request_type` must be valid null-terminated C strings
#[no_mangle]
pub unsafe extern "C" fn adblock_check_request(
    engine: *const AdblockEngine,
    url: *const c_char,
    source_url: *const c_char,
    request_type: *const c_char,
) -> AdblockResult {
    let default_result = AdblockResult {
        matched: false,
        important: false,
        redirect: ptr::null_mut(),
        rewritten_url: ptr::null_mut(),
        exception: ptr::null_mut(),
        filter: ptr::null_mut(),
    };

    if engine.is_null() || url.is_null() || source_url.is_null() || request_type.is_null() {
        return default_result;
    }

    let url = match CStr::from_ptr(url).to_str() {
        Ok(s) => s,
        Err(_) => return default_result,
    };
    let source_url = match CStr::from_ptr(source_url).to_str() {
        Ok(s) => s,
        Err(_) => return default_result,
    };
    let request_type = match CStr::from_ptr(request_type).to_str() {
        Ok(s) => s,
        Err(_) => return default_result,
    };

    let request = match Request::new(url, source_url, request_type) {
        Ok(r) => r,
        Err(_) => return default_result,
    };

    let result = (*engine).engine.check_network_request(&request);

    AdblockResult {
        matched: result.matched,
        important: result.important,
        redirect: result
            .redirect
            .and_then(|r| CString::new(r).ok())
            .map(|c| c.into_raw())
            .unwrap_or(ptr::null_mut()),
        rewritten_url: result
            .rewritten_url
            .and_then(|r| CString::new(r).ok())
            .map(|c| c.into_raw())
            .unwrap_or(ptr::null_mut()),
        exception: result
            .exception
            .and_then(|e| CString::new(e).ok())
            .map(|c| c.into_raw())
            .unwrap_or(ptr::null_mut()),
        filter: result
            .filter
            .and_then(|f| CString::new(f).ok())
            .map(|c| c.into_raw())
            .unwrap_or(ptr::null_mut()),
    }
}

/// Free a string returned by adblock functions
///
/// # Safety
/// `s` must be a valid pointer returned by an adblock function, or null
#[no_mangle]
pub unsafe extern "C" fn adblock_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// Create an adblock engine from a filter list in EasyList format (one rule per line)
///
/// # Safety
/// `filter_list` must be a valid null-terminated C string containing filter rules
#[no_mangle]
pub unsafe extern "C" fn adblock_engine_from_filter_list(
    filter_list: *const c_char,
) -> *mut AdblockEngine {
    if filter_list.is_null() {
        return adblock_engine_new();
    }

    let text = match CStr::from_ptr(filter_list).to_str() {
        Ok(s) => s,
        Err(_) => return adblock_engine_new(),
    };

    let rules: Vec<String> = text.lines().map(String::from).collect();
    let engine = Engine::from_rules(rules, ParseOptions::default());
    let wrapper = Box::new(AdblockEngine { engine });
    Box::into_raw(wrapper)
}

/// Free an AdblockResult's allocated strings
///
/// # Safety
/// `result` must be a valid pointer to an AdblockResult
#[no_mangle]
pub unsafe extern "C" fn adblock_result_free(result: *mut AdblockResult) {
    if !result.is_null() {
        adblock_string_free((*result).redirect);
        adblock_string_free((*result).rewritten_url);
        adblock_string_free((*result).exception);
        adblock_string_free((*result).filter);
        (*result).redirect = ptr::null_mut();
        (*result).rewritten_url = ptr::null_mut();
        (*result).exception = ptr::null_mut();
        (*result).filter = ptr::null_mut();
    }
}

// ---------------------------------------------------------------------------
// Cosmetic filtering
// ---------------------------------------------------------------------------

/// Cosmetic filtering resources for a specific URL
#[repr(C)]
pub struct CosmeticResources {
    /// CSS rule string: "sel1,sel2{display:none!important}" (null if empty)
    pub hide_selectors: *mut c_char,
    /// JavaScript code for scriptlet injection (null if empty)
    pub injected_script: *mut c_char,
    /// JSON-encoded exceptions array for 2nd-pass class/id filtering (null if empty)
    pub exceptions_json: *mut c_char,
    /// If true, skip generic cosmetic rules (no MutationObserver needed)
    pub generichide: bool,
}

/// Get cosmetic filtering resources for a page URL
///
/// # Safety
/// - `engine` must be a valid pointer to an AdblockEngine
/// - `url` must be a valid null-terminated C string
#[no_mangle]
pub unsafe extern "C" fn adblock_url_cosmetic_resources(
    engine: *const AdblockEngine,
    url: *const c_char,
) -> CosmeticResources {
    let empty = CosmeticResources {
        hide_selectors: ptr::null_mut(),
        injected_script: ptr::null_mut(),
        exceptions_json: ptr::null_mut(),
        generichide: false,
    };

    if engine.is_null() || url.is_null() {
        return empty;
    }

    let url_str = match CStr::from_ptr(url).to_str() {
        Ok(s) => s,
        Err(_) => return empty,
    };

    let res = (*engine).engine.url_cosmetic_resources(url_str);

    let hide_selectors = if res.hide_selectors.is_empty() {
        ptr::null_mut()
    } else {
        let selectors: Vec<&str> = res.hide_selectors.iter().map(|s| s.as_str()).collect();
        let css = format!("{}{{display:none!important}}", selectors.join(","));
        CString::new(css)
            .map(|c| c.into_raw())
            .unwrap_or(ptr::null_mut())
    };

    let injected_script = if res.injected_script.is_empty() {
        ptr::null_mut()
    } else {
        CString::new(res.injected_script)
            .map(|c| c.into_raw())
            .unwrap_or(ptr::null_mut())
    };

    let exceptions_json = if res.exceptions.is_empty() {
        ptr::null_mut()
    } else {
        serde_json::to_string(&res.exceptions)
            .ok()
            .and_then(|json| CString::new(json).ok())
            .map(|c| c.into_raw())
            .unwrap_or(ptr::null_mut())
    };

    CosmeticResources {
        hide_selectors,
        injected_script,
        exceptions_json,
        generichide: res.generichide,
    }
}

/// Get additional CSS hide rules for classes/ids found on the page (2nd pass)
///
/// Returns a CSS rule string "sel1,sel2{display:none!important}" or null if no matches.
///
/// # Safety
/// - `engine` must be a valid pointer to an AdblockEngine
/// - JSON string parameters must be valid null-terminated C strings or null
#[no_mangle]
pub unsafe extern "C" fn adblock_hidden_class_id_selectors(
    engine: *const AdblockEngine,
    classes_json: *const c_char,
    ids_json: *const c_char,
    exceptions_json: *const c_char,
) -> *mut c_char {
    if engine.is_null() {
        return ptr::null_mut();
    }

    let classes: Vec<String> = if !classes_json.is_null() {
        CStr::from_ptr(classes_json)
            .to_str()
            .ok()
            .and_then(|s| serde_json::from_str(s).ok())
            .unwrap_or_default()
    } else {
        Vec::new()
    };

    let ids: Vec<String> = if !ids_json.is_null() {
        CStr::from_ptr(ids_json)
            .to_str()
            .ok()
            .and_then(|s| serde_json::from_str(s).ok())
            .unwrap_or_default()
    } else {
        Vec::new()
    };

    let exceptions: HashSet<String> = if !exceptions_json.is_null() {
        CStr::from_ptr(exceptions_json)
            .to_str()
            .ok()
            .and_then(|s| serde_json::from_str(s).ok())
            .unwrap_or_default()
    } else {
        HashSet::new()
    };

    let selectors = (*engine).engine.hidden_class_id_selectors(
        classes.iter().map(String::as_str),
        ids.iter().map(String::as_str),
        &exceptions,
    );

    if selectors.is_empty() {
        return ptr::null_mut();
    }

    let css = format!("{}{{display:none!important}}", selectors.join(","));
    CString::new(css)
        .map(|c| c.into_raw())
        .unwrap_or(ptr::null_mut())
}

/// Free a CosmeticResources struct's allocated strings
///
/// # Safety
/// `result` must be a valid pointer to a CosmeticResources
#[no_mangle]
pub unsafe extern "C" fn adblock_cosmetic_resources_free(result: *mut CosmeticResources) {
    if !result.is_null() {
        adblock_string_free((*result).hide_selectors);
        adblock_string_free((*result).injected_script);
        adblock_string_free((*result).exceptions_json);
        (*result).hide_selectors = ptr::null_mut();
        (*result).injected_script = ptr::null_mut();
        (*result).exceptions_json = ptr::null_mut();
    }
}
