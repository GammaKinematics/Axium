{
  # === Performance Optimizations ===
  use_thin_lto = true;
  thin_lto_enable_optimizations = true;
  use_lld = true;
  use_icf = true;
  use_text_section_splitting = true;

  # SIMD (matches compiler-optimizations.patch)
  use_sse41 = true;
  use_sse42 = true;
  use_avx = true;
  use_avx2 = true;

  # === Symbol Stripping ===
  symbol_level = 0;
  blink_symbol_level = 0;
  v8_symbol_level = 0;

  # === V8 JavaScript Engine ===
  v8_enable_maglev = true;
  v8_enable_turbofan = true;
  v8_enable_wasm_simd256_revec = true;
  use_v8_context_snapshot = true;

  # === Security ===
  is_cfi = true;
  init_stack_vars_zero = true;

  # === Media (keep - core functionality) ===
  use_vaapi = true;
  proprietary_codecs = true;
  ffmpeg_branding = "Chrome";
  use_pulseaudio = true;

  # === STRIPPED: Google Integrations ===
  enable_compose = false;
  enable_glic = false;
  enable_lens_desktop = false;
  enable_on_device_translation = false;

  # === STRIPPED: Extensions/Plugins ===
  # enable_extensions = false;  # KEEP - too many asserts (100+)
  # enable_guest_view = false;  # KEEP - required by extensions (assert in extensions/common/BUILD.gn)
  enable_plugins = false;
  enable_platform_apps = false;

  # === STRIPPED: Accessibility/Speech ===
  enable_accessibility_service = false;
  enable_screen_ai_service = false;
  enable_speech_service = false;

  # === STRIPPED: PDF/Printing ===
  enable_pdf = false;
  enable_printing = false;
  enable_print_preview = false;
  enable_basic_print_dialog = false;
  enable_oop_printing = false;

  # === STRIPPED: Browser Features ===
  enable_session_service = false;
  enable_chrome_notifications = false;
  enable_captive_portal_detection = false;
  enable_offline_pages = false;
  enable_reading_list = false;
  enable_downgrade_processing = false;

  # === STRIPPED: Remote/Cast/VR ===
  enable_remoting = false;
  enable_media_remoting = false;
  enable_vr = false;

  # === KEEP: DRM (Netflix, Disney+, etc.) ===
  enable_widevine = true;

  # === STRIPPED: Background/System ===
  enable_background_mode = false;
  enable_background_contents = false;

  # === STRIPPED: Network/Privacy Invasive ===
  enable_click_to_call = false;
  enable_bound_session_credentials = false;
  enable_device_bound_sessions = false;
  enable_mdns = false;
  enable_service_discovery = false;
  enable_compute_pressure = false;
  enable_reporting = false;
  safe_browsing_mode = 0;

  # === STRIPPED: Enterprise ===
  enterprise_cloud_content_analysis = false;
  enterprise_local_content_analysis = false;

  # === STRIPPED: DevTools Frontend ===
  enable_devtools_frontend = false;  # No F12 inspector UI (backend protocol kept for automation)

  # === STRIPPED: Misc Bloat ===
  enable_hangout_services_extension = false;
  enable_webui_certificate_viewer = false;
  use_kerberos = false;
  include_transport_security_state_preload_list = false;

  # === KEEP: WebRTC (video calls) ===
  # WebRTC is enabled by default, no flag needed

  # === KEEP: WebUSB ===
  # WebUSB is enabled by default, no flag needed
}
