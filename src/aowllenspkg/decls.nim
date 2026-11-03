## `aowllens decls <file.s.nif> [symbol]` — one JSON object per SymbolDef:
## {sym, name, kind, file, line, col}. `kind` is the enclosing NIF tag.

import std/[os, strutils]
import core
import aowlkit/json

proc walk(n: Node; wanted: string; items: var seq[string]) =
  ## A SymbolDef is a declaration of the tag that directly encloses it, so its
  ## kind is that tag; recurse everywhere else.
  if n.isAtom: return
  for k in n.kids:
    if k.isAtom and k.isDef:
      let sym = k.sym
      let name = baseName(sym)
      if wanted.len > 0 and not (sym == wanted or startsWith(sym, wanted) or
                                 name == wanted):
        continue
      items.add "{\"sym\":" & jStr(sym) & ",\"name\":" & jStr(name) &
        ",\"kind\":" & jStr(n.tag) & posFragment(k) & "}"
  for k in n.kids:
    walk(k, wanted, items)

proc run*(params: seq[string]): Res =
  if params.len < 1:
    return errRes("usage: aowllens decls <file.s.nif> [symbol]", 1)
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
