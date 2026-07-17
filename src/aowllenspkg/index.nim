## `aowllens index <file>` — read a module's interface index (`.s.idx.nif`) via
## the real `nifindexes` library and report checksum / exports / converters.

import std/[os, strutils, syncio]
include "nifprelude"
import core
import symparser
import nifindexes
import aowlkit/json

proc findChecksum(indexName: string): string =
  ## The `(checksum "…")` line lives in the index file text (NifIndex has no
  ## checksum field). Returns a JSON string literal, or `null`.
  var text = ""
  try:
    text = readFile(indexName)
  except:
    return "null"
  const marker = "(checksum \""
  let start = find(text, marker)
  if start < 0: return "null"
  let vstart = start + marker.len
  let vend = find(text, '"', vstart)
  if vend < 0: return "null"
  result = jStr(substr(text, vstart, vend - 1))

proc run*(params: seq[string]): Res =
  if params.len < 1:
    return errRes("usage: aowllens index <file>", 1)
  let file = params[0]
  let indexName =
    if endsWith(file, ".s.idx.nif") or endsWith(file, ".sc.idx.nif"): file
    else: changeModuleExt(file, ".s.idx.nif")
  if not fileExists(indexName):
    return errRes("no such file: " & indexName, 2)

  let emptyRes = "{\"checksum\":null,\"exports\":[],\"converters\":[]}"

  var idx: NifIndex
  try:
    idx = readIndex(indexName)
  except:
    return okRes(emptyRes)

  let checksum = findChecksum(indexName)

  var exportsItems: seq[string] = @[]
  try:
    for item in idx.exports:
      let module = item[0]
      let kindStr = $item[1]
      let names = item[2]
      if names.len == 0:
        exportsItems.add "{\"sym\":" & jStr(module) & ",\"name\":" &
          jStr(module) & ",\"kind\":" & jStr(kindStr) & "}"
      else:
        for nm in names:
          let s = pool.strings[nm]
          let bn = baseName(s)
          let name = if bn.len == 0: s else: bn
          exportsItems.add "{\"sym\":" & jStr(s) & ",\"name\":" & jStr(name) &
            ",\"kind\":" & jStr(kindStr) & "}"
  except:
    exportsItems = @[]

  var convItems: seq[string] = @[]
  try:
    for item in idx.converters:
      let key = item[0]
      let sym = item[1]
      let k = if key == ".": "" else: key
      convItems.add "[" & jStr(k) & "," & jStr(sym) & "]"
  except:
    convItems = @[]

  var exp = "["
  for i in 0 ..< exportsItems.len:
    if i > 0: exp.add ","
    exp.add exportsItems[i]
  exp.add "]"
  var cnv = "["
  for i in 0 ..< convItems.len:
    if i > 0: cnv.add ","
    cnv.add convItems[i]
  cnv.add "]"
  return okRes("{\"checksum\":" & checksum & ",\"exports\":" & exp &
    ",\"converters\":" & cnv & "}")
