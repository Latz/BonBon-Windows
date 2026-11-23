## requests.nim against a local HTTP server: every rule of the charter, with
## no internet needed.

import std/[unittest, asynchttpserver, asyncdispatch, strutils, json, os]
import requests, opml, rtf

var serverPort: int
var serverReady: Channel[int]
serverReady.open()

const markdownPage* = "---\ntitle: Hello\n---\n# Hi\n\nSome *text*.\n"
let pngBytes = solidPng((255, 0, 0))

proc serve() {.thread.} =
  {.cast(gcsafe).}:
    let png = solidPng((255, 0, 0))
    let server = newAsyncHttpServer()
    server.listen(Port(0), "127.0.0.1")
    serverReady.send int(server.getPort)
    proc cb(req: Request) {.async, closure, gcsafe.} =
      let accept = req.headers.getOrDefault("accept")
      proc reply(code: HttpCode, body: string, headers: seq[(string, string)] = @[]) {.async.} =
        await req.respond(code, body, newHttpHeaders(headers))
      case req.url.path
      of "/page.md": await reply(Http200, markdownPage, @{"Content-Type": "text/markdown; charset=utf-8"})
      of "/plain.md": await reply(Http200, "# Plain", @{"Content-Type": "text/plain"})
      of "/redir": await reply(Http302, "", @{"Location": "/page.md"})
      of "/loop": await reply(Http302, "", @{"Location": "/loop"})
      of "/notfound": await reply(Http404, "No such page.", @{"Content-Type": "text/plain"})
      of "/gone": await reply(Http410, "<html>gone</html>", @{"Content-Type": "text/html"})
      of "/picky":
        if "text/markdown" in accept: await reply(Http406, "")
        else: await reply(Http200, "<html><head><title> Picky \n page </title></head></html>", @{"Content-Type": "text/html"})
      of "/twin.html":
        await reply(Http200, "<html><head><link rel=\"alternate\" type=\"text/markdown\" href=\"/page.md\"></head><body>x</body></html>",
          @{"Content-Type": "text/html"})
      of "/badtwin.html":
        await reply(Http200, "<html><head><link rel=\"alternate\" type=\"text/markdown\" href=\"/notfound\"><title>Bad</title></head></html>",
          @{"Content-Type": "text/html"})
      of "/archive.zip": await reply(Http200, repeat('z', 100_000), @{"Content-Type": "application/zip"})
      of "/folder/": await reply(Http200, "# Readme", @{"Content-Type": "text/markdown", "Content-Location": "readme.md"})
      of "/data.json": await reply(Http200, "{\"a\":1}", @{"Content-Type": "application/json"})
      of "/feed.xml": await reply(Http200, "<rss/>", @{"Content-Type": "application/rss+xml"})
      of "/pic": await reply(Http200, png, @{"Content-Type": "image/png"})
      of "/doc.pdf": await reply(Http200, "%PDF-1.4 fake", @{"Content-Type": "application/pdf"})
      of "/accept": await reply(Http200, accept, @{"Content-Type": "text/plain"})
      of "/favicon.ico": await reply(Http200, png, @{"Content-Type": "text/plain"}) # the bytes decide
      of "/.well-known/toc.opml":
        if "text/x-opml" notin accept: await reply(Http200, "<html>wrapped</html>", @{"Content-Type": "text/html"})
        else: await reply(Http200, """<?xml version="1.0"?><opml version="2.0"><head><title>t</title><urlSearch>stale</urlSearch></head><body>
          <outline text="Home" url="/page.md"/>
          <outline type="include" text="Sub" url="http://""" & req.headers.getOrDefault("host") & """/sub/.well-known/toc.opml"/>
          <outline type="include" text="Missing" url="http://""" & req.headers.getOrDefault("host") & """/nothere/.well-known/toc.opml"/>
          </body></opml>""", @{"Content-Type": "text/x-opml"})
      of "/sub/.well-known/toc.opml":
        await reply(Http200, """<opml version="2.0"><head/><body><outline text="One" url="one.md"/></body></opml>""",
          @{"Content-Type": "text/x-opml"})
      of "/.well-known/bonbon.json": await reply(Http200, """{"urlSearch": "https://s/root", "urlMirrorOf": 5}""")
      of "/sub/.well-known/bonbon.json": await reply(Http200, """{"urlUpdateSocket": "wss://sock/"}""")
      else: await reply(Http404, "")
    while true:
      if server.shouldAcceptRequest():
        waitFor server.acceptRequest(cb)
      else:
        poll()

var t: Thread[void]
createThread(t, serve)
serverPort = serverReady.recv()
let base = "http://127.0.0.1:" & $serverPort

