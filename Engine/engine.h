// WPE2 Engine Shim - CPU-only SHM pixel output
// GObject subclasses for WPE2 platform + raw pixel extraction
#pragma once

#include <stdbool.h>
#include <stdint.h>

// Initialize engine: creates WPE display with headless EGL
bool engine_init(void);

// Create a web view at given dimensions, returns view index (-1 on failure)
int engine_create_view(int width, int height);

// Destroy a view by index (compacts array, does NOT pick new active)
void engine_destroy_view(int index);

// Set the active view (focus out old, focus in new)
void engine_set_active_view(int index);

// Query any view by index
void engine_view_get_uri(int index, const char** uri);
void engine_view_get_title(int index, const char** title);

// View count and active index
int engine_view_count(void);
int engine_active_view(void);

// Navigate to a URI
void engine_load_uri(const char* uri);

// Resize the web view
void engine_resize(int width, int height);

// Pump GLib event loop (call once per frame)
void engine_pump(void);

// Copy the last committed frame to the render target
void engine_grab_frame(void);

// Set direct render target — WebKit pixels copied here in render_buffer
void engine_set_frame_target(uint8_t* buffer, int buf_stride,
                              int x, int y, int w, int h);

// Input events (modifier state tracked internally by the shim)
void engine_send_key(uint32_t keyval, bool pressed);
void engine_send_mouse_button(uint32_t button, bool pressed, double x, double y);
void engine_send_mouse_move(double x, double y);
void engine_send_scroll(double x, double y, double delta_x, double delta_y);
void engine_send_focus(bool focused);

// Cursor — returns new cursor code if changed, -1 if unchanged.
// Codes: 0=Arrow, 1=Text, 2=Crosshair, 3=Hand, 4=Resize_H, 5=Resize_V
int engine_get_cursor(void);

// Execute a WebKit editing command, optionally with an argument.
void engine_editing_command(const char* command, const char* argument);

// Clipboard callbacks — set by Odin, called by C shim
typedef bool (*engine_clipboard_set_fn)(const char* text);
typedef const char* (*engine_clipboard_get_fn)(void);

void engine_set_clipboard_callbacks(engine_clipboard_set_fn set_fn,
                                    engine_clipboard_get_fn get_fn);

// Navigation
void engine_go_back(void);
void engine_go_forward(void);
void engine_reload(void);
void engine_get_uri(const char** uri);
void engine_get_title(const char** title);

// Navigation callbacks — called when active view's URI or title changes
typedef void (*engine_uri_changed_fn)(const char* uri);
typedef void (*engine_title_changed_fn)(const char* title);
void engine_set_navigation_callbacks(engine_uri_changed_fn uri_fn,
                                     engine_title_changed_fn title_fn);

// Set screen properties (from Display-Onix RANDR query) — creates WPEScreen
void engine_set_screen_info(int width, int height,
                            int phys_w_mm, int phys_h_mm,
                            int refresh_rate_mhz, double scale);

// Configure adblock web process extension (must be called BEFORE engine_create_view)
void engine_init_adblock(const char* ext_dir, const char* adblock_dir);

// Fire-and-forget JS execution on active view
void engine_run_javascript(const char* script);

// JS execution with result callback
typedef void (*engine_js_result_fn)(const char* result);
void engine_evaluate_javascript(const char* script, engine_js_result_fn callback);

// Shut down engine and release resources
void engine_shutdown(void);
