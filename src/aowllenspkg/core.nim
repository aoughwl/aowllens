## Shared helpers for aowllens command modules — the nimony port of aiflens's
## core, on the NIF 27 cursor API.
##
## A `.s.nif` in the current format is a token buffer of `TagLit` heads with a
## body-token count, not a `(`/`)` stream: a node is the tag plus the values its
## jump spans, and line info rides a suffix token readable only through a
## `Cursor`. So every command works on one `Node` forest built here — the tag,
## the symbol atoms, and each value's position captured once — and the analysis
## on top of it stays plain data.

import std/[syncio, strutils, os]
include "nifprelude"
import symparser
import aowlkit/json

type
  Res* = object
    ## A command result: either a payload JSON string, or an error (message +
    ## CLI exit code). `serve` turns an error into an `{"error":..,"code":..}`
    ## line; `emit` writes it to stderr and quits.
    ok*: bool
    json*: string
    code*: int

  Node* = object
    ## One NIF value. `isAtom` is false only for a `TagLit` node, whose
    ## `kids` are its body; every atom keeps the text `render` needs and, for
    ## a symbol, the symbol name. `line`/`col`/`file` are that value's own
    ## positions, 1-based / 0-based / resolved pool name, or 0 / "" when the
    ## artifact carries no info for it. "No node" is `isEmpty`, not nil: this
    ## build's refs are non-nil.
    isAtom*: bool
    kind*: NifKind        ## the token kind (DotToken, Symbol, StrLit, …)
    tag*: string          ## list tag for a TagLit node; "" for an atom
    atom*: string         ## rendered text of an atom (strings quoted, `.` etc.)
    sym*: string          ## symbol name for a Symbol/SymbolDef atom
    isDef*: bool          ## true for a SymbolDef (a defining occurrence)
    line*: int
    col*: int
    file*: string
    kids*: seq[Node]

proc okRes*(jsonPayload: string): Res =
  Res(ok: true, json: jsonPayload, code: 0)

proc errRes*(msg: string; code = 1): Res =
  Res(ok: false, json: msg, code: code)

proc errJson*(msg: string; code: int): string =
  "{\"error\":" & jStr(msg) & ",\"code\":" & $code & "}"

proc emit*(r: Res) =
  ## CLI wrapper: on error, write the message to stderr and quit with its code;
  ## otherwise print the payload JSON.
  if not r.ok:
    try: write stderr, r.json & "\n"
    except: discard
    quit r.code
  echo r.json

proc joinSeq*(xs: seq[string]; sep: string): string =
  result = ""
  for i in 0 ..< xs.len:
    if i > 0: result.add sep
    result.add xs[i]

proc loadBuf*(path: string): TokenBuf =
  ## Read a whole NIF file into a token buffer via the real reader, keeping
  ## dense line info (every value that carries a position keeps it).
  parseFromFile(path)

# ── cursor helpers ──────────────────────────────────────────────────────────

proc tagName*(c: Cursor): string {.inline.} =
  ## The tag a `TagLit` cursor opens, as the artifact spells it.
  c.tags.tagName(c.cursorTagId)

proc atomText(c: Cursor): string =
  ## The atom at `c` as source text: strings and chars quoted, `.` as `.`.
  case c.kind
  of DotToken: "."
  of Ident: strVal(c)
  of StrLit: "\"" & strVal(c) & "\""
  of CharLit: "'" & $charLit(c) & "'"
  of IntLit: $intVal(c)
  of UIntLit: $uintVal(c)
  of FloatLit: $floatVal(c)
  of Symbol, SymbolDef: symName(c)
  else: ""

proc parseNode*(c: var Cursor): Node =
  ## One value at `c`, consuming it. A `TagLit` recurses over its body; an
  ## atom carries its kind, its text and its own position.
  result = Node(kids: @[])
  result.kind = c.kind
  let li = rawLineInfo(c)
  if li.isValid:
    result.line = int(li.line)
    result.col = int(li.col)
    result.file = lineInfoFile(c)
  case c.kind
  of TagLit:
    result.isAtom = false
    result.tag = tagName(c)
    c.loopInto:
      var sub = c
      result.kids.add parseNode(sub)
      skip c
  of Symbol:
    result.isAtom = true
    result.sym = symName(c)
    result.atom = result.sym
    inc c
  of SymbolDef:
    result.isAtom = true
    result.isDef = true
    result.sym = symName(c)
    result.atom = result.sym
    inc c
  else:
    result.isAtom = true
    result.atom = atomText(c)
    inc c

proc parseForest*(buf: var TokenBuf): seq[Node] =
  ## Every top-level value in `buf`. A `.s.nif` has exactly one root
  ## (`stmts`), but the walk does not assume it.
  result = @[]
  var c = beginRead(buf)
  while c.hasMore:
    var sub = c
    result.add parseNode(sub)
    skip c

proc isEmpty*(n: Node): bool =
  ## True for a default-constructed node — the "no value" result of a lookup.
  not n.isAtom and n.tag.len == 0 and n.kids.len == 0

proc rootOf*(forest: seq[Node]): Node =
  ## The single root node, or an empty node when the file is empty.
  if forest.len > 0: forest[forest.len - 1] else: Node()

# ── names and positions ─────────────────────────────────────────────────────

proc baseName*(sym: string): string =
  ## Human basename of a mangled symId (`add.0.mod` -> `add`).
  var isGlobal = false
  result = extractBasename(sym, isGlobal)

proc posFragment*(n: Node): string =
  ## `,"file":..,"line":..,"col":..` for a value that carries line info, else
  ## "". col is 0-based (idetools convention).
  if n.file.len > 0:
    result = ",\"file\":" & jStr(n.file) & ",\"line\":" & $n.line &
             ",\"col\":" & $n.col
  else:
    result = ""
