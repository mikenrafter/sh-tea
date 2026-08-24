# sh-tea

A transparent pipeline stage logger for stdin→stdout Unix filters. It's a
`tee` pun: `tea` sits in front of tools like `grep`, `sed`, `awk`, and `sort`,
and — when activated — quietly copies each stage's stdin to a temp file and
logs it, without touching the tool's actual stdout. Your pipeline runs
exactly as before; you just get a paper trail of what each stage saw.

```
cmd | grep --tea error | sort | uniq -c | tail -20
```

`grep` still does exactly what `grep` does. Somewhere under `/tmp` there is
now a copy of what `grep` had for stdin, and `./logs.csv` has a row pointing
at it.

## Why

Debugging a long pipeline usually means re-running it with `tee` spliced in
at every stage you're suspicious of, or adding `set -x` and hoping. `tea`
flips that: the wrapper is always there, so instead of re-running anything
you just look at what already got captured. It's aimed squarely at agentic
coding sessions (Claude Code, Cursor, Copilot CLI, etc.) chaining `nix eval`
/ `nix build` output through `grep -C 10 | sort | uniq | tail -100` — `tea`
auto-activates there so the intermediate stream is on disk by the time
something looks wrong, with zero change to the command that was run.

## Naming: sh-tea vs tea

This repo and its Nix flake package attribute are `sh-tea`. The installed
CLI, every environment variable, and the config directory are all just
`tea` — that's the tool's actual day-to-day identity, kept short because
you'll be typing `--tea` and reading `TEA_*` constantly. `sh-tea` also ships
on `PATH` as a plain alias: same binary, same flags, same config, just a
second name for anyone who typed the full project name out of habit. Not an
inconsistency — see `man tea`'s NOTES section.

## Install / build

Everything is built through the flake — there's no supported `cargo build`
path for the real package (it needs `TEA_DEFAULT_CONFIG` / `TEA_TOOLS_JSON`
wired up by Nix at wrap-build time):

```
nix build .#sh-tea
```

The result is a `symlinkJoin` of the `tea` CLI, the `sh-tea` alias, the man
page, shell completions, and one thin wrapper binary per wrapped tool (see
`tools.nix` for the full list — `grep`, `sed`, `awk`, `sort`, `head`, `tail`,
`cut`, `tr`, `wc`, `uniq`, `join`, `column`, ... 30-ish filters total).
`meta.mainProgram = "tea"`.

As a flake input in another flake:

```nix
inputs.sh-tea.url = "github:mikenrafter/sh-tea";
# ...
environment.systemPackages = [ sh-tea.packages.${system}.sh-tea ];
```

Note the package is `lib.hiPrio`'d — its wrapper binaries are meant to win
over the real `coreutils`/`gnugrep`/etc. on `PATH`.

## Using it

Every wrapped tool takes three extra flags that `tea` consumes before
handing the rest straight to the real binary:

| flag | effect |
|---|---|
| `--tea` | force logging on for this invocation |
| `--no-tea` / `--coffee` | force logging off for this invocation |
| (nothing) | fall back to config / auto-detect |

```bash
# Force it on in a script
some-cmd | grep --tea pattern

# Force it off in an interactive terminal that would otherwise auto-activate
some-cmd | grep --coffee pattern | head --coffee

# Clean stdout for jq — status blurbs are already on stderr, --coffee is belt-and-braces
nix eval --json .#foo | jq .

# CLAUDE.md-style build filter: tea captures the raw pre-filter stream
nix build .#nixosConfigurations.void.config.system.build.toplevel --no-link \
  2>&1 | grep error -C 10 | sort | uniq | tail -100
tea last     # path of the newest capture
tea show     # dump it
```

When a wrapper activates it prints exactly one line to stderr (never
stdout), e.g.:

```
[tea] --id 60 /tmp/tmp.XXXXXX.tea | tail -150
```

Set `TEA_QUIET=1` to suppress that. `tee` and `cat` are deliberately **not**
wrapped — they're identity/fan-out and don't mutate the stream, so there's
nothing interesting to capture that isn't already visible.

### CLI

```
tea last            # print path of the most recent logfile
tea list            # dump ./logs.csv
tea show [id]       # print a logfile's contents (default: most recent)
tea config          # ensure ~/.config/tea/config.toml exists, print its path
tea which TOOL      # debug: would activation fire for TOOL right now, and why
                    # (at the shell prompt interactive=false is normal; pipe in:
                    #  (same evaluate_activation() gate as tea-wrap; use --piped
                    #  or echo x | tea which TOOL for pipeline preview)
```

### When does it actually activate?

Precedence, highest first (see `src/lib.rs::evaluate_activation`):

1. `--coffee` / `--no-tea` — force off (wins over everything)
2. `--tea` — force on (wins over all env vars and auto-detect gates)
3. `TEA_OFF=1` — env force off
4. `TEA_FORCE=1` — env force on
5. config / auto-detect (only on **user pipeline stages** — see below):
   - agentic session (detected via env vars like `CURSOR_AGENT`, `CLAUDECODE`,
     `COPILOT_CLI`, `AEGIS`, `HERMES_AGENT`, or a parent process name match)
     → activates
   - interactive pipeline stage (stderr is a TTY, stdin is a pipe, and the stage
     is a user pipeline — under `TERM_PROGRAM` that requires `TEA_USER_PIPE=1`
     from the fish hook; when the parent is interactive fish (no `-c`), likewise.
     Otherwise parent-shell heuristics apply, with POSIX
     `sh`/`dash` and deep nesting (`SHLVL` ≥ 5 under `TERM_PROGRAM`) excluded)
     → activates when `default-interactive = true` in config (the default)
   - otherwise → no-op, zero extra stderr, real binary runs untouched

