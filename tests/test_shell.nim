import std/[unittest, json, os, strutils]
putEnv("APPDATA", getTempDir() / "bonbon_test_shell_" & $getCurrentProcessId())
import shell, opml, requests, datafolder

const tocText = """<?xml version="1.0"?><opml version="2.0"><head><title>a.com</title>
  <urlSearch>https://search.a.com/root</urlSearch><urlMirrorOf>http://www.mirror.com/</urlMirrorOf></head><body>
  <outline text="2026" url="/2026/" />
  <outline type="include" text="Blog" url="https://a.com/blog/.well-known/toc.opml"
    urlSearch="https://search.a.com/blog" urlUpdateSocket="wss://a.com/socket" urlMirrorOf="https://news.example.com/">
    <outline text="Nov" url="2026/11/index.md"><outline text="Day" url="2026/11/23.md#top"/></outline>
  </outline>
  </body></opml>"""

suite "addresses":
  test "fixUrl":
    check fixUrl("  scripting.com ") == "http://scripting.com"
    check fixUrl("https://a.com/") == "https://a.com/"
    check fixUrl("view-source:https://a.com/") == "view-source:https://a.com/"
  test "urlAsksForMarkdown":
    check urlAsksForMarkdown("https://a.com/x.md?format=MarkDown")
    check not urlAsksForMarkdown("https://a.com/x.md?format=opml")
    check not urlAsksForMarkdown("https://a.com/x.md")
  test "looksLikeAddress":
    check looksLikeAddress("scripting.com")
    check looksLikeAddress("localhost:8080")
    check looksLikeAddress("a/b")
    check not looksLikeAddress("  hairball ")

suite "table of contents":
  let toc = parseOpml(tocText)
  test "the root's settings for a page outside an include":
    let site = getSiteToc(toc, "https://a.com/about.md")
    check site.ok
    check site.urlSearch == "https://search.a.com/root"
    check site.urlUpdateSocket == ""
    check site.subs.len == 2
  test "an included folder's settings for a page under it":
    let site = getSiteToc(toc, "https://a.com/blog/2026/11/23.md")
    check site.urlSearch == "https://search.a.com/blog"
    check site.urlUpdateSocket == "wss://a.com/socket"
    check site.subs.len == 1
  test "no outline":
    check not getSiteToc(nil, "https://a.com/").ok
  test "search query":
    check getSearchQuery(toc, "https://search.a.com/root?q=hair%20ball") == (true, "hair ball")
    check getSearchQuery(toc, "https://a.com/blog/x.md")[0] == false
  test "stops in outliner order, made whole, without hashes or includes":
    check tocStops(toc.body.subs, "https://a.com/blog/index.md") ==
      @["https://a.com/2026/", "https://a.com/blog/2026/11/index.md", "https://a.com/blog/2026/11/23.md"]

suite "mirrors":
  let toc = parseOpml(tocText)
  let page = "https://a.com/blog/index.md"
  test "the root's mirror, www or not":
    check getMirrorUrl(toc, page, "http://mirror.com/2026/11/23/a1.html") == "https://a.com/2026/11/23/a1.md"
    check getMirrorUrl(toc, page, "http://www.mirror.com/") == "https://a.com/"
    check getMirrorUrl(toc, page, "http://mirror.com/index.html#x") == "https://a.com/#x"
    check getMirrorUrl(toc, page, "http://mirror.com/2026/") == "https://a.com/2026/"
  test "an include's mirror goes to its folder":
    check getMirrorUrl(toc, page, "https://news.example.com/2026/p.html") == "https://a.com/blog/2026/p.md"
  test "not mirrored":
    check getMirrorUrl(toc, page, "https://other.com/p.html") == ""
    check getMirrorUrl(toc, page, "http://mirror.com/feed.xml") == ""
    check getMirrorUrl(nil, page, "http://mirror.com/") == ""
    check getMirrorUrl(toc, page, "not a url") == ""
  test "a host that only contains www. elsewhere isn't stripped":
    let t = parseOpml("""<opml><head><urlMirrorOf>http://awww.b.com/</urlMirrorOf></head><body/></opml>""")
    check getMirrorUrl(t, page, "http://ab.com/x.html") == ""

