## `aowllens outline <file>` — top-level named nodes (direct children of the root
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

proc isNameTok(k: NifKind): bool =
  k == SymbolDef or k == Symbol or k == Ident

proc run*(params: seq[string]): Res =
  if params.len < 1:
    return errRes("usage: aowllens outline <file>", 1)
  let path = params[0]
  if not fileExists(path):
    return errRes("no such file: " & path, 2)
  var items: seq[string] = @[]
  try:
    var buf = loadBuf(path)
    var c = beginRead(buf)
    if c.kind == ParLe:
      inc c                          # descend into the root's first child
      while c.kind != ParRi and c.kind != EofToken:
        if c.kind == ParLe:
          let declTok = c.load
          var son = firstSon(c)
          if isNameTok(son.kind):
            let symTok = son.load
            var sym = ""
            var name = ""
            if son.kind == Ident:
              sym = pool.strings[symTok.litId]
              name = sym
            else:
              sym = symName(symTok)
              name = baseName(sym)
              if name.len == 0: name = sym
            items.add "{\"tag\":" & jStr(tagName(declTok)) & ",\"name\":" &
              jStr(name) & ",\"sym\":" & jStr(sym) & posFragment(symTok) & "}"
          skip c
        else:
          inc c
    endRead buf
  except:
    items = @[]
  var arr = "["
  for i in 0 ..< items.len:
    if i > 0: arr.add ","
    arr.add items[i]
  arr.add "]"
  return okRes("{\"tags\":" & arr & "}")

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
    var depth = 0
    while items.len < MaxMatches:
      let k = c.kind
      if k == EofToken:
        break
      elif k == ParRi:
        dec depth
        inc c
        if depth <= 0: break
        continue
      elif k == ParLe:
        inc depth
        let tag = tagName(c.load)
        var name = ""
        var matched = needle.len > 0 and contains(tag, needle)
        var son = firstSon(c)
        if son.kind == SymbolDef:
          let sym = symName(son.load)
          name = baseName(sym)
          if not matched and needle.len > 0 and contains(sym, needle):
            matched = true
        if matched:
          var sub = c
          let snippet = truncateSnippet(toString(sub, false))
          items.add "{\"tag\":" & jStr(tag) & ",\"name\":" & jStr(name) &
            ",\"snippet\":" & jStr(snippet) & "}"
      inc c
    endRead buf
  except:
    items = @[]
  var arr = "["
  for i in 0 ..< items.len:
    if i > 0: arr.add ","
    arr.add items[i]
  arr.add "]"
  return okRes("{\"matches\":" & arr & "}")
