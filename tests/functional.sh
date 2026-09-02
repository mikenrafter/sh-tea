#!/usr/bin/env bash
# Functional contract suite for tea (transparent pipeline logger).
#
# Encodes behavioural contracts from man tea + original smoke validation.
# Build via nix (never cargo).
#
# Run (from repo root):
#   tests/functional.sh
#
# Optional: TEA_PKG=/nix/store/... tests/functional.sh
set -euo pipefail

NIX="${NIX:-nix}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Harness tools must not go through tea wrappers (agent sessions auto-activate).
SYS_BIN="${TEA_TEST_SYS_BIN:-/run/current-system/sw/bin}"
GREP="${SYS_BIN}/grep"
MKTEMP="${SYS_BIN}/mktemp"
RM="${SYS_BIN}/rm"
WC="${SYS_BIN}/wc"
TR="${SYS_BIN}/tr"
CAT="${SYS_BIN}/cat"
HEAD="${SYS_BIN}/head"
TAIL="${SYS_BIN}/tail"
MKDIR="${SYS_BIN}/mkdir"
BASENAME="${SYS_BIN}/basename"
SED="${SYS_BIN}/sed"
TIMEOUT="${SYS_BIN}/timeout"
SLEEP="${SYS_BIN}/sleep"
CHMOD="${SYS_BIN}/chmod"

failures=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

if ! command -v "$NIX" >/dev/null 2>&1; then
  echo "FAIL: '$NIX' not found on PATH (set NIX=... to override)" >&2
  exit 2
fi

resolve_tea_pkg() {
  if [[ -n "${TEA_PKG:-}" ]]; then
    printf '%s' "$TEA_PKG"
    return
  fi
  (cd "$REPO" && "$NIX" build --no-link --print-out-paths --no-write-lock-file '.#sh-tea')
}

# Absolute logfile paths recorded in ./logs.csv (skip header).
# logfile is third-from-last column (…,logfile,bytes,exit_code); test rows
# keep earlier fields comma-free so a simple split is enough.
list_log_paths() {
  if [[ ! -f "$WORKDIR/logs.csv" ]]; then
    return 0
  fi
  "$TAIL" -n +2 "$WORKDIR/logs.csv" | while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    path="$(printf '%s' "$row" | awk -F',' '{print $(NF-2)}')"
    [[ -n "$path" ]] && printf '%s\n' "$path"
  done
}

count_logs() {
  list_log_paths | "$WC" -l | "$TR" -d ' '
}

# Capture stdout without bash stripping trailing newlines (cmdsubst pitfall).
# Sets CAPTURED_OUT, CAPTURED_ERR, CAPTURED_RC.
run_capture() {
  local out_tmp err_tmp
  out_tmp="$("$MKTEMP" "$WORKDIR/out.XXXXXX")"
  err_tmp="$("$MKTEMP" "$WORKDIR/err.XXXXXX")"
  set +e
  "$@" >"$out_tmp" 2>"$err_tmp"
  CAPTURED_RC=$?
  set -e
  CAPTURED_OUT="$("$CAT" "$out_tmp"; printf x)"
  CAPTURED_OUT="${CAPTURED_OUT%x}"
  CAPTURED_ERR="$("$CAT" "$err_tmp"; printf x)"
  CAPTURED_ERR="${CAPTURED_ERR%x}"
  "$RM" -f "$out_tmp" "$err_tmp"
}

clear_logs() {
  if [[ -f "$WORKDIR/logs.csv" ]]; then
    while IFS= read -r path; do
      [[ -n "$path" && -f "$path" ]] && "$RM" -f "$path"
    done < <(list_log_paths)
  fi
  "$RM" -rf "$WORKDIR/logfiles" "$WORKDIR/logs.csv"
}

isolate_env() {
  export HOME="$WORKDIR/home"
  export XDG_CONFIG_HOME="$WORKDIR/xdg"
  unset TEA_FORCE TEA_AGENT TEA_INTERACTIVE TEA_USER_PIPE TEA_EXTRA_TOOLS || true
  for v in CURSOR_AGENT CURSOR_AGENT_ID CURSOR_INVOKED_AS CLAUDECODE CLAUDE_CODE \
    CLAUDE_AGENT COPILOT_CLI COPILOT_AGENT AEGIS AEGIS_QUEUE HERMES_AGENT \
    HERMES_PROFILE AGENT_TASK_ID OPENCODE_AGENT AGENT; do
    unset "$v" || true
  done
  # Prefer tea wrappers under test; harness uses SYS_BIN absolutes.
  export PATH="$TEA_OUT/bin:$SYS_BIN:/usr/bin:/bin"
  # Keep harness PATH lookups from auto-logging into WORKDIR.
  export TEA_OFF=1
  unset TEA_QUIET || true
}

echo "== build tea package =="
TEA_OUT="$(resolve_tea_pkg)"
if [[ -z "$TEA_OUT" || ! -d "$TEA_OUT/bin" ]]; then
  echo "FAIL: tea package missing bin/ (got: ${TEA_OUT:-empty})" >&2
  exit 2
fi
pass "tea package at $TEA_OUT"

for need in tea sh-tea head grep; do
  if [[ ! -e "$TEA_OUT/bin/$need" ]]; then
    echo "FAIL: missing $TEA_OUT/bin/$need" >&2
    exit 2
  fi
done

