#!/usr/bin/env bash
# Compares the working tree against a git ref.
#
#     bench/compare.sh            # vs HEAD
#     bench/compare.sh master     # vs any ref
#
# Both revisions are measured in a single VM, from parser source dumped by
# bench/gen_module.exs, so neither side pays for a recompile and neither warms
# the machine up for the other. The dumps are left in bench/out/ to be diffed.
#
# The ref is checked out into a throwaway worktree, and this directory's scripts
# are copied in, so the ref may predate them and both sides are driven by the
# same case definitions.
set -euo pipefail

REF="${1:-HEAD}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/bench/out"
TMP="$(mktemp -d)"
WT="$TMP/worktree"

cleanup() {
  [ -d "$WT" ] && git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true
  git -C "$ROOT" worktree prune >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

cd "$ROOT"
mkdir -p "$OUT"

echo "==> working tree"
mix run bench/gen_module.exs New "$OUT/new.ex"

echo "==> $REF ($(git rev-parse --short "$REF"))"
git worktree add --quiet --detach "$WT" "$REF"
mkdir -p "$WT/bench"
cp bench/*.exs "$WT/bench/"
(cd "$WT" && mix run bench/gen_module.exs Old "$OUT/old.ex")

echo
echo "==> generated code"
if diff -q <(sed 's/BenchOld/Bench/' "$OUT/old.ex") \
           <(sed 's/BenchNew/Bench/' "$OUT/new.ex") >/dev/null; then
  echo "    identical -- any difference in the table below is noise"
else
  echo "    differs: diff bench/out/old.ex bench/out/new.ex"
  echo "    ($(diff <(sed 's/BenchOld/Bench/' "$OUT/old.ex") \
                     <(sed 's/BenchNew/Bench/' "$OUT/new.ex") | grep -c '^[<>]') changed lines;"
  echo "     renumbered functions and reordered clauses are expected and harmless)"
fi

mkdir -p "$TMP/ebin"
elixirc --ignore-module-conflict -o "$TMP/ebin" "$OUT/old.ex" "$OUT/new.ex"
BENCH_EBIN="$TMP/ebin" mix run bench/ab.exs
