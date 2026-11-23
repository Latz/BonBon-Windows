## shell.nim -- the rules of index.js that don't need a window: what an
## address means, where a site's search and mirror are in its table of
## contents, which handler draws a page, and the arrows. Kept apart from
## bonbon.nim so they can be tested.

import std/[strutils, json, options]
import urls, opml, requests, pagetext, datafolder

const prefixViewSource* = "view-source:"

proc fixUrl*(s: string): string =
  ## what a browser does with "scripting.com" -- try it as http
  result = s.strip
  if not result.startsWith("http://") and not result.startsWith("https://") and not result.startsWith(prefixViewSource):
    result = "http://" & result

proc urlAsksForMarkdown*(theUrl: string): bool =
  ## ?format=markdown on a link: the page's Markdown text, not the page
  let (found, v) = queryParam(theUrl, "format")
  found and v.toLowerAscii == "markdown"

proc looksLikeAddress*(s: string): bool =
  ## every browser's rule for the address bar: a dot, a slash or a scheme means go there, anything else is a search
  let t = s.strip
  '.' in t or '/' in t or ':' in t

# ---------------------------------------------------------------- the site's table of contents

proc includeFolder(node: OutlineNode): string =
  ## the folder an include node's outline describes: its address up to /.well-known/
  let u = node.att("url")
  let ix = u.rfind("/.well-known/")
  if ix == -1: "" else: u[0 .. ix]

proc getSiteToc*(toc: Outline, pageUrl: string): tuple[ok: bool, urlSearch, urlUpdateSocket: string, subs: seq[OutlineNode]] =
  ## the part of the domain's table of contents the page is in: a page under an
  ## included folder gets that node's children, search and socket
  if toc == nil: return
  result = (true, toc.headValue("urlSearch"), toc.headValue("urlUpdateSocket"), toc.body.subs)
  if pageUrl.len > 0:
    for node in toc.body.subs:
      if node.att("type") == "include" and node.hasAtt("url"):
        let urlFolder = includeFolder(node)
        if urlFolder.len > 0 and pageUrl.startsWith(urlFolder):
          result = (true, node.att("urlSearch"), node.att("urlUpdateSocket"), node.subs)

proc getMirrorUrl*(toc: Outline, pageUrl, theUrl: string): string =
  ## a link to a site this domain holds the Markdown version of: that version's
  ## address. Same path, .html to .md; the site's home page to the folder.
  if toc == nil or pageUrl.len == 0 or theUrl.len == 0 or not isAbsoluteUrl(theUrl): return ""
  var mirrors: seq[(string, string)]
  if toc.headValue("urlMirrorOf").len > 0:
    mirrors.add (toc.headValue("urlMirrorOf"), urlOrigin(pageUrl) & "/")
  for node in toc.body.subs:
    if node.att("type") == "include" and node.hasAtt("url") and node.att("urlMirrorOf").len > 0:
      let urlFolder = includeFolder(node)
      if urlFolder.len > 0: mirrors.add (node.att("urlMirrorOf"), urlFolder)
  proc bareHost(u: string): string =
    result = urlHostname(u)
    if result.startsWith("www."): result = result[4 .. ^1]
  let pathLink = urlPath(theUrl)
  for (mirrorOf, urlFolder) in mirrors:
    if not isAbsoluteUrl(mirrorOf): continue
    if bareHost(theUrl) == bareHost(mirrorOf) and pathLink.startsWith(urlPath(mirrorOf)):
      let thePath = pathLink[urlPath(mirrorOf).len .. ^1]
      var u = ""
      if thePath.len == 0 or thePath == "index.html": u = urlFolder
      elif thePath.endsWith(".html"): u = urlFolder & thePath[0 ..< ^5] & ".md"
      elif thePath.endsWith("/"): u = urlFolder & thePath
      if u.len > 0: return u & urlHash(theUrl)
  ""

proc getSearchQuery*(toc: Outline, pageUrl: string): (bool, string) =
  ## the word a search results page was asked for, from its address
  let urlSearch = getSiteToc(toc, pageUrl).urlSearch
  if urlSearch.len > 0 and pageUrl.startsWith(urlSearch & "?"):
    return queryParam(pageUrl, "q")
  (false, "")

