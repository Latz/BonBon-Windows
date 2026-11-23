## pagetext.nim -- port of frontMatter.js, markdownConverter.js, the two
## system page handlers (json, js) and the macro values of index.js.

import std/[strutils, json, times, unicode]
import vendor/markdown
import yaml/tojson

proc splitFrontMatter*(theText: string): tuple[frontMatter: JsonNode, markdown: string] =
  ## YAML front matter: a block at the top of a page between two lines of three
  ## dashes. A page with no front matter answers an empty object.
  result = (newJObject(), theText)
  let theLines = theText.split('\n')
  if theLines[0].strip == "---":
    var ixEnd = -1
    for i in 1 ..< theLines.len:
      let l = theLines[i].strip
      if l == "---" or l == "...":
        ixEnd = i
        break
    if ixEnd != -1:
      let yamlText = theLines[1 ..< ixEnd].join("\n")
      try:
        let docs = loadToJson(yamlText)
        if docs.len > 0 and docs[0].kind == JObject:
          result.frontMatter = docs[0]
      except CatchableError, Defect:
        discard # Can't read the front matter; the page still shows
      result.markdown = theLines[ixEnd + 1 .. ^1].join("\n")

proc convertMarkdownToHtml*(theMarkdown: string): string =
  ## Markdown in, HTML out. Raw HTML is kept here and dropped by the renderer
  ## (rtf.nim), which draws only the elements Markdown makes (the charter).
  try:
    result = markdown(theMarkdown, initGfmConfig(escape = true, keepHtml = true))
  except CatchableError, Defect:
    result = "<pre><code>" & theMarkdown.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;")) & "</code></pre>"

proc encodeHtml*(s: string): string = s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"))

# ---------------------------------------------------------------- page handlers

proc jsonHandler*(pagetext: string, ctSpaces = 4): tuple[err: string, htmltext: string] =
  ## Draws a .json file as an indented listing.
  try:
    let j = parseJson(pagetext)
    var s = pretty(j, ctSpaces)
    result = ("", "<pre><code class=\"language-json\">" & encodeHtml(s) & "</code></pre>")
  except CatchableError as e:
    result = ("the file isn't valid JSON: " & e.msg, "")

proc jsHandler*(pagetext: string): tuple[err: string, htmltext: string] =
  ("", "<pre><code class=\"language-javascript\">" & encodeHtml(pagetext) & "</code></pre>")

# ---------------------------------------------------------------- macros

proc getMacroValue*(fm: JsonNode, theName: string): (bool, string) =
  ## the front matter's value for "title", or "source.title"; (false, "") when none
  var v = fm
  for part in theName.split('.'):
    if v == nil or v.kind != JObject or not v.hasKey(part): return (false, "")
    v = v[part]
  case v.kind
  of JString: (true, v.getStr)
  of JInt: (true, $v.getInt)
  of JFloat: (true, $v.getFloat)
  of JBool: (true, $v.getBool)
  else: (false, "")

proc parseAnyDate*(s: string): (bool, DateTime) =
  ## RFC 822 dates (RSS) and ISO 8601, the ones front matter carries
  let s = s.strip
  const formats = ["ddd, d MMM yyyy HH:mm:ss 'GMT'", "ddd, d MMM yyyy HH:mm:ss zz",
    "ddd, d MMM yyyy HH:mm:ss zzz", "ddd, d MMM yyyy HH:mm:ss ZZZ", "d MMM yyyy HH:mm:ss 'GMT'",
    "yyyy-MM-dd'T'HH:mm:ss'.'fffzzz", "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'", "yyyy-MM-dd'T'HH:mm:sszzz",
    "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"]
  for f in formats:
    try:
      let utcLike = f.endsWith("'GMT'") or f.endsWith("'Z'")
      let dt = if utcLike: parse(s, f, utc()) else: parse(s, f)
      return (true, dt.local)
    except CatchableError:
      discard
  (false, now())

proc formatPubDate*(s: string): string =
  ## "October 23, 2026 at 11:19 AM", in the reader's time
  let (ok, dt) = parseAnyDate(s)
  if not ok: return s
  dt.format("MMMM d, yyyy") & " at " & dt.format("h:mm tt")

proc headingSlug*(text: string): string =
  ## marked's header ids: lower case, punctuation out, spaces to dashes
  const punct = "\\'!\"#$%&()*+,./:;<=>?@[]^`{|}~"
  for r in text.strip.toLower.runes:
    let c = int(r)
    if (c >= 0x2000 and c <= 0x206F) or (c >= 0x2E00 and c <= 0x2E7F): continue
    if c < 128 and char(c) in punct: continue
    if r.isWhiteSpace: result.add '-'
    else: result.add r.toUTF8
