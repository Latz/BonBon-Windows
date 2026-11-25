## requests.nim -- port of pageRequests.js.
##
## The requests BonBon makes of the web, by the charter's rules: a page, a
## site's icon, its table of contents, and whether an address serves
## Markdown. Everything here is synchronous; the app calls it from worker
## threads (see workers.nim).
##
## WHOSE CERTIFICATES (issue 10): requests go through WinHTTP, Windows' own
## network code, which trusts what the system trusts and unzips gzip and
## deflate itself -- the role Electron's net played in the original.

import std/[strutils, tables, times, locks, json, base64, options]
import winim/lean, winim/inc/winhttp
import urls, opml

type
  HttpResponse* = object
    err*: string                    ## "" when the server answered
    url*: string
    status*: int
    statusMessage*: string
    contentType*: string            ## "" when the server didn't say
    contentLocation*: string        ## made absolute; "" when the server didn't say
    contentLength*: int             ## -1 when the server didn't say
    headers*: seq[(string, string)] ## names in lower case, a list of values joined into one
    body*: string                   ## bytes

  BodyWantedProc* = proc (url, contentType: string, contentLength: int): bool {.nimcall.}

  PageResult* = object
    flOk*: bool
    kind*: string                   ## "" for a Markdown page; html, xml, text, image, pdf, file, handler, openedOutside
    url*: string
    urlContentLocation*: string
    title*: string                  ## "" when there's none
    source*: string
    hasSource*: bool
    contentType*: string
    headers*: seq[(string, string)]
    imageData*: string              ## bytes, kind image
    imageType*: string
    pdfData*: string                ## bytes, kind pdf
    size*: int                      ## kind file, -1 when the server didn't say
    status*: int
    message*: string
    handlerError*: string
    extension*: string

  UrlStatus* = object
    flAvailable*: bool
    urlContentLocation*: string

var reqOptions* = (
  maxRedirects: 10,
  userAgent: "Markdown Browser",
  cacheMinutes: -1,                 # -1: kept as long as the app runs
  maxTwinSearchBytes: 64 * 1024,
  maxPdfBytes: 30 * 1024 * 1024,
  maxResponseBytes: 50 * 1024 * 1024, ## no answer is read past this, so a server that never stops can't fill the memory
  ctSecsTimeout: 30
)

# ---------------------------------------------------------------- caches

type CacheEntry[T] = object
  `when`: float
  value: T

var cacheLock: Lock
initLock cacheLock

proc getCached[T](cache: var Table[string, CacheEntry[T]], key: string, value: var T): bool =
  {.cast(gcsafe).}:
    withLock cacheLock:
      if key in cache:
        let e = cache[key]
        if reqOptions.cacheMinutes >= 0 and epochTime() - e.`when` > float(reqOptions.cacheMinutes * 60):
          cache.del key
          return false
        value = e.value
        return true

proc setCached[T](cache: var Table[string, CacheEntry[T]], key: string, value: T) =
  {.cast(gcsafe).}:
    withLock cacheLock:
      cache[key] = CacheEntry[T](`when`: epochTime(), value: value)

# ---------------------------------------------------------------- WinHTTP

const
  WinHttpAccessTypeAutomaticProxy = 4
  WinHttpOptionDecompression = 118
  WinHttpDecompressionFlagAll = 3

var sessionLock: Lock
initLock sessionLock
var gSession: HINTERNET

proc session(): HINTERNET =
  {.cast(gcsafe).}:
    withLock sessionLock:
      if gSession == nil:
        let ua = +$reqOptions.userAgent
        gSession = WinHttpOpen(&ua, WinHttpAccessTypeAutomaticProxy, nil, nil, 0)
        if gSession == nil: # before Windows 8.1
          gSession = WinHttpOpen(&ua, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, nil, nil, 0)
        if gSession != nil:
          var flags: DWORD = WinHttpDecompressionFlagAll
          discard WinHttpSetOption(gSession, WinHttpOptionDecompression, addr flags, DWORD sizeof(flags))
          let ms = int32(reqOptions.ctSecsTimeout * 1000)
          discard WinHttpSetTimeouts(gSession, 0, ms, ms, ms)
      result = gSession

