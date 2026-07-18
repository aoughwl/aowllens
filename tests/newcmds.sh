#!/usr/bin/env bash
# newcmds.sh — functional tests for the `members` and `typeat` commands (the
# type-directed seam aowllsp completion rides on). Self-contained: builds a real
# `.s.nif` with `nimony check` and asserts the resolved members / types. Skips
# cleanly if nimony is unavailable.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
B="${AOWLLENS:-$ROOT/bin/aowllens}"
NIMONY="${NIMONY:-$HOME/nimony/bin/nimony}"
[ -x "$B" ] || { echo "building aowllens ..."; bash "$ROOT/build.sh" >/dev/null || exit 1; }
[ -x "$NIMONY" ] || { echo "newcmds: nimony not found — skipping"; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/s.nim" <<'EOF'
type
  Animal = ref object of RootObj
    name: string
  Dog = ref object of Animal
    breed: string
  Inner = object
    x: int
    y: int
  Outer = object
    inner: Inner
    tag: string

proc wag(d: Dog): bool = true

proc use(o: Outer; d: Dog) =
  discard o.inner.x
  discard d.breed
EOF
( cd "$WORK" && "$NIMONY" check --nimcache:"$WORK/nc" s.nim >/dev/null 2>&1 || true )
# nimony emits one .s.nif per module (system + deps + ours); pick OURS — the one
# that actually declares the sample's types.
snif=""
for f in $(find "$WORK/nc" -name '*.s.nif' ! -name '*.idx.nif'); do
  if grep -q 'Outer' "$f" && grep -q 'Inner' "$f"; then snif="$f"; break; fi
done
[ -n "$snif" ] || { echo "newcmds: could not produce our .s.nif — skipping"; exit 0; }

fail=0
has() {  # has <label> <json> <needle>
  if grep -q "$3" <<<"$2"; then echo "✅ $1"; else echo "❌ $1: missing '$3' in $2"; fail=1; fi
}
hasnt() {
  if grep -q "$3" <<<"$2"; then echo "❌ $1: unexpected '$3' in $2"; fail=1; else echo "✅ $1"; fi
}

# members: Dog offers its own field, the inherited Animal field, and the UFCS proc.
mDog="$("$B" members "$snif" Dog 2>&1)"
has   "members Dog: own field breed"      "$mDog" '"name":"breed"'
has   "members Dog: inherited field name" "$mDog" '"name":"name"'
has   "members Dog: UFCS proc wag"        "$mDog" '"name":"wag"'
hasnt "members Dog: no lifecycle hooks"   "$mDog" '=destroy'

# members: Outer offers its fields (and NOT Inner's).
mOuter="$("$B" members "$snif" Outer 2>&1)"
has   "members Outer: field inner" "$mOuter" '"name":"inner"'
has   "members Outer: field tag"   "$mOuter" '"name":"tag"'
hasnt "members Outer: not Inner's x" "$mOuter" '"name":"x"'

# typeat: positions in `  discard o.inner.x` (line 16). Columns are 0-based:
#   'o'=10  'inner'=12  'x'=18 . Each resolves through the chain.
line=16
has "typeat o -> Outer"     "$("$B" typeat "$snif" $line 10 2>&1)" '"type":"Outer"'
has "typeat o.inner -> Inner" "$("$B" typeat "$snif" $line 12 2>&1)" '"type":"Inner"'
has "typeat o.inner.x -> int" "$("$B" typeat "$snif" $line 18 2>&1)" '"type":"int"'

# ── container consistency (a `seq[Item]` field keys on the CONSTRUCTOR) ────────
# A bare container must resolve to `seq` (its own ops), never to its element —
# otherwise `xs.` would wrongly offer the element's fields. The INDEXED element
# still resolves to the element type via the `[]` operator.
cat > "$WORK/c.nim" <<'EOF'
type
  Item = object
    v: int
  Bag = object
    items: seq[Item]

proc use(b: Bag) =
  discard b.items[0].v
EOF
( cd "$WORK" && "$NIMONY" check --nimcache:"$WORK/nc2" c.nim >/dev/null 2>&1 || true )
csnif=""
for f in $(find "$WORK/nc2" -name '*.s.nif' ! -name '*.idx.nif'); do
  if grep -q 'Bag' "$f" && grep -q 'Item' "$f"; then csnif="$f"; break; fi
done
if [ -n "$csnif" ]; then
  mBag="$("$B" members "$csnif" Bag 2>&1)"
  has   "members Bag: seq field details as 'seq'" "$mBag" '"name":"items","kind":"fld","detail":"seq"'
  hasnt "members Bag: no element-field leakage (v)" "$mBag" '"name":"v"'
  # line 8 `  discard b.items[0].v`: 'b'=10, 'items'=12 (the '[]' element)
  has "typeat b -> Bag"            "$("$B" typeat "$csnif" 8 10 2>&1)" '"type":"Bag"'
  has "typeat b.items[0] -> Item"  "$("$B" typeat "$csnif" 8 12 2>&1)" '"type":"Item"'
else
  echo "newcmds: container fixture skipped (no .s.nif)"
fi

if [ "$fail" -eq 0 ]; then echo "newcmds: PASS"; else echo "newcmds: FAILURES above"; fi
exit "$fail"
