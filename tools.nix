# Canonical tea-wrapped tools: stdin→stdout stream filters that *mutate*
# the byte/line stream (reorder, rewrite, select, reshape).
#
# Excluded on purpose:
#   tee, cat     — identity / fan-out, do not mutate stdout content
#   more, less   — interactive pagers
#   split/csplit — primarily write files
#   checksums, base64/base32 — digest/encode sinks, uncommon in filter pipes
#   dd, yes, seq — special / generators
#
# BusyBox ships the same applet names; we wrap the GNU/util-linux binaries
# that NixOS puts on PATH (hiPrio), which covers the busybox-shaped workflows.

{ pkgs }:

let
  cu = "${pkgs.coreutils}/bin";
  grep = "${pkgs.gnugrep}/bin";
  sed = "${pkgs.gnused}/bin";
  gawk = "${pkgs.gawk}/bin";
  # util-linux multi-output: prefer .bin when present
  ul = "${pkgs.util-linux.bin or pkgs.util-linux}/bin";
in
{
  # --- selection / slicing ---
  grep = "${grep}/grep";
  egrep = "${grep}/egrep";
  fgrep = "${grep}/fgrep";
  head = "${cu}/head";
  tail = "${cu}/tail";
  cut = "${cu}/cut";

  # --- rewriting ---
  sed = "${sed}/sed";
  awk = "${gawk}/awk";
  gawk = "${gawk}/gawk";
  tr = "${cu}/tr";
  expand = "${cu}/expand";
  unexpand = "${cu}/unexpand";
  fmt = "${cu}/fmt";
  fold = "${cu}/fold";
  nl = "${cu}/nl";
  numfmt = "${cu}/numfmt";

  # --- ordering / uniqueness ---
  sort = "${cu}/sort";
  uniq = "${cu}/uniq";
  shuf = "${cu}/shuf";
  tac = "${cu}/tac";
  rev = "${ul}/rev";
  tsort = "${cu}/tsort";

  # --- columnar / paste ---
  paste = "${cu}/paste";
  join = "${cu}/join";
  column = "${ul}/column";
  col = "${ul}/col";
  colrm = "${ul}/colrm";

  # --- dump / count (stream → representation) ---
  od = "${cu}/od";
  hexdump = "${ul}/hexdump";
  hd = "${ul}/hd";
  wc = "${cu}/wc";

  # --- misc text transforms ---
  pr = "${cu}/pr";
  ptx = "${cu}/ptx";
  comm = "${cu}/comm";
}
