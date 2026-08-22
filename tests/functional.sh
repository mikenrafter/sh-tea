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
  unset TEA_FORCE TEA_AGENT TEA_INTERACTIVE || true
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

echo
if [[ "$failures" -eq 0 ]]; then
  echo "All functional checks passed."
  exit 0
fi
echo "$failures check(s) failed." >&2
exit 1
