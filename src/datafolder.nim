## datafolder.nim -- the reader's data folder, %APPDATA%\BonBon, the same
## folder Electron's BonBon uses on Windows, so tabs.json, bookmarks.opml,
## history.json, urlHistory.json and config.json carry over.

import std/[os, json, strutils, times]
import opml

const
  appName* = "BonBon"
  appVersion* = "0.6.56"
  fnameConfig = "config.json"
  fnameTabs = "tabs.json"
  fnameBookmarks = "bookmarks.opml"
  fnameHistory = "history.json"
  fnameUrlHistory = "urlHistory.json"
  fnamePrefs = "windowsPrefs.json"  ## what localStorage held in the original: the stylesheet, the sidebar
  maxUrlHistory* = 10000

proc dataFolder*(): string =
  result = getEnv("APPDATA") / appName
  createDir(result)

proc resourcesFolder*(): string =
  ## the app's own files: config.json's seed, the handlers
  result = getAppDir() / "resources"
  if not dirExists(result): result = getAppDir().parentDir / "resources"

# ---------------------------------------------------------------- config

proc defaultConfig*(): JsonNode =
  %*{"windowWidth": 1000, "windowHeight": 800, "maxRedirects": 10,
     "urlHomePage": "https://dave.writersweb.org/", "maxHistoryMenuItems": 25,
     "flBookmarksBar": true, "flLavenderLines": false, "urlUserCss": "", "flCalendar": false,
     "urlHitCounterServer": "https://counters.scripting.com/hello",
     "urlForHitCounter": "https://github.com/scripting/bonBon",
     "extensionsForTypes": {"application/json": "json", "application/javascript": "js",
       "application/x-javascript": "js", "text/javascript": "js"},
     "ctSecsHandlerTimeout": 5, "flOpenPdfsInSystemViewer": false}

proc readConfig*(): JsonNode =
  ## config.json lives in the data folder; the one in the app is the seed. The
  ## first run copies it; after that it's the reader's file.
  result = defaultConfig()
  let pathConfig = dataFolder() / fnameConfig
  if not fileExists(pathConfig):
    try:
      let seed = resourcesFolder() / fnameConfig
      if fileExists(seed): copyFile(seed, pathConfig)
      else: writeFile(pathConfig, result.pretty)
    except CatchableError: discard
  try:
    let j = parseFile(pathConfig)
    if j.kind == JObject:
      for k, v in j: result[k] = v
  except CatchableError: discard

proc cfgStr*(c: JsonNode, k: string, default = ""): string =
  if c.hasKey(k) and c[k].kind == JString: c[k].getStr else: default
proc cfgInt*(c: JsonNode, k: string, default = 0): int =
  if c.hasKey(k) and c[k].kind in {JInt, JFloat}: int(c[k].getFloat) else: default
proc cfgBool*(c: JsonNode, k: string, default = false): bool =
  if c.hasKey(k) and c[k].kind == JBool: c[k].getBool else: default

# ---------------------------------------------------------------- files

proc readJsonFile(fname: string): JsonNode =
  try: parseFile(dataFolder() / fname)
  except CatchableError: nil

proc writeJsonFile(fname: string, j: JsonNode) =
  try:
    let path = dataFolder() / fname
    writeFile(path & ".tmp", j.pretty.replace("  ", "\t"))
    moveFile(path & ".tmp", path) # whole or not at all
  except CatchableError: discard

type
  SavedTab* = object
    pageHistory*: seq[string]
    ixHistory*: int
  PageVisit* = object
    url*, title*, `when`*: string

proc readTabs*(): (int, seq[SavedTab]) =
  let j = readJsonFile(fnameTabs)
  if j == nil or j.kind != JObject: return (-1, @[])
  result[0] = j{"ixCurrentTab"}.getInt(0)
  for t in j{"tabs"}.getElems:
    var s = SavedTab(ixHistory: t{"ixHistory"}.getInt(-1))
    for u in t{"pageHistory"}.getElems:
      s.pageHistory.add u.getStr
    s.ixHistory = min(s.ixHistory, s.pageHistory.high)
    result[1].add s

