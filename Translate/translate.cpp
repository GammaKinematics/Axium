#include "axium_translate.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <unistd.h>

#include "translator/parser.h"
#include "translator/service.h"
#include "translator/translation_model.h"
#include "translator/response.h"
#include "translator/response_options.h"

struct TranslateEngine {
    std::unique_ptr<marian::bergamot::AsyncService> service;
    std::shared_ptr<marian::bergamot::TranslationModel> model;
    int pipe_fds[2]; // [0]=read, [1]=write

    std::mutex result_mutex;
    std::string result_text;
    std::string result_error;
    bool result_ready;

    TranslateEngine() : pipe_fds{-1, -1}, result_ready(false) {}

    ~TranslateEngine() {
        if (pipe_fds[0] >= 0) close(pipe_fds[0]);
        if (pipe_fds[1] >= 0) close(pipe_fds[1]);
    }
};

extern "C" {

TranslateEngine* translate_engine_init(int num_workers) {
    auto engine = new TranslateEngine();

    if (pipe(engine->pipe_fds) < 0) {
        delete engine;
        return nullptr;
    }

    marian::bergamot::AsyncService::Config config;
    config.numWorkers = num_workers > 0 ? (size_t)num_workers : 1;
    engine->service = std::make_unique<marian::bergamot::AsyncService>(config);

    return engine;
}

void translate_engine_free(TranslateEngine* engine) {
    if (!engine) return;
    if (engine->service) engine->service->clear();
    delete engine;
}

int translate_load_model(TranslateEngine* engine, const char* config_path) {
    if (!engine || !engine->service || !config_path) return -1;

    try {
        auto options = marian::bergamot::parseOptionsFromFilePath(
            std::string(config_path), /*validate=*/false);
        engine->model = engine->service->createCompatibleModel(options);
        return 0;
    } catch (const std::exception& e) {
        fprintf(stderr, "[translate] load_model: %s\n", e.what());
        return -1;
    }
}

void translate_unload_model(TranslateEngine* engine) {
    if (!engine) return;
    engine->model.reset();
}

void translate_text(TranslateEngine* engine, const char* text, int html_mode) {
    if (!engine || !engine->service || !engine->model || !text) return;

    size_t text_len = strlen(text);

    marian::bergamot::ResponseOptions opts;
    opts.alignment = true;
    opts.HTML = html_mode != 0;

    std::string source(text, text_len);

    engine->service->translate(
        engine->model, std::move(source),
        [engine](marian::bergamot::Response&& response) {
            std::lock_guard<std::mutex> lock(engine->result_mutex);
            engine->result_text = response.target.text;
            engine->result_error.clear();
            engine->result_ready = true;
            char c = 1;
            (void)write(engine->pipe_fds[1], &c, 1);
        },
        opts);
}

int translate_fd(TranslateEngine* engine) {
    if (!engine) return -1;
    return engine->pipe_fds[0];
}

int translate_poll(TranslateEngine* engine, const char** out_text, const char** out_error) {
    if (!engine) return 0;

    std::lock_guard<std::mutex> lock(engine->result_mutex);
    if (!engine->result_ready) return 0;

    // Drain the pipe
    char buf[64];
    (void)read(engine->pipe_fds[0], buf, sizeof(buf));

    engine->result_ready = false;

    if (!engine->result_error.empty()) {
        *out_text = nullptr;
        *out_error = strdup(engine->result_error.c_str());
    } else {
        *out_text = strdup(engine->result_text.c_str());
        *out_error = nullptr;
    }

    engine->result_text.clear();
    engine->result_error.clear();
    return 1;
}

void translate_result_free(const char* str) {
    free(const_cast<char*>(str));
}

} // extern "C"
