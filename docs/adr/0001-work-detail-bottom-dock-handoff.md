# ADR 0001: Keep Bottom Dock layouts in their pages

## Status

Accepted, revised on 2026-10-27.

## Context

The Main Screen owns a Bottom Dock containing the Mini Player and App Tab Bar, while destination pages show the Mini Player without the App Tab Bar. The previous cross-route handoff moved these controls vertically and required endpoint registration, temporary ownership, placeholders, and snapshot invalidation. The Bottom Dock and Mini Player artwork now stay in their own page layouts during navigation.

## Decision

Online and offline Work Details navigation continues to use `pushWorkDetailRoute`, which delegates to `pushBottomDockRoute`. Other pages that retain the Mini Player use `pushBottomDockRoute` directly. These entry points use ordinary page transitions without a Bottom Dock handoff session or overlay. Main Screen retains tab selection, and Riverpod retains playback state.

The Main Screen Dock stays in `Scaffold.bottomNavigationBar`, and each destination Mini Player stays in its `GlobalAudioPlayerWrapper` page subtree. The App Tab Bar uses the current bottom view padding for its safe area. Mini Player and full-screen player artwork render independently during player entry and return.

The portrait Main Screen retains `Scaffold.extendBody`. Scrollable collections and the Settings list retain trailing padding for the Dock, and nested Scaffold controls use the same inset to remain above it. This content viewport stays the same throughout entry and return.

Automatic Work Details replacement uses a zero-duration entry without adding a return step. The original navigation Future waits for the final replacement page to close and finish its return transition. Repeated taps only push while the source route is still current.

## Consequences

Pages keep their own playback controls through ordinary navigation. There is no endpoint registry, cross-route Dock ownership, frozen handoff inset, vertical Dock displacement, or Dock-specific snapshot notification. No additional dependency is required.

The app page transition moves the entering or leaving page over 300 ms with `Curves.ease`; the covered source page moves left by one third of its width and is clipped to the exposed viewport. Source movement and return reuse the page's retained paint layer without allocating a full-screen bitmap. Android keeps snapshots for the entering or leaving foreground page, identified by its dismissed secondary animation. Interactive back gestures retain that foreground snapshot through settling while the revealed source continues to use its paint layer. The transition also observes Navigator gesture changes so cancellation without animation progress releases the snapshot and restores semantics. Covered source content updates repaint its layer when it becomes visible.

Work Details screens initially build from the data already supplied by the caller or held in memory, keeping the cover, title, available creator, tag, release and language-edition metadata, online rating and progress, and Bottom Dock available during the route transition. Showing existing metadata starts no additional requests, disk-cache reads, or scans. They observe the route's primary and secondary animation states and the Navigator's interactive gesture state. After the route is current, both animations are settled, gestures have ended, and the final moving frame has painted, the screen creates file-tree content and starts detail requests or offline scans. Missing metadata is filled by the existing detail request; omitted response fields retain known creator, tag, release and language-edition values, while explicitly returned empty values replace them. Async results check readiness again before publishing UI or shared state. The HD cover starts after the deferred content has painted once; it does not wait for metadata or file-tree requests to finish.

The online and offline file explorers accept an optional readiness callback. Direct uses without that callback retain their immediate-loading behavior. File-tree requests retain this route readiness boundary. Online recommendations belong to the rightmost resource tab and start when that tab is selected.
