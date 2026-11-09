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

for tool in lddtree patchelf readelf; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing $tool. Install Linux packaging tools with: sudo apt-get install pax-utils patchelf binutils" >&2
        exit 1
    fi
done

flutter clean
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
