// Axium: C++ bridge for single-binary subprocess dispatch.
// Odin can't call C++ namespaced functions directly.

#include <stdio.h>
#include <unistd.h>

namespace WebKit {
    int WebProcessMain(int argc, char** argv);
    int NetworkProcessMain(int argc, char** argv);
}

extern "C" int axium_web_process_main(int argc, char** argv) {
    fprintf(stderr, "[axium] WebProcess starting (pid %d)\n", getpid());
    return WebKit::WebProcessMain(argc, argv);
}

// Static TLS backend registration — needed in every process that does networking.
// Dynamic builds get this from GIO modules automatically.
#ifdef STATIC
extern "C" void g_tls_backend_gnutls_register(void *module);
#endif

extern "C" int axium_network_process_main(int argc, char** argv) {
    fprintf(stderr, "[axium] NetworkProcess starting (pid %d)\n", getpid());
#ifdef STATIC
    g_tls_backend_gnutls_register(nullptr);
#endif
    return WebKit::NetworkProcessMain(argc, argv);
}
