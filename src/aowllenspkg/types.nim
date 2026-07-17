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

type
  TypeDecl = object
    depth: int    ## tagStack length at the `type` ParLe
    sym: string   ## the type's SymbolDef (empty until seen)
    pos: string   ## posFragment of the SymbolDef token
    done: bool    ## an object node has already been captured for this decl

proc run*(params: seq[string]): Res =
  if params.len < 1:
    return errRes("usage: aowllens types <file.s.nif> [symbol]", 1)
  let path = params[0]
  let wanted = if params.len >= 2: params[1] else: ""
  if not fileExists(path):
    return errRes("no such file: " & path, 2)
  let buf = loadBuf(path)
  var tagStack: seq[string] = @[]
  var types: seq[TypeDecl] = @[]
  var items: seq[string] = @[]
  for i in 0 ..< buf.len:
    let tok = buf[i]
    case tok.kind
    of ParLe:
      let t = tagName(tok)
      tagStack.add t
      if t == "type":
        types.add TypeDecl(depth: tagStack.len, sym: "", pos: "", done: false)
      elif t == "object" and types.len > 0 and not types[types.len - 1].done and
          types[types.len - 1].depth == tagStack.len - 1:
        # This `object` node is the body of the current type decl. Its parent is
        # the token right after the `object` tag: a Symbol (direct base), a
        # nested node like `(ref Base (notnil))` (parent is the first Symbol
        # inside), or `.` (no parent).
        var parent = ""
        if i + 1 < buf.len:
          let nt = buf[i+1]
          if nt.kind == Symbol:
            parent = symName(nt)
          elif nt.kind == ParLe:
            var j = i + 2
            var d = 1
            while j < buf.len and d > 0:
              case buf[j].kind
              of ParLe: inc d
              of ParRi: dec d
              of Symbol:
                parent = symName(buf[j]); break
              else: discard
              inc j
        let td = types[types.len - 1]
        types[types.len - 1].done = true
        let name = humanName(td.sym)
        if wanted.len == 0 or td.sym == wanted or startsWith(td.sym, wanted) or
            name == wanted or baseName(td.sym) == wanted:
          let parentName = if parent.len > 0: humanName(parent) else: ""
          items.add "{\"type\":" & jStr(td.sym) & ",\"name\":" & jStr(name) &
            ",\"parent\":" & jStr(parent) & ",\"parentName\":" & jStr(parentName) &
            td.pos & "}"
    of ParRi:
      if types.len > 0 and types[types.len - 1].depth == tagStack.len:
        types.setLen(types.len - 1)
      if tagStack.len > 0: tagStack.setLen(tagStack.len - 1)
    of SymbolDef:
      if types.len > 0 and types[types.len - 1].sym.len == 0 and
          types[types.len - 1].depth == tagStack.len:
        types[types.len - 1].sym = symName(tok)
        types[types.len - 1].pos = posFragment(tok)
    else:
      discard
  var arr = "["
  for i in 0 ..< items.len:
    if i > 0: arr.add ","
    arr.add items[i]
  arr.add "]"
  return okRes(arr)
