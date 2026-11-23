import std/[unittest, json, strutils]
import requests, urls

suite "requests":
  test "isMarkdownPage":
    check isMarkdownPage("http://a.com/x", "text/markdown; charset=utf-8")
    check isMarkdownPage("http://a.com/x.md", "text/plain")
    check isMarkdownPage("http://a.com/x.MARKDOWN", "")
    check not isMarkdownPage("http://a.com/x.md", "text/html")
    check not isMarkdownPage("http://a.com/x", "text/plain")
  test "getPageKind":
    check getPageKind("http://a.com/", "text/html") == "html"
    check getPageKind("http://a.com/feed", "application/rss+xml") == "xml"
    check getPageKind("http://a.com/x.opml", "") == "xml"
    check getPageKind("http://a.com/p.PNG", "") == "image"
    check getPageKind("http://a.com/d.pdf", "application/octet-stream") == "pdf"
    check getPageKind("http://a.com/a.json", "") == "text"
    check getPageKind("http://a.com/a.zip", "application/zip") == ""
  test "getImageTypeForKind":
    check getImageTypeForKind("http://a.com/x.gif", "text/plain") == "image/gif"
    check getImageTypeForKind("http://a.com/x", "image/png") == "image/png"
    check getImageTypeForKind("http://a.com/x", "") == "image/jpeg"
  test "getHtmlTitle":
    check getHtmlTitle("<html><head><TITLE lang=en>  Hello\n  world </title>") == "Hello world"
    check getHtmlTitle("<html><title></title>") == ""
    check getHtmlTitle("<titlex>no</titlex>") == ""
  test "getMarkdownTwinUrl":
    let page = """<html><head><link rel="stylesheet" href="s.css"><link rel="alternate" type="text/markdown" href="index.md?a=1&amp;b=2"></head><body><link rel="alternate" type="text/markdown" href="no.md"></body>"""
    check getMarkdownTwinUrl(page, "https://a.com/dir/") == "https://a.com/dir/index.md?a=1&b=2"
    check getMarkdownTwinUrl("<head><link rel='ALTERNATE feed' type=TEXT/MARKDOWN href=x.md></head>", "https://a.com/") == "https://a.com/x.md"
    check getMarkdownTwinUrl("<head><link rel=alternate type=text/markdown href=index.md></head>", "https://a.com/index.md") == ""
    check getMarkdownTwinUrl("<head></head><body><link rel=alternate type=text/markdown href=x.md>", "https://a.com/") == ""
  test "getServerErrorMessage":
    check getServerErrorMessage(HttpResponse(status: 404, contentType: "text/plain", body: " No such page. ")) == "No such page."
    check getServerErrorMessage(HttpResponse(status: 404, statusMessage: "Not Found")) == "Can't get the page because the server said \"Not Found.\""
    check getServerErrorMessage(HttpResponse(status: 404)) == "Can't get the page because the server said \"Not Found.\""
    check getServerErrorMessage(HttpResponse(status: 599)) == "Can't get the page because the server returned status 599."
  test "getImageType":
    check getImageType("\x89PNG\r\n\x1a\n") == "image/png"
    check getImageType("\0\0\1\0\0\0\0\0") == "image/x-icon"
    check getImageType("GIF89a..") == "image/gif"
    check getImageType("<?xml?><svg xmlns") == "image/svg+xml"
    check getImageType("hello world") == ""
  test "httpGet rejects non-http":
    check httpGet("ftp://a.com/x").err == "Can't get ftp://a.com/x because only http and https are supported."
    check httpGet("nonsense").err.endsWith("because it isn't a valid URL.")

suite "network (needs internet)":
  test "getPage of a Markdown page":
    let r = getPage("https://dave.writersweb.org/")
    if not r.flOk: echo "  (network unavailable: ", r.message, ")"
    else:
      check r.kind == "" or r.kind == "html"
      check r.url.startsWith("https://dave.writersweb.org/")
  test "redirect and 404":
    let r = getPage("http://github.com/scripting/bonBon/this-does-not-exist-xyz")
    if r.flOk == false and r.status == 0: echo "  (network unavailable)"
    else: check r.status == 404 or r.flOk
