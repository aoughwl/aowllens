## `aowllens outline <file>` — top-level named nodes (children of the root
## `(stmts …)` whose first child is a name). `aowllens query <file> <needle>` —
## subtrees whose head tag OR contained SymbolDef matches `needle`.

import std/[os, strutils]
include "nifprelude"
import core
import aowlkit/json

const
  MaxMatches = 200
  MaxLines = 40

proc truncateSnippet(s: string): string =
  let lines = splitLines(s)
  if lines.len <= MaxLines:
    result = s
  else:
    var head: seq[string] = @[]
    for i in 0 ..< MaxLines: head.add lines[i]
    result = joinSeq(head, "\n") & "\n ..."

proc isNameNode(n: Node): bool =
  n.isAtom and (n.kind == SymbolDef or n.kind == Symbol or n.kind == Ident)

proc run*(params: seq[string]): Res =
  if params.len < 1:
    return errRes("usage: aowllens outline <file>", 1)
  let path = params[0]
  if not fileExists(path):
    return errRes("no such file: " & path, 2)
  var items: seq[string] = @[]
  try:
    var buf = loadBuf(path)
    let forest = parseForest(buf)
    let root = rootOf(forest)
    if not root.isEmpty and not root.isAtom:
      for c in root.kids:
        if c.isAtom or c.kids.len == 0: continue
        let son = c.kids[0]
        if not isNameNode(son): continue
        var sym = ""
        var name = ""
        if son.kind == Ident:
          sym = son.atom
          name = sym
        else:
          sym = son.sym
          name = baseName(sym)
          if name.len == 0: name = sym
        items.add "{\"tag\":" & jStr(c.tag) & ",\"name\":" & jStr(name) &
          ",\"sym\":" & jStr(sym) & posFragment(son) & "}"
  except:
    items = @[]
  var arr = "["
  for i in 0 ..< items.len:
    if i > 0: arr.add ","
    arr.add items[i]
  arr.add "]"
  return okRes("{\"tags\":" & arr & "}")

proc containsSymDef(n: Node; needle: string): string =
  ## The first SymbolDef base name anywhere in `n` that matches `needle`.
  if n.isAtom:
    if n.isDef and contains(n.sym, needle): return baseName(n.sym)
    return ""
  for k in n.kids:
    let r = containsSymDef(k, needle)
    if r.len > 0: return r
  return ""

proc walkQuery(c: var Cursor; needle: string; items: var seq[string]) =
  ## Depth-first over the raw cursors, so a match can be rendered by the real
  ## NIF printer (`toString`) rather than reconstructed from the tree.
  c.loopInto:
    if c.kind == TagLit:
      var head = c
      let tag = tagName(head)
      var name = ""
      var matched = needle.len > 0 and contains(tag, needle)
      var son = c
      inc son
      if son.hasMore and son.kind == SymbolDef:
        let sym = symName(son)
        name = baseName(sym)
        if not matched and needle.len > 0 and contains(sym, needle):
          matched = true
      if matched:
        var sub = c
        items.add "{\"tag\":" & jStr(tag) & ",\"name\":" & jStr(name) &
          ",\"snippet\":" & jStr(truncateSnippet(toString(sub, false))) & "}"
    skip c

proc runQuery*(params: seq[string]): Res =
  if params.len < 2:
    return errRes("usage: aowllens query <file> <needle>", 1)
  let path = params[0]
  let needle = params[1]
  if not fileExists(path):
    return errRes("no such file: " & path, 2)
  var items: seq[string] = @[]
  try:
    var buf = loadBuf(path)
    var c = beginRead(buf)
    while c.hasMore and items.len < MaxMatches:
      walkQuery(c, needle, items)
      skip c
  except:
    items = @[]
  var arr = "["
  for i in 0 ..< items.len:
    if i > 0: arr.add ","
    arr.add items[i]
  arr.add "]"
  return okRes("{\"matches\":" & arr & "}")
