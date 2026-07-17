#!/usr/bin/env bash
# Build aowllens with the Nimony compiler. It links Nimony's own NIF libraries
# (nifprelude/nifstreams/symparser/nifindexes from the compiler tree) and the
# shared aowlkit lib.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIMONY="${NIMONY:-$HOME/nimony/bin/nimony}"
NIMSRC="${NIMONY_SRC:-$HOME/nimony/src}"
AOWLKIT="${AOWLKIT:-$HOME/aowlkit/src}"
LOCK="${NIMONY_BUILD_LOCK:-$HOME/.nimony-build.lock}"
cd "$ROOT"

build() {
  "$NIMONY" c --base:src -p:"$NIMSRC/lib" -p:"$NIMSRC" -p:"$AOWLKIT" \
    -d:nimony src/aowllens.nim 2>&1
}

run_locked() {
  if command -v flock >/dev/null 2>&1; then exec 9>"$LOCK"; flock 9; fi
  build
}

log="$(run_locked)"; rc=$?
if [ $rc -ne 0 ] || grep -qE '(^|[^a-zA-Z])Error:' <<<"$log"; then
  echo "$log" | grep -E 'Error:' | head -30
  echo "BUILD-FAIL"; echo "BUILD-DONE"; exit 1
fi
mkdir -p bin
exe="$(find nimcache -type f -name aowllens -executable -printf '%T@ %p\n' 2>/dev/null \
       | sort -rn | head -1 | cut -d' ' -f2-)"
[ -n "${exe:-}" ] || { echo "build.sh: no aowllens binary" >&2; echo "BUILD-FAIL"; echo "BUILD-DONE"; exit 1; }
cp "$exe" bin/aowllens
echo "built bin/aowllens"; echo "BUILD-OK"; echo "BUILD-DONE"
