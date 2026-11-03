# aowllens

A **NIF lens for tooling, in nimony** — the nimony port of the (Nim 2) `aiflens`.
A thin CLI over Nimony's own NIF libraries that reads `nimcache/*.nif` artifacts
with the *real* parser and emits compact JSON for a host tool (e.g.
[aowllsp](https://github.com/aoughwl/aowllsp), the aowl-code plugin) to consume.

Because it links the compiler's NIF libraries (`nifprelude` / `nifcore` /
`nifpools` / `symparser` / `nifindexes`), its line-info decoding, symbol handling
and tag vocabulary always match the toolchain that produced the file — no regex
approximation.

## This fork: ported to the NIF 27 representation

Upstream is written against the pre-NIF-27 token stream: `(`/`)` pairs walked by
index, with each token carrying its own line info. The current toolchain emits
`TagLit` heads with a body-token count instead, line info rides a suffix token
readable only through a `Cursor`, and `nifprelude` no longer exports
`nifstreams`/`fromStream`. So this fork rebuilds the reading layer:

* `core.nim` parses one `Node` forest per artifact through cursors
  (`parseNode`/`parseForest`), capturing each value's tag, symbol, text and
  position once;
* every command's analysis is unchanged in intent and now runs on that forest —
  `decls`, `outline`/`query`, `calls`, `types` walk node kids instead of a tag
  stack over raw tokens, and `members`/`typeat`/`render` keep their existing
  logic over the shared node;
* `index` needed no change: `nifindexes.readIndex` still exposes
  `exports`/`converters`.

Verified against an artifact the installed `nimony` produced: all subcommands
emit well-formed JSON, and `aowllsp` returns completion items from `decls` and
`members`.

> **Why nimony?** The whole aowl stack is nimony-native and JS-compilable. The
> Nim-2 aiflens shelled out from a Nim-2 process; aowllens is nimony, so the same
> NIF-reading logic can eventually run **in-process** inside a nimony tool (or a
> browser IDE) instead of as a subprocess.

## Subcommands

```sh
aowllens decls   <file.s.nif> [symbol]   declaration sites {sym,name,kind,file,line,col}
aowllens render  <file.nif>   [needle]    pseudo-Nim rendering of top-level nodes
aowllens index   <file>                   interface index (.s.idx.nif): checksum/exports/converters
aowllens outline <file>                   top-level named nodes (names only)
aowllens query   <file> <needle>          subtrees whose tag or symbol matches
aowllens serve                            line-oriented stdio daemon (one JSON req/resp per line)
aowllens version
```

## Faithful to aiflens

`tests/difftest.sh` generates a real `.s.nif` with `nimony check` and compares
every command against the Nim-2 `aiflens` it replaces:

- `decls`, `outline`, `query`, `index` — **byte-identical**.
- `render` — identical **modulo the hex-case** of `\u00XX` escapes for
  control-character literals in the heuristic pretty-printer (aiflens is itself
  inconsistent there; aowllens is consistent lowercase, matching `std/json`).

## Build

```sh
NIMONY=/path/to/nimony/bin/nimony \
NIMONY_SRC=/path/to/nimony/src \
AOWLKIT=/path/to/aowlkit/src \
bash build.sh          # -> bin/aowllens
```

`NIMONY_SRC` must be the source tree of the *same* compiler build that produces
the artifacts, or the NIF libraries and the emitted format disagree.
`NIMONY_PARALLEL=N` caps the compiler's job count (default `0` = one per core).

Links Nimony's NIF libraries from `$NIMONY_SRC` (default `$HOME/nimony/src`) and
the shared [aowlkit](https://github.com/aoughwl/aowlkit) lib (`json`).

## Layout

| file | role |
|------|------|
| `src/aowllens.nim` | CLI entry + dispatch |
| `src/aowllenspkg/core.nim` | NIF loading + shared helpers (JSON via aowlkit) |
| `src/aowllenspkg/decls.nim` | declaration sites |
| `src/aowllenspkg/outline.nim` | outline + query |
| `src/aowllenspkg/index.nim` | interface index reading |
| `src/aowllenspkg/render.nim` | NIF → pseudo-Nim renderer |
| `src/aowllenspkg/serve.nim` | stdio daemon |