WORKDIR="$("$MKTEMP" -d "${TMPDIR:-/tmp}/tea-functional.XXXXXX")"
cleanup() { clear_logs; "$RM" -rf "$WORKDIR"; }
trap cleanup EXIT

"$MKDIR" -p "$WORKDIR/home" "$WORKDIR/xdg"
cd "$WORKDIR"
isolate_env

INPUT=$'alpha\nbeta\ngamma\n'
EXPECTED_HEAD=$'alpha\nbeta\n'
# Pattern must not match every line (beta/gamma both contain the letter a).
EXPECTED_GREP=$'alpha\n'

# ---------------------------------------------------------------------------
# A. Activation / passthrough
# ---------------------------------------------------------------------------
echo "== A. activation / passthrough =="

clear_logs
printf '%s' "$INPUT" >"$WORKDIR/stdin.txt"

# --tea forces logging even with stderr redirected (non-interactive).
run_capture env -u TEA_OFF TEA_QUIET=1 "$TEA_OUT/bin/head" --tea -n 2 <"$WORKDIR/stdin.txt"
if [[ "$CAPTURED_RC" -eq 0 ]]; then
  pass "--tea activates (exit 0) with stderr redirected"
else
  fail "--tea exit $CAPTURED_RC (stderr redirected)"
fi
if [[ "$CAPTURED_OUT" == "$EXPECTED_HEAD" ]]; then
  pass "--tea preserves filter stdout (head -n 2)"
else
  fail "--tea stdout: expected $(printf %q "$EXPECTED_HEAD"), got $(printf %q "$CAPTURED_OUT")"
fi
if [[ -f "$WORKDIR/logs.csv" && "$(count_logs)" -ge 1 && ! -d "$WORKDIR/logfiles" ]]; then
  pass "--tea created logs.csv + .tea capture (no logfiles/)"
else
  fail "--tea did not create expected index/capture (csv=$([ -f "$WORKDIR/logs.csv" ] && echo y || echo n) logs=$(count_logs) logfiles=$([ -d "$WORKDIR/logfiles" ] && echo y || echo n))"
fi

# Status blurbs on stderr only; TEA_QUIET suppresses.
clear_logs
run_capture env -u TEA_OFF "$TEA_OUT/bin/head" --tea -n 2 <"$WORKDIR/stdin.txt"
if [[ "$CAPTURED_OUT" == "$EXPECTED_HEAD" ]]; then
  pass "stdout clean without TEA_QUIET (blurb not on stdout)"
else
  fail "stdout polluted without TEA_QUIET: $(printf %q "$CAPTURED_OUT")"
fi
if [[ "$CAPTURED_ERR" == *'[tea]'* ]]; then
  pass "status blurb on stderr when not quiet"
else
  fail "expected [tea] blurb on stderr, got $(printf %q "$CAPTURED_ERR")"
fi
# Single-line form: [tea] --id N /path/tmp.XXXX.tea | COMMAND
if [[ "$CAPTURED_ERR" =~ \[tea\]\ --id\ [0-9]+\ .+\.tea\ \|\  ]]; then
  pass "blurb matches '[tea] --id N …\.tea | COMMAND'"
else
  fail "blurb shape unexpected: $(printf %q "$CAPTURED_ERR")"
fi

clear_logs
run_capture env -u TEA_OFF TEA_QUIET=1 "$TEA_OUT/bin/head" --tea -n 2 <"$WORKDIR/stdin.txt"
if [[ -z "$CAPTURED_ERR" || "$CAPTURED_ERR" != *'[tea]'* ]]; then
  pass "TEA_QUIET=1 suppresses stderr blurb"
else
  fail "TEA_QUIET=1 still printed blurb: $(printf %q "$CAPTURED_ERR")"
fi

# --coffee / --no-tea passthrough
clear_logs
# Seed one log so we can detect "no new logfile".
run_capture env -u TEA_OFF TEA_QUIET=1 "$TEA_OUT/bin/head" --tea -n 1 <"$WORKDIR/stdin.txt"
before="$(count_logs)"
printf 'noop\n' >"$WORKDIR/coffee-in.txt"
run_capture env -u TEA_OFF TEA_FORCE=1 "$TEA_OUT/bin/head" --coffee -n 1 <"$WORKDIR/coffee-in.txt"
after="$(count_logs)"
if [[ "$CAPTURED_RC" -eq 0 && "$CAPTURED_OUT" == $'noop\n' ]]; then
  pass "--coffee preserves stdout"
else
  fail "--coffee failed (rc=$CAPTURED_RC out=$(printf %q "$CAPTURED_OUT"))"
fi
if [[ "$after" -eq "$before" ]]; then
  pass "--coffee did not create a new logfile"
else
  fail "--coffee created logfile (before=$before after=$after)"
fi

before="$(count_logs)"
run_capture env -u TEA_OFF TEA_FORCE=1 "$TEA_OUT/bin/head" --no-tea -n 1 <"$WORKDIR/coffee-in.txt"
after="$(count_logs)"
if [[ "$CAPTURED_RC" -eq 0 && "$CAPTURED_OUT" == $'noop\n' && "$after" -eq "$before" ]]; then
  pass "--no-tea forces passthrough (no new logfile)"
else
  fail "--no-tea failed (rc=$CAPTURED_RC after=$after before=$before out=$(printf %q "$CAPTURED_OUT"))"
