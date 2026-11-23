## rtf.nim -- draws a page as RTF for a RichEdit control.
##
## The native stand-in for what index.js does with the DOM: the Markdown
## converter's HTML goes in, RTF comes out, styled from a theme. Along the
## way it does the shell's page rules: links resolved against the page,
## heading ids, captioned pictures, margin images, {{page.xxx}} macros, and
## raw HTML dropped (the charter) -- only the elements Markdown makes are drawn.

import std/[htmlparser, xmltree, strtabs, strutils, json, unicode, tables, math]
import themes, urls, pagetext

type
  RtfImage* = object
    blip*: string     ## "pngblip" or "jpegblip"
    data*: string     ## the bytes
    w*, h*: int       ## pixels
  LinkMark* = object
    text*, url*: string
    color*: Color       ## what it's drawn in: the link color, or a heading's
  AnchorMark* = object
    id*, text*: string
  RenderedPage* = object
    rtf*: string
    links*: seq[LinkMark]       ## in the order they appear, for click handling
    anchors*: seq[AnchorMark]   ## headings in order, for #name addresses
  RenderOptions* = object
    theme*: Theme
    baseUrl*: string
    frontMatter*: JsonNode
    images*: Table[string, RtfImage]
    columnPx*: int
    rightMarginImage*: string

const
  cFg = 1
  cMuted = 2
  cLink = 3
  cRule = 4
  cSurface = 5
  cAccent = 6
  fBody = 0
  fHead = 1
  fCode = 2
  twipsPerPx = 15

proc hp(px: float): int = int(round(px * 0.75 * 2))   # CSS px -> RTF half-points

proc sl(cssLineHeight: float): int =
  ## CSS line-height is a multiple of the font size; RTF's \slmult is a multiple
  ## of single spacing, which is about 1.3 times the font size
  int(240 * cssLineHeight / 1.3)

# ---------------------------------------------------------------- tiny PNG, for rules

proc crc32(s: string): uint32 =
  var table {.global.}: array[256, uint32]
  if table[1] == 0:
    for n in 0 ..< 256:
      var c = uint32(n)
      for _ in 0 ..< 8:
        c = if (c and 1) != 0: 0xEDB88320'u32 xor (c shr 1) else: c shr 1
      table[n] = c
  result = 0xFFFFFFFF'u32
  for ch in s:
    result = table[(result xor uint32(ord(ch))) and 0xFF] xor (result shr 8)
  result = result xor 0xFFFFFFFF'u32

proc be32(v: uint32): string =
  result = newString(4)
  result[0] = char((v shr 24) and 0xFF)
  result[1] = char((v shr 16) and 0xFF)
  result[2] = char((v shr 8) and 0xFF)
  result[3] = char(v and 0xFF)

proc solidPng*(c: Color): string =
  ## a 1x1 PNG of one color; scaled by RichEdit into a rule
  proc chunk(kind, data: string): string = be32(uint32(data.len)) & kind & data & be32(crc32(kind & data))
  let raw = "\0" & char(c.r) & char(c.g) & char(c.b)
  var a = 1'u32
  var b = 0'u32
  for ch in raw:
    a = (a + uint32(ord(ch))) mod 65521
    b = (b + a) mod 65521
  let zdata = "\x78\x01" & "\x01" & char(raw.len and 0xFF) & char(raw.len shr 8) &
    char((not raw.len) and 0xFF) & char(((not raw.len) shr 8) and 0xFF) & raw & be32((b shl 16) or a)
  "\x89PNG\r\n\x1a\n" & chunk("IHDR", be32(1) & be32(1) & "\x08\x02\x00\x00\x00") &
    chunk("IDAT", zdata) & chunk("IEND", "")

# ---------------------------------------------------------------- escaping

