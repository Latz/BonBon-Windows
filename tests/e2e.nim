## End-to-end tests: the real bonbon.exe, the original's shell page in
## WebView2, pages from a local server, a data folder of its own.
##
## The test drives the app the way a reader does, through its menus (a
## WM_COMMAND with the id of the item that has that label), and looks
## inside the page through the Chrome DevTools Protocol, which WebView2
## opens when it's started with a debugging port. Run with `nimble e2e`;
## it needs a desktop, the WebView2 runtime and build\bonbon.exe with
## WebView2Loader.dll beside it.

import std/[unittest, asynchttpserver, asyncdispatch, strutils, json, os, osproc, strtabs, times, sequtils]
import winim/lean, winim/inc/winhttp
import requests

const
  exe = currentSourcePath.parentDir.parentDir / "build" / "bonbon.exe"
  homePage = "---\ntitle: Home page\n---\n# Welcome\n\nSome *text* and <b>raw html</b>.\n\n[Second](second.md)\n"
  secondPage = "---\ntitle: Second page\n---\n# Second\n\nThe second page.\n"
  bigPage = "---\ntitle: Big page\n---\n# Big\n\n" & "word ".repeat(600_000) & "\n" # 3 MB, past NavigateToString's 2
  pngBytes = "\x89PNG\r\n\x1a\n\0\0\0\rIHDR"

# ---------------------------------------------------------------- the pages

var serverReady: Channel[int]
serverReady.open()

proc serve() {.thread.} =
  {.cast(gcsafe).}:
    let server = newAsyncHttpServer()
    server.listen(Port(0), "127.0.0.1")
    serverReady.send int(server.getPort)
    proc cb(req: Request) {.async, closure, gcsafe.} =
      proc reply(body, contentType: string) {.async.} =
        await req.respond(Http200, body, newHttpHeaders({"Content-Type": contentType}))
      case req.url.path
      of "/index.md": await reply(homePage, "text/markdown; charset=utf-8")
      of "/second.md": await reply(secondPage, "text/markdown; charset=utf-8")
      of "/big.md": await reply(bigPage, "text/markdown; charset=utf-8")
      of "/data.json": await reply("{\"a\":1,\"b\":[true,null]}", "application/json")
      of "/favicon.ico": await reply(pngBytes, "image/png")
      else: await req.respond(Http404, "")
    while true:
      if server.shouldAcceptRequest():
        waitFor server.acceptRequest(cb)
      else:
        poll()

var serverThread: Thread[void]
createThread(serverThread, serve)
let base = "http://127.0.0.1:" & $serverReady.recv()

# ---------------------------------------------------------------- the app

let dataRoot = getTempDir() / "bonbon_e2e_" & $getCurrentProcessId()
let dataDir = dataRoot / "BonBon"
let debugPort = 9300 + getCurrentProcessId() mod 500

proc launch(args: openArray[string] = []): Process =
  var env = newStringTable(modeCaseInsensitive)
  for k, v in envPairs(): env[k] = v
  env["APPDATA"] = dataRoot
  env["BONBON_E2E"] = "1"
  env["WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS"] = "--remote-debugging-port=" & $debugPort
  startProcess(exe, args = args, env = env, options = {})

proc mainWindows(pid: int, classPrefix: string): seq[(HWND, string)] =
  ## the visible top-level windows of the process whose class starts so: (window, title)
  var found: seq[(HWND, string)]
  type Ctx = object
    pid: int
    prefix: string
    found: ptr seq[(HWND, string)]
  var ctx = Ctx(pid: pid, prefix: classPrefix, found: addr found)
  proc each(h: HWND, l: LPARAM): WINBOOL {.stdcall.} =
    let c = cast[ptr Ctx](l)
    var p: DWORD
    discard GetWindowThreadProcessId(h, addr p)
    if int(p) == c.pid and IsWindowVisible(h) != 0:
      var cls = newWString(256)
      cls.setLen int(GetClassNameW(h, &cls, 256))
      if ($cls).startsWith(c.prefix):
        var t = newWString(1024)
        t.setLen int(GetWindowTextW(h, &t, 1024))
        c.found[].add (h, $t)
    TRUE
  discard EnumWindows(each, cast[LPARAM](addr ctx))
  found