`tea which TOOL` calls the **same** `evaluate_activation()` gate as `tea-wrap`.
`would_activate` and `outcome` come directly from that decision; the other
lines are the runtime signals collected during that single evaluation (not
recomputed separately).

At the shell prompt, `stdin_tty=true` so `interactive_session=false` — that is
expected. To preview a pipeline stage, pass `--piped`, or run
`echo x | tea which TOOL` so stdin matches what the wrapped tool would see.

Fish users: the sh-tea package installs a hook at
`share/fish/vendor_conf.d/tea-user-pipe.fish` that sets `TEA_USER_PIPE=1`
around interactive commands whose command line contains `|` (so plain `echo hi`
does not mark Warp's internal filters). Pipeline stages are then recognized even
when parent heuristics would miss them. Bash users can add an equivalent
DEBUG-trap snippet — see `hooks/tea-user-pipe.bash`.

`--tea` / `--coffee` only work on the **tea-wrapped** binaries from this
package (they must be ahead of the real `grep`, `sed`, etc. on `PATH`). The
wrapper strips the flag before execing the real tool; passing `--tea` to an
unwrapped system binary will fail.

Fish ships a built-in `grep` **function** (with `--color=auto`) that shadows
PATH wrappers — only `grep` among sh-tea's tools; nothing else overlaps.
The package installs `share/fish/vendor_functions.d/grep.fish`, which
autoloads before embedded `grep.fish` and delegates via `command grep` so
the tea wrapper on PATH is used. Until that loads, use `command grep`.

Tab completion is a separate fish issue: helpers like `__fish_complete_pids`
(run when completing `kill`, etc.) pipe to `tail -n +2` and otherwise look
like user pipeline stages. Tea ignores fish-parented stages unless
`TEA_USER_PIPE=1` from the preexec hook — the same marker real typed pipes use.

Background systemd units (`INVOCATION_ID` set and stderr not a TTY)
suppress activation. User-session processes (shells, terminals) inherit
`INVOCATION_ID` from `user@.service` but keep stderr on a TTY, so they
are not suppressed. `TEA_INTERACTIVE=1` bypasses suppression.

### Config

`~/.config/tea/config.toml` (or `$XDG_CONFIG_HOME/tea/config.toml`),
auto-created on first use with a `[tools.<name>]` section per wrapped tool.
Defaults, from the `[defaults]` block:

```toml
default-interactive = true   # activate in interactive terminals without --tea
manual-only = false          # if true, ONLY --tea/TEA_FORCE activates
update-gitignore = true      # append logs.csv to .gitignore in a git work tree
max-log-records = 20         # rows kept in ./logs.csv; oldest + their .tea files pruned
quiet = false                # suppress the stderr blurb
only-in-git-repos = false    # restrict activation by git context
only-outside-git-repos = false
```

Any key can be overridden per tool under `[tools.grep]`, `[tools.sort]`, etc.

### Files & environment

- `$TMPDIR/tmp.XXXXXX.tea` (usually `/tmp`) — one capture per activated
  stage, created with `mktemp --suffix .tea`. Ephemeral by design.
- `./logs.csv` — index of the last N stages (`id, timestamp, cwd, tool,
  command, highlighted, logfile, bytes, exit_code`). The `highlighted`
  column marks the active stage with `⟦...⟧` inside a best-effort
  reconstruction of its pipeline siblings.
- `TEA_OFF`, `TEA_FORCE` — env-level force off/on (CLI flags still win).
- `TEA_QUIET` — suppress the stderr blurb.
- `TEA_AGENT`, `TEA_INTERACTIVE` — force agentic/interactive detection.
- `TEA_USER_PIPE` — set by the fish hook (or manually) to mark user pipeline
  stages for auto-activation; does not bypass `--coffee` / `--no-tea`.
- `XDG_CONFIG_HOME` — config root (default `~/.config`).

## Testing

There's no `cargo test` — behavior is verified end to end against the real
Nix-built package:

```
tests/functional.sh
```

It builds `.#sh-tea` itself (or set `TEA_PKG=/nix/store/...` to point at an
already-built one) and drives it as a black box: activation precedence,
stdout passthrough, `logs.csv` indexing, `tea last|list|show|config`, the
announce format, and that `sh-tea` really is a working alias for `tea`. See
`tests/README.md` for the full contract summary.

## Dev shell

```
nix develop
```

gives you `cargo`, `rustc`, `gcc`, and `rust-analyzer` for hacking on
`src/`. The actual package is still only ever built via `nix build .#sh-tea`
— the devshell is for editing/compiling, not for producing the shipped
binary.

## Docs

- `man tea` (also aliased as `man sh-tea`) — the authoritative reference for
  flags, activation order, config keys, files, and examples.
- `tools.nix` — canonical list of wrapped tools and why a few common ones
  (`tee`, `cat`, pagers, `split`/`csplit`, checksum tools, `dd`/`yes`/`seq`)
  are deliberately excluded.

`tea` is intentionally weaker than a hypothetical `tapper(1)`: tapper would
be foresight, where you hand it the whole pipeline string up front. `tea` is
hindsight bolted onto habits you already have — no new command to learn,
and pipelines your agent already writes (`grep | sort | tail`) keep working
unmodified.

## License

MIT.