proc rtfEscape*(s: string): string =
  for r in s.runes:
    let c = int(r)
    case c
    of ord('\\'): result.add "\\\\"
    of ord('{'): result.add "\\{"
    of ord('}'): result.add "\\}"
    of ord('\t'): result.add "\\tab "
    of ord('\n'): result.add "\\line "
    of ord('\r'): discard
    of 0x20 .. 0x5A, 0x5E .. 0x7A, 0x7E: result.add char(c)
    of ord('['), ord(']'), ord('|'): result.add char(c)
    else:
      if c < 0x20: discard
      elif c <= 0xFFFF:
        result.add "\\u" & $(if c > 32767: c - 65536 else: c) & "?"
      else:
        let v = c - 0x10000
        let hi = 0xD800 + (v shr 10)
        let lo = 0xDC00 + (v and 0x3FF)
        result.add "\\u" & $(hi - 65536) & "?\\u" & $(lo - 65536) & "?"

proc colorTable(t: Theme): string =
  result = "{\\colortbl ;"
  for c in [t.fg, t.muted, t.link, t.rule, t.surface, t.accent, t.bg]:
    result.add "\\red" & $c.r & "\\green" & $c.g & "\\blue" & $c.b & ";"
  result.add "}"

proc header(t: Theme): string =
  "{\\rtf1\\ansi\\ansicpg1252\\deff0\\uc1{\\fonttbl{\\f0\\fnil\\fcharset0 " & t.fontBody &
    ";}{\\f1\\fnil\\fcharset0 " & t.fontHead & ";}{\\f2\\fmodern\\fcharset0 " & t.fontCode & ";}}" &
    colorTable(t) & "\\viewkind4\\uc1\n"

# ---------------------------------------------------------------- the writer

type
  ParaStyle = object
    sb, sa, li, fi, sl: int
    align: char
    font, size, color: int
    bold, italic, upper: bool
  ListCtx = object
    ordered: bool
    counter: int
  W = object
    o: string
    opt: RenderOptions
    t: Theme
    links: seq[LinkMark]
    anchors: seq[AnchorMark]
    slugs: CountTable[string]
    style: ParaStyle
    inPara, paraHasText, pendingSpace: bool
    pendingBullet: string
    inCell: bool
    preDepth, codeDepth: int
    linkUrl: string
    linkText: string
    lists: seq[ListCtx]
    quoteDepth: int
    upper: bool
    inHeading: bool
    linkColor: int

proc bodyStyle(w: W): ParaStyle =
  let t = w.t
  ParaStyle(sb: 0, sa: hp(t.bodyPx * 1.1) * 10, sl: sl(t.lineHeight), align: 'l',
    font: fBody, size: hp(t.bodyPx), color: cFg)

proc listIndent(w: W): int = w.lists.len * 480 + w.quoteDepth * 480

proc paraCode(w: W, s: ParaStyle): string =
  result = "\\pard"
  if w.inCell: result.add "\\intbl"
  result.add case s.align
    of 'c': "\\qc"
    of 'r': "\\qr"
    else: "\\ql"
  result.add "\\li" & $s.li & "\\fi" & $s.fi & "\\sb" & $s.sb & "\\sa" & $s.sa
  if s.sl > 0: result.add "\\sl" & $s.sl & "\\slmult1"
  if s.fi < 0: result.add "\\tx" & $s.li
  result.add "\\plain\\f" & $s.font & "\\fs" & $s.size & "\\cf" & $s.color
  if s.bold: result.add "\\b"
  if s.italic: result.add "\\i"
  result.add " "

proc openPara(w: var W) =
  if w.inPara: return
  w.o.add paraCode(w, w.style)
  w.inPara = true
  w.paraHasText = false
  w.pendingSpace = false
  if w.pendingBullet.len > 0:
    w.o.add rtfEscape(w.pendingBullet) & "\\tab "
    w.pendingBullet = ""

proc closePara(w: var W) =
  if w.inPara:
    w.o.add "\\par\n"
    w.inPara = false
    w.pendingSpace = false

