#!/usr/bin/env bash
# tests/test.sh -- drive bin/aowllens.exe over artifacts produced by the real
# aowlmony compiler from tests/fixture/shapes.aowl.
#
#   bash tests/test.sh      (build first: bash build.sh)
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
B="${AOWLLENS:-$ROOT/bin/aowllens.exe}"
AOWLMONY_ROOT="${AOWLMONY_ROOT:-$HOME/dev/toolchain/aowlmony/root}"
COMPILER="$AOWLMONY_ROOT/bin/aowlmony.exe"
[ -x "$B" ] || { echo "no $B (run build.sh)"; exit 1; }
[ -x "$COMPILER" ] || { echo "no compiler at $COMPILER"; exit 1; }
export AOWLMONY_ROOT="$(cygpath -w "$AOWLMONY_ROOT" 2>/dev/null || echo "$AOWLMONY_ROOT")"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/tests/fixture/shapes.aowl" "$WORK/"
( cd "$WORK" && "$COMPILER" c -d:release shapes.aowl >"$WORK/compile.log" 2>&1 || true )
snif=""
for f in "$WORK"/nimcache/*.s.nif; do
  grep -q 'Outer' "$f" && grep -q 'Inner' "$f" && { snif="$f"; break; }
done
[ -n "$snif" ] || { echo "FAIL: compiler produced no .s.nif for the fixture"; tail -5 "$WORK/compile.log"; exit 1; }
idx="${snif%.s.nif}.s.idx.nif"
mod="$(basename "$snif" .s.nif)"
snif="$(cygpath -m "$snif" 2>/dev/null || echo "$snif")"
idx="$(cygpath -m "$idx" 2>/dev/null || echo "$idx")"

fail=0
has() {  # has <label> <haystack> <needle>   (fixed-string match)
  if grep -qF -- "$3" <<<"$2"; then echo "ok   $1"; else echo "FAIL $1: missing '$3' in: $2"; fail=1; fi
}
hasnt() {
  if grep -qF -- "$3" <<<"$2"; then echo "FAIL $1: unexpected '$3' in: $2"; fail=1; else echo "ok   $1"; fi
}

has "version" "$("$B" version)" "aowllens 0.1.0"

d="$("$B" decls "$snif")"
has "decls: type Dog"    "$d" '"name":"Dog","kind":"type","file":"shapes.aowl","line":6,"col":2'
has "decls: field breed" "$d" '"name":"breed","kind":"fld"'
has "decls: proc wag"    "$d" '"name":"wag","kind":"proc","file":"shapes.aowl","line":16,"col":5'
dw="$("$B" decls "$snif" wag)"
has   "decls <symbol>: wag found" "$dw" '"name":"wag"'
hasnt "decls <symbol>: filters others" "$dw" '"name":"Dog"'

o="$("$B" outline "$snif")"
has "outline: tags array" "$o" '{"tags":['
has "outline: proc use"   "$o" '"tag":"proc","name":"use"'

q="$("$B" query "$snif" wag)"
has "query: matches wag proc" "$q" '"tag":"proc","name":"wag"'

i="$("$B" index "$idx")"
has "index: checksum" "$i" '"checksum":"'
has "index: shape"    "$i" '"exports":['
has "index: re-export of syncio" "$i" '"kind":"export"'
si=""
for x in "$(dirname "$idx")"/*.s.idx.nif; do
  case "$x" in *"$mod"*) continue;; esac
  si="$si $("$B" index "$(cygpath -m "$x" 2>/dev/null || echo "$x")")"
done
has "index: a library module lists converters" "$si" '"converters":[["openArray.0.'

r="$("$B" render "$snif" wag)"
has "render: wag" "$r" '"render":"proc wag(d: '

c="$("$B" calls "$snif" use)"
has "calls: use -> wag" "$c" "\"caller\":\"use.0.$mod\",\"callee\":\"wag.0.$mod\",\"file\":\"shapes.aowl\",\"line\":21,\"col\":5"

t="$("$B" types "$snif")"
has "types: Dog of Beast" "$t" '"name":"Dog","parent":"Beast.Obj.0.'"$mod"'","parentName":"Beast"'
has "types: Beast of RootObj" "$t" '"parentName":"RootObj"'

m="$("$B" members "$snif" Dog)"
has   "members Dog: own field"       "$m" '"name":"breed","kind":"fld","detail":"string"'
has   "members Dog: inherited field" "$m" '"name":"name","kind":"fld"'
has   "members Dog: UFCS proc"       "$m" '"name":"wag","kind":"proc","detail":"(Dog): bool"'
hasnt "members Dog: no lifecycle hooks" "$m" '=destroy'
mo="$("$B" members "$snif" Outer)"
has   "members Outer: field inner" "$mo" '"name":"inner","kind":"fld","detail":"Inner"'
hasnt "members Outer: not Inner's x" "$mo" '"name":"x"'
mc="$("$B" members "$snif" Color)"
has   "members Color: enum value" "$mc" '"name":"green","kind":"efld"'
hasnt "members Color: no synthesized helper" "$mc" 'dollar'

ta="$("$B" typeat "$snif" 20 11)"
has "typeat: o is Outer" "$ta" '"type":"Outer"'
has "typeat: nothing at col in blank line" "$("$B" typeat "$snif" 22 0)" '{}'

sv="$(printf '{"cmd":"decls","args":["%s","Dog"]}\n' "$snif" | "$B" serve)"
has "serve: decls over stdio" "$sv" '"name":"Dog"'

"$B" decls /no/such/file >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && echo "ok   missing file exits 2" || { echo "FAIL missing file exit code $rc"; fail=1; }

if [ "$fail" -eq 0 ]; then echo "aowllens tests: PASS"; else echo "aowllens tests: FAILURES"; fi
exit "$fail"
