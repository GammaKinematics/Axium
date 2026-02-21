// WPE2 Engine Shim - CPU-only SHM pixel output
// GObject subclasses for WPE2 platform + raw pixel extraction
#pragma once

#include <stdbool.h>
#include <stdint.h>

// Initialize engine: creates WPE display with headless EGL
bool engine_init(void);

// Create a web view at given dimensions
bool engine_create_view(int width, int height);

// Navigate to a URI
void engine_load_uri(const char* uri);

// Resize the web view
void engine_resize(int width, int height);

// Pump GLib event loop (call once per frame)
void engine_pump(void);

// Check if a new frame arrived from the web process
bool engine_has_new_frame(void);

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

// Shut down engine and release resources
void engine_shutdown(void);
