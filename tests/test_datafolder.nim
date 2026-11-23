import std/[unittest, os, json, strutils]
putEnv("APPDATA", getTempDir() / "bonbon_test_data_" & $getCurrentProcessId())
import datafolder, opml

suite "data folder":
  test "it's BonBon in APPDATA, made when missing":
    check dataFolder() == getEnv("APPDATA") / "BonBon"
    check dirExists(dataFolder())
  test "config: the seed goes in the first time, the reader's file wins after":
    let c = readConfig()
    check cfgStr(c, "urlHomePage") == "https://dave.writersweb.org/"
    check fileExists(dataFolder() / "config.json")
    writeFile(dataFolder() / "config.json", """{"urlHomePage": "https://mine/", "maxHistoryMenuItems": 5}""")
    let c2 = readConfig()
    check cfgStr(c2, "urlHomePage") == "https://mine/"
    check cfgInt(c2, "maxHistoryMenuItems") == 5
    check cfgBool(c2, "flBookmarksBar") # defaults stay for what the file doesn't say
  test "a broken config.json leaves the defaults":
    writeFile(dataFolder() / "config.json", "{ nope")
    check cfgInt(readConfig(), "maxRedirects") == 10
  test "cfg helpers with wrong types":
    let c = %*{"s": 1, "i": "x", "b": "true", "f": 2.0}
    check cfgStr(c, "s", "d") == "d"
    check cfgInt(c, "i", 7) == 7
    check cfgInt(c, "f") == 2
    check not cfgBool(c, "b")
    check cfgStr(c, "missing", "d") == "d"

suite "files":
  test "tabs round trip, in the Electron app's shape":
    check readTabs() == (-1, newSeq[SavedTab]())
    writeTabs(1, @[SavedTab(pageHistory: @["https://a/", "https://b/"], ixHistory: 1), SavedTab(ixHistory: -1)])
    let (ix, tabs) = readTabs()
    check ix == 1 and tabs.len == 2 and tabs[0].pageHistory[1] == "https://b/" and tabs[1].ixHistory == -1
    let j = parseFile(dataFolder() / "tabs.json")
    check j["tabs"][0]["ixHistory"].getInt == 1
  test "an ixHistory past the end is pulled back":
    writeFile(dataFolder() / "tabs.json", """{"ixCurrentTab": 0, "tabs": [{"pageHistory": ["https://a/"], "ixHistory": 9}]}""")
    check readTabs()[1][0].ixHistory == 0
  test "history: newest first, cut to the maximum, broken entries skipped":
    writeHistory(@[PageVisit(url: "https://1/", title: "One"), PageVisit(url: "https://2/"), PageVisit(url: "https://3/")], 2)
    let h = readHistory()
    check h.len == 2 and h[0].title == "One"
    writeFile(dataFolder() / "history.json", """[{"url": ""}, {"title": "no url"}, {"url": "https://ok/"}, 5]""")
    check readHistory().len == 1
  test "url history":
    writeUrlHistory(@[PageVisit(url: "https://u/", title: "U", `when`: "2026-01-01")])
    check readUrlHistory()[0].`when` == "2026-01-01"
  test "bookmarks and prefs":
    check readBookmarks() == ""
    writeBookmarks("<opml/>")
    check readBookmarks() == "<opml/>"
    check readPrefs().len == 0
    writePrefs(%*{"nameStylesheet": "book"})
    check readPrefs()["nameStylesheet"].getStr == "book"
  test "no temp file is left behind":
    for f in walkDir(dataFolder()):
      check not f.path.endsWith(".tmp")

suite "handlers":
  test "the user's config wins, a missing one is empty":
    createDir(handlersFolder() / "user" / "json")
    writeFile(handlersFolder() / "user" / "json" / "config.json", """{"ctSpaces": 2}""")
    check handlerConfig("json")["ctSpaces"].getInt == 2
    check handlerConfig("nothing").len == 0
    check not hasUserHandler("json")
    writeFile(handlersFolder() / "user" / "json" / "handler.js", "")
    check hasUserHandler("json")

suite "starting bookmarks":
  test "Docs and Support, then the bar with Home":
    let o = startingBookmarks("https://home/")
    check o.headValue("title") == "Bookmarks"
    check o.body.subs.len == 3
    check o.body.subs[0].att("url") == urlDocs and o.body.subs[1].att("url") == urlSupport
    check o.body.subs[2].att("text") == nameBookmarksBarFolder
    check o.body.subs[2].subs[0].att("type") == "bookmark"
    check startingBookmarks("").body.subs[2].subs.len == 0
  test "dates are RFC 822, GMT":
    check nowUtcString().endsWith(" GMT")
    check parseOpml(toOpml(startingBookmarks("https://h/"))).body.subs.len == 3

removeDir(getEnv("APPDATA"))
