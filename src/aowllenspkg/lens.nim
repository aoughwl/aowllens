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
##   (u "sym" "owner" "role" "file" LINE COL)               a RESOLVED occurrence
##   (t "sym" "Name" "kind" "parent" (f "name" "sym" "type" DEPTH EXPORTED)…)
##                                                          a type's members
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
# The file is one `(lens …)` node whose children are the records, so a cursor
# walk over the buffer is all it takes. Values are plain string/int literals —
# no symbol semantics to get wrong.

proc collectAtoms(c: var Cursor; ss: var seq[string]; ns: var seq[int]) =
  ## Every atom of one record, in order: strings (and idents) into `ss`,
  ## integers into `ns`.
  c.loopInto:
    case c.kind
    of StrLit, Ident: ss.add strVal(c)
    of IntLit: ns.add int(intVal(c))
    else: discard
    skip c

proc strAt(ss: seq[string]; i: int): string =
  if i < ss.len: ss[i] else: ""

proc intAt(ns: seq[int]; i: int): int =
  if i < ns.len: ns[i] else: 0

proc readType(c: var Cursor; ty: var LensType) =
  var head: seq[string] = @[]
  c.loopInto:
    case c.kind
    of TagLit:
      if tagName(c) == "f":
        var fs: seq[string] = @[]
        var fn: seq[int] = @[]
        collectAtoms(c, fs, fn)
        ty.fields.add LensField(name: strAt(fs, 0), sym: strAt(fs, 1),
                                typ: strAt(fs, 2), depth: intAt(fn, 0),
                                exported: intAt(fn, 1) != 0)
      else:
        skip c
    of StrLit, Ident:
      head.add strVal(c)
    else:
      discard
    skip c
  ty.sym = strAt(head, 0)
  ty.name = strAt(head, 1)
  ty.kind = strAt(head, 2)
  ty.parent = strAt(head, 3)

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
  var c = beginRead(buf)
  if c.kind != TagLit or tagName(c) != "lens": return
  c.loopInto:
    if c.kind == TagLit:
      let tag = tagName(c)
      if tag == "d":
        var ss: seq[string] = @[]
        var ns: seq[int] = @[]
        collectAtoms(c, ss, ns)
        result.decls.add LensDecl(sym: strAt(ss, 0), name: strAt(ss, 1),
                                  kind: strAt(ss, 2), typ: strAt(ss, 3),
                                  sig: strAt(ss, 4), recv: strAt(ss, 5),
                                  file: strAt(ss, 6),
                                  line: intAt(ns, 0), col: intAt(ns, 1))
      elif tag == "u":
        var ss: seq[string] = @[]
        var ns: seq[int] = @[]
        collectAtoms(c, ss, ns)
        result.uses.add LensUse(sym: strAt(ss, 0), owner: strAt(ss, 1),
                                role: strAt(ss, 2), file: strAt(ss, 3),
                                line: intAt(ns, 0), col: intAt(ns, 1))
      elif tag == "t":
        var ty = LensType(fields: @[])
        readType(c, ty)
        result.types.add ty
      else:
        skip c
    else:
      discard
    skip c
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
