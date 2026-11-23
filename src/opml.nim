## OPML outlines: parse and write, the shape Dave's opml package uses --
## a head of name/value pairs, a body of nodes, each with attributes and subs.

import std/[xmlparser, xmltree, strtabs, strutils]

type
  OutlineNode* = ref object
    atts*: seq[(string, string)]
    subs*: seq[OutlineNode]
  Outline* = ref object
    head*: seq[(string, string)]
    body*: OutlineNode

proc att*(n: OutlineNode, name: string): string =
  for (k, v) in n.atts:
    if k == name: return v
  ""

proc hasAtt*(n: OutlineNode, name: string): bool =
  for (k, _) in n.atts:
    if k == name: return true

proc setAtt*(n: OutlineNode, name, value: string) =
  for i in 0 ..< n.atts.len:
    if n.atts[i][0] == name:
      n.atts[i][1] = value
      return
  n.atts.add (name, value)

proc delAtt*(n: OutlineNode, name: string) =
  for i in countdown(n.atts.high, 0):
    if n.atts[i][0] == name: n.atts.delete i

proc headValue*(o: Outline, name: string): string =
  for (k, v) in o.head:
    if k == name: return v
  ""

proc hasHead*(o: Outline, name: string): bool =
  for (k, _) in o.head:
    if k == name: return true

proc setHead*(o: Outline, name, value: string) =
  for i in 0 ..< o.head.len:
    if o.head[i][0] == name:
      o.head[i][1] = value
      return
  o.head.add (name, value)

proc delHead*(o: Outline, name: string) =
  for i in countdown(o.head.high, 0):
    if o.head[i][0] == name: o.head.delete i

proc newOutlineNode*(atts: openArray[(string, string)] = []): OutlineNode =
  OutlineNode(atts: @atts)

proc newOutline*(): Outline = Outline(body: OutlineNode())

proc readNode(x: XmlNode): OutlineNode =
  result = OutlineNode()
  if x.attrs != nil:
    for k, v in x.attrs:
      result.atts.add (k, v)
  for c in x:
    if c.kind == xnElement and c.tag == "outline":
      result.subs.add readNode(c)

proc parseOpml*(text: string): Outline =
  ## Raises ValueError when the text isn't an OPML outline.
  var root: XmlNode
  try:
    root = parseXml(text.strip)
  except CatchableError as e:
    raise newException(ValueError, e.msg)
  if root.kind != xnElement or root.tag != "opml":
    raise newException(ValueError, "the text isn't an OPML outline")
  result = newOutline()
  let head = root.child("head")
  if head != nil:
    for c in head:
      if c.kind == xnElement:
        result.head.add (c.tag, c.innerText)
  let body = root.child("body")
  if body == nil:
    raise newException(ValueError, "the outline has no body")
  result.body = readNode(body)
  result.body.atts = @[]

proc esc(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\n': result.add "&#10;"
    of '\r': discard
    of '\t': result.add "&#9;"
    else: result.add c

proc writeNode(n: OutlineNode, indent: int, s: var string) =
  s.add repeat('\t', indent) & "<outline"
  for (k, v) in n.atts:
    s.add " " & k & "=\"" & esc(v) & "\""
  if n.subs.len == 0:
    s.add " />\n"
  else:
    s.add ">\n"
    for c in n.subs: writeNode(c, indent + 1, s)
    s.add repeat('\t', indent) & "</outline>\n"

proc toOpml*(o: Outline): string =
  result = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\">\n\t<head>\n"
  for (k, v) in o.head:
    result.add "\t\t<" & k & ">" & esc(v) & "</" & k & ">\n"
  result.add "\t\t</head>\n\t<body>\n"
  for c in o.body.subs: writeNode(c, 2, result)
  result.add "\t\t</body>\n\t</opml>\n"

proc copyNode*(n: OutlineNode): OutlineNode =
  result = OutlineNode(atts: n.atts)
  for c in n.subs: result.subs.add copyNode(c)
