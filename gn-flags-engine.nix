{
  # === Performance Optimizations ===
  # LTO and linker optimizations
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

  # === Disable Bloat (engine-specific) ===
  # enable_vr = false;
  # enable_widevine = false;  # Override ungoogled's true
  # enable_background_mode = false;
  # enable_background_contents = false;
  # enable_media_remoting = false;
  # enable_click_to_call = false;
  # enable_rlz = false;

  # === Disable Browser UI Features (not needed for engine) ===
  # enable_pdf = false;
  # enable_printing = false;
  # enable_print_preview = false;
  # enable_chrome_notifications = false;
  # enable_webui_certificate_viewer = false;
  # enable_screen_ai_service = false;
  # enable_offline_pages = false;
  # enable_lens_desktop = false;
  # enable_bound_session_credentials = false;
  # include_transport_security_state_preload_list = false;

  # === Disable Enterprise ===
  # enterprise_cloud_content_analysis = false;
  # enterprise_local_content_analysis = false;

  # === Media (hardware accel) ===
  use_vaapi = true;
  proprietary_codecs = true;
  ffmpeg_branding = "Chrome";
  use_pulseaudio = true;

  # use_kerberos = false;
}