proc setBlock(w: var W, s: ParaStyle) =
  w.closePara()
  w.style = s

proc raw(w: var W, s: string) =
  w.openPara()
  w.o.add s

proc emitVisible(w: var W, s: string) =
  ## text that's already been collapsed; tracked for the link it's in
  if s.len == 0: return
  w.openPara()
  if w.pendingSpace and w.paraHasText:
    w.o.add " "
    if w.linkUrl.len > 0 and w.linkText.len > 0: w.linkText.add " "
  w.pendingSpace = false
  let s2 = if w.upper: s.toUpper else: s
  w.o.add rtfEscape(s2)
  w.paraHasText = true
  if w.linkUrl.len > 0: w.linkText.add s2

proc emitText(w: var W, s: string) =
  ## collapsing whitespace the way HTML does, outside pre
  if w.preDepth > 0:
    w.openPara()
    w.o.add rtfEscape(s)
    w.paraHasText = true
    if w.linkUrl.len > 0: w.linkText.add s
    return
  var word = ""
  for r in s.runes:
    if r.isWhiteSpace:
      if word.len > 0:
        w.emitVisible(word)
        word = ""
      w.pendingSpace = true
    else:
      word.add r.toUTF8
  if word.len > 0: w.emitVisible(word)

proc beginLink(w: var W, url: string, color = -1) =
  w.openPara()
  if w.pendingSpace and w.paraHasText:
    w.o.add " "
    w.pendingSpace = false
  w.linkUrl = url
  w.linkText = ""
  w.linkColor = if color >= 0: color elif w.inHeading: w.style.color else: cLink # h2 a, h3 a { color: inherit }
  w.o.add "{\\cf" & $w.linkColor & " "

proc endLink(w: var W) =
  w.o.add "}"
  if w.linkText.strip.len > 0:
    let t = w.t
    let c = case w.linkColor
      of cFg: t.fg
      of cMuted: t.muted
      else: t.link
    w.links.add LinkMark(text: w.linkText.strip, url: w.linkUrl, color: c)
  w.linkUrl = ""
  w.linkText = ""

proc picture(w: var W, src: string, maxPx: int, alt = ""): bool =
  ## the picture, scaled to fit; false when it didn't load
  let url = resolveUrl(w.opt.baseUrl, src)

  if url notin w.opt.images: return false
  let img = w.opt.images[url]
  if img.w <= 0 or img.h <= 0: return false
  var wpx = min(img.w, max(maxPx, 16))
  var hpx = max(1, int(round(img.h.float * wpx.float / img.w.float)))
  w.openPara()
  w.o.add "{\\pict\\" & img.blip & "\\picw" & $img.w & "\\pich" & $img.h &
    "\\picwgoal" & $(wpx * twipsPerPx) & "\\pichgoal" & $(hpx * twipsPerPx) & " " # a space ends the number; RTF skips a newline and reads on
  w.o.add toHex(img.data).toLowerAscii
  w.o.add "}"
  w.paraHasText = true
  true

proc rule(w: var W) =
  w.closePara()
  var s = w.bodyStyle()
  s.sb = 400
  s.sa = 400
  s.sl = 0
  s.li = w.listIndent
  w.style = s
  w.openPara()
  let png = solidPng(w.t.rule)
  let colTw = (w.opt.columnPx * twipsPerPx) - s.li
  w.o.add "{\\pict\\pngblip\\picw1\\pich1\\picwgoal" & $colTw & "\\pichgoal15 " & toHex(png).toLowerAscii & "}"
  w.closePara()
  w.style = w.bodyStyle()

proc isDropped(tag: string): bool =
  tag in ["script", "style", "iframe", "frame", "frameset", "object", "embed", "form", "input",
    "button", "textarea", "select", "head", "title", "meta", "link", "base", "svg", "math",
    "noscript", "template", "audio", "video", "canvas", "dialog"]

proc renderChildren(w: var W, n: XmlNode)
proc renderNode(w: var W, n: XmlNode)

