//! C FFI wrapper for adblock-rust
//!
//! Exposes adblock-rust functionality via C-compatible API for use from Odin.

use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;
use adblock::Engine;
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

/// Free an AdblockResult's allocated strings
///
/// # Safety
/// `result` must be a valid pointer to an AdblockResult
#[no_mangle]
pub unsafe extern "C" fn adblock_result_free(result: *mut AdblockResult) {
    if !result.is_null() {
        adblock_string_free((*result).redirect);
        adblock_string_free((*result).filter);
        (*result).redirect = ptr::null_mut();
        (*result).filter = ptr::null_mut();
    }
}
