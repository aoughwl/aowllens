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
import lens
import aowlkit/json

type
  Pair = object
    a: string      ## full symbol id
    b: string      ## type base name

const
  BindingTags = ["let", "var", "gvar", "glet", "const", "cursor", "param",
                 "tvar", "fld", "efld"]
  RoutineTags = ["proc", "func", "method", "converter", "iterator",
                 "template", "macro"]

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
  if typeNode.isAtom:
    if typeNode.sym.len > 0: return human(baseName(typeNode.sym))
    return ""
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

proc nearestSym(n: Node; wantLine, wantCol: int; sym: var string;
                bestCol: var int) =
  ## The symbol atom whose start is at or nearest to the LEFT of the cursor on
  ## that line (an identifier the cursor sits on or just after).
  if n.isAtom:
    if n.kind == Symbol or n.kind == SymbolDef:
      if n.line == wantLine and n.col <= wantCol and n.col > bestCol:
        bestCol = n.col
        sym = n.sym
    return
  for k in n.kids:
    nearestSym(k, wantLine, wantCol, sym, bestCol)

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

  # THE INDEX FIRST. When aowlsem wrote a sidecar, the answer is recorded
  # rather than reconstructed: the occurrence at this position already names
  # the symbol it resolved to, so shadowing, overloads and dot chains are
  # decided by the checker and not re-decided here. Falls through to the tree
  # analysis below when there is no sidecar, or when it has nothing at this
  # position (an imported symbol is declared in ITS module's index, not ours).
  let lx = lens.load(path)
  if lx.ok:
    let sym = lens.symAt(lx, wantLine, wantCol)
    if sym.len > 0:
      let t = lens.typeOf(lx, sym)
      if t.len > 0:
        return okRes("{\"type\":" & jStr(t) & ",\"sym\":" & jStr(sym) & "}")

  var symType: seq[Pair] = @[]
  var procRet: seq[Pair] = @[]
  var typeNames: seq[string] = @[]
  var bestSym = ""
  var bestCol = -1
  try:
    var buf = loadBuf(path)
    let forest = parseForest(buf)
    for r in forest:
      build(r, symType, procRet, typeNames)
    for r in forest:
      nearestSym(r, wantLine, wantCol, bestSym, bestCol)
  except:
    return okRes("{}")

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
