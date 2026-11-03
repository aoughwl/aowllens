## `aowllens calls <file.s.nif> [symbol]` — one JSON object per CALL expression
## found inside a routine body: {caller, callee, file, line, col}. `caller` is
## the enclosing routine's symbol; `callee` is the called symbol. Feeds
## call-hierarchy tooling (e.g. aowllsp outgoing calls). If [symbol] is given,
## only calls whose caller matches (by full sym, prefix, or basename) are
## reported.

import std/[os, strutils]
include "nifprelude"
import core
import lens
import aowlkit/json

proc isRoutineTag(t: string): bool =
  case t
  of "proc", "func", "method", "converter", "macro", "template", "iterator":
    true
  else:
    false

proc routineName(n: Node): string =
  ## The routine's own symbol: its first SymbolDef child.
  for k in n.kids:
    if k.isAtom and k.isDef: return k.sym
  return ""

proc walk(n: Node; caller, wanted: string; items: var seq[string]) =
  if n.isAtom: return
  var inner = caller
  if isRoutineTag(n.tag):
    let nm = routineName(n)
    if nm.len > 0: inner = nm
  elif n.tag == "call" and caller.len > 0:
    if n.kids.len > 0 and n.kids[0].isAtom and n.kids[0].kind == Symbol:
      let callee = n.kids[0].sym
      if wanted.len == 0 or caller == wanted or startsWith(caller, wanted) or
          baseName(caller) == wanted:
        items.add "{\"caller\":" & jStr(caller) & ",\"callee\":" & jStr(callee) &
          posFragment(n.kids[0]) & "}"
  for k in n.kids:
    walk(k, inner, wanted, items)

proc run*(params: seq[string]): Res =
  if params.len < 1:
    return errRes("usage: aowllens calls <file.s.nif> [symbol]", 1)
  let path = params[0]
  let wanted = if params.len >= 2: params[1] else: ""
  if not fileExists(path):
    return errRes("no such file: " & path, 2)

  # aowlsem's index carries the edges directly: an occurrence marked "call"
  # names the callee, its owner names the caller, and the position is the call
  # site. That is the same graph the walk below reconstructs — but the walk
  # takes its positions from the emitted tokens, which on an aowlsem artifact
  # carry none, so there the index is the only source of a usable edge.
  let lx = lens.load(path)
  if lx.ok:
    var edges: seq[string] = @[]
    for i in 0 ..< lx.uses.len:
      let u = lx.uses[i]
      if u.role != "call" or u.owner.len == 0: continue
      if wanted.len > 0 and not (u.owner == wanted or startsWith(u.owner, wanted) or
                                 baseName(u.owner) == wanted): continue
      edges.add "{\"caller\":" & jStr(u.owner) & ",\"callee\":" & jStr(u.sym) &
        ",\"file\":" & jStr(u.file) & ",\"line\":" & $u.line &
        ",\"col\":" & $u.col & "}"
    if edges.len > 0:
      var acc = "["            # `out` is a keyword here, not a variable name
      for i in 0 ..< edges.len:
        if i > 0: acc.add ","
        acc.add edges[i]
      acc.add "]"
      return okRes(acc)

  var items: seq[string] = @[]
  try:
    var buf = loadBuf(path)
    let forest = parseForest(buf)
    for r in forest:
      walk(r, "", wanted, items)
  except:
    items = @[]
  var arr = "["
  for i in 0 ..< items.len:
    if i > 0: arr.add ","
    arr.add items[i]
  arr.add "]"
  return okRes(arr)
