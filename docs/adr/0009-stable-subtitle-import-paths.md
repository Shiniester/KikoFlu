# Stable paths for long imported subtitles

Subtitle paths can exceed the library's supported length. When an import
shortens a path, it keeps the subtitle in its work or unknown category and
uses a stable identifier derived from the original relative path. A metadata
file records that path and the stored filename. If identifiers collide, each
subtitle receives a separate directory. The metadata preserves the original
name and language path for matching, and lets a later import replace the same
subtitle after the library moves. Changing the mapping can leave duplicate
files from earlier imports and may require migration.
