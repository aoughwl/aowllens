## `aowllens members <file.s.nif> <receiver>` — type-directed member completion.
##
## Given a RECEIVER identifier (as in `receiver.<here>`), resolve its TYPE from
## the sem'd NIF and emit the members reachable through a `.`:
##   * the fields of the receiver's object type (following `object of Base` for
##     inherited fields), or the values of its enum type;
##   * every routine (proc/func/method/template/converter/iterator) whose FIRST
##     parameter is that type — i.e. the UFCS / method candidates `recv.f()`.
##
## Output: a JSON array of {name, kind, detail}. `kind` is the NIF tag (`fld`,
## `efld`, `proc`, …) so the caller can map it to an LSP CompletionItemKind.
##
## The receiver is resolved by NAME against the module's bindings (let/var/const/
## param/global) and type decls. This is deliberately name-based (no positional
## scope resolution), so a shadowed name resolves to the first binding found — an
## honest, big step up from prefix-filtering the whole global symbol pool, which
## is what plain completion does for member access today.

import std/[os, strutils]
include "nifprelude"
import core
import lens
import aowlkit/json

type
  Node = object
    tag: string        ## list tag for a ParLe node; "" for an atom
    sym: string        ## symbol name for a Symbol/SymbolDef atom; "" otherwise
    isDef: bool        ## true for a SymbolDef (a defining occurrence)
    kids: seq[Node]

const
  BindingTags = ["let", "var", "gvar", "glet", "const", "cursor", "param",
                 "tvar", "result"]
  RoutineTags = ["proc", "func", "method", "converter", "iterator",
                 "template", "macro"]

proc parseNode(buf: TokenBuf; i: var int): Node =
  ## Recursively read ONE node (atom or `( … )` list) starting at `buf[i]`.
  let tok = buf[i]
  case tok.kind
  of ParLe:
    result = Node(tag: tagName(tok), sym: "", isDef: false, kids: @[])
    inc i
    while i < buf.len and buf[i].kind != ParRi:
      result.kids.add parseNode(buf, i)
    if i < buf.len: inc i           # consume the ParRi
  of Symbol:
    result = Node(tag: "", sym: symName(tok), isDef: false, kids: @[])
    inc i
  of SymbolDef:
    result = Node(tag: "", sym: symName(tok), isDef: true, kids: @[])
    inc i
  else:
    result = Node(tag: "", sym: "", isDef: false, kids: @[])
    inc i

proc firstSym(n: Node): string =
  ## The first symbol name anywhere in `n` (depth-first) — used to read the base
  ## symbol out of a type node like `Dog.0.m` or `(ref Dog.0.m (notnil))`.
  if n.sym.len > 0: return n.sym
  for k in 0 ..< n.kids.len:
    let s = firstSym(n.kids[k])
    if s.len > 0: return s
  return ""

proc human(name: string): string =
  ## Drop nimony's internal `.Obj` object-suffix so a `ref object` type keys on
  ## the name the user wrote (`Dog.Obj` → `Dog`).
  result = name
  if result.endsWith(".Obj"):
    result.setLen(result.len - 4)

proc builtinName(tag: string): string =
  ## Friendly name for a primitive type node tag (`(i 64)` → `int`).
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
  ## The type a node denotes, as a resolution KEY:
  ##   * a named type → its human base name (`Dog.0.m` → `Dog`);
  ##   * a transparent wrapper (`ref`/`ptr`/`var`/…) → the wrapped type's key;
  ##   * a container/constructor (`seq`/`array`/…) → the CONSTRUCTOR, so a
  ##     `seq[Cell]` keys on `seq` (its ops), never on the element `Cell`. This is
  ##     what lets a container receiver AND the routines that take one (`add(x: var
  ##     seq[T])`) key on the same name and match;
  ##   * a primitive (`(i 64)`) → a friendly name (`int`); else "".
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

proc among(s: string; xs: openArray[string]): bool =
  for i in 0 ..< xs.len:
    if xs[i] == s: return true
  return false

proc findByTag(n: Node; tags: openArray[string]): int =
  ## Index of the first direct child whose tag is in `tags`, else -1.
  for k in 0 ..< n.kids.len:
    if among(n.kids[k].tag, tags): return k
  return -1