proc winHttpErrorText(code: DWORD): string =
  ## The words for a WinHTTP error, lower case, for "Can't get x because ..."
  case code
  of 12007: "the server's name couldn't be found"
  of 12029: "the server couldn't be reached"
  of 12002: "the server took too long to answer"
  of 12030, 12152: "the connection was dropped"
  of 12175, 12045, 12037, 12038, 12044, 12169, 12179: "the site's certificate isn't trusted"
  else:
    var buf: array[512, WCHAR]
    let n = FormatMessageW(FORMAT_MESSAGE_FROM_HMODULE or FORMAT_MESSAGE_IGNORE_INSERTS,
      cast[LPCVOID](GetModuleHandleW("winhttp.dll")), code, 0, cast[LPWSTR](addr buf[0]), 512, nil)
    if n > 0:
      var s = $cast[WideCString](addr buf[0])
      s = s.strip.strip(chars = {'.'})
      if s.len > 0: s[0] = s[0].toLowerAscii
      s & " (" & $code & ")"
    else: "the request failed (error " & $code & ")"

proc wideToString(p: ptr WCHAR, n: int): string =
  if n <= 0 or p == nil: return ""
  var w = newWString(n)
  copyMem(&w, p, n * 2)
  $w

proc queryHeaderString(hReq: HINTERNET, info: DWORD): string =
  var size: DWORD = 0
  discard WinHttpQueryHeaders(hReq, info, nil, nil, addr size, nil)
  if size == 0: return ""
  var buf = newSeq[WCHAR](size div 2 + 1)
  if WinHttpQueryHeaders(hReq, info, nil, addr buf[0], addr size, nil) != 0:
    result = $cast[WideCString](addr buf[0])

proc parseRawHeaders(raw: string): seq[(string, string)] =
  var first = true
  for line in raw.splitLines:
    if first:
      first = false
      continue
    let ix = line.find(':')
    if ix <= 0: continue
    let name = line[0 ..< ix].strip.toLowerAscii
    let value = line[ix + 1 .. ^1].strip
    var found = false
    for i in 0 ..< result.len:
      if result[i][0] == name:
        result[i][1].add ", " & value
        found = true
    if not found: result.add (name, value)

proc header*(r: HttpResponse, name: string): string =
  for (k, v) in r.headers:
    if k == name: return v

proc hasHeader(headers: seq[(string, string)], name: string): bool =
  for (k, _) in headers:
    if k == name: return true

