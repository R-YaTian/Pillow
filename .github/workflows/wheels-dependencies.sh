#!/bin/bash
# Define custom utilities
# Test for macOS with [ -n "$IS_MACOS" ]
if [ -z "$IS_MACOS" ]; then
    export MB_ML_LIBC=${AUDITWHEEL_POLICY::9}
    export MB_ML_VER=${AUDITWHEEL_POLICY:9}

    # Build and install into the `build/deps` folder.
    BUILD_PREFIX=$(pwd)/build/deps
fi
export PLAT=$CIBW_ARCHS
source wheels/multibuild/common_utils.sh
source wheels/multibuild/library_builders.sh
if [ -z "$IS_MACOS" ]; then
    source wheels/multibuild/manylinux_utils.sh
fi

ARCHIVE_SDIR=pillow-depends-main

# Package versions for fresh source builds
FREETYPE_VERSION=2.13.2
HARFBUZZ_VERSION=10.0.1
LIBPNG_VERSION=1.6.44
JPEGTURBO_VERSION=3.0.4
OPENJPEG_VERSION=2.5.2
XZ_VERSION=5.6.3
TIFF_VERSION=4.6.0
LCMS2_VERSION=2.16
RAQM_VERSION=0.10.2
FRIBIDI_VERSION=1.0.16
if [[ -n "$IS_MACOS" ]]; then
    GIFLIB_VERSION=5.2.2
else
    GIFLIB_VERSION=5.2.1
fi
if [[ -n "$IS_MACOS" ]] || [[ "$MB_ML_VER" != 2014 ]]; then
    ZLIB_VERSION=1.3.1
else
    ZLIB_VERSION=1.2.8
fi
LIBWEBP_VERSION=1.4.0
BZIP2_VERSION=1.0.8
LIBXCB_VERSION=1.17.0
BROTLI_VERSION=1.1.0

function build_pkg_config {
    if [ -e pkg-config-stamp ]; then return; fi
    # This essentially duplicates the Homebrew recipe:
    # https://github.com/Homebrew/homebrew-core/blob/master/Formula/p/pkg-config.rb
    ORIGINAL_CFLAGS=$CFLAGS
    CFLAGS="$CFLAGS -Wno-int-conversion"
    build_simple pkg-config 0.29.2 https://pkg-config.freedesktop.org/releases tar.gz \
        --disable-debug --disable-host-tool --with-internal-glib \
        --with-pc-path=$BUILD_PREFIX/share/pkgconfig:$BUILD_PREFIX/lib/pkgconfig \
        --with-system-include-path=$(xcrun --show-sdk-path --sdk macosx)/usr/include
    CFLAGS=$ORIGINAL_CFLAGS
    export PKG_CONFIG=$BUILD_PREFIX/bin/pkg-config
    touch pkg-config-stamp
}

