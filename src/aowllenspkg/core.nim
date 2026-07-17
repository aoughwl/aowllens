## Shared helpers for aowllens command modules — the nimony port of aiflens's
## core. NIF reading is unchanged (nimony compiles the compiler's NIF libs); JSON
## OUTPUT is built as strings via aowlkit/json instead of Nim2's JsonNode.

import std/[syncio, strutils]
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
  ## Read a whole NIF file into a token buffer via the real streaming reader.
  var s = nifstreams.open(path)
  discard processDirectives(s.r)
  result = fromStream(s)
  close s

proc tagName*(tok: PackedToken): string = pool.tags[tok.tagId]
proc symName*(tok: PackedToken): string = pool.syms[tok.symId]

proc baseName*(sym: string): string =
  ## Human basename of a mangled symId (`add.0.mod` -> `add`).
  var isGlobal = false
  result = extractBasename(sym, isGlobal)

proc posFragment*(tok: PackedToken): string =
  ## `,"file":..,"line":..,"col":..` for a token that carries valid line info,
  ## else "". col is 0-based (idetools convention).
  let i = unpack(pool.man, tok.info)
  if i.file.isValid:
    result = ",\"file\":" & jStr(pool.files[i.file]) &
             ",\"line\":" & $int(i.line) & ",\"col\":" & $int(i.col)
  else:
    result = ""