proc httpGet*(theUrl: string, acceptHeader = "text/markdown", flHeadersOnly = false,
              isBodyWanted: BodyWantedProc = nil, maxBodyBytes = -1, ctRedirects = 0): HttpResponse =
  ## The request. Accept goes with every one (the charter). Redirects are
  ## followed here, so the count and the final address are ours.
  ## flHeadersOnly: the connection is dropped once the headers are in.
  ## isBodyWanted: asked once the headers are in; no means the body isn't read.
  ## maxBodyBytes: reading stops there.
  result.url = theUrl
  result.contentLength = -1
  if not isAbsoluteUrl(theUrl):
    result.err = "Can't get " & theUrl & " because it isn't a valid URL."
    return
  let scheme = urlScheme(theUrl)
  if scheme notin ["http", "https"]:
    result.err = "Can't get " & theUrl & " because only http and https are supported."
    return
  let hSession = session()
  if hSession == nil:
    result.err = "Can't get " & theUrl & " because " & winHttpErrorText(GetLastError()) & "."
    return
  var wurl = +$theUrl
  var comps: URL_COMPONENTS
  comps.dwStructSize = DWORD sizeof(comps)
  comps.dwHostNameLength = DWORD(-1)
  comps.dwUrlPathLength = DWORD(-1)
  comps.dwExtraInfoLength = DWORD(-1)
  comps.dwSchemeLength = DWORD(-1)
  if WinHttpCrackUrl(&wurl, 0, 0, addr comps) == 0:
    result.err = "Can't get " & theUrl & " because it isn't a valid URL."
    return
  var host = newWString(comps.dwHostNameLength)
  copyMem(&host, comps.lpszHostName, int(comps.dwHostNameLength) * 2)
  var pathPart = ""
  if comps.dwUrlPathLength > 0:
    pathPart.add wideToString(comps.lpszUrlPath, comps.dwUrlPathLength.int)
  if comps.dwExtraInfoLength > 0:
    var extra = wideToString(comps.lpszExtraInfo, comps.dwExtraInfoLength.int)
    let ixHash = extra.find('#')
    if ixHash != -1: extra.setLen ixHash
    pathPart.add extra
  if pathPart.len == 0: pathPart = "/"

  let hConnect = WinHttpConnect(hSession, &host, comps.nPort, 0)
  if hConnect == nil:
    result.err = "Can't get " & theUrl & " because " & winHttpErrorText(GetLastError()) & "."
    return
  defer: discard WinHttpCloseHandle(hConnect)
  let wpath = +$pathPart
  let hReq = WinHttpOpenRequest(hConnect, "GET", &wpath, nil, nil, nil,
    if scheme == "https": WINHTTP_FLAG_SECURE else: 0)
  if hReq == nil:
    result.err = "Can't get " & theUrl & " because " & winHttpErrorText(GetLastError()) & "."
    return
  defer: discard WinHttpCloseHandle(hReq)
  var policy: DWORD = WINHTTP_OPTION_REDIRECT_POLICY_NEVER
  discard WinHttpSetOption(hReq, WINHTTP_OPTION_REDIRECT_POLICY, addr policy, DWORD sizeof(policy))
  let hdrs = +$("Accept: " & acceptHeader & "\r\nCache-Control: no-cache\r\n")
  if WinHttpSendRequest(hReq, &hdrs, DWORD(-1), nil, 0, 0, 0) == 0 or WinHttpReceiveResponse(hReq, nil) == 0:
    result.err = "Can't get " & theUrl & " because " & winHttpErrorText(GetLastError()) & "."
    return

  var status: DWORD
  var size = DWORD sizeof(status)
  discard WinHttpQueryHeaders(hReq, WINHTTP_QUERY_STATUS_CODE or WINHTTP_QUERY_FLAG_NUMBER, nil, addr status, addr size, nil)
  result.status = int(status)
  result.statusMessage = queryHeaderString(hReq, WINHTTP_QUERY_STATUS_TEXT)
  result.headers = parseRawHeaders(queryHeaderString(hReq, WINHTTP_QUERY_RAW_HEADERS_CRLF))

  let location = result.header("location")
  if result.status >= 300 and result.status < 400 and result.headers.hasHeader("location"):
    if ctRedirects >= reqOptions.maxRedirects:
      return HttpResponse(url: theUrl, contentLength: -1,
        err: "Can't get " & theUrl & " because there were too many redirects.")
    let urlRedirect = resolveUrl(theUrl, location)
    if urlRedirect.len == 0:
      return HttpResponse(url: theUrl, contentLength: -1,
        err: "Can't get " & theUrl & " because it redirects to an address that isn't a valid URL.")
    return httpGet(urlRedirect, acceptHeader, flHeadersOnly, isBodyWanted, maxBodyBytes, ctRedirects + 1)

  result.contentType = result.header("content-type")
  if result.headers.hasHeader("content-location"):
    result.contentLocation = resolveUrl(theUrl, result.header("content-location"))
  if result.headers.hasHeader("content-length"):
    try: result.contentLength = parseInt(result.header("content-length").strip)
    except ValueError: discard
  if flHeadersOnly or (isBodyWanted != nil and result.status == 200 and
      not isBodyWanted(theUrl, result.contentType, result.contentLength)):
    return

  var buf: array[32768, char]
  while true:
    var avail: DWORD = 0
    if WinHttpQueryDataAvailable(hReq, addr avail) == 0:
      result.err = "Can't get " & theUrl & " because " & winHttpErrorText(GetLastError()) & "."
      result.body = ""
      return
    if avail == 0: break
    var got: DWORD = 0
    if WinHttpReadData(hReq, addr buf[0], DWORD(min(int(avail), buf.len)), addr got) == 0:
      result.err = "Can't get " & theUrl & " because " & winHttpErrorText(GetLastError()) & "."
      result.body = ""
      return
    if got == 0: break
    let old = result.body.len
    result.body.setLen old + int(got)
    copyMem(addr result.body[old], addr buf[0], int(got))
    if maxBodyBytes > 0 and result.body.len >= maxBodyBytes: break
    if result.body.len > reqOptions.maxResponseBytes:
      result.err = "Can't get " & theUrl & " because it's larger than " & $(reqOptions.maxResponseBytes div (1024 * 1024)) & " MB."
      result.body = ""
      return

