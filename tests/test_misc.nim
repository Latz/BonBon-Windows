import std/[unittest, json, strutils]
import opml, urls, winutil

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

suite "menus":
  test "getMenuItemLabel trims, cuts long titles the way main.js does, and doubles ampersands":
    check getMenuItemLabel("  Tom & Jerry ") == "Tom && Jerry"
    check getMenuItemLabel(repeat("ä", 70)) == repeat("ä", 57) & "..."
    check getMenuItemLabel(repeat("a", 60)) == repeat("a", 60)