fi

# TEA_OFF / TEA_FORCE; flags win over env
clear_logs
run_capture env -u TEA_OFF TEA_OFF=1 TEA_QUIET=1 "$TEA_OUT/bin/head" -n 2 <"$WORKDIR/stdin.txt"
if [[ "$CAPTURED_OUT" == "$EXPECTED_HEAD" && "$(count_logs)" -eq 0 && ! -f "$WORKDIR/logs.csv" ]]; then
  pass "TEA_OFF=1 forces off (no logfile)"
else
  fail "TEA_OFF=1 should not log (logs=$(count_logs) csv=$([ -f "$WORKDIR/logs.csv" ] && echo y || echo n))"
fi

clear_logs
run_capture env -u TEA_OFF TEA_FORCE=1 TEA_QUIET=1 "$TEA_OUT/bin/head" -n 2 <"$WORKDIR/stdin.txt"
if [[ "$CAPTURED_RC" -eq 0 && "$CAPTURED_OUT" == "$EXPECTED_HEAD" && "$(count_logs)" -ge 1 ]]; then
  pass "TEA_FORCE=1 forces on"
else
  fail "TEA_FORCE=1 should log (rc=$CAPTURED_RC logs=$(count_logs))"
fi

# TEA_OFF wins over TEA_FORCE
clear_logs
run_capture env -u TEA_OFF TEA_OFF=1 TEA_FORCE=1 TEA_QUIET=1 "$TEA_OUT/bin/head" -n 2 <"$WORKDIR/stdin.txt"
if [[ "$(count_logs)" -eq 0 && ! -f "$WORKDIR/logs.csv" ]]; then
  pass "TEA_OFF wins over TEA_FORCE"
else
  fail "TEA_OFF should beat TEA_FORCE (logs=$(count_logs))"
fi

# --tea wins over TEA_OFF
clear_logs
run_capture env -u TEA_OFF TEA_OFF=1 TEA_QUIET=1 "$TEA_OUT/bin/head" --tea -n 2 <"$WORKDIR/stdin.txt"
if [[ "$(count_logs)" -ge 1 ]]; then
  pass "--tea wins over TEA_OFF"
else
  fail "--tea should win over TEA_OFF"
fi

# --coffee wins over TEA_FORCE
clear_logs
run_capture env -u TEA_OFF TEA_FORCE=1 TEA_QUIET=1 "$TEA_OUT/bin/head" --coffee -n 2 <"$WORKDIR/stdin.txt"
if [[ "$(count_logs)" -eq 0 && ! -f "$WORKDIR/logs.csv" ]]; then
  pass "--coffee wins over TEA_FORCE"
else
  fail "--coffee should win over TEA_FORCE (logs=$(count_logs))"
fi

# grep filter stdout equals real tool
clear_logs
printf '%s' "$INPUT" >"$WORKDIR/grep-in.txt"
run_capture env -u TEA_OFF TEA_QUIET=1 "$TEA_OUT/bin/grep" --tea '^alpha' <"$WORKDIR/grep-in.txt"
if [[ "$CAPTURED_RC" -eq 0 && "$CAPTURED_OUT" == "$EXPECTED_GREP" ]]; then
  pass "grep --tea stdout equals real filter (pattern ^alpha)"
else
  fail "grep --tea stdout mismatch (rc=$CAPTURED_RC out=$(printf %q "$CAPTURED_OUT"))"
fi

# ---------------------------------------------------------------------------
# B. Logging / index + CLI
# ---------------------------------------------------------------------------
echo "== B. logging / index + CLI =="

clear_logs
run_capture env -u TEA_OFF TEA_QUIET=1 "$TEA_OUT/bin/head" --tea -n 2 <"$WORKDIR/stdin.txt"
mapfile -t LOGS < <(list_log_paths)
if [[ "${#LOGS[@]}" -ge 1 ]]; then
  pass "activated run created at least one logfile"
else
  fail "no logfile paths in logs.csv"
fi

LOG_PATH="${LOGS[0]:-}"
if [[ -f "$LOG_PATH" ]] && "$GREP" -q 'alpha' "$LOG_PATH" && "$GREP" -q 'gamma' "$LOG_PATH"; then
  pass "logfile contains a copy of stdin (not just stdout)"
else
  fail "logfile missing full stdin ($LOG_PATH)"
fi

CSV_HEADER="$("$HEAD" -n 1 "$WORKDIR/logs.csv" 2>/dev/null || true)"
EXPECTED_COLS='id,timestamp,cwd,tool,command,highlighted,logfile,bytes,exit_code'
if [[ "$CSV_HEADER" == "$EXPECTED_COLS" ]]; then
  pass "logs.csv has expected columns"
else
  fail "logs.csv header: expected '$EXPECTED_COLS', got '$CSV_HEADER'"
fi

# Data row should reference absolute .tea path, tool, exit_code (last field).
DATA_ROW="$("$TAIL" -n 1 "$WORKDIR/logs.csv")"
if echo "$DATA_ROW" | "$GREP" -qE '/[^,]+\.tea,' \
  && echo "$DATA_ROW" | "$GREP" -q ',head,' \
  && echo "$DATA_ROW" | "$GREP" -qE ',0$'; then
  pass "logs.csv row references .tea path, tool=head, exit_code"
else
  fail "logs.csv row unexpected: $DATA_ROW"