# ---------------------------------------------------------------- the charter's rules

proc mainType(contentType: string): string =
  contentType.split(';')[0].strip.toLowerAscii

proc lowerPath(theUrl: string): string = urlPath(theUrl).toLowerAscii

proc isMarkdownPage*(theUrl, theContentType: string): bool =
  ## text/markdown is a page. text/plain or a generic binary type with a path
  ## ending in .md or .markdown is a page. Anything else, HTML included, is not.
  let theType = mainType(theContentType)
  if theType == "text/markdown": return true
  if theType in ["text/plain", "application/octet-stream", ""]:
    let p = lowerPath(theUrl)
    return p.endsWith(".md") or p.endsWith(".markdown")

proc getPageKind*(theUrl, theContentType: string): string =
  ## what a non-Markdown answer is, when it's something we show: "html", "xml",
  ## "image", "pdf", "text", or "" (a file to download)
  let theType = mainType(theContentType)
  let p = lowerPath(theUrl)
  proc hasExt(exts: openArray[string]): bool =
    for e in exts:
      if p.endsWith(e): return true
  if theType in ["text/html", "application/xhtml+xml"] or hasExt([".html", ".htm"]): return "html"
  if theType in ["text/xml", "application/xml", "text/x-opml", "application/x-opml"] or
      theType.endsWith("+xml") or hasExt([".xml", ".rss", ".opml", ".atom", ".rdf"]): return "xml"
  if theType in ["image/gif", "image/png", "image/jpeg", "image/webp"] or
      hasExt([".gif", ".png", ".jpg", ".jpeg", ".webp"]): return "image"
  if theType == "application/pdf" or hasExt([".pdf"]): return "pdf"
  if theType.startsWith("text/") or theType in ["application/json", "application/javascript",
      "application/x-javascript", "application/yaml"] or
      hasExt([".txt", ".js", ".css", ".json", ".yaml", ".yml", ".py", ".sh", ".c", ".h", ".php",
              ".rb", ".go", ".rs", ".java", ".ts", ".sql", ".csv", ".ini", ".toml"]): return "text"
  ""

proc getImageTypeForKind*(theUrl, theContentType: string): string =
  var theType = mainType(theContentType)
  if not theType.startsWith("image/"):
    let p = lowerPath(theUrl)
    theType = if p.endsWith(".gif"): "image/gif" elif p.endsWith(".png"): "image/png"
              elif p.endsWith(".webp"): "image/webp" else: "image/jpeg"
  theType

proc collapseSpaces(s: string): string =
  var lastSpace = false
  for c in s:
    if c in Whitespace:
      if not lastSpace: result.add ' '
      lastSpace = true
    else:
      result.add c
      lastSpace = false
  result = result.strip

proc getHtmlTitle*(htmltext: string): string =
  ## the text of the <title> element, or ""
  let lower = htmltext.toLowerAscii
  var ix = lower.find("<title")
  while ix != -1:
    let c = if ix + 6 < lower.len: lower[ix + 6] else: '>'
    if c in {'>', ' ', '\t', '\n', '\r', '/'}: break
    ix = lower.find("<title", ix + 6)
  if ix == -1: return ""
  let ixStart = lower.find('>', ix)
  if ixStart == -1: return ""
  let ixEnd = lower.find("</title>", ixStart)
  if ixEnd == -1: return ""
  collapseSpaces(htmltext[ixStart + 1 ..< ixEnd])

proc getTagAttribute*(theTag, theName: string): Option[string] =
  ## an attribute's value in a tag's text, quoted or not; &amp; decoded
  let lower = theTag.toLowerAscii
  let name = theName.toLowerAscii
  var ix = 0
  while true:
    ix = lower.find(name, ix)
    if ix == -1: return none(string)
    let before = if ix > 0: lower[ix - 1] else: 'x'
    var j = ix + name.len
    if before in Whitespace:
      while j < lower.len and lower[j] in Whitespace: inc j
      if j < lower.len and lower[j] == '=':
        inc j
        while j < lower.len and lower[j] in Whitespace: inc j
        var value = ""
        if j < theTag.len and theTag[j] in {'"', '\''}:
          let q = theTag[j]
          let k = theTag.find(q, j + 1)
          if k == -1: return none(string)
          value = theTag[j + 1 ..< k]
        else:
          var k = j
          while k < theTag.len and theTag[k] notin Whitespace and theTag[k] != '>': inc k
          value = theTag[j ..< k]
        return some(value.replace("&amp;", "&").strip)
    ix = ix + name.len

