## Reading aowlsem's semantic index (`<module>.lens.nif`).
##
## Every other module here reconstructs meaning from the emitted tree by
## pattern-matching — the binding's type is child 3, the receiver resolves by
## NAME, a container keys on its constructor. Those rules are careful, and they
## are still guesses at things the semantic checker knew exactly.
##
## aowlsem publishes them now. `aowlsem m … --lens:<out.lens.nif>` writes a
## sidecar next to the `.s.nif` holding what it resolved (see aowlsem's
## LENS.md), and this module reads it:
##
##   (d "sym" "name" "kind" "type" "sig" "file" LINE COL)   a declaration
##   (u "sym" "file" LINE COL)                              a RESOLVED occurrence
##   (t "sym" "Name" "parent" (f "name" "sym" "type" D E)…) a type's members
##
## The `(u …)` records are the ones no amount of care recovers from the tree:
## two same-named bindings in two scopes are two symbols, and only the checker
## knows which one an occurrence bound to.
##
## Everything here is BEST-EFFORT by design. `load` returns `ok = false` when
## there is no sidecar, and each caller keeps its existing analysis as the
## fallback — so a project that never runs aowlsem behaves exactly as before,
## and one that does gets exact answers wherever the index has them.
##
## Staleness: the sidecar is written by the same run that writes the `.s.nif`,
## so the two agree by construction. A `.s.nif` recompiled WITHOUT `--lens:`
## leaves the old sidecar in place; nothing here can detect that, and the build
## is expected to write both or neither.

import std/[os, strutils]
include "nifprelude"
import core

type
  LensDecl* = object
    sym*, name*, kind*, typ*, sig*, recv*, file*: string
    line*, col*: int
  LensUse* = object
    sym*, owner*, file*: string   ## owner = the routine this sits in, "" at module level
    role*: string                 ## "call" or "read"
    line*, col*: int
  LensField* = object
    name*, sym*, typ*: string
    depth*: int
    exported*: bool
  LensType* = object
    sym*, name*, kind*, parent*: string    ## kind is "object" or "enum"
    fields*: seq[LensField]
  Lens* = object
    ok*: bool
    decls*: seq[LensDecl]
    uses*: seq[LensUse]
    types*: seq[LensType]

proc emptyLens*(): Lens =
  Lens(ok: false, decls: @[], uses: @[], types: @[])

proc pathFor*(snif: string): string =
  ## The sidecar that belongs to a `.s.nif`: same directory, same module,
  ## `.lens.nif` instead. Empty when there is none.
  var base = snif
  if base.endsWith(".s.nif"): base.setLen(base.len - 6)
  elif base.endsWith(".nif"): base.setLen(base.len - 4)
  let cand = base & ".lens.nif"
  if fileExists(cand): return cand
  return ""

# ── reading ────────────────────────────────────────────────────────────────
# A flat token walk: the file is one `(lens …)` node whose children are the
# records, so a small cursor over the buffer is all it takes. Values are plain
# string/int literals — no symbol semantics to get wrong.

proc strAt(buf: TokenBuf; i: int): string =
  if i < buf.len and buf[i].kind == StringLit: pool.strings[buf[i].litId]
  else: ""

proc intAt(buf: TokenBuf; i: int): int =
  if i < buf.len and buf[i].kind == IntLit: int(pool.integers[buf[i].intId])
  else: 0

