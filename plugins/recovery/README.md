# Recovery for Lite XL

Periodic private snapshots of dirty documents, including unnamed buffers, with
opt-in restoration after an abnormal exit. Original files are never autosaved or
overwritten by recovery. Restored documents open as new, dirty, unnamed copies.

Requires Lite XL plugin API 4 and POSIX `chmod`/`ps`. Tested on macOS Apple Silicon.

## Installation

Copy this `recovery/` directory into your USERDIR's `plugins/` directory and restart
Lite XL. No require statement or key binding is needed.

The implementation was also tested against stock 2.1.8 (API 3), using an API-3 entry
header. This catalog edition declares API 4 for the development branch.

## Use

After a crash or forced termination, startup offers **Later**, **Restore All**,
and **Review**. Later is the default for both affirmative and cancellation keys.
Choose restoration only when you want to inspect recovered copies.

Commands in the stock command palette:

- `Recovery: Snapshot Now`
- `Recovery: Review` — filter by source/name, then Restore Copy or Discard Snapshot.
- `Recovery: Restore All`

Discard Snapshot requires an additional cancel-first confirmation. Successful
save and confirmed last-view close/shutdown retire the associated snapshots.
Cancelling a stock close/quit prompt keeps them. Recovery does not replace or
redesign the editor's save or close prompts.

Snapshots retain text, blank lines, source path/name, LF/CRLF output setting and
up to 256 cursors/selections. In the view-based API, one view's selections are
captured per document, preferring the active view. Undo history, scroll position
and uncommitted IME composition are not captured. Syntax is inferred from the
original source path where available.

## Configuration

Set these values in your isolated `init.lua` before plugin loading:

```lua
local config = require "core.config"
config.plugins.recovery = {
  interval = 5,                 -- seconds, 1–3600
  generations = 3,              -- integer, 1–20 per current session/document
  max_bytes = 16 * 1024 * 1024, -- text limit, up to 256 MiB
  root = USERDIR .. PATHSEP .. "recovery-v1",
}
```

Disable loading with `config.plugins.recovery = false`, then restart. Disabling or
uninstalling the plugin does not remove existing snapshots. Do not remove the
recovery data directory while buffers still depend on it.

## Storage and limits

Data files are length-delimited and checksummed; they are never evaluated as Lua.
Private directories use mode 0700 and files 0600. A same-directory rename publishes
a generation after checked write, close, permission setting and read-back. Only
then are older generations pruned. Corrupt latest generations fall back to a
previous valid generation. Pending files and symlink snapshots are excluded.

Each process owns a session. Live or indeterminate owners are skipped. Claims
serialize restoration by origin; acknowledged revisions suppress old duplicates.
A restored copy is snapshotted before the old source is acknowledged. Saving or
explicitly discarding a restored buffer removes acknowledged inactive archives.
Small ownership/acknowledgement records remain. Unhandled snapshots are not aged
out automatically.

Important limits:

- Edits after the last completed snapshot may be lost; the interval is not a hard
  maximum latency under load.
- **No fsync/power-loss durability guarantee.** Tests cover process termination.
- Filesystem operations and short POSIX helpers are synchronous. A helper has a
  five-second deadline, and many documents/large buffers can delay the UI.
- Snapshots contain unsaved text. Storage permissions protect access but do not
  provide encryption. Recovery is neither backup software nor autosave.
- PID reuse and unknown process state conservatively delay restoration. An ownerless
  claim becomes reclaimable after 60 seconds. An unrecognizable session owner is
  left untouched for manual investigation.
- macOS Apple Silicon is tested. Linux uses the same POSIX adapter but is **not
  runtime-validated here**. Windows is rejected before hooks/storage are installed;
  it needs a separate permission and process-owner adapter.
- Existing workspace data is outside the plugin's store. Workspace policy remains
  stock-editor behavior; a workspace may reopen its own tabs alongside recovered
  copies. No attempt is made to equate those tabs by filename or text.
- Custom plugins that replace save/close hooks without chaining may interfere.
  Reloading this plugin within one process is idempotent; restart to apply changes.

## Compatibility and tests

See [VALIDATION.md](VALIDATION.md) for exact source commits, native test results,
platform scope and reproduction commands. Tests generate disposable USERDIRs with
only this plugin and test initialization. They do not load personal settings.
Standard bundled plugins retain their defaults, apart from disabling the legacy
compatibility3 shim in the 3.0 API test profile.

The plugin deliberately stores cursor columns as UTF-8 byte offsets. Its adapter
converts the view-based code-point API to/from this canonical representation.

MIT license. See [LICENSE](LICENSE).
