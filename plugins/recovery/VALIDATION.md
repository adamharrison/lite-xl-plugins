# Native validation — 2026-10-16

All five matrices passed. Tests ran on macOS Apple Silicon against source-built,
unmodified Lite XL runtimes. Each process received a disposable USERDIR containing
only the recovery plugin and a test init file. No personal configuration, existing
workspace directory or installed application data was used.

## Pinned runtimes

| Runtime | Repository / ref | Commit | Plugin API |
|---|---|---|---|
| Stock 2.1.8 | lite-xl/lite-xl, v2.1.8 | `0af4dae0e2748d6afe7bded41c13d96f627cb520` | 3 |
| Upstream master | lite-xl/lite-xl, master | `234fa0998016f3da9eb9ceaf3c4bc79b93462276` | 4 |
| Development preview | adamharrison/lite-xl, 3.0-preview | `683e8bf2b3852d1d6a4a8af5a357cd49355a573e` | 4 |

The master source's internal project version is 2.1.7 despite its newer API; the
commit is the authoritative identity for that row. Preview identifies as 3.0.0.
The contributor guide identifies 3.0-preview as an active development target, so
both official master and that preview were tested.

All tracked runtime sources remained unchanged. Meson created an untracked
`subprojects/.wraplock` while resolving its Lua dependency. Lua was built from each
runtime's own pinned wrap (stock: 5.4.4; newer runtimes: 5.4.6). System SDL3,
FreeType and PCRE2 were used. Runtimes were staged into local build directories;
none was installed over a system application.

## Results

| Writer → reader | Native unit / failure injection | Process integration |
|---|---:|---:|
| Stock 2.1.8 → same | 38/38 | 9/9 |
| Upstream master → same | 38/38 | 9/9 |
| 3.0-preview → same | 38/38 | 9/9 |
| Stock 2.1.8 → 3.0-preview | 38/38 on writer | 9/9 |
| 3.0-preview → stock 2.1.8 | 38/38 on writer | 9/9 |

The process result files originally also contained an aggregate “unit suite
completed” check. Public JSON separates that aggregate from the nine process
checks, avoiding double-counting the 38 unit checks.

The cross-version tests keep the same snapshot store but change the reader binary
and the installed entry's mod-version header after killing the writer. Body modules
and data format are unchanged. The entire restart/save/discard sequence then runs
on the reader. Preview tests explicitly disable its legacy compatibility3 shim;
the plugin uses its native view-based API.

### Unit and failure coverage

- Named/unnamed dirty buffers, empty recovered buffers, blank lines, NUL and Unicode.
- Source/name/CRLF/selection metadata; UTF-8 cursor alignment and multicursors.
- Change detection, bounded generations and corrupt-latest fallback.
- Truncation, checksum failure, executable-looking input, payload size limits.
- Independent sessions, live-owner exclusion, unknown-owner conservatism,
  exclusive restoration claims, stale claims and duplicate acknowledgements.
- Persisting the restored copy before acknowledging the source; repeated recovery;
  fresh origin after saving and editing a recovered document again.
- Injected open/close/rename/transfer/acknowledgement/save/shutdown failures.
- Stock save hook, cancelled and confirmed last-view close, shared-view close,
  stock shutdown confirmation, and callback failure.
- Symlink snapshots excluded; symlink claims rejected without deleting external
  files; unsupported Windows rejected; repeated module loading is idempotent.

### Process coverage

1. Real periodic timer commits dirty named and unnamed snapshots.
2. A second process skips the active writer's snapshots.
3. SIGKILL followed by startup's opt-in recovery path preserves content, CRLF,
   Japanese/emoji and canonical selection positions.
4. Killing the restored process again recovers exactly two copies.
5. Stock `Doc.save` retires recovered snapshots.
6. A subsequent process does not offer saved candidates.
7. A new crash/recovery cycle exercises actual stock Quit: No preserves snapshots,
   Yes retires them before process exit; a further probe sees no candidates.
8. The original source remains byte-identical.
9. Recovery directories are 0700 and files 0600.

