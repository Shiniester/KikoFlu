# ADR 0001: Hand off the Bottom Dock to Work Details routes

## Status

Accepted

## Context

The Main Screen owns a Bottom Dock containing the Mini Player and App Tab Bar, while Work Details screens need the same Mini Player at the bottom without the App Tab Bar. Creating unrelated Mini Players on both routes made the artwork follow the full-player Hero path and briefly leave the screen. The transition must also follow native route timing and interactive back gestures without affecting other routes or landscape navigation.

## Decision

All online and offline Work Details navigation goes through `pushWorkDetailRoute`, which delegates to `pushBottomDockRoute`. Other pages that retain the Mini Player, including search results, comic categories and comic downloads, use `pushBottomDockRoute` directly. The nearest `AppBottomDockTransitionScope` owns the temporary handoff session until the destination route's `completed` future resolves. Main Screen retains tab selection, and Riverpod retains playback state.

At rest, the Main Screen Dock remains in `Scaffold.bottomNavigationBar`, and the destination Mini Player remains in the `GlobalAudioPlayerWrapper` page subtree. Endpoints register their actual sizes. After the destination has laid out, stable GlobalKeys move its real Mini Player and the source App Tab Bar into a separate layer in the dedicated `MaterialPageRoute` subclass's `buildTransitions`. Equal-height placeholders retain page layout; the source Mini Player remains offstage with its state intact. The layer is a sibling of the native page transition, so horizontal page movement does not move the Dock horizontally. Once settled, the destination Mini Player returns to the page subtree where the full-player artwork Hero can discover it.

A Flutter `SlideTransition` uses the full route viewport as its layout box and bottom-aligns the natural-height Mini Player and App Tab Bar in one column. Both move down by `58 + bottom inset`, maintaining their spacing without assuming a Mini Player height. The endpoint offset is `(0, distance / viewport height)`, following [Flutter's child-relative offset semantics](https://api.flutter.dev/flutter/widgets/SlideTransition-class.html). Mini-only source pages use the same independent layer with zero displacement. The layer inherits the frozen physical bottom inset and endpoint themes, uses transparent Material, and excludes interaction, semantics and artwork Heroes during handoff. The full-player artwork Hero remains available after settling.

Route animation and Navigator gesture state jointly determine handoff ownership. Starting a back gesture enters handoff even while route progress is still 1. Endpoint ownership changes clear the native page transition's existing snapshots and pause capture for the switching frame; the next frame restores the original body snapshot conditions. View metric changes exit handoff in landscape, and the source scope's live endpoint registry prevents removed App Tab Bars from reappearing during return.

When a route from the same source scope is returning, the next entry waits for that route's `completed` future before arming a new handoff. This keeps Cupertino's background animation from switching between overlapping reverse and forward animations while retaining the reverse curve. Repeated taps only push while the source route is still current. Both portrait and landscape Main Screen layouts provide the scope; the landscape scope has no App Tab Bar endpoint.

## Consequences

New entry points to pages retaining the Mini Player must use the centralized navigation functions, with a context below the source Dock scope. Routes without a Mini Player, landscape NavigationRail layouts, and the platform page transition remain independent of the Bottom Dock handoff.

Rapid reentry waits for the remaining return animation. Dock timing follows the route duration (500 ms in the current Flutter SDK), with `easeInOutCubic` for ordinary entry and return. Interactive back gestures use linear progress through gesture settling. The native page transition retains its existing behavior. Without a source scope, in landscape, or with reduced motion enabled, the destination keeps its static Dock layout. No additional dependency is required.

Work Details screens initially build from the data already supplied by the caller or held in memory, keeping the cover, title, available creator, tag, release and language-edition metadata, online rating and progress, and Bottom Dock available during the route transition. Showing existing metadata starts no additional requests, disk-cache reads, or scans. They observe the route's primary and secondary animation states and the Navigator's interactive gesture state. After the route is current, both animations are settled, gestures have ended, and the final moving frame has painted, the screen creates file-tree content and starts detail requests or offline scans. Missing metadata is filled by the existing detail request; omitted response fields retain known creator, tag, release and language-edition values, while explicitly returned empty values replace them. Async results check readiness again before publishing UI or shared state. The HD cover starts after the deferred content has painted once; it does not wait for metadata or file-tree requests to finish.

The online and offline file explorers accept an optional readiness callback. Direct uses without that callback retain their immediate-loading behavior. File-tree layout and its existing recommendation-ready handoff remain unchanged.
