import std/unittest
import opml

suite "opml":
  test "parse and write round trip":
    let text = """<?xml version="1.0"?><opml version="2.0"><head><title>Bookmarks</title></head><body>
      <outline text="Docs" url="https://x.com/?a=1&amp;b=2" type="bookmark"/>
      <outline text="Bookmarks bar"><outline text="Home &lt;3" url="https://h.com/"/></outline></body></opml>"""
    let o = parseOpml(text)
    check o.headValue("title") == "Bookmarks"
    check o.body.subs.len == 2
    check o.body.subs[0].att("url") == "https://x.com/?a=1&b=2"
    check o.body.subs[1].subs[0].att("text") == "Home <3"
    let o2 = parseOpml(toOpml(o))
    check o2.body.subs[1].subs[0].att("text") == "Home <3"
    check o2.body.subs[0].att("url") == "https://x.com/?a=1&b=2"
    check o2.headValue("title") == "Bookmarks"
  test "not an outline":
    expect ValueError: discard parseOpml("<html><body></body></html>")
    expect ValueError: discard parseOpml("not xml at all <")
