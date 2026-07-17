## `aowllens calls <file.s.nif> [symbol]` — one JSON object per CALL expression
## found inside a routine body: {caller, callee, file, line, col}. `caller` is the
## enclosing routine's symbol; `callee` is the called symbol. Feeds call-hierarchy
## tooling (e.g. aowllsp outgoing calls). If [symbol] is given, only calls whose
## caller matches (by full sym, prefix, or basename) are reported.

import std/[os, strutils]
include "nifprelude"
import core
import aowlkit/json

proc isRoutineTag(t: string): bool =
  case t
  of "proc", "func", "method", "converter", "macro", "template", "iterator":
    true
  else:
    false

type
  Routine = object
    depth: int      ## tagStack length at the routine's ParLe
    caller: string  ## the routine's own symbol (empty until its SymbolDef seen)

proc run*(params: seq[string]): Res =
  if params.len < 1:
    return errRes("usage: aowllens calls <file.s.nif> [symbol]", 1)
  let path = params[0]
  let wanted = if params.len >= 2: params[1] else: ""
  if not fileExists(path):
    return errRes("no such file: " & path, 2)
  let buf = loadBuf(path)
  var tagStack: seq[string] = @[]
  var routines: seq[Routine] = @[]
  var items: seq[string] = @[]
  for i in 0 ..< buf.len:
    let tok = buf[i]
    case tok.kind
    of ParLe:
      let t = tagName(tok)
      tagStack.add t
      if isRoutineTag(t):
        routines.add Routine(depth: tagStack.len, caller: "")
      elif t == "call":
        # callee is the immediately-following token when it is a Symbol.
        if i + 1 < buf.len and buf[i+1].kind == Symbol and routines.len > 0:
          let caller = routines[routines.len - 1].caller
          let callee = symName(buf[i+1])
          if caller.len > 0 and (wanted.len == 0 or caller == wanted or
              startsWith(caller, wanted) or baseName(caller) == wanted):
            items.add "{\"caller\":" & jStr(caller) &
              ",\"callee\":" & jStr(callee) & posFragment(buf[i+1]) & "}"
    of ParRi:
      if routines.len > 0 and routines[routines.len - 1].depth == tagStack.len:
        routines.setLen(routines.len - 1)
      if tagStack.len > 0: tagStack.setLen(tagStack.len - 1)
    of SymbolDef:
      # The routine's own name: first SymbolDef directly under the routine tag.
      if routines.len > 0 and routines[routines.len - 1].caller.len == 0 and
          routines[routines.len - 1].depth == tagStack.len:
        routines[routines.len - 1].caller = symName(tok)
    else:
      discard
  var arr = "["
  for i in 0 ..< items.len:
    if i > 0: arr.add ","
    arr.add items[i]
  arr.add "]"
  return okRes(arr)
