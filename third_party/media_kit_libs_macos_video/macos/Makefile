all: Frameworks/*.xcframework Frameworks/.symlinks

DARWIN_ARCHIVE=../../../build/native-audio/darwin-output/libmpv-xcframeworks_v0.6.0_macos-arm64-video-default.tar.gz

.cache/xcframeworks/libmpv-xcframeworks-v0.6.0-macos-arm64.tar.gz: FORCE
	@test -s "$(DARWIN_ARCHIVE)" || { echo "Required custom macOS libmpv archive is missing: $(DARWIN_ARCHIVE). Run scripts/native_audio/build_darwin.sh." >&2; exit 1; }
	mkdir -p .cache/xcframeworks
	cp -f "$(DARWIN_ARCHIVE)" $@

.cache/xcframeworks/libmpv-xcframeworks-macos-arm64.tar.gz: .cache/xcframeworks/libmpv-xcframeworks-v0.6.0-macos-arm64.tar.gz
	rm -f $@
	ln -s libmpv-xcframeworks-v0.6.0-macos-arm64.tar.gz $@

Frameworks/*.xcframework: .cache/xcframeworks/libmpv-xcframeworks-macos-arm64.tar.gz
	mkdir -p Frameworks
	rm -rf Frameworks/*.xcframework
	tar -xvf .cache/xcframeworks/libmpv-xcframeworks-macos-arm64.tar.gz --strip-components 1 -C Frameworks
	touch Frameworks/*.xcframework

Frameworks/.symlinks: Frameworks/*.xcframework
	rm -rf Frameworks/.symlinks
	mkdir -p Frameworks/.symlinks/mpv
	sed -i '' 's/\r$$//g' create_framework_symlinks.sh # remove CRLF line terminator added by Flutter packaging (https://github.com/media-kit/media-kit/issues/338)
	sh create_framework_symlinks.sh Frameworks/Mpv.xcframework Frameworks/.symlinks/mpv

.PHONY: FORCE clean
FORCE:

clean:
	rm -rf .cache
	rm -f ./Headers/mpv/*.h
	rm -rf ./Frameworks/*.xcframework
