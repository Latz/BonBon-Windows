## End-to-end tests: the real bonbon.exe, the original's shell page in
## WebView2, pages from a local server, a data folder of its own.
##
## The test drives the app the way a reader does, through its menus (a
## WM_COMMAND with the id of the item that has that label), and looks
## inside the page through the Chrome DevTools Protocol, which WebView2
## opens when it's started with a debugging port. Run with `nimble e2e`;
## it needs a desktop, the WebView2 runtime and build\bonbon.exe, by itself:
## the app carries its files and finds the runtime on its own.

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
      of "/attachment.bin": await req.respond(Http200, "some bytes", newHttpHeaders({
        "Content-Type": "application/octet-stream", "Content-Disposition": "attachment; filename=\"bonbon-e2e.bin\""}))
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
  env["LOCALAPPDATA"] = dataRoot / "local" # where the app unpacks its files: fresh each run
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

proc menuIndex(bar: HMENU, title: string): int =
  ## the place of a menu in the menu bar, -1 when it isn't there
  result = -1
  for i in 0 ..< GetMenuItemCount(bar):
    var w = newWString(256)
    w.setLen int(GetMenuStringW(bar, UINT i, &w, 256, MF_BYPOSITION))
    if ($w).replace("&", "") == title: return i

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
let windowPlace = %*{"x": 120, "y": 90, "w": 900, "h": 650, "maximized": false}
writeFile(dataDir / "windowsPrefs.json", $(%*{"nameStylesheet": "book", "window": windowPlace})) # where the window was the last time; the other key is the old version's
doAssert fileExists(exe), "build bonbon.exe first: nimble e2e does"
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
  test "the app's files come out of the exe, and the runtime is found without WebView2Loader.dll":
    var folders: seq[string]
    for kind, path in walkDir(dataRoot / "local" / "BonBon" / "resources"):
      if kind == pcDir: folders.add path
    check folders.len == 1
    if folders.len == 1:
      check fileExists(folders[0] / ".complete")
      check fileExists(folders[0] / "app" / "index.html")
      check not fileExists(folders[0] / "WebView2Loader.dll") # unpacked only when the app's own loader fails
    check "Bookmarks bar" in readFile(dataDir / "bookmarks.opml")

