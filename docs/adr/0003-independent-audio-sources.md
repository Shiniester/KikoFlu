# ADR 0003: Keep audio source identities independent of browsing selection

## Status

Accepted.

## Context

Japanese ASMR (jp-asmr, https://japaneseasmr.com/) adds an independent catalog
alongside ASMR.ONE. The current audio implementation uses Kikoeru servers and
numeric work IDs, while local history and download paths do not distinguish
providers. A second catalog must preserve existing records and avoid collisions
between unrelated works with the same ID.

## Decision

The Audio Screen offers source selection, with ASMR.ONE as the default. The
Works Home Tab and Global Works Search use the selected source. Japanese ASMR's
initial scope includes browsing, search, work details, in-app playback and
downloads.

History and downloads combine entries from both sources and identify their
origin. A work's identity includes its source: even when both catalogs contain
the same release, each retains its own history and downloads. Existing Kikoeru
records and downloaded files remain usable.

Kikoeru keeps its positive integer work IDs. Japanese ASMR's positive page IDs
map to negative internal work IDs; the real RJ code remains display metadata.
This gives each provider a distinct namespace within the existing integer-keyed
history, queue and download storage without rewriting legacy data or paths.

Browsing selection is independent of playback ownership. Changing the selected
source preserves the current track and queue. Selecting a new track follows the
existing Audio Add Mode. Each queued track and download retains its origin so
subsequent operations resolve through that origin after a browsing source change.

Online marks and playlists follow the selected source's verified capabilities.
Each capability supported by Japanese ASMR joins the initial acceptance scope;
an unsupported capability's entry is hidden while Japanese ASMR is selected.
ASMR.ONE account collections remain available when ASMR.ONE is selected.

## Japanese ASMR capabilities

The public [homepage](https://japaneseasmr.com/),
[Info page](https://japaneseasmr.com/info/) and a
[work details page](https://japaneseasmr.com/151342/) inspected on 2026-10-13
expose no account, online-mark or user-playlist controls. The details player's
track list is a work's chapter index, not a user-owned playlist. The initial
adapter therefore advertises neither online marks nor user playlists and hides
both entries when selected. Verified support for either capability adds it to
the acceptance scope.

The initial media entry represents the complete work: playback uses the site's
HLS stream, and offline download resolves its full-work audio link. Signed file
URLs are resolved for each download attempt. A failed resolution or an HTML
response is a download failure, not a completed offline audio file.

Japanese ASMR media requests carry its public Referer and Origin headers. Its
catalog, images, player and downloads never receive ASMR.ONE account credentials.

## Acceptance

- Browsing and search use the selected source; Japanese ASMR works open in the
  app's details, player and download flows.
- Equal work IDs from different sources retain separate history, download
  metadata and files, with visible source labels in the combined collections.
- Existing ASMR.ONE history and downloads remain accessible after upgrade.
- Switching browsing sources preserves playback and the queue, including the
  origin used for subsequent track and download operations.
- Adding audio from either source respects the existing Audio Add Mode.
- Supported Japanese ASMR online marks and playlists use that source's data;
  unsupported entries are hidden when it is selected. Switching back to ASMR.ONE
  restores access to its existing account collections.

## Validation limits

The public catalog, work details, HLS manifest and a media byte range were
verified against the live site. Native playback and a complete hosted download
still require end-to-end validation. The download host can return an access
challenge; the app reports that response as a failed download.
