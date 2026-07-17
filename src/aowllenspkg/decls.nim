## `aowllens decls <file.s.nif> [symbol]` — one JSON object per SymbolDef:
## {sym, name, kind, file, line, col}. `kind` is the enclosing NIF tag.

import std/[os, strutils]
include "nifprelude"
import core
import aowlkit/json

proc run*(params: seq[string]): Res =
  if params.len < 1:
    return errRes("usage: aowllens decls <file.s.nif> [symbol]", 1)
  let path = params[0]
  let wanted = if params.len >= 2: params[1] else: ""
  if not fileExists(path):
    return errRes("no such file: " & path, 2)
  let buf = loadBuf(path)
  var tagStack: seq[string] = @[]
  var items: seq[string] = @[]
  for i in 0 ..< buf.len:
    let tok = buf[i]
    case tok.kind
    of ParLe:
      tagStack.add tagName(tok)
    of ParRi:
      if tagStack.len > 0: tagStack.setLen(tagStack.len - 1)
    of SymbolDef:
      let sym = symName(tok)
      let name = baseName(sym)
      if wanted.len > 0 and not (sym == wanted or startsWith(sym, wanted) or
                                 name == wanted):
        continue
      let kind = if tagStack.len > 0: tagStack[tagStack.len - 1] else: ""
      items.add "{\"sym\":" & jStr(sym) & ",\"name\":" & jStr(name) &
        ",\"kind\":" & jStr(kind) & posFragment(tok) & "}"
    else:
      discard
  var arr = "["
  for i in 0 ..< items.len:
    if i > 0: arr.add ","
    arr.add items[i]
  arr.add "]"
  return okRes(arr)