proc getMarkdownTwinUrl*(htmltext, urlPage: string): string =
  ## THE MARKDOWN COPY: the address the page's head names with
  ## <link rel="alternate" type="text/markdown" href="...">, made whole; "" when none
  let lower = htmltext.toLowerAscii
  var ixBody = -1
  var k = lower.find("<body")
  while k != -1:
    if k + 5 < lower.len and lower[k + 5] in {' ', '\t', '\n', '\r', '>'}:
      ixBody = k
      break
    k = lower.find("<body", k + 5)
  let head = if ixBody == -1: htmltext else: htmltext[0 ..< ixBody]
  let headLower = head.toLowerAscii
  var ix = headLower.find("<link")
  while ix != -1:
    let after = if ix + 5 < headLower.len: headLower[ix + 5] else: ' '
    let ixClose = headLower.find('>', ix)
    if ixClose == -1: break
    if after in Whitespace or after in {'>', '/'}:
      let tag = head[ix .. ixClose]
      let rel = getTagAttribute(tag, "rel")
      let typ = getTagAttribute(tag, "type")
      let href = getTagAttribute(tag, "href")
      if rel.isSome and typ.isSome and href.isSome and href.get.len > 0:
        if "alternate" in rel.get.toLowerAscii.splitWhitespace and typ.get.toLowerAscii == "text/markdown":
          let u = resolveUrl(urlPage, href.get)
          if u.len > 0 and u != urlPage:
            return u
    ix = headLower.find("<link", ixClose)
  ""

const statusCodes = {100: "Continue", 200: "OK", 201: "Created", 204: "No Content",
  301: "Moved Permanently", 302: "Found", 304: "Not Modified", 400: "Bad Request",
  401: "Unauthorized", 402: "Payment Required", 403: "Forbidden", 404: "Not Found",
  405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout", 409: "Conflict",
  410: "Gone", 413: "Payload Too Large", 414: "URI Too Long", 415: "Unsupported Media Type",
  418: "I'm a Teapot", 429: "Too Many Requests", 451: "Unavailable For Legal Reasons",
  500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway",
  503: "Service Unavailable", 504: "Gateway Timeout"}.toTable

proc getServerErrorMessage*(r: HttpResponse): string =
  ## what to tell the reader when the server answered with something other than the page
  const maxLegibleLength = 300
  if mainType(r.contentType) == "text/plain":
    let theText = r.body.strip
    if theText.len > 0 and theText.len <= maxLegibleLength:
      return theText
  var theWords = r.statusMessage
  if theWords.len == 0: theWords = statusCodes.getOrDefault(r.status, "")
  if theWords.len == 0:
    return "Can't get the page because the server returned status " & $r.status & "."
  "Can't get the page because the server said \"" & theWords & ".\""

# ---------------------------------------------------------------- the page

proc isBodyWantedForPage(urlAnswered, theContentType: string, theContentLength: int): bool {.nimcall.} =
  if isMarkdownPage(urlAnswered, theContentType): return true
  let theKind = getPageKind(urlAnswered, theContentType)
  if theKind == "pdf":
    return theContentLength < 0 or theContentLength <= reqOptions.maxPdfBytes
  theKind.len > 0

