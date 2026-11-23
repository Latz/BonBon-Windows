import std/[unittest, json, strutils]
import opml, urls, pagetext, themes, winutil

suite "opml more":
  test "attributes: set, replace, delete, keep order":
    let n = newOutlineNode({"text": "a", "url": "u"})
    n.setAtt("text", "b")
    n.setAtt("type", "bookmark")
    check n.atts == @[("text", "b"), ("url", "u"), ("type", "bookmark")]
    n.delAtt("url")
    check not n.hasAtt("url") and n.att("url") == ""
  test "head values":
    let o = newOutline()
    o.setHead("title", "T")
    o.setHead("title", "T2")
    check o.headValue("title") == "T2" and o.head.len == 1
    o.delHead("title")
    check not o.hasHead("title")
  test "a copy is its own":
    let n = newOutlineNode({"text": "a"})
    n.subs.add newOutlineNode({"text": "child"})
    let c = copyNode(n)
    c.subs[0].setAtt("text", "changed")
    c.subs.add newOutlineNode()
    check n.subs.len == 1 and n.subs[0].att("text") == "child"
  test "newlines, tabs and quotes survive the round trip":
    let o = newOutline()
    o.body.subs.add newOutlineNode({"text": "two\nlines\tand \"quotes\" & <tags>"})
    check parseOpml(toOpml(o)).body.subs[0].att("text") == "two\nlines\tand \"quotes\" & <tags>"
  test "an outline with no head":
    check parseOpml("<opml version=\"2.0\"><body><outline text=\"x\"/></body></opml>").body.subs.len == 1
  test "no body is an error":
    expect ValueError: discard parseOpml("<opml><head/></opml>")

suite "urls more":
  test "isAbsoluteUrl":
    check isAbsoluteUrl("https://a.com")
    check not isAbsoluteUrl("/relative")
    check not isAbsoluteUrl("https://")
    check isAbsoluteUrl("mailto:x@y.z")
  test "normalizeUrl":
    check normalizeUrl("HTTPS://A.COM") == "https://a.com/"
    check normalizeUrl("nope") == ""
  test "resolveUrl keeps queries and handles dot segments":
    check resolveUrl("https://a.com/a/b/c.md", "./d.md?x=1#y") == "https://a.com/a/b/d.md?x=1#y"
    check resolveUrl("https://a.com/a/b/c.md", "../../../x.md") == "https://a.com/x.md"
    check resolveUrl("https://a.com/a/", "//cdn.com/p.png") == "https://cdn.com/p.png"
  test "decodeURIComponent leaves broken escapes":
    check decodeURIComponent("a%20b") == "a b"
    check decodeURIComponent("a+b") == "a+b"
  test "encodeURIComponent keeps what JavaScript keeps":
    check encodeURIComponent("a-b_c.d!e~f*g'h(i)") == "a-b_c.d!e~f*g'h(i)"
    check encodeURIComponent("ä") == "%C3%A4"

suite "front matter more":
  test "the YAML block can end with three dots":
    let (fm, md) = splitFrontMatter("---\ntitle: T\n...\nbody")
    check fm["title"].getStr == "T" and md == "body"
  test "Windows line endings":
    let (fm, md) = splitFrontMatter("---\r\ntitle: T\r\n---\r\nbody\r\n")
    check fm["title"].getStr == "T"
    check md.strip == "body"
  test "no closing line: not front matter":
    let (fm, md) = splitFrontMatter("---\ntitle: T\nno end")
    check fm.len == 0 and md.startsWith("---")
  test "a YAML list isn't front matter":
    check splitFrontMatter("---\n- a\n- b\n---\nx")[0].len == 0
  test "dates in the formats feeds use":
    for s in ["Mon, 23 Nov 2026 16:27:04 GMT", "Mon, 2 Nov 2026 16:27:04 GMT", "2026-11-23T16:27:04.123Z",
              "2026-11-23T16:27:04+01:00", "2026-11-23 16:27:04"]:
      check parseAnyDate(s)[0]
    check not parseAnyDate("yesterday")[0]
  test "headingSlug keeps letters of any language":
    check headingSlug("Über Größe") == "über-größe"
    check headingSlug("  a  b ") == "a--b"
  test "encodeHtml":
    check encodeHtml("<a&b>") == "&lt;a&amp;b&gt;"

suite "themes and menus":
  test "getTheme falls back to Basic":
    check getTheme("book").fontBody == "Garamond"
    check getTheme("nonexistent").name == "basic"
  test "toColorRef is Windows' BGR":
    check toColorRef((1, 2, 3)) == 0x030201
  test "menuLabel cuts long titles and doubles ampersands":
    check menuLabel("Tom & Jerry") == "Tom && Jerry"
    let long = repeat("ä", 70)
    check menuLabel(long) == repeat("ä", 60) & "…"
    check menuLabel("short", 60) == "short"
