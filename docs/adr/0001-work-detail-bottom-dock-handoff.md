# ADR 0001: Hand off the Bottom Dock to Work Details routes

## Status

Accepted

## Context

The Main Screen owns a Bottom Dock containing the Mini Player and App Tab Bar, while Work Details screens need the same Mini Player at the bottom without the App Tab Bar. Creating unrelated Mini Players on both routes made the artwork follow the full-player Hero path and briefly leave the screen. The transition must also follow native route timing and interactive back gestures without affecting other routes or landscape navigation.

## Decision

All online and offline Work Details navigation goes through `pushWorkDetailRoute`, which delegates to `pushBottomDockRoute`. Other pages that retain the Mini Player, including search results, comic categories and comic downloads, use `pushBottomDockRoute` directly. The entry temporarily arms the source Bottom Dock for the lifetime of the route and uses two route-level Hero channels driven by the route animation: one hands off the complete Mini Player, and one moves the App Tab Bar to an equal-size endpoint below the viewport. Work Details screens and `GlobalAudioPlayerWrapper` pages receiving handoff metrics expose matching endpoints, while pages that already contain only a Mini Player keep its rectangle unchanged. The Mini Player disables its full-player artwork Hero during this handoff and restores that Hero only while opening the full player.

When a route from the same source scope is returning, the next entry waits for that route's `completed` future before arming a new handoff. This keeps Cupertino's background animation from switching between overlapping reverse and forward animations while retaining the reverse curve. Repeated taps only push while the source route is still current. Both portrait and landscape Main Screen layouts provide the scope; the landscape scope has no App Tab Bar endpoint.

## Consequences

New entry points to pages retaining the Mini Player must use the centralized navigation functions, with a context below the source Dock scope. Routes without a Mini Player, landscape NavigationRail layouts, and the platform page transition remain independent of the Bottom Dock handoff.

Rapid reentry waits for the remaining return animation. Ordinary entry and return use a 400 ms duration with Cupertino's default curves; interactive back gestures retain Cupertino's native behavior.

Work Details screens initially build from the data already supplied by the caller or held in memory, keeping the cover, title, available creator, tag, release and language-edition metadata, online rating and progress, and Bottom Dock available during the route transition. Showing existing metadata starts no additional requests, disk-cache reads, or scans. They observe the route's primary and secondary animation states and the Navigator's interactive gesture state. After the route is current, both animations are settled, gestures have ended, and the final moving frame has painted, the screen creates file-tree content and starts detail requests or offline scans. Missing metadata is filled by the existing detail request; omitted response fields retain known creator, tag, release and language-edition values, while explicitly returned empty values replace them. Async results check readiness again before publishing UI or shared state. The HD cover starts after the deferred content has painted once; it does not wait for metadata or file-tree requests to finish.

The online and offline file explorers accept an optional readiness callback. Direct uses without that callback retain their immediate-loading behavior. File-tree layout and its existing recommendation-ready handoff remain unchanged.