suite "httpGet":
  test "the Accept header goes with the request":
    check httpGet(base & "/accept", "text/markdown").body == "text/markdown"
    check httpGet(base & "/accept", "text/x-opml").body == "text/x-opml"
  test "redirects are followed, the final address is ours":
    let r = httpGet(base & "/redir")
    check r.status == 200
    check r.url == base & "/page.md"
  test "too many redirects":
    check httpGet(base & "/loop").err == "Can't get " & base & "/loop because there were too many redirects."
  test "a server that isn't there":
    check httpGet("http://127.0.0.1:1/x").err.startsWith("Can't get http://127.0.0.1:1/x because")
  test "headers only, and a body that isn't wanted, aren't read":
    let r = httpGet(base & "/archive.zip", "*/*", true)
    check r.status == 200 and r.body.len == 0 and r.contentLength == 100_000
    let r2 = httpGet(base & "/archive.zip", "*/*", false, proc (u, ct: string, n: int): bool = false)
    check r2.body.len == 0
  test "reading stops at maxBodyBytes":
    check httpGet(base & "/archive.zip", "*/*", false, nil, 1000).body.len < 100_000
  test "Content-Location is made whole":
    check httpGet(base & "/folder/").contentLocation == base & "/folder/readme.md"

suite "getPage":
  test "a Markdown page: front matter off, converted":
    let p = getPage(base & "/page.md")
    check p.flOk and p.kind == ""
    check parseJson(p.frontMatter)["title"].getStr == "Hello"
    check "<h1>Hi</h1>" in p.html
    check p.source == markdownPage
  test "text/plain with .md is a page":
    check getPage(base & "/plain.md").kind == ""
  test "the server's plain words are the message":
    let p = getPage(base & "/notfound")
    check not p.flOk and p.status == 404 and p.message == "No such page."
  test "otherwise the status's words, in quotes":
    check getPage(base & "/gone").message == "Can't get the page because the server said \"Gone.\""
  test "406: asked once more, for anything":
    let p = getPage(base & "/picky")
    check p.flOk and p.kind == "html" and p.title == "Picky page"
  test "the Markdown copy an HTML page names is the page":
    let p = getPage(base & "/twin.html")
    check p.flOk and p.kind == "" and p.url == base & "/page.md"
  test "View Source gets the HTML, not its copy":
    check getPage(base & "/twin.html", true).kind == "html"
  test "a copy that isn't there leaves the HTML":
    let p = getPage(base & "/badtwin.html")
    check p.kind == "html" and p.title == "Bad"
  test "kinds":
    check getPage(base & "/data.json").kind == "text"
    check getPage(base & "/feed.xml").kind == "xml"
    let img = getPage(base & "/pic")
    check img.kind == "image" and img.imageType == "image/png" and img.imageData == pngBytes
    let pdf = getPage(base & "/doc.pdf")
    check pdf.kind == "pdf" and pdf.pdfData.startsWith("%PDF")
  test "anything else is a download, not read":
    let f = getPage(base & "/archive.zip")
    check f.kind == "file" and f.size == 100_000 and f.source.len == 0
  test "a folder answered with its readme":
    check getPage(base & "/folder/").urlContentLocation == base & "/folder/readme.md"

suite "questions about an address":
  test "isMarkdownUrl":
    check isMarkdownUrl(base & "/page.md")
    check isMarkdownUrl(base & "/twin.html")
    check not isMarkdownUrl(base & "/badtwin.html")
    check not isMarkdownUrl(base & "/data.json")
    check not isMarkdownUrl(base & "/notfound")
  test "getUrlStatus":
    check getUrlStatus(base & "/page.md").flAvailable
    check not getUrlStatus(base & "/notfound").flAvailable
    check getUrlStatus(base & "/folder/").urlContentLocation == base & "/folder/readme.md"
  test "getFavicon: the bytes decide when the server doesn't say":
    let (mime, bytes) = getFavicon(base & "/any/page.md")
    check mime == "image/png" and bytes == pngBytes

suite "table of contents":
  test "includes filled in, settings from bonbon.json, a missing include left empty":
    let o = parseOpml(getToc(base & "/page.md"))
    check o.headValue("urlSearch") == "https://s/root" # bonbon.json's, not the outline's own
    check not o.hasHead("urlMirrorOf")                 # not a string
    let sub = o.body.subs[1]
    check sub.subs.len == 1 and sub.subs[0].att("text") == "One"
    check sub.att("urlUpdateSocket") == "wss://sock/"
    check o.body.subs[2].subs.len == 0
  test "a site with none":
    check getToc("http://127.0.0.1:1/") == ""
