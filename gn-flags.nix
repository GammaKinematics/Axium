{
  # === Performance Optimizations ===
  use_thin_lto = true;
  thin_lto_enable_optimizations = true;
  use_lld = true;                    # LLVM linker
  use_icf = true;                    # Identical code folding
  use_text_section_splitting = true; # Better CPU cache usage
  optimize_webui = true;             # Minify WebUI resources
  exclude_unwind_tables = true;      # Smaller binary
  disable_fieldtrial_testing_config = true;  # No A/B test overhead

  # SIMD - adjust based on your CPU
  use_sse42 = true;
  use_avx = true;
  use_avx2 = true;    # Haswell 2013+

  # === V8 JavaScript Engine ===
  v8_enable_maglev = true;
  v8_enable_turbofan = true;
  v8_enable_wasm_simd256_revec = true;
  v8_enable_fast_torque = true;      # Faster builtins
  v8_enable_builtins_optimization = true;
  use_v8_context_snapshot = true;    # Faster startup

  # === Security Hardening ===
  is_cfi = true;                     # Control flow integrity
  init_stack_vars_zero = true;       # Zero-init stack vars

  # === Symbol Stripping ===
  symbol_level = 0;
  blink_symbol_level = 0;
  v8_symbol_level = 0;
  enable_stripping = true;

  # === Disable Google Services ===
  enable_hangout_services_extension = false;
  enable_compose = false;            # Google AI compose
  enable_widevine = false;           # DRM - use Spotify app instead
  enable_lens_desktop = false;       # Google Lens
  enable_dice_support = false;       # Google account DICE
  enable_bound_session_credentials = false;

  # === Disable Bloat ===
  enable_nacl = false;               # Dead technology
  enable_remoting = false;           # Chrome Remote Desktop
  enable_vr = false;                 # VR/AR support
  enable_reading_list = false;
  enable_click_to_call = false;      # Phone number detection
  enable_background_mode = false;    # No system tray lurking
  enable_background_contents = false; # No invisible background pages
  enable_session_service = false;    # No "restore tabs?" prompt
  enable_webui_certificate_viewer = false;
  enable_chrome_notifications = false; # No desktop notifications

  # === Disable PDF & Printing ===
  enable_pdf = false;                # Use external PDF viewer
  enable_printing = false;
  enable_print_preview = false;

  # === Disable Spellcheck ===
  enable_spellcheck = false;

  # === Privacy (Network) ===
  safe_browsing_mode = 0;
  enable_reporting = false;
  enable_mdns = false;
  enable_service_discovery = false;
  use_kerberos = false;

  # === Media (keep hardware accel) ===
  use_vaapi = true;                  # Hardware video decode
  proprietary_codecs = true;         # H.264 etc
}