function build_brotli {
    if [ -e brotli-stamp ]; then return; fi
    local cmake=$(get_modern_cmake)
    local out_dir=$(fetch_unpack https://github.com/google/brotli/archive/v$BROTLI_VERSION.tar.gz brotli-$BROTLI_VERSION.tar.gz)
    (cd $out_dir \
        && $cmake -DCMAKE_INSTALL_PREFIX=$BUILD_PREFIX -DCMAKE_INSTALL_NAME_DIR=$BUILD_PREFIX/lib . \
        && make install)
    if [[ "$MB_ML_LIBC" == "manylinux" ]]; then
        cp /usr/local/lib64/libbrotli* /usr/local/lib
        cp /usr/local/lib64/pkgconfig/libbrotli* /usr/local/lib/pkgconfig
    fi
    touch brotli-stamp
}

function build_harfbuzz {
    if [ -e harfbuzz-stamp ]; then return; fi
    python3 -m pip install meson ninja

    local out_dir=$(fetch_unpack https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VERSION/$HARFBUZZ_VERSION.tar.xz harfbuzz-$HARFBUZZ_VERSION.tar.xz)
    (cd $out_dir \
        && meson setup build --prefix=$BUILD_PREFIX --buildtype=release -Dfreetype=enabled -Dglib=disabled)
    (cd $out_dir/build \
        && meson install)
    if [[ "$MB_ML_LIBC" == "manylinux" ]]; then
        cp /usr/local/lib64/libharfbuzz* /usr/local/lib
    fi
    touch harfbuzz-stamp
}

function build_raqm {
    if [ -e raqm-stamp ]; then return; fi
    python3 -m pip install meson ninja

    local out_dir=$(fetch_unpack https://github.com/HOST-Oman/libraqm/releases/download/v$RAQM_VERSION/raqm-$RAQM_VERSION.tar.xz raqm-$RAQM_VERSION.tar.xz)
    (cd $out_dir \
        && meson setup build --prefix=$BUILD_PREFIX)
    (cd $out_dir/build \
        && meson install)
    touch raqm-stamp
}

function build {
    build_xz
    if [ -z "$IS_ALPINE" ] && [ -z "$IS_MACOS" ]; then
        yum remove -y zlib-devel
    fi
    build_new_zlib

    build_simple xcb-proto 1.17.0 https://xorg.freedesktop.org/archive/individual/proto
    if [ -n "$IS_MACOS" ]; then
        build_simple xorgproto 2024.1 https://www.x.org/pub/individual/proto
        build_simple libXau 1.0.11 https://www.x.org/pub/individual/lib
        build_simple libXdmcp 1.1.5 https://www.x.org/pub/individual/lib
        build_simple libpthread-stubs 0.5 https://xcb.freedesktop.org/dist
    else
        sed s/\${pc_sysrootdir\}// /usr/local/share/pkgconfig/xcb-proto.pc > /usr/local/lib/pkgconfig/xcb-proto.pc
    fi
    build_simple libxcb $LIBXCB_VERSION https://www.x.org/releases/individual/lib

    build_libjpeg_turbo
    if [ -n "$IS_MACOS" ]; then
        # Custom tiff build to include jpeg; by default, configure won't include
        # headers/libs in the custom macOS prefix. Explicitly disable webp and
        # zstd, because on x86_64 macs, it will pick up the Homebrew versions of
        # webp and zstd from /usr/local.
        build_simple tiff $TIFF_VERSION https://download.osgeo.org/libtiff tar.gz \
            --with-jpeg-include-dir=$BUILD_PREFIX/include --with-jpeg-lib-dir=$BUILD_PREFIX/lib \
            --disable-webp --disable-zstd
    else
        build_tiff
    fi

    build_libpng
    build_lcms2
    build_openjpeg
    if [ -f /usr/local/lib64/libopenjp2.so ]; then
        cp /usr/local/lib64/libopenjp2.so /usr/local/lib
    fi

    ORIGINAL_CFLAGS=$CFLAGS
    CFLAGS="$CFLAGS -O3 -DNDEBUG"
    if [[ -n "$IS_MACOS" ]]; then
        CFLAGS="$CFLAGS -Wl,-headerpad_max_install_names"
    fi
    build_libwebp
    CFLAGS=$ORIGINAL_CFLAGS

    build_brotli

    if [ -n "$IS_MACOS" ]; then
        # Custom freetype build
        build_simple freetype $FREETYPE_VERSION https://download.savannah.gnu.org/releases/freetype tar.gz --with-harfbuzz=no
    else
        build_freetype
    fi

    build_harfbuzz

    if [ -n "$IS_MACOS" ]; then
        build_simple fribidi $FRIBIDI_VERSION https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI_VERSION tar.xz --enable-shared
        build_raqm
    fi
}

# Perform all dependency builds in the build subfolder.
mkdir -p build
pushd build > /dev/null

# Any stuff that you need to do before you start building the wheels
# Runs in the root directory of this repository.
if [[ ! -d pillow-depends-main ]]; then
  if [[ ! -f pillow-depends-main.zip ]]; then
    echo "Download pillow dependency sources..."
    curl -fSL -o pillow-depends-main.zip https://github.com/python-pillow/pillow-depends/archive/main.zip
  fi
  untar pillow-depends-main.zip
fi

if [[ -n "$IS_MACOS" ]]; then
    # Homebrew (or similar packaging environments) install can contain some of
    # the libraries that we're going to build. However, they may be compiled
    # with a MACOSX_DEPLOYMENT_TARGET that doesn't match what we want to use,
    # and they may bring in other dependencies that we don't want. The same will
    # be true of any other locations on the path. To avoid conflicts, strip the
    # path down to the bare mimimum (which, on macOS, won't include any
    # development dependencies).
    export PATH="$BUILD_PREFIX/bin:$(dirname $(which python3)):/usr/bin:/bin:/usr/sbin:/sbin:/Library/Apple/usr/bin"
    export CMAKE_PREFIX_PATH=$BUILD_PREFIX

    # Link the brew command into our isolated build directory.
    mkdir -p "$BUILD_PREFIX/bin"
    mkdir -p "$BUILD_PREFIX/lib"

    # Ensure pkg-config is available
    build_pkg_config
    # Ensure cmake is available
    python3 -m pip install cmake
fi

wrap_wheel_builder build

# Return to the project root to finish the build
popd > /dev/null

# Append licenses
for filename in wheels/dependency_licenses/*; do
  echo -e "\n\n----\n\n$(basename $filename | cut -f 1 -d '.')\n" | cat >> LICENSE
  cat $filename >> LICENSE
done