proc textOf(n: XmlNode): string =
  if n.kind == xnText or n.kind == xnEntity or n.kind == xnCData: return n.text
  if n.kind != xnElement: return ""
  for c in n: result.add textOf(c)

proc elementChildren(n: XmlNode): seq[XmlNode] =
  for c in n:
    if c.kind == xnElement: result.add c

proc hasOwnText(n: XmlNode, skip: XmlNode = nil): bool =
  for c in n:
    if c == skip: continue
    if c.kind in {xnText, xnEntity, xnCData}:
      if c.text.strip.len > 0: return true
    elif c.kind == xnElement:
      return true

# ---- macros and bare links in text

proc emitMacroText(w: var W, s: string) =
  ## {{page.xxx}} from the front matter; a missing value is left as written
  let fm = w.opt.frontMatter
  if fm == nil or fm.kind != JObject or "{{" notin s or w.codeDepth > 0 or w.preDepth > 0:
    w.emitText(s)
    return
  var i = 0
  while i < s.len:
    let ix = s.find("{{", i)
    if ix == -1:
      w.emitText(s[i .. ^1])
      break
    let ixEnd = s.find("}}", ix)
    if ixEnd == -1:
      w.emitText(s[i .. ^1])
      break
    let inner = s[ix + 2 ..< ixEnd].strip
    var handled = false
    if inner.startsWith("page."):
      let name = inner[5 .. ^1]
      var ok = name.len > 0
      for ch in name:
        if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '_', '.'}: ok = false
      if ok:
        let (found, value) = getMacroValue(fm, name)
        if found:
          w.emitText(s[i ..< ix])
          if name == "pubDate":
            w.emitText(formatPubDate(value))
          elif name == "title" and fm.hasKey("link") and fm["link"].kind == JString:
            var u = resolveUrl(w.opt.baseUrl, fm["link"].getStr)
            if u.len == 0: u = fm["link"].getStr
            w.beginLink(u)
            w.emitText(value)
            w.endLink()
          else:
            w.emitText(value)
          handled = true
    if not handled:
      w.emitText(s[i ..< ixEnd + 2])
    i = ixEnd + 2

proc emitTextNode(w: var W, s: string) =
  ## GFM's bare links: an address in the text is a link
  if w.linkUrl.len > 0 or w.codeDepth > 0 or w.preDepth > 0 or ("http://" notin s and "https://" notin s and "www." notin s):
    w.emitMacroText(s)
    return
  var i = 0
  while i < s.len:
    var ix = -1
    for p in ["https://", "http://", "www."]:
      let k = s.find(p, i)
      if k != -1 and (ix == -1 or k < ix) and (k == 0 or s[k - 1] in Whitespace or s[k - 1] in {'(', '"', '\''}):
        ix = k
    if ix == -1:
      w.emitMacroText(s[i .. ^1])
      break
    var j = ix
    while j < s.len and s[j] notin Whitespace and s[j] notin {'<', '>', '"'}: inc j
    while j > ix and s[j - 1] in {'.', ',', ':', ';', '!', '?', ')', '\''}: dec j
    let u = s[ix ..< j]
    if u in ["www.", "http://", "https://"]:
      w.emitMacroText(s[i ..< j])
      i = j
      continue
    w.emitMacroText(s[i ..< ix])
    w.beginLink(if u.startsWith("www."): "http://" & u else: u)
    w.emitText(u)
    w.endLink()
    i = j

# ---- blocks

proc headingStyle(w: W, level: int): ParaStyle =
  let t = w.t
  result = w.bodyStyle()
  result.font = fHead
  result.bold = true
  result.li = w.listIndent
  result.sl = sl(1.25)
  case level
  of 1:
    result.size = hp(t.bodyPx * t.h1Scale)
    result.bold = t.h1Bold
    result.sb = 200
    result.sa = 500
  of 2:
    result.size = hp(t.bodyPx * t.h2Scale)
    result.bold = t.h2Bold
    if t.h2Muted: result.color = cMuted
    result.upper = t.h2Upper
    result.sb = 700
    result.sa = 240
  of 3:
    result.size = hp(t.bodyPx * t.h3Scale)
    result.sb = 520
    result.sa = 180
  else:
    result.size = hp(t.bodyPx * (if level == 4: 1.1 else: 1.0))
    result.sb = 360
    result.sa = 120

