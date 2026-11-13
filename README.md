# aowllens

A NIF lens for tooling, written in aowlmony. A thin CLI over the toolchain's own
NIF libraries (`nifprelude`, `nifstreams`, `symparser`, `nifindexes`) that reads
the artifacts the aowlmony compiler leaves in `nimcache/` with the real parser
and prints compact JSON for a host tool to consume (the aowllsp language server
in the aowlcode plugin calls it as `aowllens.exe <subcommand>`).

Because it links the compiler's own libraries, line-info decoding, symbol
handling and the tag vocabulary always match the compiler that produced the
file.

## Subcommands

```sh
aowllens decls   <file.s.nif> [symbol]   declaration sites {sym,name,kind,file,line,col}
aowllens render  <file.nif>   [needle]   pseudo-source rendering of top-level nodes
aowllens index   <file>                  interface index (.s.idx.nif): checksum/exports/converters
aowllens outline <file>                  top-level named nodes (names only)
aowllens query   <file> <needle>         subtrees whose tag or symbol matches
aowllens calls   <file.s.nif> [symbol]   call edges {caller,callee,file,line,col}
aowllens types   <file.s.nif> [symbol]   object types and their parent
aowllens members <file.s.nif> <receiver> completion members for `receiver.`
aowllens typeat  <file.s.nif> <line> <col>  type of the symbol at a position
aowllens serve                           line-oriented stdio daemon (one JSON req/resp per line)
aowllens version
```

Exit codes: 1 usage error, 2 no such file. Errors go to stderr.

## Artifacts it reads

The aowlmony compiler writes flat files into `nimcache/` (the directory name is
imposed by the compiler), one set per module, named by a module hash:

| file | what | read by |
|------|------|---------|
| `<hash>.s.nif` | semantically checked tree | decls, render, outline, query, calls, types, members, typeat |
| `<hash>.s.idx.nif` | interface index: `(checksum ..)`, `(export ..)`, `(converter ..)` | index |
| `<hash>.lens.nif` | optional semantic sidecar | members, calls, typeat (used when present, ignored otherwise) |

Mapping notes, found by inspecting real aowlmony output:

- The same tag vocabulary the tools were written for is emitted (`type`, `proc`,
  `param`, `fld`, `efld`, `object`, `ref`, `call`, `cmd`, ...). A `ref object`
  is a `Name` type wrapping `(ref Name.Obj ..)` plus a separate `Name.Obj` type
  holding the `object`; the `.Obj` suffix is stripped from reported names.
- Line info is decoded by the compiler's own library, so `file` is the source
  file name as the compiler recorded it, `line` is 1-based, `col` 0-based.
- The compiler synthesizes lifecycle hooks (`=destroy`, `=copy`, ...) per type
  and enum helpers named like ``dollar`.Color``. `members` hides both. `decls`
  and `calls` report them as they are; hook edges carry the type's position.
- The `export` entries in `.s.idx.nif` hold a module path, reported as an
  `exports` item of kind `export`.

## Build and test

```sh
bash build.sh        # -> bin/aowllens.exe (fails loudly when no exe is produced)
bash tests/test.sh   # compiles tests/fixture/shapes.aowl and drives every subcommand
```

`build.sh` uses `AOWLMONY_ROOT` (default `~/dev/toolchain/aowlmony/root`) and
puts `$AOWLMONY_ROOT/src/lib` on the path for the NIF libraries. The compiler
exits 0 even when it produced no executable, so the script deletes the cached
exe first, retries once (the shared static cache can fail a build spuriously),
and treats a missing exe as the failure.

## Layout

| file | role |
|------|------|
| `src/aowllens.aowl` | CLI entry + dispatch |
| `src/aowllenspkg/core.aowl` | NIF loading, JSON string helper, result type |
| `src/aowllenspkg/decls.aowl` | declaration sites |
| `src/aowllenspkg/outline.aowl` | outline + query |
| `src/aowllenspkg/index.aowl` | interface index reading |
| `src/aowllenspkg/render.aowl` | NIF to pseudo-source renderer |
| `src/aowllenspkg/calls.aowl`, `types.aowl`, `members.aowl`, `typeat.aowl` | call graph, type hierarchy, completion members, type at position |
| `src/aowllenspkg/lens.aowl` | reader for the optional `.lens.nif` sidecar |
| `src/aowllenspkg/serve.aowl` | stdio daemon |