proc writeTabs*(ixCurrentTab: int, tabs: seq[SavedTab]) =
  var arr = newJArray()
  for t in tabs: arr.add %*{"pageHistory": t.pageHistory, "ixHistory": t.ixHistory}
  writeJsonFile(fnameTabs, %*{"ixCurrentTab": ixCurrentTab, "tabs": arr})

proc readVisits(fname: string): seq[PageVisit] =
  let j = readJsonFile(fname)
  if j == nil or j.kind != JArray: return
  for v in j:
    if v.kind == JObject and v{"url"}.getStr.len > 0:
      result.add PageVisit(url: v{"url"}.getStr, title: v{"title"}.getStr, `when`: v{"when"}.getStr)

proc writeVisits(fname: string, list: seq[PageVisit], max: int) =
  var arr = newJArray()
  for i, v in list:
    if i >= max: break
    arr.add %*{"url": v.url, "title": v.title, "when": v.`when`}
  writeJsonFile(fname, arr)

proc readHistory*(): seq[PageVisit] = readVisits(fnameHistory)
proc writeHistory*(list: seq[PageVisit], max: int) = writeVisits(fnameHistory, list, max)
proc readUrlHistory*(): seq[PageVisit] = readVisits(fnameUrlHistory)
proc writeUrlHistory*(list: seq[PageVisit]) = writeVisits(fnameUrlHistory, list, maxUrlHistory)

proc readBookmarks*(): string =
  ## the opml text, or "" the first time
  try: readFile(dataFolder() / fnameBookmarks) except CatchableError: ""

proc writeBookmarks*(opmltext: string) =
  try: writeFile(dataFolder() / fnameBookmarks, opmltext) except CatchableError: discard

proc readPrefs*(): JsonNode =
  result = readJsonFile(fnamePrefs)
  if result == nil or result.kind != JObject: result = newJObject()

proc writePrefs*(j: JsonNode) = writeJsonFile(fnamePrefs, j)

# ---------------------------------------------------------------- handlers

proc handlersFolder*(): string = dataFolder() / "handlers"

proc seedHandlers*() =
  ## the system folder is replaced with the app's; the user folder is made if
  ## it isn't there, and never touched after that
  try:
    let src = resourcesFolder() / "handlers" / "system"
    let dst = handlersFolder() / "system"
    if dirExists(src):
      if dirExists(dst): removeDir(dst)
      copyDir(src, dst)
    createDir(handlersFolder() / "user")
  except CatchableError: discard

proc handlerConfig*(ext: string): JsonNode =
  for sub in ["user", "system"]:
    let p = handlersFolder() / sub / ext / "config.json"
    if fileExists(p):
      try: return parseFile(p)
      except CatchableError: return newJObject()
  newJObject()

proc hasUserHandler*(ext: string): bool = fileExists(handlersFolder() / "user" / ext / "handler.js")

# ---------------------------------------------------------------- the starting bookmarks

const
  nameBookmarksBarFolder* = "Bookmarks bar"
  urlDocs* = "https://github.com/scripting/bonBon/tree/main/docs"
  urlSupport* = "https://github.com/scripting/bonBon/issues"

proc nowUtcString*(): string =
  now().utc.format("ddd, dd MMM yyyy HH:mm:ss") & " GMT"

proc newBookmark*(text, url: string): OutlineNode =
  newOutlineNode({"text": text, "url": url, "type": "bookmark", "icon": "bookmark", "created": nowUtcString()})

proc startingBookmarks*(urlHomePage: string): Outline =
  ## Docs and Support at the top, then the Bookmarks bar headline with Home under it
  result = newOutline()
  let now = nowUtcString()
  result.head = @[("title", "Bookmarks"), ("dateCreated", now), ("dateModified", now)]
  let folder = newOutlineNode({"text": nameBookmarksBarFolder, "created": now})
  if urlHomePage.len > 0: folder.subs.add newBookmark("Home", urlHomePage)
  result.body.subs = @[newBookmark("Docs", urlDocs), newBookmark("Support", urlSupport), folder]
