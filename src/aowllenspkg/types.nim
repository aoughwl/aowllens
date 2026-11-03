## `aowllens types <file.s.nif> [symbol]` — one JSON object per OBJECT TYPE
## declaration and its direct inheritance parent:
## {type, name, parent, parentName, file, line, col}. `type` is the full type
## symbol of the object-bearing decl; `name`/`parentName` are the human base
## names (the auto-generated `.Obj` suffix nimony adds behind a `ref object` is
## stripped). `parent`/`parentName` are empty for a root/non-inheriting type.
## Feeds type-hierarchy tooling (e.g. aowllsp). If [symbol] is given, only types
## matching it (by full sym, prefix, or base name) are reported.

import std/[os, strutils]
include "nifprelude"
import core
import aowlkit/json

proc humanName(sym: string): string =
  ## Base name with the internal `.Obj` object-suffix removed (`Dog.Obj` -> `Dog`).
  result = baseName(sym)
  if result.endsWith(".Obj"):
    result.setLen(result.len - 4)

proc firstSym(n: Node): string =
  ## The first symbol name anywhere in `n` (depth-first) — the base symbol out
  ## of a wrapper like `(ref Base (notnil))`.
  if n.isAtom:
    if n.sym.len > 0: return n.sym
    return ""
  for k in n.kids:
    let s = firstSym(k)
    if s.len > 0: return s
  return ""

proc walk(n: Node; wanted: string; items: var seq[string]) =
  if n.isAtom: return
  if n.tag == "type":
    var symNode: Node
    var found = false
    for k in n.kids:
      if k.isAtom and k.isDef:
        symNode = k
        found = true
        break
    if found:
      for k in n.kids:
        if not k.isAtom and k.tag == "object":
          var parent = ""
          if k.kids.len > 0:
            let f = k.kids[0]
            if f.isAtom and f.kind == Symbol:
              parent = f.sym
            elif not f.isAtom:
              parent = firstSym(f)
          let name = humanName(symNode.sym)
          if wanted.len == 0 or symNode.sym == wanted or
              startsWith(symNode.sym, wanted) or name == wanted or
              baseName(symNode.sym) == wanted:
            let parentName = if parent.len > 0: humanName(parent) else: ""
            items.add "{\"type\":" & jStr(symNode.sym) & ",\"name\":" & jStr(name) &
              ",\"parent\":" & jStr(parent) & ",\"parentName\":" & jStr(parentName) &
              posFragment(symNode) & "}"
          break
  for k in n.kids:
    walk(k, wanted, items)

proc run*(params: seq[string]): Res =
  if params.len < 1:
    return errRes("usage: aowllens types <file.s.nif> [symbol]", 1)
  let path = params[0]
  let wanted = if params.len >= 2: params[1] else: ""
  if not fileExists(path):
    return errRes("no such file: " & path, 2)
  var items: seq[string] = @[]
  try:
    var buf = loadBuf(path)
    let forest = parseForest(buf)
    for r in forest:
      walk(r, wanted, items)
  except:
    items = @[]
  var arr = "["
  for i in 0 ..< items.len:
    if i > 0: arr.add ","
    arr.add items[i]
  arr.add "]"
  return okRes(arr)