suite "arrows":
  let page = "https://a.com/blog/2026/11/23/b.md"
  test "the page's own neighbors win":
    let fm = %*{"urlPrev": "a.md"}
    check pageArrowUrl(fm, "https://x/p", "https://x/n", page, false) == "https://a.com/blog/2026/11/23/a.md"
    check pageArrowUrl(fm, "https://x/p", "https://x/n", page, true) == "" # it named one, so no toc arrows
  test "the table of contents' when the page names none":
    check pageArrowUrl(%*{"title": "t"}, "https://x.com/p.md", "https://x.com/n.md", page, true) == "https://x.com/n.md"
    check pageArrowUrl(nil, "", "", page, true) == ""

suite "page handlers":
  let config = defaultConfig()
  test "getExtensionForPage":
    check getExtensionForPage(config, "https://a.com/x", "application/json; charset=utf-8") == "json"
    check getExtensionForPage(config, "https://a.com/x.JS", "text/plain") == "js"
    check getExtensionForPage(config, "https://a.com/dir.x/file", "") == ""
    check getExtensionForPage(config, "https://a.com/x.a%2Fb", "") == ""
    check getExtensionForPage(nil, "https://a.com/x.yaml", "") == "yaml"
  test "json is drawn as an indented listing":
    seedHandlers()
    var r = PageResult(flOk: true, kind: "text", url: "https://a.com/d.json", source: "{\"a\":1}", hasSource: true)
    handlePage(r, config)
    check r.kind == "handler"
    check r.extension == "json"
    check htmlListingText(r.html) == "{\n    \"a\": 1\n}"
  test "bad json keeps the page and says why":
    var r = PageResult(flOk: true, kind: "text", url: "https://a.com/d.json", source: "{nope", hasSource: true)
    handlePage(r, config)
    check r.kind == "text"
    check r.handlerError.startsWith("Can't use the json handler because the file isn't valid JSON")
  test "a user's JavaScript handler can't run, and says so":
    createDir(handlersFolder() / "user" / "csv")
    writeFile(handlersFolder() / "user" / "csv" / "handler.js", "function handler () {}")
    var r = PageResult(flOk: true, kind: "text", url: "https://a.com/d.csv", source: "a,b", hasSource: true)
    handlePage(r, config)
    check r.kind == "text"
    check "don't run in the Windows version" in r.handlerError
  test "markdown, pictures and failures aren't for handlers":
    var r = PageResult(flOk: true, kind: "", url: "https://a.com/d.json", source: "{}", hasSource: true)
    handlePage(r, config)
    check r.kind == ""
    var r2 = PageResult(flOk: false, kind: "text", url: "https://a.com/d.json")
    handlePage(r2, config)
    check r2.kind == "text"
  test "htmlListingText":
    check htmlListingText("<pre><code class=\"x\">a &lt;b&gt; &amp;&quot;</code></pre>") == "a <b> &\""
    check htmlListingText("plain &amp; simple") == "plain & simple"
  test "imageUrlsIn":
    check imageUrlsIn("""<p><img src="a.png" alt=""><img alt='x' src='https://c.com/b.jpg'/><img src="a.png"><img alt="none"></p>""",
      "https://a.com/dir/p.md") == @["https://a.com/dir/a.png", "https://c.com/b.jpg"]

suite "bookmarks":
  test "the bar's folder is found whatever its case, made when asked":
    let o = startingBookmarks("https://home/")
    check getBookmarksBarFolder(o, false).subs[0].att("url") == "https://home/"
    let empty = newOutline()
    check getBookmarksBarFolder(empty, false) == nil
    let made = getBookmarksBarFolder(empty, true)
    check made != nil and empty.body.subs.len == 1
    made.setAtt("text", "  BOOKMARKS BAR ")
    check getBookmarksBarFolder(empty, false) == made

removeDir(getEnv("APPDATA"))
