#!/usr/bin/env bash
#
# tests/lens.sh — aowllens reading aowlsem's SEMANTIC INDEX (`<mod>.lens.nif`).
#
# Every other analysis in this repo reconstructs meaning from the emitted tree.
# aowlsem publishes what it actually resolved (its LENS.md), and typeat/members
# prefer that when a sidecar is present. This gate proves three things:
#
#   1. positions resolve to the RIGHT symbol — two `d` bindings of two
#      different types, in two routines, must answer Dog and Cat respectively;
#   2. member lists come from the checker's own table (field + its type);
#   3. the NEGATIVE CONTROL — with the sidecar hidden, position 7:29 answers
#      `{}`. aowlsem's `.s.nif` carries no position on the symbols it mints, so
#      that answer is one only the index can give. Without this check the test
#      would pass just as happily on a build that ignored the sidecar entirely.
#
# Skipped (exit 0, loudly) when aowlsem or nimony is not available: this repo
# does not depend on aowlsem, it merely uses its index when one is there.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LENS="${LENS:-$ROOT/bin/aowllens}"
AOWLSEM="${AOWLSEM:-$HOME/aowlsem/bin/aowlsem}"
PROBE="${PROBE:-$HOME/aowlsem/tests/probe.sh}"
WORK="${WORK:-/tmp/aowllens_lens_$$}"

[ -x "$LENS" ] || { echo "no aowllens binary at $LENS (run build.sh)"; exit 1; }
if [ ! -x "$AOWLSEM" ] || [ ! -f "$PROBE" ]; then
  echo "SKIP: aowlsem not available ($AOWLSEM) — the index path is untested here"
  exit 0
fi

rm -rf "$WORK"; mkdir -p "$WORK"
SRC="$WORK/shadow.nim"
cat > "$SRC" <<'EOF'
type
  Dog = object
    breed: string
  Cat = object
    lives: int

proc speak(d: Dog): string = d.breed

proc count(d: Cat): int = d.lives

proc both(dg: Dog; ct: Cat): string =
  result = speak(dg)
EOF

# probe.sh resolves the oracle's --sys:/--imp: set into probe.env; reuse it
# rather than re-deriving the import graph here.
AOWLSEM="$AOWLSEM" WORK="$WORK/nc" bash "$PROBE" "$SRC" > "$WORK/probe.log" 2>&1
ENV="$WORK/nc/probe.env"
[ -f "$ENV" ] || { echo "FAIL: no oracle compile (see $WORK/probe.log)"; exit 1; }
# shellcheck disable=SC1090
. "$ENV"

SNIF="$WORK/out.s.nif"
eval "$AOWLSEM" m "$PROBE_P" "$SNIF" "--sys:$PROBE_S" $PROBE_MA \
     "--lens:$WORK/out.lens.nif" > "$WORK/aowlsem.log" 2>&1
[ -s "$WORK/out.lens.nif" ] || { echo "FAIL: aowlsem wrote no sidecar"; tail -5 "$WORK/aowlsem.log"; exit 1; }

fails=0
want() { # want <description> <expected exact stdout> <command...>
  local desc="$1" exp="$2"; shift 2
  local got; got="$("$@" 2>&1)"
  if [ "$got" = "$exp" ]; then
    echo "  ok   $desc"
  else
    echo "  FAIL $desc"
    echo "       expected: $exp"
    echo "       got:      $got"
    fails=$((fails + 1))
  fi
}

echo "with the index:"
# `d` at 7:29 is the Dog parameter; `d` at 9:26 is the Cat one. Same name, two
# symbols, two types — the question a by-name lookup cannot answer.
want "d in speak(7:29) -> Dog" '{"type":"Dog","sym":"d.0"}' \
     "$LENS" typeat "$SNIF" 7 29
want "d in count(9:26) -> Cat" '{"type":"Cat","sym":"d.1"}' \
     "$LENS" typeat "$SNIF" 9 26
# `speak` and `both` both take a Dog first — the index states each routine's
# receiver, so this is a filter over declarations, not a re-derivation of every
# signature's first parameter.
want "Dog's members: field + both UFCS routines" \
     '[{"name":"breed","kind":"fld","detail":"string"},{"name":"speak","kind":"proc","detail":"(Dog): string"},{"name":"both","kind":"proc","detail":"(Dog, Cat): string"}]' \
     "$LENS" members "$SNIF" Dog

# Call edges come straight from the index: an occurrence marked "call", its
# owner, and the call site. The tree walk can still find the edge, but takes
# its position from the emitted tokens — which on an aowlsem artifact carry
# none, so only the index yields a usable one.
MOD="$(basename "$PROBE_P" .p.nif)"
want "both calls speak at 12:11" \
     "[{\"caller\":\"both.0.$MOD\",\"callee\":\"speak.0.$MOD\",\"file\":\"shadow.nim\",\"line\":12,\"col\":11}]" \
     "$LENS" calls "$SNIF"

echo "negative control (sidecar hidden):"
mv "$WORK/out.lens.nif" "$WORK/out.lens.hidden"
want "7:29 is unanswerable without it" '{}' "$LENS" typeat "$SNIF" 7 29
mv "$WORK/out.lens.hidden" "$WORK/out.lens.nif"

if [ "$fails" -eq 0 ]; then
  echo "lens: PASS"
  rm -rf "$WORK"
  exit 0
fi
echo "lens: $fails FAILED  [work: $WORK]"
exit 1
