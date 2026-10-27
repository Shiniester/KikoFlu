# Audio slice ownership and playback

Audio slices belong to a playable track, with positions measured from that
track's start. Online, cached, and downloaded playback of the same track share
slices; different audio sources and audio versions keep separate slices. Each
Japanese ASMR chapter has independent slices on its zero-based chapter timeline.
Slices are device-local annotations shared across audio accounts, including
anonymous playback. Signing out or deleting a playback cache does not delete
the annotations.

[EaraAsmrPlayer uses the file path as the slice identity for local tracks](https://github.com/eValDoll/EaraAsmrPlayer/blob/c63daa37895456b8fa1066f4296ad7cef59acdce/app/src/main/java/com/asmr/player/playback/MediaItemFactory.kt#L52-L70).
KikoFlu needs slices to survive switching between remote playback and a downloaded
file, so playback URLs and local paths cannot define slice ownership. Whole-work
timestamps would also require translating chapter-relative positions during
online and offline playback. Track ownership keeps slice positions consistent
with the time shown in the player.

Only Slices Mode is global for the running app session. It survives track changes
but starts disabled after a restart; tracks without slices play in full. Unlike
EaraAsmrPlayer's paused-position enforcement, KikoFlu preserves manual seeking
while paused and skips gaps only when playback resumes, so the user can inspect
and mark positions outside existing slices.

Native successor preparation is suspended during Slice Preview and Only Slices
Mode. Native auto-advance can start a successor before its slice metadata is
loaded, so these modes use the guarded track load and normalize the position
before starting playback.
