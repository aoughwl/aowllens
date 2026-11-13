#!/usr/bin/env bash
# Build bin/aowllens.exe with the aowlmony compiler.
#
# Overrides: AOWLMONY_ROOT (toolchain root; default ~/dev/toolchain/aowlmony/root),
#            AOWLJSONREF (jsonref src dir; default ~/dev/jsonref/src).
#
# The compiler exits 0 even when it produced no executable, and writes the exe
# into nimcache/<hash>/. So: delete any cached exe first, build (retrying once,
# because the shared static cache can make one build fail spuriously), then
# treat "no exe found" as the failure and copy the exe to bin/aowllens.exe.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AOWLMONY_ROOT="${AOWLMONY_ROOT:-$HOME/dev/toolchain/aowlmony/root}"
JSONREF="${AOWLJSONREF:-$HOME/dev/jsonref/src}"
COMPILER="$AOWLMONY_ROOT/bin/aowlmony.exe"
[[ -x "$COMPILER" ]] || { echo "build.sh: no compiler at $COMPILER" >&2; exit 1; }
if command -v cygpath >/dev/null 2>&1; then
  export AOWLMONY_ROOT="$(cygpath -w "$AOWLMONY_ROOT")"
  LIBS="$(cygpath -m "$AOWLMONY_ROOT/src/lib")"
  JSONREF="$(cygpath -m "$JSONREF")"
else
  export AOWLMONY_ROOT
  LIBS="$AOWLMONY_ROOT/src/lib"
fi
cd "$ROOT/src"
mkdir -p "$ROOT/bin"
ok=0
for attempt in 1 2; do
  rm -f "$ROOT"/src/nimcache/*/aowllens.exe 2>/dev/null || true
  "$COMPILER" c -d:release --path:"$LIBS" --path:"$JSONREF" --path:"$ROOT/src" aowllens.aowl \
    >"$ROOT/bin/build.log" 2>&1 || true
  exe="$(ls -t "$ROOT"/src/nimcache/*/aowllens.exe 2>/dev/null | head -1 || true)"
  if [[ -n "$exe" ]]; then cp "$exe" "$ROOT/bin/aowllens.exe"; ok=1; break; fi
done
if [[ $ok -eq 1 ]]; then
  rm -f "$ROOT/bin/build.log"; echo "built bin/aowllens.exe"
else
  echo "build.sh: FAILED, no aowllens.exe produced (see bin/build.log)" >&2
  grep -E 'Error' "$ROOT/bin/build.log" | head -20 >&2 || true
  exit 1
fi
