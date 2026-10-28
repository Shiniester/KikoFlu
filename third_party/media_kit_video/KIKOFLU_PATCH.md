# KikoFlu iOS picture in picture

This directory contains `media_kit_video` 2.0.1 from pub.dev, with its original
MIT license and all platform implementations. KikoFlu uses a path dependency.

The iOS patch locates the existing libmpv video output and copies its rendered
frames into an independent CVPixelBufferPool for an AVSampleBufferDisplayLayer
on iOS 15 and later. It adds a separate platform
channel for picture in picture, including native start/failure/stop events.
System playback controls call back to the same Dart Player. State subscriptions
update the native timebase without synchronous libmpv calls on the render path.
No second media
source, AVPlayer, audio session, or system volume control is created.

KikoFlu configures iOS video output with `enableHardwareAcceleration: false`.
The upstream OpenGLES renderer cannot safely render after iOS backgrounds the
app. Other platforms retain their existing renderers and Dart APIs.

Changed upstream files are limited to the iOS plugin registration, VideoOutput,
and VideoOutputManager, plus the new VideoPictureInPicture.swift implementation.
Validate PiP startup, background playback, system controls, return, and teardown
on a physical iOS 15+ device before releasing this patch.
