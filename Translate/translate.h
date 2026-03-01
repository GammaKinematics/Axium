#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TranslateEngine TranslateEngine;

// Lifecycle
TranslateEngine* translate_engine_init(int num_workers);
void             translate_engine_free(TranslateEngine* engine);

// Model management — config_path is a marian YAML config file
int  translate_load_model(TranslateEngine* engine, const char* config_path);
void translate_unload_model(TranslateEngine* engine);

// Submit text for async translation (result retrieved via translate_poll)
void translate_text(TranslateEngine* engine, const char* text, int html_mode);

// File descriptor for poll() — readable when a result is ready
int translate_fd(TranslateEngine* engine);

// Poll for result. Returns 1 if result available, 0 if nothing pending.
// out_text/out_error are set on success (caller must call translate_result_free).
int translate_poll(TranslateEngine* engine, const char** out_text, const char** out_error);

// Free a result string returned by translate_poll
void translate_result_free(const char* str);

#ifdef __cplusplus
}
#endif