proc mainWindow(p: Process): HWND =
  let ws = mainWindows(p.processID, "BonBonMain_")
  if ws.len > 0: ws[0][0] else: 0

proc menuItemId(m: HMENU, label: string): int =
  ## the id of the item with this label, in this menu or one under it; -1 when there's none
  for i in 0 ..< GetMenuItemCount(m):
    let sub = GetSubMenu(m, int32 i)
    if sub != 0:
      let id = menuItemId(sub, label)
      if id != -1: return id
    else:
      var w = newWString(256)
      w.setLen int(GetMenuStringW(m, UINT i, &w, 256, MF_BYPOSITION))
      if ($w).split('\t')[0] == label: return int(GetMenuItemID(m, int32 i))
  -1

proc menuLabels(p: Process, title: string): seq[string] =
  ## the labels in one menu of the menu bar
  let bar = GetMenu(mainWindow(p))
  for i in 0 ..< GetMenuItemCount(bar):
    var w = newWString(256)
    w.setLen int(GetMenuStringW(bar, UINT i, &w, 256, MF_BYPOSITION))
    if ($w).replace("&", "") == title: # the & marks the menu's Alt+letter
      let sub = GetSubMenu(bar, int32 i)
      for j in 0 ..< GetMenuItemCount(sub):
        var t = newWString(256)
        t.setLen int(GetMenuStringW(sub, UINT j, &t, 256, MF_BYPOSITION))
        result.add ($t).split('\t')[0]

proc menuLabelsOf(hwnd: HWND): seq[string] =
  ## the titles in this window's menu bar
  let bar = GetMenu(hwnd)
  for i in 0 ..< GetMenuItemCount(bar):
    var w = newWString(256)
    w.setLen int(GetMenuStringW(bar, UINT i, &w, 256, MF_BYPOSITION))
    result.add $w

proc choose(p: Process, label: string) =
  ## a menu item, chosen
  let hwnd = mainWindow(p)
  let id = menuItemId(GetMenu(hwnd), label)
  doAssert id != -1, "no menu item " & label
  discard PostMessageW(hwnd, WM_COMMAND, WPARAM id, 0)

proc pressKeys(vks: openArray[int]) =
  ## real keystrokes, to whatever has the focus: down in order, up in reverse
  var inputs: seq[INPUT]
  for vk in vks:
    inputs.add INPUT(`type`: INPUT_KEYBOARD)
    inputs[^1].ki.wVk = WORD vk
  for ix in countdown(vks.high, 0):
    inputs.add INPUT(`type`: INPUT_KEYBOARD)
    inputs[^1].ki.wVk = WORD vks[ix]
    inputs[^1].ki.dwFlags = KEYEVENTF_KEYUP
  discard SendInput(UINT inputs.len, addr inputs[0], int32 sizeof(INPUT))
  sleep 200

proc waitUntil(what: string, cond: proc (): bool, timeout = 15.0) =
  let t0 = epochTime()
  while not cond():
    if epochTime() - t0 > timeout: raise newException(AssertionDefect, "timed out waiting for " & what)
    sleep 100

# ---------------------------------------------------------------- the page, through the DevTools Protocol

proc WinHttpWebSocketCompleteUpgrade(hRequest: HINTERNET, pContext: DWORD_PTR): HINTERNET {.stdcall, dynlib: "winhttp", importc.}
proc WinHttpWebSocketSend(hWebSocket: HINTERNET, eBufferType: DWORD, pvBuffer: pointer, dwBufferLength: DWORD): DWORD {.stdcall, dynlib: "winhttp", importc.}
proc WinHttpWebSocketReceive(hWebSocket: HINTERNET, pvBuffer: pointer, dwBufferLength: DWORD, pdwBytesRead: ptr DWORD, peBufferType: ptr DWORD): DWORD {.stdcall, dynlib: "winhttp", importc.}

