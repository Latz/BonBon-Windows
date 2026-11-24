## datafolder.nim -- the reader's data folder, %APPDATA%\BonBon, the same
## folder Electron's BonBon uses on Windows, so tabs.json, bookmarks.opml,
## history.json, urlHistory.json and config.json carry over.

import std/[os, json, strutils]
import urls

const
  appName* = "BonBon"
  appVersion* = "1.0.2"
  fnameConfig = "config.json"
  maxUrlHistory* = 10000

proc dataFolder*(): string =
  result = getEnv("APPDATA") / appName
  createDir(result)

proc resourcesFolder*(): string =
  ## the app's own files: config.json's seed, the handlers, the shell page (app)
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

proc readText*(fname: string): (bool, string) =
  ## a file in the data folder; false when it isn't there
  try: (true, readFile(dataFolder() / fname))
  except CatchableError: (false, "")

proc writeText*(fname, text: string) =
  try:
    let path = dataFolder() / fname
    writeFile(path & ".tmp", text)
    moveFile(path & ".tmp", path) # whole or not at all
  except CatchableError as e:
    echo "Can't save " & fname & " because " & e.msg

proc readJson*(fname: string): JsonNode =
  ## nil when the file isn't there or isn't JSON
  let (ok, text) = readText(fname)
  if not ok: return nil
  try: parseJson(text) except CatchableError: nil

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

proc findHandler*(theExtension: string, ctSecsTimeout: int): JsonNode =
  ## the user's if there is one, ours if not: {extension, code, config,
  ## ctSecsTimeout, version}, with configError when its config.json is broken;
  ## nil when there's none. It runs in the page, see bridge.js.
  for nameFolder in ["user", "system"]:
    let folder = handlersFolder() / nameFolder / theExtension
    var code: string
    try: code = readFile(folder / "handler.js")
    except CatchableError: continue
    result = %*{"extension": theExtension, "code": code, "config": {},
      "ctSecsTimeout": ctSecsTimeout, "version": appVersion}
    if fileExists(folder / "config.json"):
      try: result["config"] = parseFile(folder / "config.json")
      except CatchableError as e: result["configError"] = %("its config.json isn't valid JSON: " & e.msg)
    return

proc getExtensionForPage*(config: JsonNode, theUrl, contentType: string): string =
  ## which handler gets a page: the server's type when it's in the table, the
  ## extension on the address when it isn't; "" when there's neither
  let theType = contentType.split(';')[0].strip.toLowerAscii
  let table = if config == nil: nil else: config{"extensionsForTypes"}
  if table != nil and table.kind == JObject and table.hasKey(theType) and table[theType].kind == JString:
    return table[theType].getStr.toLowerAscii
  let p = urlPath(theUrl).toLowerAscii
  if p.rfind('.') > p.rfind('/'):
    let ext = p[p.rfind('.') + 1 .. ^1]
    var ok = ext.len > 0
    for c in ext:
      if c notin {'a'..'z', '0'..'9', '_', '-'}: ok = false # it names a folder: nothing that walks out of it
    if ok: return ext
  ""
