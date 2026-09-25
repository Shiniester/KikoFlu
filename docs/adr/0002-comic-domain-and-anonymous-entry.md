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
theme, language, and Mini Player. Audio and comic details share ADR 0001's route
and Dock handoff, responsive detail layout, metadata chips and toolbar actions.
The fullscreen reader uses an independent route with a stable immersive canvas.
Its control layer owns the Mini Player and preserves the reader route while the
full player is open. Main navigation uses the same horizontal tab transition as
the library tabs and retains each visited page's state.

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
