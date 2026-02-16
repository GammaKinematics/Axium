// WPE2 Engine Shim - CPU-only SHM pixel output
// GObject subclasses for WPE2 platform + raw pixel extraction
#pragma once

#include <stdbool.h>
#include <stdint.h>

// Initialize engine: creates WPE display with headless EGL
bool axium_engine_init(void);

// Create a web view at given dimensions
bool axium_engine_create_view(int width, int height);

// Navigate to a URI
void axium_engine_load_uri(const char* uri);

// Resize the web view
void axium_engine_resize(int width, int height);

// Pump GLib event loop (call once per frame)
void axium_engine_pump(void);

// Check if a new frame arrived from the web process
bool axium_engine_has_new_frame(void);

// Get raw BGRA pixel data from latest frame
// Returns true if pixels available. Pointer valid until next call.
bool axium_engine_get_frame_pixels(const uint8_t** pixels,
                                    int* width, int* height, int* stride);

// Shut down engine and release resources
void axium_engine_shutdown(void);