proc renderPictureParagraph(w: var W, p, img: XmlNode, direct: XmlNode) =
  ## a paragraph that is only a picture: centered, its alt text under it as the caption
  var s = w.bodyStyle()
  s.align = 'c'
  s.li = w.listIndent
  s.sb = 300
  s.sa = 120
  s.sl = 0 # a fixed line spacing would clip the picture
  w.setBlock(s)
  let alt = img.attr("alt").strip
  if not w.picture(img.attr("src"), w.opt.columnPx - s.li div twipsPerPx, alt):
    if alt.len > 0: w.emitText("[" & alt & "]")
  w.closePara()
  if alt.len > 0 or direct != nil:
    var c = w.bodyStyle()
    c.align = 'c'
    c.li = w.listIndent
    c.italic = true
    c.color = cMuted
    c.size = hp(w.t.bodyPx * 0.9)
    c.sa = 360
    w.setBlock(c)
    if alt.len > 0: w.emitText(alt)
    if direct != nil:
      w.renderNode(direct)
    w.closePara()
  w.style = w.bodyStyle()

proc renderParagraph(w: var W, p: XmlNode) =
  let kids = elementChildren(p)
  if kids.len > 0 and kids[0].tag == "img":
    let img = kids[0]
    var direct: XmlNode = nil
    if kids.len == 2 and kids[1].tag == "a" and textOf(kids[1]).strip == "#":
      direct = kids[1]
    let ctKids = if direct == nil: 1 else: 2
    var text = textOf(p)
    if direct != nil: text = text.replace("#", "")
    if text.strip.len == 0 and kids.len == ctKids:
      w.renderPictureParagraph(p, img, direct)
      return
    # a picture at the head of a paragraph with words after it: the margin
    # image; RichEdit can't float it, so it goes at the right, above the words
    var s = w.bodyStyle()
    s.align = 'r'
    s.li = w.listIndent
    s.sa = 120
    s.sl = 0
    w.setBlock(s)
    discard w.picture(img.attr("src"), int(w.opt.columnPx.float * 0.38), img.attr("alt"))
    w.closePara()
    var b = w.bodyStyle()
    b.li = w.listIndent
    w.setBlock(b)
    for c in p:
      if c != img: w.renderNode(c)
    w.closePara()
    return
  var s = w.bodyStyle()
  s.li = w.listIndent
  if w.lists.len > 0:
    s.fi = -480
    s.sa = 120
  if w.quoteDepth > 0: s.color = cMuted
  w.setBlock(s)
  w.renderChildren(p)
  w.closePara()

proc renderPre(w: var W, n: XmlNode) =
  w.closePara()
  var code = textOf(n)
  if code.endsWith("\n"): code.setLen code.len - 1
  let li = w.listIndent
  let colTw = w.opt.columnPx * twipsPerPx
  w.o.add "\\pard\\sb120\\par\\trowd\\trgaph220\\trleft" & $li & "\\trpaddl220\\trpaddr220\\trpaddt160\\trpaddb160\\trpaddfl3\\trpaddfr3\\trpaddft3\\trpaddfb3\\clcbpat" &
    $cSurface & "\\cellx" & $colTw & "\n"
  w.o.add "\\pard\\intbl\\ql\\sl" & $sl(1.5) & "\\slmult1\\plain\\f" & $fCode & "\\fs" & $hp(w.t.bodyPx * 0.82) &
    "\\cf" & $cFg & " " & rtfEscape(code) & "\\cell\\row\n"
  w.o.add "\\pard\\sa" & $hp(w.t.bodyPx * 1.1) & "\\fs8\\par\n"
  w.style = w.bodyStyle()

