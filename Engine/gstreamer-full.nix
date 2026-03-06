# GStreamer full static library with cherry-picked plugins for Axium.
# Builds from the GStreamer monorepo with only the plugins WebKit needs,
# producing a single libgstreamer-full-1.0.a with gst_init_static_plugins().
#
# This replaces nixpkgs' gst_all_1.* packages for the static build,
# eliminating ~150 transitive deps (pulseaudio, wayland, jack, etc.)
# and making GStreamer work without dlopen.
{ pkgs, hostPkgs ? pkgs, gstreamer-src }:

pkgs.stdenv.mkDerivation {
  pname = "gstreamer-full";
  version = "1.28.1";

  src = gstreamer-src;

  # Fix shebangs in build-time Python scripts (get_flex_version.py etc.)
  # so they use the build-platform interpreter, not /usr/bin/env
  postPatch = ''
    patchShebangs --build .
  '';

  nativeBuildInputs = with hostPkgs; [
    meson
    ninja
    pkg-config
    python3
    flex
    bison
    glib         # glib-mkenums, glib-compile-resources (build tools)
    gettext      # msgfmt used during build
  ];

  buildInputs = with pkgs; [
    glib
    libogg
    libvorbis
    libopus
    libvpx
    zlib
  ];

  mesonFlags = [
    # Note: --default-library=static is NOT listed here because nix's meson
    # setup for isStatic cross builds auto-injects -Ddefault_library=static.
    "-Dgst-full-target-type=static_library"
    "-Dgst-full=enabled"
    "-Dauto_features=disabled"

    # ── Subprojects ──
    "-Dbase=enabled"
    "-Dgood=enabled"
    "-Dbad=enabled"
    "-Dugly=disabled"
    "-Dlibav=disabled"
    "-Ddevtools=disabled"
    "-Dges=disabled"
    "-Drtsp_server=disabled"
    "-Drs=disabled"
    "-Dgst-examples=disabled"
    "-Dpython=disabled"

    # ── Common features ──
    "-Dtests=disabled"
    "-Dexamples=disabled"
    "-Dintrospection=disabled"
    "-Ddoc=disabled"
    "-Dnls=disabled"
    "-Dtools=disabled"
    "-Dbenchmarks=disabled"
    "-Dorc=disabled"         # SIMD codegen — can enable later if needed
    "-Dwebrtc=disabled"
    "-Dqt5=disabled"
    "-Dqt6=disabled"
    "-Dgtk=disabled"

    # ── Libraries exposed in gstreamer-full ABI ──
    # These symbols are re-exported from the monolithic libgstreamer-full-1.0.a.
    # Must match what WebKit links against (see Source/WebCore/platform/GStreamer.cmake).
    # With WEB_AUDIO=OFF we drop gstreamer-fft-1.0.
    "-Dgst-full-libraries=gstreamer-video-1.0,gstreamer-audio-1.0,gstreamer-app-1.0,gstreamer-pbutils-1.0,gstreamer-tag-1.0,gstreamer-base-1.0,gstreamer-allocators-1.0"

    # ── gst-plugins-base: core media infrastructure ──
    "-Dgst-plugins-base:app=enabled"
    "-Dgst-plugins-base:playback=enabled"
    "-Dgst-plugins-base:videoconvertscale=enabled"
    "-Dgst-plugins-base:audioconvert=enabled"
    "-Dgst-plugins-base:audioresample=enabled"
    "-Dgst-plugins-base:volume=enabled"
    "-Dgst-plugins-base:typefind=enabled"
    "-Dgst-plugins-base:subparse=enabled"
    "-Dgst-plugins-base:videorate=enabled"
    "-Dgst-plugins-base:ogg=enabled"
    "-Dgst-plugins-base:opus=enabled"
    "-Dgst-plugins-base:vorbis=enabled"
    "-Dgst-plugins-base:gio=enabled"
    "-Dgst-plugins-base:gl=disabled"
    "-Dgst-plugins-base:x11=disabled"
    "-Dgst-plugins-base:xshm=disabled"
    "-Dgst-plugins-base:xvideo=disabled"
    "-Dgst-plugins-base:alsa=disabled"
    "-Dgst-plugins-base:cdparanoia=disabled"
    "-Dgst-plugins-base:pango=disabled"
    "-Dgst-plugins-base:theora=disabled"

    # ── gst-plugins-good: container demuxers + codecs ──
    "-Dgst-plugins-good:autodetect=enabled"
    "-Dgst-plugins-good:matroska=enabled"
    "-Dgst-plugins-good:isomp4=enabled"
    "-Dgst-plugins-good:vpx=enabled"
    "-Dgst-plugins-good:audioparsers=enabled"
    "-Dgst-plugins-good:id3demux=enabled"
    # Disable the heavy hitters
    "-Dgst-plugins-good:pulse=disabled"
    "-Dgst-plugins-good:jack=disabled"
    "-Dgst-plugins-good:aalib=disabled"
    "-Dgst-plugins-good:libcaca=disabled"
    "-Dgst-plugins-good:cairo=disabled"
    "-Dgst-plugins-good:dv=disabled"
    "-Dgst-plugins-good:dv1394=disabled"
    "-Dgst-plugins-good:flac=disabled"
    "-Dgst-plugins-good:gdk-pixbuf=disabled"
    "-Dgst-plugins-good:lame=disabled"
    "-Dgst-plugins-good:mpg123=disabled"
    "-Dgst-plugins-good:shout2=disabled"
    "-Dgst-plugins-good:speex=disabled"
    "-Dgst-plugins-good:taglib=disabled"
    "-Dgst-plugins-good:twolame=disabled"
    "-Dgst-plugins-good:wavpack=disabled"
    "-Dgst-plugins-good:adaptivedemux2=disabled"
    "-Dgst-plugins-good:v4l2=disabled"
    "-Dgst-plugins-good:oss=disabled"
    "-Dgst-plugins-good:oss4=disabled"

    # ── gst-plugins-bad: parsers + closedcaption ──
    "-Dgst-plugins-bad:videoparsers=enabled"
    "-Dgst-plugins-bad:closedcaption=enabled"
    # Disable GL and everything else
    "-Dgst-plugins-bad:gl=disabled"
    "-Dgst-plugins-bad:webrtc=disabled"
    "-Dgst-plugins-bad:webrtcdsp=disabled"
    "-Dgst-plugins-bad:dash=disabled"
    "-Dgst-plugins-bad:smoothstreaming=disabled"
    "-Dgst-plugins-bad:dtls=disabled"
    "-Dgst-plugins-bad:srtp=disabled"
    "-Dgst-plugins-bad:sctp=disabled"
    "-Dgst-plugins-bad:opus=disabled"
    "-Dgst-plugins-bad:transcode=disabled"
    "-Dgst-plugins-bad:va=disabled"
    "-Dgst-plugins-bad:vulkan=disabled"
  ];

  enableParallelBuilding = true;

  meta = {
    description = "GStreamer full static library with selected plugins for Axium";
    homepage = "https://gstreamer.freedesktop.org/";
    platforms = [ "x86_64-linux" ];
  };
}
