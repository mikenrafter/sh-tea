# sh-tea functional tests

Behavioural contract suite for `sh-tea` (transparent pipeline logger). Use
**`nix`**, not `fix`. Assertions target runtime behaviour from `man sh-tea` —
not language/runtime packaging shape.

## functional

Living functional contract: activation / passthrough (`--tea`, `--coffee` /
`--no-tea`, `SH_TEA_OFF`, `SH_TEA_FORCE`, flag precedence), filter stdout
preservation, stderr blurbs / `SH_TEA_QUIET`, `./logs.csv` indexing with
`mktemp --suffix .tea` captures (usually under `/tmp`), `sh-tea last|list|show|config`,
wrapper flag stripping, and single-line announce format
`[sh-tea] --id N /tmp/tmp.XXXXXX.tea | COMMAND`.

```bash
tests/functional.sh
```

Optional: `SH_TEA_PKG=/nix/store/... tests/functional.sh`
