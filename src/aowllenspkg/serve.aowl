## `aowllens serve` — a line-oriented stdio daemon. One request JSON per line
## (`{"cmd":"<name>","args":[...]}`), one response JSON per line. EOF exits.
## Keeping the process alive amortizes startup and lets the interned `pool`
## persist across requests — the basis for a shared NIF daemon.

import std/[syncio, strutils, json]
import core, decls, render, index, outline, calls, types

proc dispatch(cmd: string; args: seq[string]): Res =
  case cmd
  of "decls": decls.run(args)
  of "render": render.run(args)
  of "index": index.run(args)
  of "outline": outline.run(args)
  of "query": outline.runQuery(args)
  of "calls": calls.run(args)
  of "types": types.run(args)
  else: errRes("unknown cmd: " & cmd, 1)

proc parseReq(line: string; cmd: var string; args: var seq[string]) =
  var tree = default(JsonTree)
  try:
    tree = parseJson(line)
  except:
    return
  for k, v in pairs(tree.root):
    case k
    of "cmd": cmd = v.getStr
    of "args":
      if v.kind == JArray:
        for el in items(v): args.add el.getStr
    else: discard

proc serve*() =
  var line = ""
  while readLine(stdin, line):
    if strip(line).len == 0: continue
    var cmd = ""
    var args: seq[string] = @[]
    parseReq(line, cmd, args)
    let r = dispatch(cmd, args)
    let outp = if r.ok: r.json else: errJson(r.json, r.code)
    try:
      write stdout, outp & "\n"
      flushFile stdout
    except:
      discard
