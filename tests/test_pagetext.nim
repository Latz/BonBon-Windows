import std/[unittest, json, strutils]
import pagetext

suite "pagetext":
  test "splitFrontMatter":
    let (fm, md) = splitFrontMatter("---\ntitle: Hello\nsource:\n  title: Inner\n---\n# Body\n")
    check fm["title"].getStr == "Hello"
    check getMacroValue(fm, "source.title") == (true, "Inner")
    check md == "# Body\n"
    let (fm2, md2) = splitFrontMatter("# No front matter\n")
    check fm2.len == 0
    check md2 == "# No front matter\n"
    let (fm3, md3) = splitFrontMatter("---\n: : bad yaml [\n---\ntext")
    check fm3.len == 0
    check md3 == "text"
  test "convertMarkdownToHtml":
    let h = convertMarkdownToHtml("# Title\n\nSome *text* and a [link](x.md).\n\n| a | b |\n|---|---|\n| 1 | 2 |\n")
    check "<h1>Title</h1>" in h
    check "<em>text</em>" in h
    check "<a href=\"x.md\">link</a>" in h
    check "<table>" in h
    # regression: the vendored nim-markdown swallowed the character after an inline image
    check "/>Next focus" in convertMarkdownToHtml("![](x.png)Next focus")
  test "handlers":
    check jsonHandler("{\"a\":[1,2]}", 2).htmltext == "<pre><code class=\"language-json\">{\n  &quot;a&quot;: [\n    1,\n    2\n  ]\n}</code></pre>".replace("&quot;", "\"")
    check jsonHandler("{bad").err.startsWith("the file isn't valid JSON")
    check jsHandler("a < b").htmltext == "<pre><code class=\"language-javascript\">a &lt; b</code></pre>"
  test "macros and dates":
    let fm = %*{"title": "T", "n": 3, "o": {"x": "y"}}
    check getMacroValue(fm, "n") == (true, "3")
    check getMacroValue(fm, "o")[0] == false
    check getMacroValue(fm, "missing")[0] == false
    check parseAnyDate("Fri, 23 Oct 2026 15:19:00 GMT")[0]
    check parseAnyDate("2026-10-23T15:19:00Z")[0]
    check formatPubDate("not a date") == "not a date"
    check " at " in formatPubDate("2026-10-23")
  test "headingSlug":
    check headingSlug("Where to download") == "where-to-download"
    check headingSlug("Hello, World! (2026)") == "hello-world-2026"