proc getPage*(theUrl: string, flAsItCame = false): PageResult =
  ## Answers the Markdown page {flOk, url, source}, or
  ## {flOk, kind, ...} for something else we show, or {flOk: false, status, message}.
  ## flAsItCame, for View Source: an HTML page is answered as the HTML.
  const acceptForPage = "text/markdown, text/x-opml"
  const acceptForAnything = "*/*"
  var flTwinTried = false

  proc ask(urlToGet, accept: string): HttpResponse =
    result = httpGet(urlToGet, accept, false, isBodyWantedForPage)
    if result.err.len == 0 and result.status == 406 and accept == acceptForPage: # NOT ACCEPTABLE: ask once more, for anything
      result = httpGet(result.url, acceptForAnything, false, isBodyWantedForPage)

  var r = ask(theUrl, acceptForPage)
  while true:
    if r.err.len > 0:
      return PageResult(flOk: false, url: theUrl, status: 0, message: r.err, size: -1)
    if r.status != 200:
      return PageResult(flOk: false, url: r.url, status: r.status, message: getServerErrorMessage(r), size: -1)
    if isMarkdownPage(r.url, r.contentType):
      # the front matter and the Markdown are done in the page, with the original's js-yaml and marked (bridge.js)
      return PageResult(flOk: true, url: r.url, urlContentLocation: r.contentLocation,
        source: r.body, hasSource: true, size: -1)
    let theKind = getPageKind(r.url, r.contentType)
    case theKind
    of "html":
      let htmlAnswer = PageResult(flOk: true, kind: "html", url: r.url, urlContentLocation: r.contentLocation,
        title: getHtmlTitle(r.body), source: r.body, hasSource: true, contentType: r.contentType,
        headers: r.headers, size: -1)
      let urlTwin = if flAsItCame or flTwinTried: "" else: getMarkdownTwinUrl(r.body, r.url)
      if urlTwin.len == 0:
        return htmlAnswer
      flTwinTried = true # once; a copy that names a copy isn't followed
      let twin = httpGet(urlTwin, acceptForPage, false, isBodyWantedForPage)
      if twin.err.len == 0 and twin.status == 200 and isMarkdownPage(twin.url, twin.contentType):
        r = twin
        continue
      return htmlAnswer
    of "xml", "text":
      return PageResult(flOk: true, kind: theKind, url: r.url, urlContentLocation: r.contentLocation,
        source: r.body, hasSource: true, contentType: r.contentType, headers: r.headers, size: -1)
    of "image":
      return PageResult(flOk: true, kind: "image", url: r.url, urlContentLocation: r.contentLocation,
        imageData: r.body, imageType: getImageTypeForKind(r.url, r.contentType), size: -1)
    of "pdf":
      if r.body.len > 0:
        return PageResult(flOk: true, kind: "pdf", url: r.url, urlContentLocation: r.contentLocation,
          pdfData: r.body, size: -1)
    else: discard
    # anything else is a file to download; the body wasn't read
    return PageResult(flOk: true, kind: "file", url: r.url, urlContentLocation: r.contentLocation,
      contentType: r.contentType, size: r.contentLength)

# ---------------------------------------------------------------- favicons

var faviconCache: Table[string, CacheEntry[(string, string)]]

proc getImageType*(b: string): string =
  ## what kind of image the bytes say this is, or ""
  if b.len >= 8:
    if b[0] == '\0' and b[1] == '\0' and b[2] == '\1' and b[3] == '\0': return "image/x-icon"
    if b[0] == '\x89' and b[1 .. 3] == "PNG": return "image/png"
    if b[0 .. 3] == "GIF8": return "image/gif"
    if b[0] == '\xFF' and b[1] == '\xD8': return "image/jpeg"
    if "<svg" in b[0 ..< min(256, b.len)].toLowerAscii: return "image/svg+xml"
  ""

proc getFavicon*(theUrl: string): (string, string) =
  ## the site's /favicon.ico: (mime type, bytes), or ("", "") when it has none
  let theOrigin = urlOrigin(theUrl)
  if theOrigin.len == 0: return
  {.cast(gcsafe).}:
    if getCached(faviconCache, theOrigin, result): return
    let r = httpGet(theOrigin & "/favicon.ico", "text/markdown")
    if r.err.len == 0 and r.status == 200:
      var theType = mainType(r.contentType)
      if not theType.startsWith("image/"): theType = getImageType(r.body)
      if theType.len > 0: result = (theType, r.body)
    setCached(faviconCache, theOrigin, result)

proc toDataUrl*(mime, bytes: string): string = "data:" & mime & ";base64," & encode(bytes)

# ---------------------------------------------------------------- the table of contents

var tocCache: Table[string, CacheEntry[string]]
const siteSettingNames* = ["urlSearch", "urlUpdateSocket", "urlMirrorOf"]