suite "pages":
  test "a link loads in the tab, Back comes back":
    discard js("[...document.querySelectorAll ('.divPage a')].find (a => a.textContent === 'Second').click ()")
    waitForJs("currentTab ().title === 'Second page'")
    app.choose("Back")
    waitForJs("currentTab ().title === 'Home page'")
  test "Ctrl-click on a link opens it in a new tab behind this one, as Cmd-click does on a Mac":
    let n = js("tabs.length").getInt
    discard js("[...document.querySelectorAll ('.divPage a')].find (a => a.textContent === 'Second').dispatchEvent (new MouseEvent ('click', {bubbles: true, cancelable: true, ctrlKey: true}))")
    waitForJs("tabs.length === " & $(n + 1))
    waitForJs("tabs.some (t => t.url === '" & base & "/second.md')")
    check js("currentTab ().title").getStr == "Home page"
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
  test "the menus' Alt letters: Alt+S opens History (the keys posted to the window, no real input)":
    let hwnd = app.mainWindow
    let host = FindWindowExW(hwnd, 0, "Chrome_WidgetWin_0", nil) # WebView2's window, which hands Alt keys to its parent as Windows does
    check host != 0
    proc keyLParam(vk: int, up: bool): LPARAM =
      var l = 1 or (int(MapVirtualKeyW(UINT vk, 0)) shl 16) or 0x20000000 # one press, the scan code, Alt down
      if up: l = l or int(0xC0000000'u32)
      LPARAM l
    # only the presses: an Alt let go while the menu is opening can close it again. Posted keys don't
    # change the keyboard's state, so nothing is left held down
    for vk in [VK_MENU, ord('S')]:
      discard PostMessageW(host, WM_SYSKEYDOWN, WPARAM vk, keyLParam(vk, false))
    let bar = GetMenu(hwnd)
    let ix = menuIndex(bar, "History")
    check ix != -1
    waitUntil("the History menu", proc (): bool = (GetMenuState(bar, UINT ix, MF_BYPOSITION) and MF_HILITE) != 0)
    discard SendMessageW(hwnd, WM_CANCELMODE, 0, 0)
    waitUntil("the menu to close", proc (): bool = (GetMenuState(bar, UINT ix, MF_BYPOSITION) and MF_HILITE) == 0)
  test "Alt+S with the focus in the page opens the History menu (a real click and real keys: BONBON_E2E_REAL_INPUT=1)":
    if getEnv("BONBON_E2E_REAL_INPUT") != "1": skip() # it takes the mouse and the keyboard, so not while someone works at the computer
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
    let ix = menuIndex(bar, "History")
    check ix != -1
    waitUntil("the History menu", proc (): bool = (GetMenuState(bar, UINT ix, MF_BYPOSITION) and MF_HILITE) != 0)
    pressKeys([VK_ESCAPE])
    pressKeys([VK_ESCAPE])

suite "new versions":
  test "a newer release on GitHub is offered in the confirm dialog, once":
    let dialogText = "document.body.innerText" # what's showing; a closed dialog is hidden, so not in it
    # GitHub's answer, made up here: what's offered doesn't depend on what's published
    discard js("""(() => {
      window.fetchBeforeTest = window.fetch;
      window.fetch = (u) => u.includes ('api.github.com') ? Promise.resolve ({ok: true, json: () => Promise.resolve ({tag_name: 'v99.0.0', html_url: 'https://example.com/release'})}) : window.fetchBeforeTest (u);
      localStorage.removeItem ('bonbonUpdateOffered');
      return 1; })()""")
    discard js("bonbonCheckForUpdates ().then (() => 1)")
    waitForJs(dialogText & ".includes ('99.0.0 is available')")
    discard js("[...document.querySelectorAll ('a.btn')].filter (e => e.offsetParent).find (e => e.textContent.trim () === 'Cancel').click ()")
    waitForJs("!(" & dialogText & ").includes ('99.0.0')")
    discard js("bonbonCheckForUpdates ().then (() => 1)") # the second time: not again
    sleep 1000
    check not js(dialogText & ".includes ('99.0.0')").getBool
    discard js("window.fetch = window.fetchBeforeTest; 1")

suite "downloads":
  test "a download asks where to save it, in Windows' Save As dialog, and Cancel saves nothing":
    let downloaded = getHomeDir() / "Downloads" / "bonbon-e2e.bin"
    removeFile(downloaded)
    # from a frame nobody sees, so the shell page stays as it is
    discard js("(() => { const f = document.createElement ('iframe'); f.style.display = 'none'; f.src = '" & base &
      "/attachment.bin'; document.body.appendChild (f); setTimeout (() => f.remove (), 5000); return 1; })()")
    var dialog: HWND
    waitUntil("the Save As dialog", proc (): bool =
      let ws = mainWindows(app.processID, "#32770")
      if ws.len > 0: dialog = ws[0][0]
      dialog != 0)
    check IsWindowEnabled(app.mainWindow) == 0 # modal
    discard PostMessageW(dialog, WM_COMMAND, IDCANCEL, 0)
    waitUntil("the dialog to close", proc (): bool = IsWindow(dialog) == 0)
    sleep 1000
    check not fileExists(downloaded)
    check IsWindowEnabled(app.mainWindow) != 0

  test "the window never leaves the shell: a link the page let through is a download in a frame, and the shell stays":
    discard js("(() => { location.href = '" & base & "/attachment.bin'; return 1; })()")
    var dialog: HWND
    waitUntil("the Save As dialog", proc (): bool =
      let ws = mainWindows(app.processID, "#32770")
      if ws.len > 0: dialog = ws[0][0]
      dialog != 0)
    discard PostMessageW(dialog, WM_COMMAND, IDCANCEL, 0)
    waitUntil("the dialog to close", proc (): bool = IsWindow(dialog) == 0)
    check js("location.origin").getStr == "http://bonbon.example"
    check js("typeof window.mdBrowser.getPage").getStr == "function"

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
  test "the window opened where it was the last time, and that's where it's saved on closing":
    let prefs = parseFile(dataDir / "windowsPrefs.json")
    check prefs{"window"} == windowPlace
    check prefs{"nameStylesheet"}.getStr == "book" # the rest of the file is kept

app.close()
for i in 1 .. 50: # WebView2's own processes let go of the data folder a moment after the app
  try:
    removeDir(dataRoot)
    break
  except OSError: sleep 200
