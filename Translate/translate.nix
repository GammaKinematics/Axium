{ pkgs, hostPkgs ? pkgs, translations, translation-models, static_lto ? false }:

let
  # Generate Odin source with model registry from Mozilla Remote Settings.
  # Uses hostPkgs for build tools (jq) — this is a native build-time operation.
  modelsRegistry = hostPkgs.runCommand "translate_models_gen.odin" {
    nativeBuildInputs = [ hostPkgs.jq ];
  } ''
    jq -r '
      .data
      # Desktop only — skip Android and Nightly-only records
      | map(select(.filter_expression == ""))
      # Group by language pair
      | group_by(.fromLang + "-" + .toLang)
      # For each pair, pick highest version per fileType, then extract fields
      | map(
          # Sort by version descending within the group, so first match is latest
          sort_by(.version) | reverse
          | {
              src: .[0].fromLang,
              tgt: .[0].toLang,
              model:     (map(select(.fileType == "model"))    | .[0].attachment.location // ""),
              lex:       (map(select(.fileType == "lex"))      | .[0].attachment.location // ""),
              vocab:     (map(select(.name | startswith("vocab.")))    | .[0].attachment.location // ""),
              src_vocab: (map(select(.name | startswith("srcvocab."))) | .[0].attachment.location // ""),
              tgt_vocab: (map(select(.name | startswith("trgvocab."))) | .[0].attachment.location // "")
            }
        )
      # Only include pairs that have all essential files
      | map(select(.model != "" and .lex != "" and (.vocab != "" or (.src_vocab != "" and .tgt_vocab != ""))))
      | sort_by(.src + "-" + .tgt)
    ' ${translation-models} > models.json

    # Generate Odin source from the processed JSON
    echo 'package axium' > $out
    echo >> $out
    echo '// Auto-generated from Mozilla Firefox Remote Settings' >> $out
    echo '// Refresh with: nix flake update translation-models' >> $out
    echo >> $out
    echo 'MODELS_CDN :: "https://firefox-settings-attachments.cdn.mozilla.net/"' >> $out
    echo >> $out
    echo 'translate_registry := [?]Translate_Model_Entry{' >> $out

    jq -r '.[] |
      "    { src = \"\(.src)\", tgt = \"\(.tgt)\", model = \"\(.model)\", lex = \"\(.lex)\", vocab = \"\(.vocab)\", src_vocab = \"\(.src_vocab)\", tgt_vocab = \"\(.tgt_vocab)\" },"
    ' models.json >> $out

    echo '}' >> $out
  '';

  lib = pkgs.stdenv.mkDerivation {
    pname = "axium-translate";
    version = "0.1.0";
    src = "${translations}/inference";

    nativeBuildInputs = with hostPkgs; [ cmake pkg-config ];

    buildInputs = with pkgs; [
      blis
      pcre2
      gperftools
    ];

    cmakeFlags = [
      "-DCOMPILE_CUDA=OFF"
      "-DCOMPILE_TESTS=OFF"
      "-DCOMPILE_LIBRARY_ONLY=ON"
      "-DUSE_STATIC_LIBS=ON"
      "-DUSE_MKL=OFF"
      "-DCOMPILE_SERVER=OFF"
      "-DUSE_FBGEMM=OFF"
      # intgemm ON (default on x86) — needed for int8 quantized models
      "-DBUILD_ARCH=x86-64"
      "-DGIT_SUBMODULE=OFF"
    ];

    preConfigure = ''
      # Fix cmake minimum version (3.1 too old for nix cmake 3.27+)
      substituteInPlace marian-fork/src/3rd_party/sentencepiece/CMakeLists.txt \
        --replace-quiet "cmake_minimum_required(VERSION 3.1 FATAL_ERROR)" \
                        "cmake_minimum_required(VERSION 3.10)"
      substituteInPlace marian-fork/src/3rd_party/ruy/third_party/cpuinfo/deps/clog/CMakeLists.txt \
        --replace-quiet "CMAKE_MINIMUM_REQUIRED(VERSION 3.1 FATAL_ERROR)" \
                        "cmake_minimum_required(VERSION 3.10)"

      # Bergamot GetVersionFromFile.cmake: replace git rev-parse with dummy
      substituteInPlace cmake/GetVersionFromFile.cmake \
        --replace-quiet \
          'execute_process(COMMAND ''${GIT_EXECUTABLE} rev-parse --short HEAD
  WORKING_DIRECTORY ''${CMAKE_CURRENT_SOURCE_DIR}
  OUTPUT_VARIABLE PROJECT_VERSION_GIT_SHA
  OUTPUT_STRIP_TRAILING_WHITESPACE)' \
          'set(PROJECT_VERSION_GIT_SHA 000000000000)'

      # Marian: rip out git dir lookup + custom command that generates git_revision.h
      # (sed range delete avoids nix quoting nightmares)
      sed -i '/^set(MARIAN_GIT_DIR/,/^add_dependencies(marian marian_version)/d' \
        marian-fork/src/CMakeLists.txt

      # Generate git_revision.h for marian
      echo '#define GIT_REVISION "000000 nix"' > marian-fork/src/common/git_revision.h

      # Generate project_version.h for bergamot
      cat > src/translator/project_version.h << 'VEOF'
#pragma once
#include <string>
namespace marian { namespace bergamot {
std::string bergamotBuildVersion() { return "v0.6.0+nix"; }
} }
VEOF

      # Bypass cmake BLAS detection (hardcoded to OpenBLAS) — use BLIS directly
      sed -i '/set(BLAS_VENDOR "OpenBLAS")/,/endif(BLAS_FOUND)/c\      set(EXT_LIBS ''${EXT_LIBS} blis)\n      add_definitions(-DBLAS_FOUND=1)' \
        marian-fork/CMakeLists.txt

      # Skip translator-cli (we only need the libraries)
      substituteInPlace CMakeLists.txt \
        --replace-quiet 'add_subdirectory(src/app)' '# add_subdirectory(src/app)'

      # musl strerror_r is XSI-compliant (returns int), not GNU (returns char*)
      substituteInPlace marian-fork/src/3rd_party/zstr/strict_fstream.hpp \
        --replace-quiet '(_POSIX_C_SOURCE >= 200112L || _XOPEN_SOURCE >= 600 || __APPLE__) && ! _GNU_SOURCE' \
                         '1'

      # musl doesn't have execinfo.h (backtrace) — provide inline stubs
      substituteInPlace marian-fork/src/3rd_party/ExceptionWithCallStack.cpp \
        --replace-quiet '#include <execinfo.h>' \
'/* musl: no execinfo.h — inline stubs */
static inline int backtrace(void**, int) { return 0; }
static inline char** backtrace_symbols(void* const*, int) { return nullptr; }'
      # clang -Werror rejects VLA — make size constants const
      substituteInPlace marian-fork/src/3rd_party/ExceptionWithCallStack.cpp \
        --replace-quiet 'unsigned int MAX_NUM_FRAMES = 1024' \
                         'const unsigned int MAX_NUM_FRAMES = 1024' \
        --replace-quiet 'unsigned int MAX_FUNCNAME_SIZE = 4096' \
                         'const unsigned int MAX_FUNCNAME_SIZE = 4096'

      # faiss VectorTransform.h only includes x86intrin.h on Apple — need it on Linux too
      substituteInPlace marian-fork/src/3rd_party/faiss/VectorTransform.h \
        --replace-quiet '#if defined(__APPLE__) && !defined(__arm64__)' \
                         '#if (defined(__APPLE__) && !defined(__arm64__)) || defined(__x86_64__)'

      # clang 21 C++23: constexpr rejects out-of-range enum cast
      substituteInPlace marian-fork/src/3rd_party/sentencepiece/src/trainer_interface.cc \
        --replace-quiet 'constexpr unicode_script::ScriptType kAnyType =' \
                         'const unicode_script::ScriptType kAnyType ='

      # Copy our FFI wrapper into the source tree so we can compile it
      # after cmake finishes (all include paths are already configured)
      cp ${./translate.cpp} axium_translate.cpp
      cp ${./translate.h} axium_translate.h
    '';

    postBuild = ''
      # Stub LAPACK symbols referenced by faiss VectorTransform (never called at runtime)
      cat > lapack_stubs.c << 'STUB'
      void dsyev_(void) { __builtin_trap(); }
      void sgeqrf_(void) { __builtin_trap(); }
      void sorgqr_(void) { __builtin_trap(); }
      STUB
      $CC -c -o lapack_stubs.o lapack_stubs.c

      # Compile our C FFI wrapper using the same include paths cmake set up
      src=$NIX_BUILD_TOP/$sourceRoot
      $CXX -c -o translate.o $src/axium_translate.cpp \
        -I$src \
        -I$src/src \
        -I$src/marian-fork/src \
        -I$src/marian-fork/src/3rd_party \
        -I$src/marian-fork/src/3rd_party/sentencepiece \
        -I$src/marian-fork/src/3rd_party/sentencepiece/third_party/protobuf-lite \
        -I$src/marian-fork/src/3rd_party/intgemm \
        -I$src/marian-fork/src/3rd_party/ruy \
        -I$src/3rd_party/ssplit-cpp/src/ssplit \
        -I$PWD/marian-fork/src/3rd_party/intgemm \
        -I$PWD/marian-fork/src/3rd_party \
        -std=c++17 -fPIC -DUSE_SENTENCEPIECE
    '';

    installPhase = ''
      mkdir -p $out/lib $out/include

      # Copy all static libraries produced by the build
      find . -name '*.a' -exec cp {} $out/lib/ \;

      # Copy our FFI object, LAPACK stubs, and header
      cp translate.o lapack_stubs.o $out/lib/
      cp $NIX_BUILD_TOP/$sourceRoot/axium_translate.h $out/include/translate.h
    '';

    meta = {
      description = "Bergamot translator + C FFI wrapper";
      platforms = [ "x86_64-linux" ];
    };
  };

in {
  inherit lib;
  sources = [ ./translate.odin modelsRegistry ];
  buildInputs = with pkgs; [ blis pcre2 gperftools ];

  # Link order matters: bergamot-translator-source -> marian -> sentencepiece -> intgemm -> system libs
  # yaml-cpp, pathie-cpp, zlib, faiss objects are baked into libmarian.a
  # sentencepiece bundles its own protobuf-lite (no system protobuf needed)
  linkFlags = builtins.concatStringsSep " " [
    "${lib}/lib/translate.o"
    "${lib}/lib/lapack_stubs.o"
    "-L${lib}/lib"
    "-lbergamot-translator-source"
    "-lmarian"
    "-lssplit"
    "-lsentencepiece"
    "-lsentencepiece_train"
    "-lintgemm"
    "-lblis"
    "-lpcre2-8"
    "-ltcmalloc_minimal"
    "-ldl"
    "-lpthread"
  ];
}