fi

# tea last / list / show / config (+ sh-tea alias)
run_capture env -u TEA_OFF "$TEA_OUT/bin/tea" last
if [[ "$CAPTURED_RC" -eq 0 && "$CAPTURED_OUT" == *.tea* ]]; then
  pass "tea last prints logfile path"
else
  fail "tea last failed (rc=$CAPTURED_RC out=$(printf %q "$CAPTURED_OUT"))"
fi

run_capture env -u TEA_OFF "$TEA_OUT/bin/tea" list
if [[ "$CAPTURED_RC" -eq 0 && "$CAPTURED_OUT" == *"$EXPECTED_COLS"* && "$CAPTURED_OUT" == *.tea* ]]; then
  pass "tea list prints csv"
else
  fail "tea list failed (rc=$CAPTURED_RC out=$(printf %q "$CAPTURED_OUT"))"
fi

run_capture env -u TEA_OFF "$TEA_OUT/bin/tea" show
if [[ "$CAPTURED_RC" -eq 0 && "$CAPTURED_OUT" == *alpha* && "$CAPTURED_OUT" == *gamma* ]]; then
  pass "tea show dumps logfile bytes"
else
  fail "tea show failed (rc=$CAPTURED_RC out=$(printf %q "$CAPTURED_OUT"))"
fi

run_capture env -u TEA_OFF "$TEA_OUT/bin/tea" config
CFG_PATH="$(printf '%s' "$CAPTURED_OUT" | "$TR" -d '\n')"
if [[ "$CAPTURED_RC" -eq 0 && -n "$CFG_PATH" && -f "$CFG_PATH" ]]; then
  pass "tea config prints path and ensures config exists ($CFG_PATH)"
else
  fail "tea config failed (rc=$CAPTURED_RC out=$(printf %q "$CAPTURED_OUT") exists=$([ -f "${CFG_PATH:-}" ] && echo y || echo n))"
fi

# sh-tea is a plain alias for tea — same subcommands, same output.
run_capture env -u TEA_OFF "$TEA_OUT/bin/sh-tea" last
ALIAS_OUT="$CAPTURED_OUT"
run_capture env -u TEA_OFF "$TEA_OUT/bin/tea" last
if [[ "$CAPTURED_RC" -eq 0 && "$ALIAS_OUT" == "$CAPTURED_OUT" ]]; then
  pass "sh-tea alias matches tea (last)"
else
  fail "sh-tea alias diverged from tea (last): alias=$(printf %q "$ALIAS_OUT") tea=$(printf %q "$CAPTURED_OUT")"
fi

# ---------------------------------------------------------------------------
# C. Flag stripping
# ---------------------------------------------------------------------------
echo "== C. flag stripping =="

clear_logs
# If --tea were passed through, GNU grep would error: unrecognized option '--tea'
run_capture env -u TEA_OFF TEA_QUIET=1 "$TEA_OUT/bin/grep" --tea '^alpha' <"$WORKDIR/grep-in.txt"
if [[ "$CAPTURED_RC" -eq 0 && "$CAPTURED_OUT" == "$EXPECTED_GREP" && "$CAPTURED_ERR" != *unrecognized* && "$CAPTURED_ERR" != *unknown* ]]; then
  pass "grep --tea: flag stripped (grep still matches)"
else
  fail "grep --tea leaked or failed (rc=$CAPTURED_RC err=$(printf %q "$CAPTURED_ERR") out=$(printf %q "$CAPTURED_OUT"))"
fi

clear_logs
run_capture env -u TEA_OFF TEA_FORCE=1 "$TEA_OUT/bin/grep" --coffee '^alpha' <"$WORKDIR/grep-in.txt"
if [[ "$CAPTURED_RC" -eq 0 && "$CAPTURED_OUT" == "$EXPECTED_GREP" && "$(count_logs)" -eq 0 ]]; then
  pass "grep --coffee: flag stripped + passthrough"
else
  fail "grep --coffee leaked or logged (rc=$CAPTURED_RC logs=$(count_logs) err=$(printf %q "$CAPTURED_ERR"))"
fi

clear_logs
run_capture env -u TEA_OFF TEA_FORCE=1 "$TEA_OUT/bin/grep" --no-tea '^alpha' <"$WORKDIR/grep-in.txt"
if [[ "$CAPTURED_RC" -eq 0 && "$CAPTURED_OUT" == "$EXPECTED_GREP" && "$(count_logs)" -eq 0 ]]; then
  pass "grep --no-tea: flag stripped + passthrough"
else
  fail "grep --no-tea leaked or logged (rc=$CAPTURED_RC logs=$(count_logs))"
fi

# ---------------------------------------------------------------------------
# D. mktemp --suffix .tea naming (under TMPDIR, not ./logfiles/)
# ---------------------------------------------------------------------------
echo "== D. mktemp --suffix .tea naming =="

clear_logs
run_capture env -u TEA_OFF TEA_QUIET=1 "$TEA_OUT/bin/head" --tea -n 2 <"$WORKDIR/stdin.txt"
mapfile -t LOGS < <(list_log_paths)

LEGACY_RE='^[0-9]{8}-[0-9]{6}-[A-Za-z0-9._+-]+-[0-9]+\.log$'
# mktemp --suffix .tea → tmp.XXXXXX.tea
MKTEMP_RE='^tmp\.[A-Za-z0-9]+\.tea$'