proc renderTable(w: var W, n: XmlNode) =
  w.closePara()
  var rows: seq[XmlNode]
  proc collect(x: XmlNode) =
    for c in x:
      if c.kind != xnElement: continue
      if c.tag == "tr": rows.add c
      elif c.tag in ["thead", "tbody", "tfoot"]: collect(c)
  collect(n)
  if rows.len == 0: return
  var ctCols = 0
  for r in rows:
    var k = 0
    for c in r:
      if c.kind == xnElement and c.tag in ["td", "th"]: inc k
    ctCols = max(ctCols, k)
  if ctCols == 0: return
  let li = w.listIndent
  let colTw = w.opt.columnPx * twipsPerPx - li
  let cellTw = colTw div ctCols
  w.o.add "\\pard\\sb200\\fs8\\par\n"
  for r in rows:
    w.o.add "\\trowd\\trgaph140\\trleft" & $li & "\\trpaddl140\\trpaddr140\\trpaddt100\\trpaddb100\\trpaddfl3\\trpaddfr3\\trpaddft3\\trpaddfb3"
    for i in 1 .. ctCols:
      w.o.add "\\clbrdrb\\brdrs\\brdrw10\\brdrcf" & $cRule & "\\cellx" & $(li + cellTw * i)
    w.o.add "\n"
    var k = 0
    for c in r:
      if c.kind != xnElement or c.tag notin ["td", "th"]: continue
      inc k
      var s = w.bodyStyle()
      s.sa = 0
      s.sl = sl(1.4)
      s.size = hp(w.t.bodyPx * 0.95)
      let align = c.attr("align")
      if align == "center": s.align = 'c'
      elif align == "right": s.align = 'r'
      if c.tag == "th":
        s.bold = true
        s.color = cMuted
        s.size = hp(w.t.bodyPx * 0.85)
      w.inCell = true
      w.style = s
      w.openPara()
      w.renderChildren(c)
      w.inPara = false
      w.o.add "\\cell "
    while k < ctCols:
      inc k
      w.o.add "\\pard\\intbl\\cell "
    w.inCell = false
    w.o.add "\\row\n"
  w.o.add "\\pard\\sa" & $hp(w.t.bodyPx * 1.1) & "\\fs8\\par\n"
  w.style = w.bodyStyle()

proc renderListItem(w: var W, li: XmlNode, ordinal: string) =
  w.closePara()
  var s = w.bodyStyle()
  s.li = w.listIndent
  s.fi = -480
  s.sa = 100
  if w.quoteDepth > 0: s.color = cMuted
  w.style = s
  w.pendingBullet = ordinal
  var flPara = false
  for c in li:
    if c.kind == xnElement and c.tag in ["p", "ul", "ol", "pre", "blockquote", "table", "h1", "h2", "h3", "h4", "h5", "h6", "hr"]:
      flPara = true
      w.renderNode(c)
      w.style = s
    else:
      if flPara and c.kind == xnText and c.text.strip.len == 0: continue
      w.renderNode(c)
  if w.pendingBullet.len > 0: # an empty item still shows its bullet
    w.openPara()
  w.closePara()

proc renderList(w: var W, n: XmlNode, ordered: bool) =
  w.closePara()
  var start = 1
  if ordered and n.attr("start").len > 0:
    try: start = parseInt(n.attr("start"))
    except ValueError: discard
  w.lists.add ListCtx(ordered: ordered, counter: start)
  let bullets = ["\u2022", "\u25E6", "\u25AA"]
  for c in n:
    if c.kind == xnElement and c.tag == "li":
      let ordinal = if ordered: $w.lists[^1].counter & "." else: bullets[(w.lists.len - 1) mod 3]
      w.renderListItem(c, ordinal)
      inc w.lists[^1].counter
  discard w.lists.pop()
  if w.lists.len == 0:
    w.o.add "\\pard\\sa" & $hp(w.t.bodyPx * 0.6) & "\\fs8\\par\n"
  w.style = w.bodyStyle()

