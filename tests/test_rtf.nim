import std/[unittest, json, strutils, tables]
import rtf, themes, pagetext

proc render(md: string, fm = newJObject(), images = initTable[string, RtfImage]()): RenderedPage =
  htmlToRtf(convertMarkdownToHtml(md), RenderOptions(theme: getTheme("basic"),
    baseUrl: "https://a.com/dir/page.md", frontMatter: fm, images: images, columnPx: 700))

suite "rtf":
  test "escaping":
    check rtfEscape("a{b}\\c") == "a\\{b\\}\\\\c"
    check rtfEscape("ä") == "\\u228?"
    check rtfEscape("😀") == "\\u-10179?\\u-8704?"
  test "links are resolved and listed in order":
    let p = render("See [one](x.md) and [two](https://b.com/) and https://c.com/z.")
    check p.links.len == 3
    check p.links[0].url == "https://a.com/dir/x.md"
    check p.links[0].text == "one"
    check p.links[1].url == "https://b.com/"
    check p.links[2].url == "https://c.com/z"
    check p.rtf.startsWith("{\\rtf1")
    check p.rtf.endsWith("}")
  test "headings get ids":
    let p = render("# Hello World\n\n## Hello World\n")
    check p.anchors.len == 2
    check p.anchors[0].id == "hello-world"
    check p.anchors[1].id == "hello-world-1"
  test "raw html is dropped, its text kept":
    let p = render("hi <span>there</span>\n\n<script>alert(1)</script>\n")
    check "there" in p.rtf
    check "alert" notin p.rtf
  test "macros":
    let p = render("{{page.title}} by {{ page.author }} {{page.missing}} `{{page.title}}`",
      %*{"title": "My Page", "author": "Dave", "link": "https://l.com/"})
    check "My Page" in p.rtf
    check "Dave" in p.rtf
    check "{{page.missing}}" in p.rtf.replace("\\{", "{").replace("\\}", "}")
    check p.links.len == 1
    check p.links[0].url == "https://l.com/"
  test "pictures":
    var imgs = initTable[string, RtfImage]()
    imgs["https://a.com/dir/p.png"] = RtfImage(blip: "pngblip", data: solidPng((1, 2, 3)), w: 10, h: 5)
    let p = render("![a caption](p.png)\n\n![](missing.png)\n", images = imgs)
    check "\\pngblip" in p.rtf
    check "a caption" in p.rtf
    # regression: a newline after \pichgoal let RTF read the hex as part of the number
    check "\\pichgoal75 89504e47" in p.rtf
  test "lists, tables, code, rules render":
    let p = render("- a\n- b\n  1. c\n\n```\ncode {x}\n```\n\n---\n\n| h |\n|---|\n| v |\n\n> quote\n")
    check "\\u8226?" in p.rtf
    check "1." in p.rtf
    check "code \\{x\\}" in p.rtf
    check "\\row" in p.rtf
    check "quote" in p.rtf
  test "solidPng is a png":
    let png = solidPng((255, 0, 0))
    check png.startsWith("\x89PNG")
    check png.endsWith("IEND\xAE\x42\x60\x82")
