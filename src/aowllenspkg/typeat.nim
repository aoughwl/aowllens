## `aowllens typeat <file.s.nif> <line> <col>` — the type at a source position.
##
## Resolves the SYMBOL at (line, col) in the sem'd NIF and reports its type as a
## human base name: `{"type":"Dog","sym":"rex.0.m"}`, or `{}` when nothing
## resolves. line is 1-based, col 0-based (the idetools / posFragment convention).
##
## This is the primitive that makes member completion work for EXPRESSIONS, not
## just bare names: the position under `a.b.` lands on the field symbol `b`, whose
## type is looked up directly — so `a.b.c.` chains and shadowed names resolve
## precisely (each occurrence carries its own resolved symbol + position), which a
## by-name lookup cannot do. A binding/param/field resolves to its declared type;
## a routine resolves to its return type (a call callee).

import std/[os, strutils]
include "nifprelude"
import core
import aowlkit/json

type
  Node = object
    tag: string
    sym: string
    isDef: bool
    kids: seq[Node]
  Pair = object
    a: string      ## full symbol id
    b: string      ## type base name

const
  BindingTags = ["let", "var", "gvar", "glet", "const", "cursor", "param",
                 "tvar", "fld", "efld"]
  RoutineTags = ["proc", "func", "method", "converter", "iterator",
                 "template", "macro"]

proc parseNode(buf: TokenBuf; i: var int): Node =
  let tok = buf[i]
  case tok.kind
  of ParLe:
    result = Node(tag: tagName(tok), sym: "", isDef: false, kids: @[])
    inc i
    while i < buf.len and buf[i].kind != ParRi:
      result.kids.add parseNode(buf, i)
    if i < buf.len: inc i
  of Symbol:
    result = Node(tag: "", sym: symName(tok), isDef: false, kids: @[])
    inc i
  of SymbolDef:
    result = Node(tag: "", sym: symName(tok), isDef: true, kids: @[])
    inc i
  else:
    result = Node(tag: "", sym: "", isDef: false, kids: @[])
    inc i

proc among(s: string; xs: openArray[string]): bool =
  for i in 0 ..< xs.len:
    if xs[i] == s: return true
  return false

proc human(name: string): string =
  result = name
  if result.endsWith(".Obj"): result.setLen(result.len - 4)

proc firstSym(n: Node): string =
  if n.sym.len > 0: return n.sym
  for k in 0 ..< n.kids.len:
    let s = firstSym(n.kids[k])
    if s.len > 0: return s
  return ""

proc builtinName(tag: string): string =
  case tag
  of "i": "int"
  of "u": "uint"
  of "f": "float"
  of "bool": "bool"
  of "c": "char"
  of "cstring": "cstring"
  of "pointer": "pointer"
  else: ""

proc baseType(typeNode: Node): string =
  ## Type key: named type → base name; wrapper (ref/ptr/var/…) → wrapped type;
  ## container (seq/array/…) → the constructor (so `seq[Cell]` keys on `seq`, not
  ## the element); primitive → friendly name; else "". Kept in sync with members.nim.
  if typeNode.sym.len > 0: return human(baseName(typeNode.sym))
  let t = typeNode.tag
  if t == "ref" or t == "ptr" or t == "mut" or t == "var" or t == "out" or
     t == "lent" or t == "sink" or t == "typedesc":
    for k in 0 ..< typeNode.kids.len:
      let inner = baseType(typeNode.kids[k])
      if inner.len > 0: return inner
    return ""
  if t == "seq" or t == "array" or t == "openArray" or t == "uarray" or
     t == "set" or t == "varargs":
    return t
  let b = builtinName(t)
  if b.len > 0: return b
  let s = firstSym(typeNode)
  if s.len > 0: return human(baseName(s))
  return ""

proc findByTag(n: Node; tags: openArray[string]): int =
  for k in 0 ..< n.kids.len:
    if among(n.kids[k].tag, tags): return k
  return -1

proc lookup(xs: seq[Pair]; k: string): string =
  for i in 0 ..< xs.len:
    if xs[i].a == k: return xs[i].b
  return ""

proc contains(xs: seq[string]; k: string): bool =
  for i in 0 ..< xs.len:
    if xs[i] == k: return true
  return false

proc build(n: Node; symType: var seq[Pair]; procRet: var seq[Pair];
           typeNames: var seq[string]) =
  ## Map every decl symbol to its type: a binding/param/field to its declared
  ## type (child index 3), a routine to its return type (the child after params);
  ## and record type-decl names so a bare type reference resolves to itself.
  if among(n.tag, BindingTags):
    if n.kids.len > 3 and n.kids[0].isDef:
      let t = baseType(n.kids[3])
      if t.len > 0: symType.add Pair(a: n.kids[0].sym, b: t)
  elif n.tag == "type":
    if n.kids.len > 0 and n.kids[0].isDef:
      typeNames.add human(baseName(n.kids[0].sym))
  elif among(n.tag, RoutineTags):
    if n.kids.len > 0 and n.kids[0].isDef:
      let pi = findByTag(n, ["params"])
      if pi >= 0 and pi + 1 < n.kids.len:
        let t = baseType(n.kids[pi + 1])
        if t.len > 0: procRet.add Pair(a: n.kids[0].sym, b: t)
  for k in 0 ..< n.kids.len:
    build(n.kids[k], symType, procRet, typeNames)

proc run*(params: seq[string]): Res =
  if params.len < 3:
    return errRes("usage: aowllens typeat <file.s.nif> <line> <col>", 1)
  let path = params[0]
  var wantLine = 0
  var wantCol = 0
  try:
    wantLine = parseInt(params[1])
    wantCol = parseInt(params[2])
  except:
    return errRes("line and col must be integers", 1)
  if not fileExists(path):
    return errRes("no such file: " & path, 2)
  let buf = loadBuf(path)

  # Resolution tables from the parsed forest.
  var roots: seq[Node] = @[]
  var i = 0
  while i < buf.len:
    roots.add parseNode(buf, i)
  var symType: seq[Pair] = @[]
  var procRet: seq[Pair] = @[]
  var typeNames: seq[string] = @[]
  for r in 0 ..< roots.len:
    build(roots[r], symType, procRet, typeNames)

  # Find the symbol token at (line, col): the symbol whose start is at or nearest
  # to the left of the cursor on that line (an identifier the cursor sits on/after).
  var bestSym = ""
  var bestCol = -1
  for k in 0 ..< buf.len:
    let tok = buf[k]
    if tok.kind != Symbol and tok.kind != SymbolDef: continue
    let inf = unpack(pool.man, tok.info)
    if not inf.file.isValid: continue
    if int(inf.line) != wantLine: continue
    let c = int(inf.col)
    if c <= wantCol and c > bestCol:
      bestCol = c
      bestSym = symName(tok)

  if bestSym.len == 0:
    return okRes("{}")

  # Resolve: a value symbol → its declared type; a routine → its return type; a
  # type symbol → itself.
  var typeName = lookup(symType, bestSym)
  if typeName.len == 0:
    typeName = lookup(procRet, bestSym)
  if typeName.len == 0:
    # the symbol may itself name a type — only then does its base name resolve.
    let bn = human(baseName(bestSym))
    if contains(typeNames, bn): typeName = bn
  if typeName.len == 0:
    return okRes("{}")
  return okRes("{\"type\":" & jStr(typeName) & ",\"sym\":" & jStr(bestSym) & "}")
