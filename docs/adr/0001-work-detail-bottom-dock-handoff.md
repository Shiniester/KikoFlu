# ADR 0001: Hand off the Bottom Dock to Work Details routes

## Status

Accepted

## Context

The Main Screen owns a Bottom Dock containing the Mini Player and App Tab Bar, while Work Details screens need the same Mini Player at the bottom without the App Tab Bar. Creating unrelated Mini Players on both routes made the artwork follow the full-player Hero path and briefly leave the screen. The transition must also follow native route timing and interactive back gestures without affecting other routes or landscape navigation.

## Decision

All online and offline Work Details navigation goes through `pushWorkDetailRoute`. The entry temporarily arms the source Bottom Dock for the lifetime of the route and uses two route-level Hero channels driven by the route animation: one hands off the complete Mini Player, and one moves the App Tab Bar to an equal-size endpoint below the viewport. Work Details screens expose matching endpoints, while pages that already contain only a Mini Player keep its rectangle unchanged. The Mini Player disables its full-player artwork Hero during this handoff and restores that Hero only while opening the full player.

## Consequences

New Work Details entry points must use the centralized navigation function. Ordinary routes, landscape NavigationRail layouts, and the platform page transition remain independent of the Bottom Dock handoff.
