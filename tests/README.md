# tea functional tests

Behavioural contract suite for `tea` (transparent pipeline logger; the repo
and its Nix package attribute are named `sh-tea`, which also ships on PATH
as a plain alias for `tea`). Use **`nix`**, not `fix`. Assertions target
runtime behaviour from `man tea` — not language/runtime packaging shape.

## functional

Living functional contract: activation / passthrough (`--tea`, `--coffee` /
`--no-tea`, `TEA_OFF`, `TEA_FORCE`, flag precedence), filter stdout
preservation, stderr blurbs / `TEA_QUIET`, `./logs.csv` indexing with
`mktemp --suffix .tea` captures (usually under `/tmp`), `tea last|list|show|config`,
wrapper flag stripping, single-line announce format
`[tea] --id N /tmp/tmp.XXXXXX.tea | COMMAND`, and that `sh-tea` on PATH is
a working alias for `tea`.

```bash
tests/functional.sh
```

Optional: `TEA_PKG=/nix/store/... tests/functional.sh`

### Section H — user-defined extra tools

Consumer-defined wraps, both routed through the standard `tea-wrap` gate:
the build-time `extraTools` package override (`.#sh-tea.override { extraTools
= { … }; }` — wrapper binary on PATH referencing the declared outpath,
`[tools.<name>]` config sections, `tea which` recognition) and the runtime
`TEA_EXTRA_TOOLS` env var (`name=path` pairs, comma/whitespace separated,
malformed entries skipped, rejected without the var) plus the
`tea-extra-tools.fish` hook: shadow functions created at first `fish_prompt`
in interactive sessions only, working with non-exported (`set -g`) scopes,
idempotent across re-runs, and absent in non-interactive fish. Uses a
`fakefilter` tool (a cat copy) so the suite never depends on any specific
consumer tool being installed.