proc findDeep(n: Node; tags: openArray[string]): Node =
  ## The first node (self or descendant) whose tag is in `tags`; empty Node if none.
  if among(n.tag, tags): return n
  for k in 0 ..< n.kids.len:
    let r = findDeep(n.kids[k], tags)
    if r.tag.len > 0: return r
  return Node(tag: "", sym: "", isDef: false, kids: @[])

proc routineSig(n: Node): string =
  ## A compact `(T1, T2): R` signature for a routine node — shown as the detail of
  ## a proc/func member so completion tells you what to call, not just its owner.
  let pi = findByTag(n, ["params"])
  var sig = "("
  if pi >= 0:
    var first = true
    for k in 0 ..< n.kids[pi].kids.len:
      let p = n.kids[pi].kids[k]
      if p.tag != "param" or p.kids.len <= 3: continue
      let t = baseType(p.kids[3])
      if not first: sig.add ", "
      sig.add (if t.len > 0: t else: "_")
      first = false
  sig.add ")"
  if pi >= 0 and pi + 1 < n.kids.len:
    let rt = baseType(n.kids[pi + 1])
    if rt.len > 0 and rt != "void": sig.add ": " & rt
  result = sig

type
  Pair = object
    a: string
    b: string
  Named = object
    name: string
    node: Node
  Ufcs = object
    typ: string
    routine: string
    kind: string
    sig: string
  Index = object
    bindType: seq[Pair]     ## (binding base name, type base name); first wins
    typeObj: seq[Named]     ## (type base name, its object/enum node)
    typeParent: seq[Pair]   ## (type base name, base parent name)
    ufcs: seq[Ufcs]         ## (type name, routine name, routine kind)

proc lookup(xs: seq[Pair]; k: string): string =
  ## First value whose key equals `k`, else "" (name-based, first-wins).
  for i in 0 ..< xs.len:
    if xs[i].a == k: return xs[i].b
  return ""

proc hasName(xs: seq[Named]; k: string): bool =
  for i in 0 ..< xs.len:
    if xs[i].name == k: return true
  return false

proc lookupNode(xs: seq[Named]; k: string): Node =
  ## The richest body registered under `k` — so a real object wins over an empty
  ## forward decl that happens to share the name.
  var best = -1
  for i in 0 ..< xs.len:
    if xs[i].name == k:
      if best < 0 or xs[i].node.kids.len > xs[best].node.kids.len: best = i
  if best >= 0: return xs[best].node
  return Node(tag: "", sym: "", isDef: false, kids: @[])

proc contains(xs: seq[string]; k: string): bool =
  for i in 0 ..< xs.len:
    if xs[i] == k: return true
  return false

proc declName(n: Node): string =
  ## Base name of a decl node (its SymbolDef is the first kid).
  if n.kids.len > 0 and n.kids[0].isDef: return baseName(n.kids[0].sym)
  return ""

proc build(n: Node; idx: var Index) =
  ## One recursive pass populating the resolution tables.
  if among(n.tag, BindingTags):
    let nm = declName(n)
    if nm.len > 0 and n.kids.len > 3:
      let t = baseType(n.kids[3])          # type is child index 3 for bindings
      if t.len > 0: idx.bindType.add Pair(a: nm, b: t)  # first-wins via lookup order
  elif n.tag == "type":
    let nm = human(declName(n))
    if nm.len > 0:
      let body = findDeep(n, ["object", "enum"])
      if body.tag.len > 0:
        idx.typeObj.add Named(name: nm, node: body)
        if body.tag == "object" and body.kids.len > 0:
          # the object's first child is the base-type slot (`.`/Symbol/`(ref …)`)
          let p = firstSym(body.kids[0])
          if p.len > 0: idx.typeParent.add Pair(a: nm, b: human(baseName(p)))
  elif among(n.tag, RoutineTags):
    let nm = declName(n)
    # Skip nimony's generated lifecycle hooks (`=destroy`/`=copy`/…) — they take
    # the type as first param but are never a user-facing completion.
    if nm.len > 0 and nm[0] != '=':
      let pi = findByTag(n, ["params"])
      if pi >= 0 and n.kids[pi].kids.len > 0:
        let p0 = n.kids[pi].kids[0]
        if p0.tag == "param" and p0.kids.len > 3:
          let ft = baseType(p0.kids[3])
          if ft.len > 0:
            idx.ufcs.add Ufcs(typ: ft, routine: nm, kind: n.tag, sig: routineSig(n))
  for k in 0 ..< n.kids.len:
    build(n.kids[k], idx)

