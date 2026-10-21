# ADR 0004: Play and download Japanese ASMR chapters as separate tracks

Japanese ASMR publishes chapter names and start times for a complete audio
stream. Works with chapters expose those chapters, in source order, as separate
tracks in the Work Details Screen's Audio tab. Each chapter ends at the next
chapter's start, and the last chapter ends with the stream. Works without a
chapter index retain their complete-work audio entry.

Chapter tracks share the online stream and carry their own identity and time
bounds. Playback positions are relative to the chapter, and queue insertion,
previous/next navigation, repeat modes, and work-level history retain their
existing rules. Downloaded chapters are independent AAC files, so local playback
does not apply the online time bounds a second time. Existing complete-work
downloads and saved queues remain usable.

Chapter downloads extract the AAC frames from the HLS segments covering the
requested interval. This preserves the compressed audio without a transcoder
dependency or repeated complete-work downloads. Chapter boundaries align to AAC
frames rather than individual PCM samples. Unsupported stream formats fail the
download instead of producing a mislabeled or complete-work chapter file.
