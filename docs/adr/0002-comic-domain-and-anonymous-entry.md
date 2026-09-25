# ADR 0002: Share presentation infrastructure and separate comic accounts and data

## Status

Accepted

## Context

Audio and comics need consistent navigation, search tools, appearance, and playback
access. Their identities, progress units, account authorities, and download units
are different. Requiring an audio login at the root would also block independent
comic sources and local content.

## Decision

The Main Screen is available anonymously and presents Audio, Comics, and Settings.
Audio server configuration survives logout, while active credentials and cache
scope switch to the anonymous identity. Existing audio preference keys remain.

Share the floating LibraryTabStrip, toolbar components, global proxy, logging,
theme, language, and Mini Player. Audio Work Details retain ADR 0001's Dock handoff.
Comic details and the fullscreen reader use ordinary independent routes. The
reader owns its control-layer Mini Player and preserves its route while the full
player is open.

Keep comic models, source adapters, credentials, SQLite tables, image cache and
chapter download service separate. A source-qualified comic ID prevents collisions;
reading progress stores actual image indices rather than spread indices or audio
milliseconds. Downloads retain chapter metadata and per-image completion state.

Built-in Dart adapters implement source capabilities. No JavaScript runtime or
custom source loader is introduced. Source favorites remain account-owned and
local favorites remain device-owned; failed source writes are visible errors.
Global settings contain Audio settings and Comic settings as independent entries.

## Consequences

Audio authentication cannot grant comic access and source logout does not delete
local reading history. A source can require login without blocking the app. Shared
presentation changes need audio and comic regressions, while protocol changes can
be tested through isolated adapters. Each source needs live compatibility checks
because its external API, cookies, and image hosts can change independently.
