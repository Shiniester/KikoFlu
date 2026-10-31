# ADR 0001: Keep app navigation outside page routes

## Status

Accepted, revised on 2026-10-31.

## Context

Browsing pages need persistent app navigation and shared audio playback access. Keeping the Bottom Dock in the Main Screen route hides it when a detail or search route covers that screen. Full-screen audio playback, comic reading, and full-screen video need the full viewport. Work Details opened from the full-screen audio player belong to the Audio browsing history after the player returns to the Mini Player.

## Decision

`MaterialApp.builder` wraps the existing root Navigator in `AppNavigationShell`. The shell owns the shared Mini Player, portrait App Tab Bar, and landscape NavigationRail. `MainScreen` retains its PageView and lazy pages, with a Navigator for each app tab. Each tab retains its browsing history when another tab is selected. Returning to a tab shows its previous page and preserves its return path.

`AppNavigationController` observes the root stack and the tab stacks, and owns the selected app tab. Ordinary pages show navigation. Comic reader, work-image reader, reader settings, and dedicated video presentation routes use `appImmersiveRouteSettings`. Inline video retains navigation; the existing video fullscreen callback hides navigation only while fullscreen is active. Popup routes retain the underlying page presentation, and their barriers, focus restrictions, and semantics also cover shell controls.

The full-screen audio player uses `appAudioPlayerRouteSettings`. The Bottom Dock stays hidden while the player route is open or its closing transition is running, including when Cover Preview, metadata search, or a lyric text preview is open.

`AppNavigationScope` shares this state and resolves the root Navigator for shell controls. Audio entry and interactive drag handoff use that Navigator; their temporary overlay uses the shell's outer Overlay. Page-local `GlobalAudioPlayerWrapper` uses the shell's existing playback surface instead of adding a second Mini Player.

Online and offline Work Details navigation continues to use `pushWorkDetailRoute`, which delegates to `pushBottomDockRoute`. Other browsing routes keep their current Navigator calls. Opening Work Details from the full-screen audio player closes the player to the Mini Player, selects Audio, and opens the details in its browsing history. Automatic Work Details replacement uses a zero-duration entry without adding a return step. The original navigation Future waits for the final replacement page to close and finish its return transition. Repeated taps only push while the source route is still current.

## Consequences

The shared navigation stays outside page transition movement. Portrait content retains `Scaffold.extendBody` and trailing padding so nested controls stay above the Dock. Landscape navigation stays on the left; playback retains its existing compact placement below the content. Media entry and return use the full viewport, and outgoing media keeps that viewport until its close transition completes. Playback state remains in Riverpod. No additional dependency is required.

Switching away from Video Details pauses playback and saves its position. Returning leaves the video paused until the user resumes playback.

Audio player entry slides the shared playback and navigation controls out. On return, the controls slide in only after the player's closing route has completed. The shell preserves the full-screen viewport while the keyboard is visible; the Player Lyrics Page clips its lower visible region instead of moving or shrinking the entire page.

Interactive previews keep the shared launch subtree mounted while its controls are hidden, so hiding the Dock cannot cancel the pointer. Handoff keeps the Dock hidden when the root route replaces the preview; cancellation restores it.

Work Details screens initially build from the data already supplied by the caller or held in memory, keeping the cover, title, available creator, tag, release and language-edition metadata, online rating and progress, and Bottom Dock available during the route transition. Showing existing metadata starts no additional requests, disk-cache reads, or scans. They observe the route's primary and secondary animation states and the Navigator's interactive gesture state. After the route is current, both animations are settled, gestures have ended, and the final moving frame has painted, the screen creates file-tree content and starts detail requests or offline scans. Audio tab Work Details also wait for the Bottom Dock's return animation before starting deferred work. Missing metadata is filled by the existing detail request; omitted response fields retain known creator, tag, release and language-edition values, while explicitly returned empty values replace them. Async results check readiness again before publishing UI or shared state. The HD cover starts after the deferred content has painted once; it does not wait for metadata or file-tree requests to finish.

The online and offline file explorers accept an optional readiness callback. Direct uses without that callback retain their immediate-loading behavior. File-tree requests retain this route readiness boundary. Online recommendations belong to the rightmost resource tab and start when that tab is selected.
