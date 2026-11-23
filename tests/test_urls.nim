import std/unittest
import urls

suite "urls":
  test "resolveUrl":
    check resolveUrl("https://a.com/dir/page.md", "other.md") == "https://a.com/dir/other.md"
    check resolveUrl("https://a.com/dir/page.md", "../x.md") == "https://a.com/x.md"
    check resolveUrl("https://a.com/dir/page.md", "/root.md") == "https://a.com/root.md"
    check resolveUrl("https://a.com/dir/page.md", "#h") == "https://a.com/dir/page.md#h"
    check resolveUrl("https://a.com/", "http://B.com") == "http://b.com/"
    check resolveUrl("", "x.md") == ""
  test "origin, path, hash":
    check urlOrigin("https://A.com/x/y?z#q") == "https://a.com"
    check urlOrigin("http://a.com:8080/x") == "http://a.com:8080"
    check urlOrigin("nonsense") == ""
    check urlPath("https://a.com") == "/"
    check urlWithoutHash("https://a.com/x#y") == "https://a.com/x"
    check urlHash("https://a.com/x#y") == "#y"
  test "queryParam":
    check queryParam("https://a.com/s?q=hello%20world", "q") == (true, "hello world")
    check queryParam("https://a.com/x.md?format=markdown", "format") == (true, "markdown")
    check queryParam("https://a.com/", "q")[0] == false
  test "encode":
    check encodeURIComponent("a b&c") == "a%20b%26c"
    check lastPathName("https://a.com/files/My%20File.zip") == "My File.zip"
    check lastPathName("https://a.com/files/") == ""