proc load*(snif: string): Lens =
  ## Read the sidecar belonging to `snif`. `ok = false` when there is none, or
  ## when the file is not a lens index — every caller then keeps its own
  ## analysis, so a malformed sidecar degrades to the old behaviour rather than
  ## to a wrong answer.
  result = emptyLens()
  let path = pathFor(snif)
  if path.len == 0: return
  var buf: TokenBuf
  try:
    buf = loadBuf(path)
  except:
    return
  var i = 0
  # Step into the `(lens …)` root.
  while i < buf.len and not (buf[i].kind == ParLe and tagName(buf[i]) == "lens"):
    inc i
  if i >= buf.len: return
  inc i
  while i < buf.len and buf[i].kind != ParRi:
    if buf[i].kind != ParLe:
      inc i
      continue
    let tag = tagName(buf[i])
    let start = i
    inc i
    if tag == "d":
      result.decls.add LensDecl(
        sym: strAt(buf, i), name: strAt(buf, i + 1), kind: strAt(buf, i + 2),
        typ: strAt(buf, i + 3), sig: strAt(buf, i + 4), recv: strAt(buf, i + 5),
        file: strAt(buf, i + 6),
        line: intAt(buf, i + 7), col: intAt(buf, i + 8))
    elif tag == "u":
      result.uses.add LensUse(
        sym: strAt(buf, i), owner: strAt(buf, i + 1), role: strAt(buf, i + 2),
        file: strAt(buf, i + 3),
        line: intAt(buf, i + 4), col: intAt(buf, i + 5))
    elif tag == "t":
      var ty = LensType(sym: strAt(buf, i), name: strAt(buf, i + 1),
                        kind: strAt(buf, i + 2), parent: strAt(buf, i + 3),
                        fields: @[])
      var k = i + 4
      while k < buf.len and buf[k].kind != ParRi:
        if buf[k].kind == ParLe and tagName(buf[k]) == "f":
          ty.fields.add LensField(
            name: strAt(buf, k + 1), sym: strAt(buf, k + 2),
            typ: strAt(buf, k + 3), depth: intAt(buf, k + 4),
            exported: intAt(buf, k + 5) != 0)
          k = k + 7                      # `(f` + 5 values + `)`
        else:
          inc k
      result.types.add ty
    # Skip the whole record: walk to its matching `)`.
    i = start
    var depth = 0
    while i < buf.len:
      if buf[i].kind == ParLe: inc depth
      elif buf[i].kind == ParRi:
        dec depth
        if depth == 0:
          inc i
          break
      inc i
  result.ok = true

# ── queries ────────────────────────────────────────────────────────────────

proc typeKey*(t: string): string =
  ## Reduce a rendered type to the KEY the member tables are addressed by —
  ## the same key `baseType` computes from the tree, so a lens answer and a
  ## fallback answer are interchangeable. `ref Node`/`var int` unwrap to the
  ## thing they point at; `seq[Cell]`/`Box[int]` key on the constructor, never
  ## on the element.
  var s = t
  while true:
    var stripped = false
    for w in ["ref ", "ptr ", "var ", "out ", "lent ", "sink ", "mut "]:
      if s.len > w.len and s.substr(0, w.len - 1) == w:
        s = s.substr(w.len)
        stripped = true
    if not stripped: break
  for i in 0 ..< s.len:
    if s[i] == '[': return s.substr(0, i - 1)
  return s

proc declOf*(l: Lens; sym: string): int =
  for i in 0 ..< l.decls.len:
    if l.decls[i].sym == sym: return i
  return -1

proc symAt*(l: Lens; line, col: int): string =
  ## The symbol written at (line, col): the record starting at or nearest to
  ## the LEFT of the cursor on that line — an identifier the cursor sits on or
  ## just after. Declarations count too, so the cursor on a decl name resolves
  ## to what it declares.
  var best = ""
  var bestCol = -1
  for i in 0 ..< l.uses.len:
    let u = l.uses[i]
    if u.line != line: continue
    if u.col <= col and u.col > bestCol:
      bestCol = u.col
      best = u.sym
  for i in 0 ..< l.decls.len:
    let d = l.decls[i]
    if d.line != line: continue
    if d.col <= col and d.col > bestCol:
      bestCol = d.col
      best = d.sym
  return best

proc typeOf*(l: Lens; sym: string): string =
  ## The type the checker gave this symbol, as a member-table key. A symbol
  ## that IS a type keys on itself.
  let i = declOf(l, sym)
  if i < 0: return ""
  if l.decls[i].kind == "type": return typeKey(l.decls[i].name)
  return typeKey(l.decls[i].typ)

proc typeIndex*(l: Lens; key: string): int =
  ## The `(t …)` record for a type addressed by its source name.
  for i in 0 ..< l.types.len:
    if l.types[i].name == key: return i
  return -1