if [[ "${#LOGS[@]}" -lt 1 ]]; then
  fail "no logfile to check naming"
else
  for path in "${LOGS[@]}"; do
    [[ -z "$path" ]] && continue
    base="$("$BASENAME" "$path")"
    if [[ "$path" == "$WORKDIR"/* ]]; then
      fail "logfile '$path' is under workdir (want TMPDIR/mktemp, not ./logfiles/)"
    elif [[ "$base" =~ $LEGACY_RE ]]; then
      fail "logfile '$base' uses legacy {YYYYMMDD-HHMMSS}-{tool}-{pid}.log"
    elif [[ "$base" =~ $MKTEMP_RE ]]; then
      pass "logfile '$path' matches mktemp --suffix .tea style"
    else
      fail "logfile '$base' is not mktemp tmp.*.tea (want ^tmp\\.[A-Za-z0-9]+\\.tea\$)"
    fi
  done
fi

if [[ -d "$WORKDIR/logfiles" ]]; then
  fail "logfiles/ directory was created (should not exist)"
else
  pass "no ./logfiles/ directory"
fi

# ---------------------------------------------------------------------------
# E. TEA_USER_PIPE + piped stdin auto-activation
# ---------------------------------------------------------------------------
echo "== E. TEA_USER_PIPE auto-activation =="

clear_logs
out_tmp="$("$MKTEMP" "$WORKDIR/out.XXXXXX")"
set +e
env -u TEA_OFF TEA_USER_PIPE=1 TEA_QUIET=1 "$TEA_OUT/bin/head" -n 2 <"$WORKDIR/stdin.txt" >"$out_tmp"
tea_user_pipe_rc=$?
set -e
CAPTURED_OUT="$("$CAT" "$out_tmp"; printf x)"
CAPTURED_OUT="${CAPTURED_OUT%x}"
"$RM" -f "$out_tmp"
if [[ "$tea_user_pipe_rc" -eq 0 && "$CAPTURED_OUT" == "$EXPECTED_HEAD" && "$(count_logs)" -ge 1 ]]; then
  pass "TEA_USER_PIPE=1 + piped stdin activates"
elif [[ ! -t 2 ]]; then
  pass "TEA_USER_PIPE=1 + piped stdin (skipped: stderr not a TTY)"
else
  fail "TEA_USER_PIPE=1 should activate (rc=$tea_user_pipe_rc logs=$(count_logs) out=$(printf %q "$CAPTURED_OUT"))"
fi

# TEA_USER_PIPE does not bypass --coffee
clear_logs
out_tmp="$("$MKTEMP" "$WORKDIR/out.XXXXXX")"
set +e
env -u TEA_OFF TEA_USER_PIPE=1 TEA_QUIET=1 "$TEA_OUT/bin/head" --coffee -n 2 <"$WORKDIR/stdin.txt" >"$out_tmp"
tea_user_pipe_rc=$?
set -e
CAPTURED_OUT="$("$CAT" "$out_tmp"; printf x)"
CAPTURED_OUT="${CAPTURED_OUT%x}"
"$RM" -f "$out_tmp"
if [[ "$tea_user_pipe_rc" -eq 0 && "$CAPTURED_OUT" == "$EXPECTED_HEAD" && "$(count_logs)" -eq 0 ]]; then
  pass "TEA_USER_PIPE=1 does not bypass --coffee"
else
  fail "TEA_USER_PIPE + --coffee should not log (rc=$tea_user_pipe_rc logs=$(count_logs))"
fi

# ---------------------------------------------------------------------------
# F. Fish: suppress completion pipelines without TEA_USER_PIPE
# ---------------------------------------------------------------------------
echo "== F. fish completion suppression =="

if command -v fish >/dev/null 2>&1; then
  fish_pipe_test="$WORKDIR/fish-pipe-test.fish"
  printf '%s\n' 'printf "a\nb\nc\n" | '"$TEA_OUT"'/bin/tea which tail --piped 2>&1' >"$fish_pipe_test"
  clear_logs
  set +e
  fish -i "$fish_pipe_test" | "$GREP" -q 'user_pipeline=false'
  fish_no_pipe_rc=$?
  set -e
  if [[ "$fish_no_pipe_rc" -eq 0 ]]; then
    pass "fish-parented pipeline without TEA_USER_PIPE is not user_pipeline"
  else
    fail "expected user_pipeline=false for fish parent without TEA_USER_PIPE"
  fi

  clear_logs
  out_tmp="$("$MKTEMP" "$WORKDIR/out.XXXXXX")"
  set +e
  fish -i -c 'complete -C "kill "' >/dev/null 2>"$out_tmp"
  fish_comp_rc=$?
  set -e
  if [[ "$fish_comp_rc" -eq 0 && ! -s "$out_tmp" || "$("$CAT" "$out_tmp")" != *'[tea]'* ]]; then
    if [[ "$(count_logs)" -eq 0 ]]; then
      pass "fish kill completion does not emit [tea] blurbs"
    else
      fail "fish kill completion created logs.csv rows ($(count_logs))"
    fi
  else
    fail "fish kill completion stderr contained [tea]: $("$CAT" "$out_tmp")"
  fi
  "$RM" -f "$out_tmp"
else
  pass "fish completion suppression (skipped: fish not on PATH)"
fi

# ---------------------------------------------------------------------------
# G. min-duration gate
# ---------------------------------------------------------------------------
echo "== G. min-duration gate =="

# Materialize the isolated config, then give `head` a low min-duration-ms
# threshold so a fast stage is gated while a genuinely slow upstream producer
# still logs. Insert right after the existing [tools.head] header (already
# present with `enabled = true` from TEA_DEFAULT_CONFIG) rather than
# appending a second [tools.head] table, which TOML would reject.
run_capture env -u TEA_OFF "$TEA_OUT/bin/tea" config
GATE_CFG="$WORKDIR/xdg/tea/config.toml"
if [[ ! -f "$GATE_CFG" ]]; then
  echo "FAIL: expected config at $GATE_CFG" >&2
  exit 2
fi
"$SED" -i '/^\[tools\.head\]$/a min-duration-ms = 500' "$GATE_CFG"
if ! "$GREP" -q 'min-duration-ms = 500' "$GATE_CFG"; then
  echo "FAIL: could not inject min-duration-ms into $GATE_CFG" >&2
  exit 2
fi

# Deterministic auto-activation (agentic + user-pipeline), routed through
# `timeout` as a genuine non-shell parent so parent_is_running_script() does
# not suppress it (this harness itself runs as `bash tests/functional.sh`,
# a script file), and TEA_INTERACTIVE=1 so systemd_suppresses_activation()
# does not fire if this harness happens to run under a systemd-managed
# session (INVOCATION_ID set, stderr not a tty).
EXPECTED_GATE_FAST=$'a\n'
EXPECTED_GATE_SLOW=$'a\nb\n'

# G1: fast producer, auto-activated, elapsed well under the threshold ->
# gated: no new logs.csv row, no [tea] blurb.
clear_logs
before="$(count_logs)"
printf 'a\nb\n' >"$WORKDIR/gate-fast.txt"
out_tmp="$("$MKTEMP" "$WORKDIR/out.XXXXXX")"
err_tmp="$("$MKTEMP" "$WORKDIR/err.XXXXXX")"
set +e
"$TIMEOUT" 10 env -u TEA_OFF TEA_AGENT=1 TEA_USER_PIPE=1 TEA_INTERACTIVE=1 TEA_QUIET=1 \
  "$TEA_OUT/bin/head" -n 1 <"$WORKDIR/gate-fast.txt" >"$out_tmp" 2>"$err_tmp"
gate_fast_rc=$?
set -e
CAPTURED_OUT="$("$CAT" "$out_tmp"; printf x)"; CAPTURED_OUT="${CAPTURED_OUT%x}"
CAPTURED_ERR="$("$CAT" "$err_tmp"; printf x)"; CAPTURED_ERR="${CAPTURED_ERR%x}"
"$RM" -f "$out_tmp" "$err_tmp"
after="$(count_logs)"
if [[ "$gate_fast_rc" -eq 0 && "$CAPTURED_OUT" == "$EXPECTED_GATE_FAST" \
  && "$after" -eq "$before" && "$CAPTURED_ERR" != *'[tea]'* ]]; then
  pass "fast auto-activated stage under min-duration-ms is not logged"
else
  fail "fast auto-activated stage should be gated (rc=$gate_fast_rc before=$before after=$after out=$(printf %q "$CAPTURED_OUT") err=$(printf %q "$CAPTURED_ERR"))"
fi

# G2: slow upstream producer (sleep before final write), auto-activated ->
# tea-wrap's own spawn->wait elapsed is bounded below by the producer, so
# the row is logged even though the wrapped tool itself does little work.
clear_logs
before="$(count_logs)"
out_tmp="$("$MKTEMP" "$WORKDIR/out.XXXXXX")"
err_tmp="$("$MKTEMP" "$WORKDIR/err.XXXXXX")"
set +e
{ printf 'a\n'; "$SLEEP" 1; printf 'b\n'; } | "$TIMEOUT" 10 env -u TEA_OFF TEA_AGENT=1 TEA_USER_PIPE=1 TEA_INTERACTIVE=1 \
  "$TEA_OUT/bin/head" -n 5 >"$out_tmp" 2>"$err_tmp"
gate_slow_rc=$?
set -e
CAPTURED_OUT="$("$CAT" "$out_tmp"; printf x)"; CAPTURED_OUT="${CAPTURED_OUT%x}"
CAPTURED_ERR="$("$CAT" "$err_tmp"; printf x)"; CAPTURED_ERR="${CAPTURED_ERR%x}"
"$RM" -f "$out_tmp" "$err_tmp"
after="$(count_logs)"
if [[ "$gate_slow_rc" -eq 0 && "$CAPTURED_OUT" == "$EXPECTED_GATE_SLOW" \
  && "$after" -eq $((before + 1)) && "$CAPTURED_ERR" == *'[tea]'* ]]; then
  pass "slow upstream producer through auto-activation is logged despite fast downstream tool"
else
  fail "slow producer stage should be logged (rc=$gate_slow_rc before=$before after=$after out=$(printf %q "$CAPTURED_OUT") err=$(printf %q "$CAPTURED_ERR"))"
fi

# G3: fast producer forced via --tea -> gate is a post-activation logging
# filter for auto-detect outcomes only; an explicit --tea ask still logs.
clear_logs
before="$(count_logs)"
run_capture env -u TEA_OFF TEA_QUIET=1 "$TEA_OUT/bin/head" --tea -n 1 <"$WORKDIR/gate-fast.txt"
after="$(count_logs)"
if [[ "$CAPTURED_RC" -eq 0 && "$CAPTURED_OUT" == "$EXPECTED_GATE_FAST" && "$after" -eq $((before + 1)) ]]; then
  pass "--tea forced activation bypasses min-duration-ms gate"
else
  fail "--tea should bypass gate and still log (rc=$CAPTURED_RC before=$before after=$after out=$(printf %q "$CAPTURED_OUT"))"
fi

# ---------------------------------------------------------------------------
# H. User-defined extra tools (build-time extraTools + runtime TEA_EXTRA_TOOLS)
# ---------------------------------------------------------------------------
echo "== H. user-defined extra tools =="

# Tool under wrap: a plain cat copy under a distinct name, so tests never
# depend on ripgrep (or any specific consumer tool) being present.
"$MKDIR" -p "$WORKDIR/bin"
FAKE_BIN="$WORKDIR/bin/fakefilter"
printf '#!%s\ncat "$@"\n' "$SYS_BIN/bash" >"$FAKE_BIN"
"$CHMOD" +x "$FAKE_BIN"

# H0: the default package does not wrap consumer-defined tools.
if [[ -e "$TEA_OUT/bin/fakefilter" ]]; then
  fail "default package should not contain extraTools entries"
else
  pass "default package has no consumer-defined extraTools wraps"
fi

# H1: build-time extraTools override — wrapper binary lands in the package
# (PATH everywhere), wired to the declared real-binary outpath, with
# `tea which` support and a logs.csv row like any built-in wrap.
OVERRIDE_OUT="$("$NIX" build --no-link --print-out-paths --no-write-lock-file --impure --expr "
  (builtins.getFlake \"$REPO\").packages.x86_64-linux.sh-tea.override {
    extraTools = { fakefilter = \"$FAKE_BIN\"; };
  }" 2>"$WORKDIR/nix-override.err")"
if [[ -z "$OVERRIDE_OUT" || ! -e "$OVERRIDE_OUT/bin/fakefilter" ]]; then
  fail "extraTools override produced no fakefilter wrapper ($(printf %q "$OVERRIDE_OUT"))"
else
  pass "extraTools override builds a fakefilter wrapper"
  if ! "$GREP" -q "$FAKE_BIN" "$OVERRIDE_OUT/bin/fakefilter"; then
    fail "extraTools wrapper does not reference declared outpath $FAKE_BIN"
  else
    pass "extraTools wrapper execs the declared real-binary outpath"
  fi
  clear_logs
  run_capture env -u TEA_OFF TEA_QUIET=1 "$OVERRIDE_OUT/bin/fakefilter" --tea <"$WORKDIR/stdin.txt"
  if [[ "$CAPTURED_RC" -eq 0 && "$CAPTURED_OUT" == "$INPUT" ]]; then
    pass "extraTools wrapper preserves stdout (--tea, fakefilter=cat)"
  else
    fail "extraTools wrapper stdout (rc=$CAPTURED_RC out=$(printf %q "$CAPTURED_OUT"))"
  fi
  if [[ -f "$WORKDIR/logs.csv" ]] && "$TAIL" -n 1 "$WORKDIR/logs.csv" | "$GREP" -q ',fakefilter,'; then
    pass "extraTools wrapper logs rows like a built-in wrap"
  else
    fail "extraTools wrapper row missing from logs.csv"
  fi
  run_capture env -u TEA_OFF "$OVERRIDE_OUT/bin/tea" which fakefilter --piped
  if [[ "$CAPTURED_RC" -eq 0 && "$CAPTURED_OUT" == *'tool=fakefilter'* ]]; then
    pass "tea which recognizes extraTools entries"
  else
    fail "tea which fakefilter (rc=$CAPTURED_RC out=$(printf %q "$CAPTURED_OUT"))"
  fi
fi

# H2: runtime TEA_EXTRA_TOOLS — `tea which` accepts the name, rejects without.
run_capture env -u TEA_OFF TEA_EXTRA_TOOLS="garbage fakefilter=$FAKE_BIN" "$TEA_OUT/bin/tea" which fakefilter --piped
if [[ "$CAPTURED_RC" -eq 0 && "$CAPTURED_OUT" == *'tool=fakefilter'* ]]; then
  pass "TEA_EXTRA_TOOLS entries are accepted by tea which (malformed skipped)"
else
  fail "tea which should accept TEA_EXTRA_TOOLS (rc=$CAPTURED_RC out=$(printf %q "$CAPTURED_OUT"))"
fi

run_capture env -u TEA_OFF "$TEA_OUT/bin/tea" which fakefilter
if [[ "$CAPTURED_RC" -eq 2 ]]; then
  pass "without TEA_EXTRA_TOOLS the extra tool is unknown"
else
  fail "unknown tool should exit 2 without TEA_EXTRA_TOOLS (rc=$CAPTURED_RC)"
fi

# H3: tea-wrap direct (the call the fish-generated function makes) — accepts
# the env-declared tool and execs the declared real binary.
clear_logs
run_capture env -u TEA_OFF TEA_EXTRA_TOOLS="fakefilter=$FAKE_BIN" TEA_QUIET=1 \
  "$TEA_OUT/bin/tea-wrap" fakefilter "$FAKE_BIN" --tea <"$WORKDIR/stdin.txt"
if [[ "$CAPTURED_RC" -eq 0 && "$CAPTURED_OUT" == "$INPUT" && -f "$WORKDIR/logs.csv" ]] \
  && "$TAIL" -n 1 "$WORKDIR/logs.csv" | "$GREP" -q ',fakefilter,'; then
  pass "tea-wrap accepts TEA_EXTRA_TOOLS tool and logs a row"
else
  fail "tea-wrap with TEA_EXTRA_TOOLS (rc=$CAPTURED_RC out=$(printf %q "$CAPTURED_OUT"))"
fi

# H4: fish hook — shadow functions created at first prompt, only in
# interactive sessions; env-declared entries route through tea-wrap.
if command -v fish >/dev/null 2>&1; then
  clear_logs
  fish_extra="$WORKDIR/extra-tools.fish"
  {
    printf 'set -e TEA_OFF\n'
    printf 'set -gx PATH "%s/bin" $PATH\n' "$TEA_OUT"
    printf "set -gx TEA_EXTRA_TOOLS 'fakefilter=%s'\n" "$FAKE_BIN"
    printf 'source %s/share/fish/vendor_conf.d/tea-extra-tools.fish\n' "$TEA_OUT"
    # Idempotent: a second pass must replace, not duplicate.
    printf '__tea_extra_tools_apply\n'
    printf '__tea_extra_tools_apply\n'
    printf 'if functions -q fakefilter\n'
    printf '    printf "a\\nb\\nc\\n" | fakefilter --tea >"%s/fish-out.txt"\n' "$WORKDIR"
    printf '    echo "FISH_RC=$status"\n'
    printf 'else\n'
    printf '    echo FISH_RC=no-function\n'
    printf 'end\n'
  } >"$fish_extra"
  set +e
  fish -i "$fish_extra" >"$WORKDIR/fish-stdout.txt" 2>"$WORKDIR/fish-stderr.txt"
  fish_hook_rc=$?
  set -e
  FISH_RC_LINE="$("$GREP" -o 'FISH_RC=[^[:space:]]*' "$WORKDIR/fish-stdout.txt" 2>/dev/null | "$TAIL" -n 1)"
  if [[ "$FISH_RC_LINE" == 'FISH_RC=0' && -f "$WORKDIR/fish-out.txt" ]] \
    && "$GREP" -q '^a$' "$WORKDIR/fish-out.txt"; then
    pass "fish hook creates a working shadow function (TEA_EXTRA_TOOLS)"
  else
    fail "fish shadow function failed (line=$(printf %q "$FISH_RC_LINE") rc=$fish_hook_rc err=$("$TAIL" -n 3 "$WORKDIR/fish-stderr.txt" 2>/dev/null))"
  fi
  if [[ -f "$WORKDIR/logs.csv" ]] && "$TAIL" -n 1 "$WORKDIR/logs.csv" | "$GREP" -q ',fakefilter,'; then
    pass "fish shadow function routes through tea-wrap (logs.csv row)"
  else
    fail "fish shadow function produced no logs.csv row"
  fi

  # Non-exported scope (set -g): the generated function re-exports its own
  # pair for the child, so the wrap works even if the variable never leaves
  # the fish process.
  clear_logs
  fish_nx="$WORKDIR/extra-tools-noexport.fish"
  {
    printf 'set -e TEA_OFF\n'
    printf 'set -gx PATH "%s/bin" $PATH\n' "$TEA_OUT"
    printf "set -g TEA_EXTRA_TOOLS 'fakefilter=%s'\n" "$FAKE_BIN"
    printf 'source %s/share/fish/vendor_conf.d/tea-extra-tools.fish\n' "$TEA_OUT"
    printf 'emit fish_prompt\n'
    printf 'printf "x\\n" | fakefilter --tea >/dev/null\n'
    printf 'echo "FISH_RC=$status"\n'
  } >"$fish_nx"
  set +e
  fish -i "$fish_nx" >"$WORKDIR/fish-nx-out.txt" 2>/dev/null
  set -e
  if "$GREP" -q 'FISH_RC=0' "$WORKDIR/fish-nx-out.txt"; then
    pass "shadow function works with non-exported TEA_EXTRA_TOOLS scope"
  else
    fail "non-exported TEA_EXTRA_TOOLS scope should still wrap ($("$CAT" "$WORKDIR/fish-nx-out.txt" 2>/dev/null))"
  fi

  # Non-interactive sessions never see fish_prompt → no shadow functions.
  set +e
  fish -N -c "set -g TEA_EXTRA_TOOLS 'fakefilter=$FAKE_BIN'
source $TEA_OUT/share/fish/vendor_conf.d/tea-extra-tools.fish
if functions -q fakefilter
    exit 3
end
exit 0"
  fish_ni_rc=$?
  set -e
  if [[ "$fish_ni_rc" -eq 0 ]]; then
    pass "non-interactive fish does not create shadow functions"
  else
    fail "shadow functions leaked into non-interactive fish (rc=$fish_ni_rc)"
  fi
else
  pass "fish hook shadow functions (skipped: fish not on PATH)"
fi

echo
if [[ "$failures" -eq 0 ]]; then
  echo "All functional checks passed."
  exit 0
fi
echo "$failures check(s) failed." >&2
exit 1
