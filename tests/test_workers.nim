import std/unittest
import workers, requests

proc fakeStatus(u: string): UrlStatus =
  case u
  of "https://a.com/empty/": UrlStatus(flAvailable: false)
  of "https://a.com/folder/": UrlStatus(flAvailable: true, urlContentLocation: "https://a.com/folder/readme.md")
  else: UrlStatus(flAvailable: true)

suite "toc neighbors":
  let stops = @["https://a.com/1.md", "https://a.com/empty/", "https://a.com/2.md", "https://a.com/folder/",
                "https://a.com/folder/readme.md", "https://a.com/3.md"]
  test "steps over a line with nothing at its address":
    check findNeighbors(stops, "https://a.com/2.md", "https://a.com/2.md", fakeStatus) ==
      ("https://a.com/1.md", "https://a.com/folder/")
  test "a folder and its readme are one page":
    check findNeighbors(stops, "https://a.com/folder/", "https://a.com/folder/readme.md", fakeStatus) ==
      ("https://a.com/2.md", "https://a.com/3.md")
  test "the tour is a loop":
    check findNeighbors(stops, "https://a.com/3.md", "https://a.com/3.md", fakeStatus)[1] == "https://a.com/1.md"
  test "a page not in the outline has none":
    check findNeighbors(stops, "https://a.com/x.md", "https://a.com/x.md", fakeStatus) == ("", "")
