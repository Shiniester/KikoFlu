# ADR 0001: Keep app navigation outside page routes

## Status

Accepted, revised on 2026-10-28.

## Context

Browsing pages need persistent app navigation and shared audio playback access. Keeping the Bottom Dock in the Main Screen route hides it when a detail or search route covers that screen. Full-screen audio playback, comic reading, and full-screen video need the full viewport. Work Details can also open above the full-screen audio player and must show the Dock there.

## Decision

`MaterialApp.builder` wraps the existing root Navigator in `AppNavigationShell`. The shell owns the shared Mini Player, portrait App Tab Bar, and landscape NavigationRail. `MainScreen` retains its PageView, lazy pages, and browsing state. Selecting another app tab returns the root Navigator to its first route and selects that home page. The same tab keeps its current browsing route.

`AppNavigationController` observes the existing root stack and owns the selected app tab. Ordinary pages show navigation. Audio player, comic reader, work-image reader, reader settings, and dedicated video presentation routes use `appImmersiveRouteSettings`. Inline video retains navigation; the existing video fullscreen callback hides navigation only while fullscreen is active. Popup routes retain the underlying page presentation, and their barriers, focus restrictions, and semantics also cover shell controls.

`AppNavigationScope` shares this state and resolves the root Navigator for shell controls. Audio entry and interactive drag handoff use that Navigator; their temporary overlay uses the shell's outer Overlay. Page-local `GlobalAudioPlayerWrapper` uses the shell's existing playback surface instead of adding a second Mini Player.

Online and offline Work Details navigation continues to use `pushWorkDetailRoute`, which delegates to `pushBottomDockRoute`. Other browsing routes keep their current Navigator calls. Automatic Work Details replacement uses a zero-duration entry without adding a return step. The original navigation Future waits for the final replacement page to close and finish its return transition. Repeated taps only push while the source route is still current.

## Consequences

The shared navigation stays outside page transition movement. Portrait content retains `Scaffold.extendBody` and trailing padding so nested controls stay above the Dock. Landscape navigation stays on the left; playback retains its existing compact placement below the content. Media entry and return use the full viewport, and outgoing media keeps that viewport until its close transition completes. Playback state remains in Riverpod. No additional dependency is required.

Work Details screens initially build from the data already supplied by the caller or held in memory, keeping the cover, title, available creator, tag, release and language-edition metadata, online rating and progress, and Bottom Dock available during the route transition. Showing existing metadata starts no additional requests, disk-cache reads, or scans. They observe the route's primary and secondary animation states and the Navigator's interactive gesture state. After the route is current, both animations are settled, gestures have ended, and the final moving frame has painted, the screen creates file-tree content and starts detail requests or offline scans. Missing metadata is filled by the existing detail request; omitted response fields retain known creator, tag, release and language-edition values, while explicitly returned empty values replace them. Async results check readiness again before publishing UI or shared state. The HD cover starts after the deferred content has painted once; it does not wait for metadata or file-tree requests to finish.

The online and offline file explorers accept an optional readiness callback. Direct uses without that callback retain their immediate-loading behavior. File-tree requests retain this route readiness boundary. Online recommendations belong to the rightmost resource tab and start when that tab is selected.
