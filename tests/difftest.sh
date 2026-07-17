#!/usr/bin/env bash
# difftest.sh — prove the nimony aowllens produces the SAME JSON as the Nim-2
# aiflens (`niflens`) it replaces. Generates a real `.s.nif` with `nimony check`,
# then compares every command. Skips cleanly if the reference or nimony is absent.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
B="${AOWLLENS:-$ROOT/bin/aowllens}"
A="${AIFLENS:-/home/savant/aiflens/bin/niflens}"
NIMONY="${NIMONY:-$HOME/nimony/bin/nimony}"
[ -x "$B" ] || { echo "building aowllens ..."; bash "$ROOT/build.sh" >/dev/null || exit 1; }
[ -x "$A" ] || { echo "difftest: reference $A not found — skipping"; exit 0; }
[ -x "$NIMONY" ] || { echo "difftest: nimony not found — skipping"; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/sample.nim" <<'EOF'
import std/syncio

proc greet(name: string): string = "hi " & name
type Color = enum red, green, blue
proc area(w, h: int): int = w * h

let g = greet("bob")
echo g, area(3, 4)
EOF
( cd "$WORK" && "$NIMONY" check --nimcache:"$WORK/nc" sample.nim >/dev/null 2>&1 || true )
snif="$(find "$WORK/nc" -name '*.s.nif' | head -1)"
idx="$(find "$WORK/nc" -name '*.s.idx.nif' | head -1)"
[ -n "$snif" ] || { echo "difftest: could not produce a .s.nif — skipping"; exit 0; }

fail=0
cmp_exact() {
  local name="$1"; shift
  "$A" "$@" > "$WORK/a" 2>&1; "$B" "$@" > "$WORK/b" 2>&1
  if diff -q "$WORK/a" "$WORK/b" >/dev/null; then echo "✅ $name (byte-identical)"
  else echo "❌ $name differs:"; diff "$WORK/a" "$WORK/b" | head -4; fail=1; fi
}
# render is a HEURISTIC pretty-printer; the only delta vs aiflens is the hex CASE
# of \u00XX escapes for control-char literals (aiflens is itself inconsistent
# there). Compare with hex case normalized, so a real structural diff still fails.
cmp_render() {
  "$A" render "$snif" 2>&1 | tr 'A-F' 'a-f' > "$WORK/a"
  "$B" render "$snif" 2>&1 | tr 'A-F' 'a-f' > "$WORK/b"
  if diff -q "$WORK/a" "$WORK/b" >/dev/null; then echo "✅ render (identical mod \\u hex-case)"
  else echo "❌ render differs structurally:"; diff "$WORK/a" "$WORK/b" | head -4; fail=1; fi
}

cmp_exact "decls"     decls "$snif"
cmp_exact "outline"   outline "$snif"
cmp_exact "query"     query "$snif" greet
cmp_render
[ -n "$idx" ] && cmp_exact "index" index "$idx" || echo "(no .s.idx.nif to test)"

if [ "$fail" -eq 0 ]; then echo "difftest: PASS"; else echo "difftest: FAILURES above"; fi
exit "$fail"
