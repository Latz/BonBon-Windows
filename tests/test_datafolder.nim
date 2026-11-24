import std/[unittest, os, json, strutils]
putEnv("APPDATA", getTempDir() / "bonbon_test_data_" & $getCurrentProcessId())
import datafolder

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
  test "text and JSON round trip, nothing there is false and nil":
    check readText("nothing.txt") == (false, "")
    check readJson("nothing.json") == nil
    writeText("tabs.json", """{"ixCurrentTab": 1, "tabs": []}""")
    check readText("tabs.json")[0]
    check readJson("tabs.json")["ixCurrentTab"].getInt == 1
  test "a file that isn't JSON is nil":
    writeText("broken.json", "{ nope")
    check readJson("broken.json") == nil
  test "no temp file is left behind":
    for f in walkDir(dataFolder()):
      check not f.path.endsWith(".tmp")

suite "handlers":
  test "seeding makes both folders":
    seedHandlers()
    check dirExists(handlersFolder() / "user")
  test "none for an extension nobody handles":
    check findHandler("nothing", 5) == nil
  test "the user's wins, with its config":
    createDir(handlersFolder() / "user" / "json")
    writeFile(handlersFolder() / "user" / "json" / "handler.js", "function handler (options, callback) {}")
    writeFile(handlersFolder() / "user" / "json" / "config.json", """{"ctSpaces": 2}""")
    let h = findHandler("json", 7)
    check h["code"].getStr.startsWith("function handler")
    check h["config"]["ctSpaces"].getInt == 2
    check h["ctSecsTimeout"].getInt == 7 and h["version"].getStr == appVersion
    check not h.hasKey("configError")
  test "a broken config.json says so, and the handler isn't run":
    writeFile(handlersFolder() / "user" / "json" / "config.json", "{ nope")
    check findHandler("json", 5)["configError"].getStr.startsWith("its config.json isn't valid JSON")
  test "getExtensionForPage":
    let config = defaultConfig()
    check getExtensionForPage(config, "https://a.com/x", "application/json; charset=utf-8") == "json"
    check getExtensionForPage(config, "https://a.com/x.JS", "text/plain") == "js"
    check getExtensionForPage(config, "https://a.com/dir.x/file", "") == ""
    check getExtensionForPage(config, "https://a.com/x.a%2Fb", "") == ""
    check getExtensionForPage(nil, "https://a.com/x.yaml", "") == "yaml"

removeDir(getEnv("APPDATA"))
