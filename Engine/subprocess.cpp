// Axium: C++ bridge for single-binary subprocess dispatch.
// Odin can't call C++ namespaced functions directly.

#include <stdio.h>

namespace WebKit {
    int WebProcessMain(int argc, char** argv);
    int NetworkProcessMain(int argc, char** argv);
}

extern "C" int axium_web_process_main(int argc, char** argv) {
    fprintf(stderr, "[axium] WebProcess starting (pid %d)\n", getpid());
    return WebKit::WebProcessMain(argc, argv);
}

extern "C" int axium_network_process_main(int argc, char** argv) {
    fprintf(stderr, "[axium] NetworkProcess starting (pid %d)\n", getpid());
    return WebKit::NetworkProcessMain(argc, argv);
}
