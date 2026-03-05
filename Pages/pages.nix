{ pkgs }:

pkgs.stdenv.mkDerivation {
  pname = "axium-pages";
  version = "0.1.0";
  src = ./.;

  nativeBuildInputs = [ pkgs.binutils ];

  buildPhase = ''
    page_objects=""
    externs=""
    entries=""
    count=0

    for f in $(find . -type f -not -name '*.nix' | sort); do
      rel="''${f#./}"
      sym=$(echo "$rel" | tr '/.' '__')

      objcopy -I binary -O elf64-x86-64 \
        --rename-section .data=.rodata,alloc,load,readonly,data,contents \
        "$rel" "page_''${sym}.o"
      page_objects="$page_objects page_''${sym}.o"

      case "$rel" in
        *.html) mime="text/html" ;;
        *.css)  mime="text/css" ;;
        *.js)   mime="application/javascript" ;;
        *)      mime="application/octet-stream" ;;
      esac

      externs="$externs"'extern const uint8_t _binary_'"''${sym}"'_start[];
'
      externs="$externs"'extern const uint8_t _binary_'"''${sym}"'_end[];
'
      entries="$entries"'  {"'"$rel"'","'"$mime"'",_binary_'"''${sym}"'_start,_binary_'"''${sym}"'_end},
'
      count=$((count + 1))
    done

    {
      printf '#pragma once\n#include <stdint.h>\n\n'
      printf 'typedef struct { const char* path; const char* mime; const uint8_t* start; const uint8_t* end; } PageFile;\n\n'
      printf '%s' "$externs"
      printf '\nstatic const PageFile g_pages[] = {\n%s};\n' "$entries"
      printf 'static const int g_pages_count = %d;\n' "$count"
    } > pages.h

    ar rcs libpages.a $page_objects
  '';

  installPhase = ''
    mkdir -p $out/lib $out/include
    cp libpages.a $out/lib/
    cp pages.h $out/include/
  '';

  meta = {
    description = "Axium Pages - embedded internal page assets";
    platforms = [ "x86_64-linux" ];
  };
}