SIGKILL is sent only to child PIDs created by the runner. Tests use SDL's dummy
video driver. They exercise real editor APIs and the startup dialog callback path,
not mouse/keyboard automation or a fake Lua editor model. The standalone plugin
was not additionally visually inspected in every runtime. Earlier personal-config
GUI results are not counted as standalone validation evidence.

## Reproduction

Prerequisites: Python 3, Git, a C/Objective-C compiler, Meson, Ninja, pkg-config,
SDL3, FreeType and PCRE2. Network access is needed for source/wrap downloads.

Use a **new** build destination outside live settings and existing workspaces:

```sh
python3 tests/recovery/tools/build_runtimes.py --root /absolute/new/path/recovery-builds
```

The helper fetches the exact commits in `tests/recovery/tests/runtimes.json`, builds them and
prints staged binary paths. The equivalent commands used for the recorded runs
were `meson setup build --buildtype=debugoptimized`, `meson compile -C build`, and
`meson install -C build --destdir runtime --skip-subprojects --no-rebuild` in each
checkout. The helper uses an explicit local `/runtime` prefix instead of the local
machine's Meson default. Its Python syntax is checked; a second full rebuild via
that convenience helper was not performed.

For a same-version test:

```sh
python3 tests/recovery/run.py --binary /path/to/stock/lite-xl --mod-version 3 --label stock
python3 tests/recovery/run.py --binary /path/to/master/lite-xl --mod-version 4 --label master
python3 tests/recovery/run.py --binary /path/to/preview/lite-xl --mod-version 4 --label preview
```

For cross-version tests:

```sh
python3 tests/recovery/run.py --binary /path/to/stock/lite-xl --mod-version 3 \
  --reader-binary /path/to/preview/lite-xl --reader-mod-version 4 --label cross-2-to-3
python3 tests/recovery/run.py --binary /path/to/preview/lite-xl --mod-version 4 \
  --reader-binary /path/to/stock/lite-xl --reader-mod-version 3 --label cross-3-to-2
```

The runner installs into a newly generated `tests/recovery/test-runs/` profile. It never points
LITE_USERDIR at the default live profile. Test data and unsaved sample text are
excluded from version control and release archives. Public results under
`tests/recovery/tests/results/` omit absolute local paths.

## Scope and remaining work

- Validated host: macOS Apple Silicon. Linux is not runtime-tested. Windows needs
  its own adapter and is explicitly unsupported in this candidate.
- No fsync/power-loss guarantee, undo history, IME composition, scroll recovery or
  per-view layout reconstruction. Default snapshots are periodic, not continuous.
- POSIX helper waits are bounded and synchronous. UI latency with many large dirty
  buffers and long-lived metadata growth remain review/performance topics.
- Stock bundled workspace plugins were allowed to run in disposable profiles.
  Existing workspace data was never read. This does not establish compatibility
  with every third-party session/save/close plugin or every multi-window topology.
- Runtime sources and plugin archives are identified by hashes/commits. No claim
  is made about upstream changes after the recorded commits.

## References

1. Lite XL contributors. v2.1.8 source, commit 0af4dae0e2748d6afe7bded41c13d96f627cb520.
   https://github.com/lite-xl/lite-xl/tree/0af4dae0e2748d6afe7bded41c13d96f627cb520
2. Lite XL contributors. master source as fetched 2026-10-16, commit 234fa0998016f3da9eb9ceaf3c4bc79b93462276.
   https://github.com/lite-xl/lite-xl/tree/234fa0998016f3da9eb9ceaf3c4bc79b93462276
3. Adam Harrison and Lite XL contributors. 3.0-preview source as fetched 2026-10-16, commit 683e8bf2b3852d1d6a4a8af5a357cd49355a573e.
   https://github.com/adamharrison/lite-xl/tree/683e8bf2b3852d1d6a4a8af5a357cd49355a573e
4. Lite XL contributors. CONTRIBUTING.md, master at the recorded commit.
   https://github.com/lite-xl/lite-xl/blob/234fa0998016f3da9eb9ceaf3c4bc79b93462276/CONTRIBUTING.md