var socket: HINTERNET
var lastId = 0

proc connectPage() =
  ## the shell page's debugging socket, once WebView2 has opened the port
  var urlSocket = ""
  waitUntil("the debugging port", proc (): bool =
    let r = httpGet("http://127.0.0.1:" & $debugPort & "/json", "*/*")
    if r.err.len == 0 and r.status == 200:
      for t in parseJson(r.body):
        if t{"type"}.getStr == "page" and t{"url"}.getStr.startsWith("http://bonbon.example/"):
          urlSocket = t{"webSocketDebuggerUrl"}.getStr
    urlSocket.len > 0, 30.0)
  let path = urlSocket[urlSocket.find('/', "ws://".len) .. ^1]
  let hSession = WinHttpOpen(&(+$"BonBon e2e"), 1, nil, nil, 0)
  let hConnect = WinHttpConnect(hSession, &(+$"127.0.0.1"), INTERNET_PORT debugPort, 0)
  let hReq = WinHttpOpenRequest(hConnect, &(+$"GET"), &(+$path), nil, nil, nil, 0)
  doAssert WinHttpSetOption(hReq, 114, nil, 0) != 0 # WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET
  doAssert WinHttpSendRequest(hReq, nil, 0, nil, 0, 0, 0) != 0
  doAssert WinHttpReceiveResponse(hReq, nil) != 0
  socket = WinHttpWebSocketCompleteUpgrade(hReq, 0)
  doAssert socket != nil

proc send(meth: string, params: JsonNode): JsonNode =
  inc lastId
  var msg = $(%*{"id": lastId, "method": meth, "params": params})
  doAssert WinHttpWebSocketSend(socket, 2, addr msg[0], DWORD msg.len) == 0 # UTF-8 message
  var buf: array[65536, char]
  var message = ""
  while true: # events come too; the answer is the message with our id
    var got, kind: DWORD
    doAssert WinHttpWebSocketReceive(socket, addr buf[0], DWORD buf.len, addr got, addr kind) == 0
    if got > 0:
      let old = message.len
      message.setLen old + int(got)
      copyMem(addr message[old], addr buf[0], int(got))
    if kind == 2: # the end of a message
      let j = parseJson(message)
      message = ""
      if j{"id"}.getInt == lastId: return j

proc js(expression: string): JsonNode =
  ## the value of a JavaScript expression in the shell page; a promise is waited for
  let r = send("Runtime.evaluate", %*{"expression": expression, "awaitPromise": true, "returnByValue": true})
  if r{"result", "exceptionDetails"} != nil:
    raise newException(AssertionDefect, "JavaScript failed: " & $r["result"]["exceptionDetails"])
  r{"result", "result", "value"}

proc waitForJs(expression: string, timeout = 15.0) =
  waitUntil(expression, proc (): bool = js(expression).getBool, timeout)

# ---------------------------------------------------------------- the tests

createDir(dataDir)
writeFile(dataDir / "config.json", $(%*{"urlHomePage": base & "/index.md", "urlHitCounterServer": base & "/hello"})) # the hit counter counts here, not at scripting.com
doAssert fileExists(exe), "build bonbon.exe first: nimble e2e does"
doAssert fileExists(exe.parentDir / "WebView2Loader.dll"), "WebView2Loader.dll has to be beside " & exe
let app = launch()
waitUntil("the window", proc (): bool = mainWindow(app) != 0)
connectPage()
waitForJs("typeof tabs !== 'undefined' && tabs.length > 0", 30.0) # index.js is up