proc tocStops*(subs: seq[OutlineNode], pageUrl: string): seq[string] =
  ## the addresses of the outline's lines, in an outliner's order, made whole
  for n in subs:
    if n.hasAtt("url") and n.att("type") != "include":
      let u = resolveUrl(pageUrl, n.att("url"))
      if u.len > 0: result.add urlWithoutHash(u)
    result.add tocStops(n.subs, pageUrl)

# ---------------------------------------------------------------- the arrows

proc pageArrowUrl*(frontMatter: JsonNode, neighborPrev, neighborNext, pageUrl: string, flNext: bool): string =
  ## a page that names its own neighbors keeps them; otherwise the table of contents'
  var u = ""
  var own = false
  if frontMatter != nil and frontMatter.kind == JObject:
    let p = frontMatter{"urlPrev"}.getStr
    let n = frontMatter{"urlNext"}.getStr
    own = p.len > 0 or n.len > 0
    if own: u = if flNext: n else: p
  if not own: u = if flNext: neighborNext else: neighborPrev
  if u.len == 0: return ""
  let r = resolveUrl(pageUrl, u)
  if r.len > 0: r else: u

# ---------------------------------------------------------------- page handlers

proc getExtensionForPage*(config: JsonNode, theUrl, contentType: string): string =
  ## the server's type when it's in the table, the extension on the address when it isn't
  let theType = contentType.split(';')[0].strip.toLowerAscii
  let table = if config == nil: nil else: config{"extensionsForTypes"}
  if table != nil and table.kind == JObject and table.hasKey(theType) and table[theType].kind == JString:
    return table[theType].getStr.toLowerAscii
  let p = urlPath(theUrl).toLowerAscii
  if p.rfind('.') > p.rfind('/'):
    let ext = p[p.rfind('.') + 1 .. ^1]
    var ok = ext.len > 0
    for c in ext:
      if c notin {'a'..'z', '0'..'9', '_', '-'}: ok = false # it names a folder: nothing that walks out of it
    if ok: return ext
  ""

proc handlePage*(r: var PageResult, config: JsonNode) =
  ## PAGE HANDLERS: a page that isn't Markdown goes to its handler, if there's
  ## one for its extension. The json and js handlers are built in; a user's
  ## JavaScript handler can't run without a browser engine, and says so.
  if not r.flOk or r.kind notin ["html", "xml", "text"] or not r.hasSource: return
  let ext = getExtensionForPage(config, r.url, r.contentType)
  if ext.len == 0: return
  if hasUserHandler(ext):
    r.handlerError = "Can't use the " & ext & " handler because JavaScript page handlers don't run in the Windows version of BonBon."
    return
  var res: tuple[err: string, htmltext: string]
  case ext
  of "json": res = jsonHandler(r.source, cfgInt(handlerConfig("json"), "ctSpaces", 4))
  of "js": res = jsHandler(r.source)
  else: return
  if res.err.len > 0:
    r.handlerError = "Can't use the " & ext & " handler because " & res.err & "."
    return
  r.kind = "handler"
  r.extension = ext
  r.html = res.htmltext

proc htmlListingText*(htmltext: string): string =
  ## a handler's answer that is one pre is drawn as a listing; its text
  var s = htmltext
  let ixCode = s.find("<code")
  let a = if ixCode == -1: -1 else: s.find('>', ixCode)
  let b = s.rfind("</code>")
  if a != -1 and b > a: s = s[a + 1 ..< b]
  s.multiReplace(("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&amp;", "&"))

proc imageUrlsIn*(html, baseUrl: string): seq[string] =
  ## the pictures a page needs before it's drawn, made whole, each once
  var ix = html.find("<img")
  while ix != -1:
    let ixEnd = html.find('>', ix)
    if ixEnd == -1: break
    let src = getTagAttribute(html[ix .. ixEnd], "src")
    if src.isSome:
      let u = resolveUrl(baseUrl, src.get)
      if u.len > 0 and u notin result: result.add u
    ix = html.find("<img", ixEnd)

# ---------------------------------------------------------------- bookmarks

proc getBookmarksBarFolder*(o: Outline, flCreate: bool): OutlineNode =
  ## the headline whose sub-heads are the bar's items, made if it's missing and flCreate
  for n in o.body.subs:
    if n.att("text").strip.toLowerAscii == nameBookmarksBarFolder.toLowerAscii: return n
  if flCreate:
    result = newOutlineNode({"text": nameBookmarksBarFolder, "created": nowUtcString()})
    o.body.subs.add result
