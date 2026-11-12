#!/bin/bash
set -e

echo "Building Iroru for Linux..."

case "$(uname -m)" in
    x86_64|amd64)
        LINUX_ARCH="x64"
        ;;
    aarch64|arm64)
        LINUX_ARCH="arm64"
        ;;
    *)
        echo "Unsupported Linux architecture: $(uname -m). Supported architectures are x86_64 and aarch64." >&2
        exit 1
        ;;
esac

NATIVE_AUDIO_PREFIX="build/native-audio/linux-output"
if [[ ! -s "$NATIVE_AUDIO_PREFIX/lib/pkgconfig/mpv.pc" ]]; then
    echo "Missing pinned Linux native audio libraries: $NATIVE_AUDIO_PREFIX" >&2
    echo "Build them once with: bash scripts/native_audio/build_linux.sh" >&2
    exit 1
fi

for tool in lddtree patchelf readelf; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing $tool. Install Linux packaging tools with: sudo apt-get install pax-utils patchelf binutils" >&2
        exit 1
    fi
done

# Keep build/native-audio intact; only remove this architecture's Flutter output.
rm -rf "build/linux/$LINUX_ARCH"
flutter pub get
flutter build linux --release

BUILD_DIR="build/linux/$LINUX_ARCH/release/bundle"
echo "Build output: $BUILD_DIR"
bash linux/check_linux_bundle.sh "$BUILD_DIR"

# Create tar.gz package
VERSION=$(grep 'version:' pubspec.yaml | head -1 | awk '{print $2}')
PACKAGE="Iroru-${VERSION}-linux-${LINUX_ARCH}.tar.gz"
tar -czf "$PACKAGE" -C "$BUILD_DIR" .
echo "Package created: $PACKAGE"