proc emitMember(items: var seq[string]; seen: var seq[string];
                name, kind, detail: string) =
  if name.len == 0 or contains(seen, name): return
  seen.add name
  items.add "{\"name\":" & jStr(name) & ",\"kind\":" & jStr(kind) &
            ",\"detail\":" & jStr(detail) & "}"

proc run*(params: seq[string]): Res =
  if params.len < 2:
    return errRes("usage: aowllens members <file.s.nif> <receiver>", 1)
  let path = params[0]
  let receiver = params[1]
  if not fileExists(path):
    return errRes("no such file: " & path, 2)
  let buf = loadBuf(path)

  # Parse the whole buffer into a forest, then index it.
  var roots: seq[Node] = @[]
  var i = 0
  while i < buf.len:
    roots.add parseNode(buf, i)
  var idx = Index(bindType: @[], typeObj: @[], typeParent: @[], ufcs: @[])
  for r in 0 ..< roots.len:
    build(roots[r], idx)

  # aowlsem's index, when the build wrote one. Its member tables are the
  # checker's own; the receiver resolution below is unchanged (`members` is
  # asked by NAME, and a name has no position to resolve precisely from —
  # that is what `typeat` is for).
  let lx = lens.load(path)

  # Resolve the receiver to a type: a binding's type, else the receiver itself
  # if it names a type (enum-value / static access).
  var typeName = lookup(idx.bindType, receiver)
  if typeName.len == 0 and hasName(idx.typeObj, receiver):
    typeName = receiver
  if typeName.len == 0 and lx.ok:
    # The index knows bindings the tree walk cannot type (an imported generic
    # instance, a `let` whose type was only ever inferred).
    for i in 0 ..< lx.decls.len:
      if lx.decls[i].name == receiver and lx.decls[i].kind != "type":
        let t = lens.typeKey(lx.decls[i].typ)
        if t.len > 0: (typeName = t; break)
  if typeName.len == 0:
    return okRes("[]")

  # Walk the type and its base chain, gathering fields/enum-values and every
  # routine whose first parameter is that type (or an inherited type).
  var items: seq[string] = @[]
  var seen: seq[string] = @[]
  var visited: seq[string] = @[]
  var queue = @[typeName]
  while queue.len > 0:
    let t = queue[queue.len - 1]
    queue.setLen(queue.len - 1)
    if contains(visited, t): continue
    visited.add t
    # A type's FIELDS come from aowlsem's index when it wrote one: that table
    # is the checker's own, already flattened across the inheritance chain and
    # carrying each member's visibility — so a private field cannot leak into a
    # completion and an inherited one cannot go missing. The UFCS pass below is
    # unaffected; only the field half is taken from the index.
    let ti = if lx.ok: lens.typeIndex(lx, t) else: -1
    if ti >= 0:
      let fldKind = if lx.types[ti].kind == "enum": "efld" else: "fld"
      for f in 0 ..< lx.types[ti].fields.len:
        let fl = lx.types[ti].fields[f]
        emitMember(items, seen, fl.name, fldKind, fl.typ)
    elif hasName(idx.typeObj, t):
      let body = lookupNode(idx.typeObj, t)
      let fldTag = if body.tag == "enum": "efld" else: "fld"
      for k in 0 ..< body.kids.len:
        let c = body.kids[k]
        if c.tag == fldTag:
          let fnm = declName(c)
          let fdetail =
            if c.kids.len > 3: baseType(c.kids[3]) else: ""
          emitMember(items, seen, fnm, c.tag, fdetail)
    for m in 0 ..< idx.ufcs.len:
      if idx.ufcs[m].typ == t:
        emitMember(items, seen, idx.ufcs[m].routine, idx.ufcs[m].kind, idx.ufcs[m].sig)
    let par = lookup(idx.typeParent, t)
    if par.len > 0: queue.add par

  var arr = "["
  for k in 0 ..< items.len:
    if k > 0: arr.add ","
    arr.add items[k]
  arr.add "]"
  return okRes(arr)
