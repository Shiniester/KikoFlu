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

Rapid reentry waits for the remaining return animation. Ordinary entry and return use a 300 ms duration with Cupertino's default curves; interactive back gestures retain Cupertino's native behavior.