proc getSiteSettings(urlFolder: string): JsonNode =
  ## the folder's /.well-known/bonbon.json as an object, empty when there's none
  result = newJObject()
  let r = httpGet(urlFolder & ".well-known/bonbon.json", "application/json")
  if r.err.len == 0 and r.status == 200:
    try:
      let j = parseJson(r.body)
      if j.kind == JObject: result = j
    except CatchableError:
      discard

proc expandTocIncludes*(opmltext, theOrigin: string): string =
  ## the outline with its include nodes filled in, and each site's settings
  ## from its bonbon.json on the head or the include node
  var theOutline: Outline
  try: theOutline = parseOpml(opmltext)
  except CatchableError: return opmltext
  var includeNodes: seq[OutlineNode]
  proc findIncludes(n: OutlineNode) =
    for sub in n.subs:
      if sub.att("type") == "include" and sub.hasAtt("url"): includeNodes.add sub
      else: findIncludes(sub)
  findIncludes(theOutline.body)
  let rootSettings = getSiteSettings(theOrigin & "/")
  for name in siteSettingNames:
    theOutline.delHead name
    if rootSettings.hasKey(name) and rootSettings[name].kind == JString:
      theOutline.setHead(name, rootSettings[name].getStr)
  for node in includeNodes:
    let u = node.att("url")
    let r = httpGet(u, "text/x-opml")
    if r.err.len > 0 or r.status != 200: continue
    var included: Outline
    try: included = parseOpml(r.body)
    except CatchableError: continue
    node.subs = included.body.subs
    let ixWellKnown = u.rfind("/.well-known/")
    if ixWellKnown != -1:
      let settings = getSiteSettings(u[0 .. ixWellKnown])
      for name in siteSettingNames:
        node.delAtt name
        if settings.hasKey(name) and settings[name].kind == JString:
          node.setAtt(name, settings[name].getStr)
  toOpml(theOutline)

proc getToc*(theUrl: string): string =
  ## the site's /.well-known/toc.opml, expanded; "" when the site has none
  let theOrigin = urlOrigin(theUrl)
  if theOrigin.len == 0: return ""
  {.cast(gcsafe).}:
    if getCached(tocCache, theOrigin, result): return
    let r = httpGet(theOrigin & "/.well-known/toc.opml", "text/x-opml")
    if r.err.len == 0 and r.status == 200 and r.body.len > 0:
      result = expandTocIncludes(r.body, theOrigin)
    setCached(tocCache, theOrigin, result)

# ---------------------------------------------------------------- questions about an address

var markdownUrlAnswers: Table[string, CacheEntry[bool]]

proc isHtmlKind(urlAnswered, theContentType: string, theContentLength: int): bool {.nimcall.} =
  getPageKind(urlAnswered, theContentType) == "html"

proc isMarkdownUrl*(theUrl: string): bool =
  ## does this address serve a Markdown page, directly or through its Markdown copy?
  {.cast(gcsafe).}:
    if getCached(markdownUrlAnswers, theUrl, result): return
    let r = httpGet(theUrl, "text/markdown", false, isHtmlKind, reqOptions.maxTwinSearchBytes)
    if r.err.len > 0 or r.status != 200: result = false
    elif isMarkdownPage(r.url, r.contentType): result = true
    else:
      let urlTwin = if getPageKind(r.url, r.contentType) == "html": getMarkdownTwinUrl(r.body, r.url) else: ""
      if urlTwin.len == 0: result = false
      else:
        let twin = httpGet(urlTwin, "text/markdown", true)
        result = twin.err.len == 0 and twin.status == 200 and isMarkdownPage(twin.url, twin.contentType)
    setCached(markdownUrlAnswers, theUrl, result)

var urlStatusAnswers: Table[string, CacheEntry[UrlStatus]]

proc getUrlStatus*(theUrl: string): UrlStatus =
  ## is there something at this address, and which file does the server say it sent?
  {.cast(gcsafe).}:
    if getCached(urlStatusAnswers, theUrl, result): return
    let r = httpGet(theUrl, "text/markdown, text/x-opml", true)
    result = UrlStatus(flAvailable: r.err.len == 0 and r.status == 200,
      urlContentLocation: if r.err.len > 0: "" else: r.contentLocation)
    setCached(urlStatusAnswers, theUrl, result)