suite "the first run":
  test "the home page from config.json, its title from the front matter":
    waitForJs("currentTab ().title === 'Home page' && document.querySelector ('.divPage h1') !== null") # drawn, not only fetched
    check js("document.title").getStr == "Home page"
  test "marked converted the Markdown, and the page's HTML is gone":
    check js("document.querySelector ('.divPage h1').textContent").getStr == "Welcome"
    check js("document.querySelector ('.divPage em').textContent").getStr == "text"
    check js("document.querySelector ('.divPage b') === null").getBool
  test "the window's title is the page's":
    waitUntil("the title", proc (): bool = mainWindows(app.processID, "BonBonMain_")[0][1] == "Home page")
  test "the data folder is seeded":
    for f in ["stylesheets" / "basic.css", "stylesheets" / "fonts" / "eb-garamond.css",
              "handlers" / "system" / "json" / "handler.js"]:
      check fileExists(dataDir / f)
    waitUntil("bookmarks.opml", proc (): bool = fileExists(dataDir / "bookmarks.opml"))
    check "Bookmarks bar" in readFile(dataDir / "bookmarks.opml")

suite "pages":
  test "a link loads in the tab, Back comes back":
    discard js("[...document.querySelectorAll ('.divPage a')].find (a => a.textContent === 'Second').click ()")
    waitForJs("currentTab ().title === 'Second page'")
    app.choose("Back")
    waitForJs("currentTab ().title === 'Home page'")
  test "the History menu lists the pages":
    waitUntil("History", proc (): bool = "Second page" in app.menuLabels("History"))
    check "Home page" in app.menuLabels("History")
  test "the site's icon comes as a data URL":
    check js("mdBrowser.getFavicon ('" & base & "/index.md')").getStr.startsWith("data:image/png;base64,")
  test "JSON goes to the json handler, which runs in the sandbox":
    discard js("loadUrl (currentTab (), '" & base & "/data.json')")
    waitForJs("currentTab ().kind === 'handler'")
    check "\"a\": 1" in js("document.querySelector ('.divPage code').textContent").getStr
  test "a page that isn't there says so":
    let r = js("mdBrowser.getPage ('" & base & "/nothere.md')")
    check not r["flOk"].getBool and r["status"].getInt == 404

suite "the stylesheets":
  test "listed from the data folder, served to the page":
    check js("mdBrowser.getStylesheets ().then (l => l.map (s => s.name).join (','))").getStr ==
      "basic,book,classic,mono,newsprint"
    check js("mdBrowser.getStylesheets ().then (l => fetch (l [1].url)).then (r => r.status)").getInt == 200