proc renderNode(w: var W, n: XmlNode) =
  case n.kind
  of xnText, xnEntity, xnCData:
    if w.inPara or n.text.strip.len > 0 or w.preDepth > 0:
      w.emitTextNode(n.text)
  of xnElement:
    let tag = n.tag.toLowerAscii
    if isDropped(tag): return
    case tag
    of "p": w.renderParagraph(n)
    of "h1", "h2", "h3", "h4", "h5", "h6":
      let level = ord(tag[1]) - ord('0')
      let s = w.headingStyle(level)
      w.setBlock(s)
      let text = textOf(n).strip
      var id = n.attr("id")
      if id.len == 0:
        id = headingSlug(text)
        let ct = w.slugs.getOrDefault(id)
        w.slugs.inc id
        if ct > 0: id = id & "-" & $ct
      if text.len > 0: w.anchors.add AnchorMark(id: id, text: (if s.upper: text.toUpper else: text))
      w.upper = s.upper
      w.inHeading = true
      w.renderChildren(n)
      w.inHeading = false
      w.upper = false
      w.closePara()
      w.style = w.bodyStyle()
    of "ul": w.renderList(n, false)
    of "ol": w.renderList(n, true)
    of "li": w.renderListItem(n, "\u2022")
    of "blockquote":
      w.closePara()
      inc w.quoteDepth
      w.renderChildren(n)
      w.closePara()
      dec w.quoteDepth
      w.style = w.bodyStyle()
    of "pre":
      inc w.preDepth
      w.renderPre(n)
      dec w.preDepth
    of "hr": w.rule()
    of "table": w.renderTable(n)
    of "br":
      if w.inPara: w.o.add "\\line "
      w.pendingSpace = false
    of "img":
      let alt = n.attr("alt")
      if not w.picture(n.attr("src"), w.opt.columnPx - w.listIndent div twipsPerPx, alt):
        if alt.len > 0: w.emitText("[" & alt & "]")
    of "a":
      let href = n.attr("href")
      if href.len == 0:
        w.renderChildren(n)
      else:
        var u = resolveUrl(w.opt.baseUrl, href)
        if u.len == 0: u = href
        let direct = n.attr("title") == "Direct link to this item."
        w.beginLink(u, if direct: cMuted else: -1)
        if direct: w.o.add "\\fs" & $hp(w.t.bodyPx * 0.8) & " "
        w.renderChildren(n)
        w.endLink()
    of "em", "i", "cite":
      w.raw("{\\i ")
      w.renderChildren(n)
      w.o.add "}"
    of "strong", "b":
      w.raw("{\\b ")
      w.renderChildren(n)
      w.o.add "}"
    of "del", "s", "strike":
      w.raw("{\\strike ")
      w.renderChildren(n)
      w.o.add "}"
    of "code", "kbd", "samp", "tt":
      w.openPara()
      if w.pendingSpace and w.paraHasText:
        w.o.add " "
        w.pendingSpace = false
      w.o.add "{\\f" & $fCode & "\\fs" & $hp(w.t.bodyPx * 0.86) & "\\highlight" & $cSurface & " "
      inc w.codeDepth
      w.renderChildren(n)
      dec w.codeDepth
      w.o.add "}"
    of "sup":
      w.raw("{\\super ")
      w.renderChildren(n)
      w.o.add "}"
    of "sub":
      w.raw("{\\sub ")
      w.renderChildren(n)
      w.o.add "}"
    of "div", "section", "article", "main", "header", "footer", "aside", "nav", "figure", "center",
       "dl", "details", "address":
      w.closePara()
      w.renderChildren(n)
      w.closePara()
    of "dt":
      var s = w.bodyStyle()
      s.bold = true
      s.sa = 60
      w.setBlock(s)
      w.renderChildren(n)
      w.closePara()
      w.style = w.bodyStyle()
    of "dd", "figcaption", "summary":
      var s = w.bodyStyle()
      s.li = w.listIndent + 480
      w.setBlock(s)
      w.renderChildren(n)
      w.closePara()
      w.style = w.bodyStyle()
    else:
      w.renderChildren(n) # any other element: its text, not the element (the charter)
  else: discard

