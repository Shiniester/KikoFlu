# KikoFlu patch notes

This directory vendors `just_audio_media_kit` 2.1.0 under its upstream
license.

## Pending load error propagation

Upstream reports libmpv media-open failures through `Player.stream.error`, but
does not complete the pending `AudioPlayerPlatform.load()` operation. As a
result, `just_audio` callers can wait indefinitely and application-level error
handling never receives the playback failure.

The KikoFlu patch connects the error stream to the pending load operation with
a numeric `PlatformException`, which `just_audio` converts to its normal
`PlayerException`. Successful loads and all playback/session behavior remain
unchanged across Windows, Linux, and macOS.

Keep this patch until the same behavior is available in an upstream release.

## Seek position reporting

The adapter reads libmpv seek and cache state asynchronously so the Flutter UI
can build frames while the playback core processes audio.

libmpv can report a position one audio sample before a seek target. The adapter
reports the target for a nearby undershoot after a seek or initial load, then
returns to the native position as playback advances.

While an explicit seek waits for the native command, libmpv can still report
positions from before the seek. The adapter holds the target during that wait.
The vendored `just_audio` also suspends position extrapolation until the latest
seek request returns.

A short seek during playback can finish before the first native position poll.
The adapter accepts a settled position within the expected playback advance.
Once a seek moves the playback clock, confirmation waits while the clock advances
toward the target. The stall timeout counts from the last advance, and the
overall confirmation timeout still applies.
After confirmation, the position stream cannot move before the receipt on the
same audio source until a new seek or playback boundary. Native repeat releases
that bound after the stream advances, since it can rewind without a seek request.