suite "the menus":
  test "New Tab and Close Tab":
    let n = js("tabs.length").getInt
    app.choose("New Tab")
    waitForJs("tabs.length === " & $(n + 1))
    app.choose("Close Tab")
    waitForJs("tabs.length === " & $n)
  test "View Source opens a window with the text as it came":
    discard js("loadUrl (currentTab (), '" & base & "/second.md')")
    waitForJs("currentTab ().title === 'Second page'")
    app.choose("View Source")
    waitUntil("the source window", proc (): bool = mainWindows(app.processID, "BonBonSource").len > 0)
    let (h, title) = mainWindows(app.processID, "BonBonSource")[0]
    check title == "view-source:" & base & "/second.md"
    check "History" in menuLabelsOf(h).mapIt(it.replace("&", "")) # the menu bar in every window, as in Electron
    discard PostMessageW(h, WM_CLOSE, 0, 0)
    waitUntil("the source window to close", proc (): bool = mainWindows(app.processID, "BonBonSource").len == 0)
  test "View Source shows a source past 2 MB":
    discard js("loadUrl (currentTab (), '" & base & "/big.md')")
    waitForJs("currentTab ().title === 'Big page'", 30.0)
    app.choose("View Source")
    waitUntil("the source window", proc (): bool = mainWindows(app.processID, "BonBonSource").len > 0)
    # its page's title shows up in the debugging port's list only once the page has loaded
    waitUntil("the big source to load", proc (): bool =
      let r = httpGet("http://127.0.0.1:" & $debugPort & "/json", "*/*")
      r.err.len == 0 and r.status == 200 and
        parseJson(r.body).getElems.anyIt(it{"title"}.getStr == "view-source:" & base & "/big.md"), 30.0)
    discard PostMessageW(mainWindows(app.processID, "BonBonSource")[0][0], WM_CLOSE, 0, 0)
    waitUntil("the source window to close", proc (): bool = mainWindows(app.processID, "BonBonSource").len == 0)
    discard js("loadUrl (currentTab (), '" & base & "/second.md')")
    waitForJs("currentTab ().title === 'Second page'")
  test "Developer Tools opens DevTools, and closes them the second time, as Electron's toggle does":
    let title = "DevTools - bonbon.example/index.html"
    app.choose("Developer Tools")
    waitUntil("DevTools", proc (): bool = FindWindowW(nil, title) != 0)
    app.choose("Developer Tools")
    waitUntil("DevTools to close", proc (): bool = FindWindowW(nil, title) == 0)
  test "Find opens the page's find bar":
    app.choose("Find...")
    waitForJs("getComputedStyle (document.querySelector ('.divFindBar')).display !== 'none'")
    discard js("document.dispatchEvent (new KeyboardEvent ('keydown', {key: 'Escape'}))")
  test "Alt+S in the page opens the History menu":
    let hwnd = app.mainWindow
    # a real click into the page, at its blank bottom-left: a test in the background can't SetForegroundWindow
    discard SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE)
    var rc: RECT
    discard GetClientRect(hwnd, addr rc)
    var pt = POINT(x: rc.left + 10, y: rc.bottom - 10)
    discard ClientToScreen(hwnd, addr pt)
    discard SetCursorPos(pt.x, pt.y)
    var click: seq[INPUT]
    for flags in [MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP]:
      click.add INPUT(`type`: INPUT_MOUSE)
      click[^1].mi.dwFlags = DWORD flags
    discard SendInput(2, addr click[0], int32 sizeof(INPUT))
    discard SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE)
    sleep 300
    pressKeys([VK_MENU, ord('S')])
    let bar = GetMenu(hwnd)
    var ix = -1
    for i in 0 ..< GetMenuItemCount(bar):
      var w = newWString(256)
      w.setLen int(GetMenuStringW(bar, UINT i, &w, 256, MF_BYPOSITION))
      if ($w).replace("&", "") == "History": ix = i
    check ix != -1
    waitUntil("the History menu", proc (): bool = (GetMenuState(bar, UINT ix, MF_BYPOSITION) and MF_HILITE) != 0)
    pressKeys([VK_ESCAPE])
    pressKeys([VK_ESCAPE])

suite "tabs and the one instance":
  test "the tabs are saved":
    waitUntil("tabs.json", proc (): bool = fileExists(dataDir / "tabs.json") and "/second.md" in readFile(dataDir / "tabs.json"))
  test "a second launch hands its address to the first, in a new tab":
    let n = js("tabs.length").getInt
    let second = launch([base & "/index.md?again"])
    check second.waitForExit(10_000) == 0
    second.close()
    waitForJs("tabs.length === " & $(n + 1))
    waitForJs("tabs.some (t => t.url === '" & base & "/index.md?again')") # behind the current one, as the original opens it
  test "closing the last tab closes the app and leaves tabs.json alone":
    while js("tabs.length").getInt > 1:
      app.choose("Close Tab")
      sleep 300
    # saveTabs writes a second after the last change, and a page still loading
    # changes its tab later: wait until the file has been the same for 2 s
    var saved = readFile(dataDir / "tabs.json")
    var since = epochTime()
    waitUntil("tabs.json to settle", proc (): bool =
      let now = readFile(dataDir / "tabs.json")
      if now != saved:
        saved = now
        since = epochTime()
      epochTime() - since >= 2.0)
    app.choose("Close Tab")
    check app.waitForExit(10_000) == 0
    check readFile(dataDir / "tabs.json") == saved

app.close()
for i in 1 .. 50: # WebView2's own processes let go of the data folder a moment after the app
  try:
    removeDir(dataRoot)
    break
  except OSError: sleep 200
