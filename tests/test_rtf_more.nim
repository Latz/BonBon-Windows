import std/[unittest, json, strutils, tables]
import rtf, themes, pagetext

proc opts(theme = "basic", fm = newJObject(), images = initTable[string, RtfImage](), rightMargin = ""): RenderOptions =
  RenderOptions(theme: getTheme(theme), baseUrl: "https://a.com/dir/page.md", frontMatter: fm, images: images,
    columnPx: 700, rightMarginImage: rightMargin)

proc render(md: string, o = opts()): RenderedPage = htmlToRtf(convertMarkdownToHtml(md), o)

suite "links and their colors":
  test "a link in a heading takes the heading's color (h2 a { color: inherit })":
    let p = render("## [Monday](day.md)\n\n### [Post](post.md)\n\n[body](b.md)")
    let t = getTheme("basic")
    check p.links[0].color == t.muted # Basic's h2 is muted
    check p.links[1].color == t.fg
    check p.links[2].color == t.link
  test "the # permalink is muted and small":
    let p = render("Item. [#](a1.md \"Direct link to this item.\")")
    check p.links[0].color == getTheme("basic").muted
    check p.links[0].url == "https://a.com/dir/a1.md"
  test "bare addresses become links, punctuation stays out":
    let p = render("See www.x.com, and (https://y.com/a?b=1).")
    check p.links.len == 2
    check p.links[0].url == "http://www.x.com"
    check p.links[1].url == "https://y.com/a?b=1"
  test "addresses in code aren't links":
    check render("`https://x.com/`").links.len == 0
  test "a link with no text isn't listed":
    check render("[](x.md)").links.len == 0

suite "blocks":
  test "an ordered list keeps its start":
    let p = render("3. three\n4. four\n")
    check "3." in p.rtf and "4." in p.rtf and "1." notin p.rtf
  test "nested bullets change shape":
    let p = render("- a\n  - b\n    - c\n")
    check "\\u8226?" in p.rtf and "\\u9702?" in p.rtf and "\\u9642?" in p.rtf
  test "a hard break is a line, not a paragraph":
    check "\\line" in render("one  \ntwo").rtf
  test "table cells keep their alignment":
    let p = render("| l | c | r |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n")
    check "\\qc" in p.rtf and "\\qr" in p.rtf
    check p.rtf.count("\\row") == 2
  test "a quote is indented and muted":
    let p = render("> quoted words")
    check "\\li480" in p.rtf and "\\cf2" in p.rtf
  test "strike, bold, italic, superscript":
    let p = htmlToRtf("<p><del>d</del><strong>b</strong><em>i</em><sup>2</sup></p>", opts())
    check "{\\strike d}" in p.rtf and "{\\b b}" in p.rtf and "{\\i i}" in p.rtf and "{\\super 2}" in p.rtf
  test "whitespace collapses outside pre, stays inside":
    let p = htmlToRtf("<p>a   \n  b</p><pre><code>x  y\n z</code></pre>", opts())
    check "a b" in p.rtf
    check "x  y\\line  z" in p.rtf

suite "pictures":
  var imgs = initTable[string, RtfImage]()
  imgs["https://a.com/dir/w.png"] = RtfImage(blip: "pngblip", data: solidPng((1, 1, 1)), w: 1000, h: 500)
  test "a picture wider than the column is scaled to it":
    let p = render("![cap](w.png)", opts(images = imgs))
    check "\\picwgoal10500\\pichgoal5250 " in p.rtf # 700 px column
  test "the margin picture goes at the right, at most 38% of the column":
    let p = render("![](w.png)Words after it.", opts(images = imgs))
    check "\\qr" in p.rtf and "\\picwgoal3990" in p.rtf and "Words after it." in p.rtf
  test "a picture that didn't load shows its alt text":
    check "[missing one]" in render("![missing one](nope.png) and words").rtf
  test "a picture with a # link after it is still a picture, the link under it":
    let p = render("![cap](w.png) [#](x.md \"Direct link to this item.\")", opts(images = imgs))
    check "\\qc" in p.rtf and p.links.len == 1
  test "front matter's rightMarginImage goes first":
    let p = render("Text", opts(images = imgs, rightMargin = "w.png"))
    check p.rtf.find("\\pict") < p.rtf.find("Text")

suite "themes":
  test "Newsprint's day headings are upper case":
    let p = render("## Monday", opts("newsprint"))
    check "MONDAY" in p.rtf
    check p.anchors[0].text == "MONDAY" and p.anchors[0].id == "monday"
  test "each theme's fonts and colors are in the header":
    for name in ["basic", "book", "classic", "mono", "newsprint"]:
      let t = getTheme(name)
      let p = render("x", opts(name))
      check t.fontBody in p.rtf and t.fontCode in p.rtf
      check ("\\red" & $t.fg.r & "\\green" & $t.fg.g & "\\blue" & $t.fg.b) in p.rtf

suite "other pages":
  test "a listing is the text, monospace, escaped":
    let p = listingToRtf("a {b}\r\nc\\d", opts())
    check "a \\{b\\}\\line c\\\\d" in p.rtf
    check p.links.len == 0
  test "a picture by itself":
    var imgs = initTable[string, RtfImage]()
    imgs["image:"] = RtfImage(blip: "jpegblip", data: "\xFF\xD8", w: 10, h: 10)
    var o = opts(images = imgs)
    o.baseUrl = "image:"
    check "\\jpegblip" in imageToRtf("image:", o).rtf
    check "Can't show this picture." in imageToRtf("image:", opts()).rtf
  test "the download page: name, size, a link that downloads":
    let p = downloadToRtf("https://a.com/files/My%20App.zip", 3 * 1024 * 1024 + 200_000, opts())
    check "My App.zip" in p.rtf and "3.2 MB" in p.rtf
    check p.links[0].url == "bonbon-download:https://a.com/files/My%20App.zip"
    check "12 KB" in downloadToRtf("https://a.com/x.zip", 12_000, opts()).rtf
    check "500 bytes" in downloadToRtf("https://a.com/x.zip", 500, opts()).rtf
    check "bytes" notin downloadToRtf("https://a.com/x.zip", -1, opts()).rtf
  test "a message":
    check "Nothing here" in messageToRtf("Nothing here", opts()).rtf

suite "macros":
  test "pubDate is drawn in words":
    let p = render("{{page.pubDate}}", opts(fm = %*{"pubDate": "Mon, 23 Nov 2026 16:27:04 GMT"}))
    check "2026 at" in p.rtf and "{{" notin p.rtf
  test "values inside values, numbers, and a macro in a fenced block stays":
    let p = render("{{page.source.title}} {{page.n}}\n\n```\n{{page.n}}\n```", opts(fm = %*{"source": {"title": "SN"}, "n": 3}))
    check "SN 3" in p.rtf
    check "\\{\\{page.n\\}\\}" in p.rtf