proc renderChildren(w: var W, n: XmlNode) =
  for c in n: w.renderNode(c)

proc newWriter(opt: RenderOptions): W =
  result.opt = opt
  result.t = opt.theme
  if result.opt.columnPx <= 0: result.opt.columnPx = opt.theme.maxWidthPx
  result.style = result.bodyStyle()
  result.o = header(opt.theme)

proc finish(w: var W): RenderedPage =
  w.closePara()
  w.o.add "}"
  RenderedPage(rtf: w.o, links: w.links, anchors: w.anchors)

proc htmlToRtf*(html: string, opt: RenderOptions): RenderedPage =
  ## the page: the Markdown converter's HTML, drawn
  var w = newWriter(opt)
  if opt.rightMarginImage.len > 0:
    var s = w.bodyStyle()
    s.align = 'r'
    s.sl = 0
    w.setBlock(s)
    discard w.picture(opt.rightMarginImage, int(w.opt.columnPx.float * 0.38))
    w.closePara()
    w.style = w.bodyStyle()
  let root = parseHtml(html)
  w.renderNode(root)
  w.finish()

proc listingToRtf*(text: string, opt: RenderOptions): RenderedPage =
  ## the source of a page, a code file or plain text: the width of the window, monospace
  var w = newWriter(opt)
  w.o.add "\\pard\\ql\\sl" & $sl(1.45) & "\\slmult1\\plain\\f" & $fCode & "\\fs" & $hp(13) & "\\cf" & $cFg & " "
  w.o.add rtfEscape(text.replace("\r\n", "\n"))
  w.o.add "\\par\n}"
  RenderedPage(rtf: w.o)

proc imageToRtf*(url: string, opt: RenderOptions): RenderedPage =
  ## a picture by itself, centered
  var w = newWriter(opt)
  var s = w.bodyStyle()
  s.align = 'c'
  s.sb = 400
  s.sl = 0
  w.setBlock(s)
  if not w.picture(url, opt.columnPx):
    w.emitText("Can't show this picture.")
  w.finish()

proc downloadToRtf*(url: string, size: int, opt: RenderOptions): RenderedPage =
  ## the page for a file that isn't a page, a picture or text: its name, its size, a link that downloads it
  var w = newWriter(opt)
  var name = lastPathName(url)
  if name.len == 0: name = url
  var s = w.bodyStyle()
  s.align = 'c'
  s.sb = 1200
  s.size = hp(48)
  s.color = cMuted
  w.setBlock(s)
  w.emitText("\u2B07")
  w.closePara()
  s = w.bodyStyle()
  s.align = 'c'
  w.setBlock(s)
  w.emitText(name)
  w.closePara()
  w.setBlock(s)
  w.beginLink("bonbon-download:" & url)
  w.emitText("Download")
  w.endLink()
  if size >= 0:
    let sizeText = if size >= 1024 * 1024: formatFloat(size / (1024 * 1024), ffDecimal, 1) & " MB"
                   elif size >= 1024: $int(round(size / 1024)) & " KB"
                   else: $size & " bytes"
    w.emitText(", " & sizeText)
  w.finish()

proc messageToRtf*(text: string, opt: RenderOptions): RenderedPage =
  var w = newWriter(opt)
  var s = w.bodyStyle()
  s.color = cMuted
  s.align = 'c'
  s.sb = 1200
  w.setBlock(s)
  w.emitText(text)
  w.finish()
