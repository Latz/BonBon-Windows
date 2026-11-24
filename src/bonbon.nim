## BonBon for Windows -- a browser for a web made of Markdown files.
##
## main.js of BonBon 0.6.56 (Electron, by Dave Winer), in Nim. One window,
## the original's shell page in it (resources/app: index.html, index.js,
## index.css, unchanged), shown by WebView2. The page asks for what it needs
## through window.mdBrowser, which bridge.js makes the way preload.js does;
## the requests, the files in the data folder and the menus are here.

{.link: "bonbon_res.o".}

import std/[os, strutils, json, tables, algorithm, sequtils, hashes]
import winim/lean, winim/inc/[shellapi, winreg, objbase]
import urls, requests, datafolder, workers, winutil, webview2, embedded, darkmode

const
  classSource = "BonBonSource"
  hostApp = "bonbon.example"                   ## the shell page's files, resources/app
  hostStylesheets = "stylesheets.bonbon.example" ## the data folder's stylesheets; a page can't link file:// addresses
  urlShellPage = "http://" & hostApp & "/index.html" # http, not https, so pictures from http sites still load, as they do from Electron's file:// page
  bridgeScript = staticRead("bridge.js").multiReplace(
    ("/*MARKED*/", staticRead("../resources/app/node_modules/marked/marked.min.js")),
    ("/*JSYAML*/", staticRead("../resources/app/node_modules/js-yaml/dist/js-yaml.min.js")),
    ("/*DARKCSS*/\"\"", escapeJson(staticRead("dark.css")))) # a JSON string is a JavaScript string

type
  Cmd = enum
    cmdNone, cmdAbout, cmdQuit, cmdNewTab, cmdCloseTab, cmdOpenDataFolder,
    cmdUndo, cmdRedo, cmdCut, cmdCopy, cmdPaste, cmdPasteAndMatchStyle, cmdDelete, cmdSelectAll,
    cmdFind, cmdFindNext, cmdFindPrevious, cmdReload, cmdViewSource, cmdDevTools,
    cmdHome, cmdBack, cmdForward, cmdAddBookmark, cmdEditBookmarks, cmdMinimize, cmdZoom
  Key = object
    vk: int
    ctrl, shift, alt: bool
    cmd: Cmd
  PendingCall = object
    id: JsonNode    ## the page's call id
    urlAsked: string
    flAsItCame: bool

const
  cmdMenuItemBase = 1000 ## + index in menuItemCommands: the History and Bookmarks menus' pages

  keys = [ # the menu's keys; Edit's are the page's own (Ctrl+C in the page is the page's), so they aren't here
    Key(vk: ord('T'), ctrl: true, cmd: cmdNewTab),
    Key(vk: ord('W'), ctrl: true, cmd: cmdCloseTab),
    Key(vk: ord('F'), ctrl: true, cmd: cmdFind),
    Key(vk: ord('G'), ctrl: true, cmd: cmdFindNext),
    Key(vk: ord('G'), ctrl: true, shift: true, cmd: cmdFindPrevious),
    Key(vk: ord('R'), ctrl: true, cmd: cmdReload),
    Key(vk: ord('U'), ctrl: true, alt: true, cmd: cmdViewSource),
    Key(vk: ord('I'), ctrl: true, alt: true, cmd: cmdDevTools),
    Key(vk: ord('H'), ctrl: true, shift: true, cmd: cmdHome),
    Key(vk: VK_OEM_4, ctrl: true, cmd: cmdBack),
    Key(vk: VK_OEM_6, ctrl: true, cmd: cmdForward),
    Key(vk: ord('D'), ctrl: true, cmd: cmdAddBookmark),
    Key(vk: ord('M'), ctrl: true, cmd: cmdMinimize)]

let classMain = "BonBonMain_" & toHex(hash(dataFolder().toLowerAscii)) ## one BonBon per data folder: a second launch finds the first by it

var
  hInst: HINSTANCE
  hwndMain: HWND
  hAccel: HACCEL
  iconApp: HICON
  config: JsonNode
  env, ctrlMain, wvMain: pointer
  sourceWindows: Table[HWND, pointer] ## View Source windows and their controllers
  flLoaded = false                    ## the shell page finished loading
  urlsWaitingToOpen: seq[string]      ## bon:// links that arrived before it did
  recentPages = newJArray()           ## the History menu, from history.json, then from the page
  bookmarksOutline: JsonNode          ## the Bookmarks menu, the outline the page sends
  menuItemCommands: seq[(string, string)] ## (command, url) for each page in the History and Bookmarks menus
  pendingCalls: Table[int, PendingCall]   ## job id -> the call waiting for it
  flAltAlone = false                  ## Alt went down in the page with nothing after it: the menu bar, as in any window

# ---------------------------------------------------------------- talking to the page

proc post(j: JsonNode) =
  if wvMain != nil: postWebMessageAsJson(wvMain, $j)

proc reply(id: JsonNode, result: JsonNode = nil) =
  ## the answer to one of the page's calls; nil is undefined there
  let j = %*{"id": id}
  if result != nil: j["result"] = result
  post j

proc sendCommand(command: string, param = "") =
  ## a menu command, to the page
  let j = %*{"command": command}
  if param.len > 0: j["param"] = %param
  post j

# ---------------------------------------------------------------- files in the data folder

proc moveDataFromOldName() =
  ## the app was Markdown Browser, then BonBon Browser, on 10/13/26; the first
  ## time the new folder is empty, tabs, bookmarks and history come over
  if fileExists(dataFolder() / "tabs.json"): return
  for oldName in ["BonBon Browser", "Markdown Browser"]:
    let oldFolder = dataFolder().parentDir / oldName
    if fileExists(oldFolder / "tabs.json"):
      for fname in ["tabs.json", "bookmarks.opml", "history.json"]:
        try: copyFile(oldFolder / fname, dataFolder() / fname) except CatchableError: discard
      return

# ---------------------------------------------------------------- stylesheets

proc stylesheetsFolder(): string = dataFolder() / "stylesheets"

proc seedStylesheets() =
  ## any file the data folder's stylesheets folder doesn't have yet comes from
  ## the app's, so an edited stylesheet is never overwritten
  proc copyMissing(folderFrom, folderTo: string) =
    createDir(folderTo)
    for kind, path in walkDir(folderFrom):
      let pathTo = folderTo / path.extractFilename
      if kind == pcDir: copyMissing(path, pathTo)
      elif not fileExists(pathTo): copyFile(path, pathTo)
  try:
    let pathReader = stylesheetsFolder() / "reader.css"
    let pathBasic = stylesheetsFolder() / "basic.css" # Reader became Basic the day it shipped
    if fileExists(pathReader) and not fileExists(pathBasic): moveFile(pathReader, pathBasic)
    copyMissing(resourcesFolder() / "app" / "stylesheets", stylesheetsFolder())
  except CatchableError as e:
    echo "Can't copy the stylesheets to the data folder because " & e.msg

proc getStylesheets(): JsonNode =
  ## the .css files in the folder, sorted by name: [{name, title, url}]
  result = newJArray()
  var names: seq[string]
  for kind, path in walkDir(stylesheetsFolder()):
    let fname = path.extractFilename
    if kind == pcFile and fname.toLowerAscii.endsWith(".css") and not fname.startsWith("."): names.add fname
  names.sort(system.cmp)
  for fname in names:
    let name = fname[0 ..< ^4]
    result.add %*{"name": name, "title": name[0 .. 0].toUpperAscii & name[1 .. ^1],
      "url": "http://" & hostStylesheets & "/" & encodeURIComponent(fname)}

# ---------------------------------------------------------------- the menus

proc addItem(m: HMENU, label: string, id: int, key = "") =
  discard AppendMenuW(m, MF_STRING, UINT_PTR id, if key.len > 0: label & "\t" & key else: label)

proc addSeparator(m: HMENU) = discard AppendMenuW(m, MF_SEPARATOR, 0, nil)

proc addSubmenu(m, sub: HMENU, label: string) = discard AppendMenuW(m, MF_POPUP, cast[UINT_PTR](sub), label)

proc addPageItem(m: HMENU, label, command, url: string) =
  menuItemCommands.add (command, url)
  addItem(m, label, cmdMenuItemBase + menuItemCommands.high)

proc addBookmarksMenuItems(m: HMENU, theSubs: JsonNode) =
  ## a headline with sub-heads is a submenu, a headline that is a single dash
  ## is a separator, anything else with a url is a bookmark
  if theSubs == nil or theSubs.kind != JArray: return
  for theNode in theSubs:
    let theText = theNode{"text"}.getStr
    if theNode{"subs"} != nil:
      let sub = CreatePopupMenu()
      addBookmarksMenuItems(sub, theNode{"subs"})
      addSubmenu(m, sub, getMenuItemLabel(theText))
    elif theText.strip == "-": addSeparator(m)
    elif theNode{"url"} != nil:
      addPageItem(m, getMenuItemLabel(theText), "openBookmark", theNode{"url"}.getStr)

proc menuBar(): HMENU =
  ## one copy of the menu bar; a window can't share its menu with another
  let appMenu = CreatePopupMenu()
  addItem(appMenu, "About", ord cmdAbout)
  addSeparator(appMenu)
  addItem(appMenu, "Exit", ord cmdQuit)
  let fileMenu = CreatePopupMenu()
  addItem(fileMenu, "New Tab", ord cmdNewTab, "Ctrl+T")
  addItem(fileMenu, "Close Tab", ord cmdCloseTab, "Ctrl+W")
  addSeparator(fileMenu)
  addItem(fileMenu, "Open Data Folder", ord cmdOpenDataFolder)
  let editMenu = CreatePopupMenu()
  addItem(editMenu, "Undo", ord cmdUndo, "Ctrl+Z")
  addItem(editMenu, "Redo", ord cmdRedo, "Ctrl+Shift+Z") # the original's key; Ctrl+Y redoes too, in the page
  addSeparator(editMenu)
  addItem(editMenu, "Cut", ord cmdCut, "Ctrl+X")
  addItem(editMenu, "Copy", ord cmdCopy, "Ctrl+C")
  addItem(editMenu, "Paste", ord cmdPaste, "Ctrl+V")
  addItem(editMenu, "Paste and Match Style", ord cmdPasteAndMatchStyle, "Ctrl+Shift+V")
  addItem(editMenu, "Delete", ord cmdDelete)
  addItem(editMenu, "Select All", ord cmdSelectAll, "Ctrl+A")
  addSeparator(editMenu)
  addItem(editMenu, "Find...", ord cmdFind, "Ctrl+F")
  addItem(editMenu, "Find Next", ord cmdFindNext, "Ctrl+G")
  addItem(editMenu, "Find Previous", ord cmdFindPrevious, "Ctrl+Shift+G")
  let viewMenu = CreatePopupMenu()
  addItem(viewMenu, "Reload This Page", ord cmdReload, "Ctrl+R")
  addSeparator(viewMenu)
  addItem(viewMenu, "View Source", ord cmdViewSource, "Ctrl+Alt+U")
  addItem(viewMenu, "Developer Tools", ord cmdDevTools, "Ctrl+Alt+I")
  let historyMenu = CreatePopupMenu()
  addItem(historyMenu, "Home", ord cmdHome, "Ctrl+Shift+H")
  addItem(historyMenu, "Back", ord cmdBack, "Ctrl+[")
  addItem(historyMenu, "Forward", ord cmdForward, "Ctrl+]")
  var flFirst = true
  for ix, thePage in recentPages.getElems:
    if ix >= cfgInt(config, "maxHistoryMenuItems", 25): break
    if flFirst:
      addSeparator(historyMenu)
      flFirst = false
    let title = thePage{"title"}.getStr
    addPageItem(historyMenu, getMenuItemLabel(if title.len == 0: thePage{"url"}.getStr else: title),
      "openUrl", thePage{"url"}.getStr)
  let bookmarksMenu = CreatePopupMenu() # the bookmarks go between the two commands, the way Dave's menu lays it out
  addItem(bookmarksMenu, "Add Bookmark...", ord cmdAddBookmark, "Ctrl+D")
  if bookmarksOutline != nil:
    let theSubs = bookmarksOutline{"opml", "body", "subs"}
    if theSubs != nil and theSubs.len > 0:
      addSeparator(bookmarksMenu)
      addBookmarksMenuItems(bookmarksMenu, theSubs)
  addSeparator(bookmarksMenu)
  addItem(bookmarksMenu, "Edit Bookmarks...", ord cmdEditBookmarks)
  let windowMenu = CreatePopupMenu()
  addItem(windowMenu, "Minimize", ord cmdMinimize, "Ctrl+M")
  addItem(windowMenu, "Zoom", ord cmdZoom)
  let bar = CreateMenu()
  # the & marks the Alt+letter of each menu, Chrome's where it has the menu
  addSubmenu(bar, appMenu, "B&onBon")
  addSubmenu(bar, fileMenu, "&File")
  addSubmenu(bar, editMenu, "&Edit")
  addSubmenu(bar, viewMenu, "&View")
  addSubmenu(bar, historyMenu, "Hi&story")
  addSubmenu(bar, bookmarksMenu, "&Bookmarks")
  addSubmenu(bar, windowMenu, "&Window")
  bar

proc setMenuBar(hwnd: HWND) =
  let old = GetMenu(hwnd)
  discard SetMenu(hwnd, menuBar())
  if old != 0: discard DestroyMenu(old)

proc buildMenu() =
  ## the menu bar in every window, as Electron's application menu is
  menuItemCommands.setLen 0
  setMenuBar(hwndMain)
  for h in sourceWindows.keys: setMenuBar(h)

proc buildAccelerators() =
  ## the same keys, for when the window itself has the focus and not the page
  var table: seq[ACCEL]
  for k in keys:
    var flags = FVIRTKEY
    if k.ctrl: flags = flags or FCONTROL
    if k.shift: flags = flags or FSHIFT
    if k.alt: flags = flags or FALT
    table.add ACCEL(fVirt: BYTE flags, key: WORD k.vk, cmd: WORD ord(k.cmd))
  hAccel = CreateAcceleratorTableW(addr table[0], int32 table.len)

proc isDown(vk: int): bool = GetAsyncKeyState(int32 vk) < 0

proc pageKeys(hwnd: HWND): proc (kind: int32, vk: UINT, lParam: int32): bool =
  ## the keys pressed in the page of this window: the menu's keys are the
  ## menu's, and a press of Alt alone opens the menu bar
  result = proc (kind: int32, vk: UINT, lParam: int32): bool =
    if kind == systemKeyDown and int(vk) == VK_MENU:
      flAltAlone = true
      return false
    if kind == 3 and int(vk) == VK_MENU: # SYSTEM_KEY_UP
      if flAltAlone:
        flAltAlone = false
        discard PostMessageW(hwnd, WM_SYSCOMMAND, SC_KEYMENU, 0)
        return true
      return false
    if kind in [keyDown, systemKeyDown]: flAltAlone = false
    if kind notin [keyDown, systemKeyDown]: return false
    let ctrl = isDown(VK_CONTROL)
    let shift = isDown(VK_SHIFT)
    let alt = isDown(VK_MENU)
    for k in keys:
      if k.vk == int(vk) and k.ctrl == ctrl and k.shift == shift and k.alt == alt:
        discard PostMessageW(hwnd, WM_COMMAND, WPARAM ord(k.cmd), 0)
        return true
    let c = chr(int(vk) and 0xFF) # virtual-key codes are below 256
    if kind == systemKeyDown and c in {'A'..'Z', '0'..'9'}:
      # Alt+letter (a system key: Alt without Ctrl): the menu bar's, as if the window had the focus and not the page
      discard PostMessageW(hwnd, WM_SYSCOMMAND, SC_KEYMENU, LPARAM ord(toLowerAscii(c)))
      return true
    false

proc sendKeys(vks: openArray[int], ctrl = ctrlMain) =
  ## Edit's commands from the menu: the page gets the keys, as if they were typed
  var inputs: seq[INPUT]
  for vk in vks:
    var i = INPUT(`type`: INPUT_KEYBOARD)
    i.ki.wVk = WORD vk
    inputs.add i
  for ix in countdown(vks.high, 0):
    var i = INPUT(`type`: INPUT_KEYBOARD)
    i.ki.wVk = WORD vks[ix]
    i.ki.dwFlags = KEYEVENTF_KEYUP
    inputs.add i
  if ctrl != nil: moveFocus(ctrl)
  discard SendInput(UINT inputs.len, addr inputs[0], int32 sizeof(INPUT))

proc devToolsWindow(): HWND =
  ## the shell page's DevTools window; WebView2 titles it with the page's
  ## address, which it knows once its page is running
  FindWindowW(nil, "DevTools - " & urlShellPage["http://".len .. ^1])

proc toggleDevTools() =
  ## Electron's toggleDevTools: DevTools open, or closed when they're open
  let dt = devToolsWindow()
  if dt != 0: discard PostMessageW(dt, WM_CLOSE, 0, 0)
  elif wvMain != nil: openDevToolsWindow(wvMain)

proc toggleZoom(hwnd: HWND) =
  discard ShowWindow(hwnd, if IsZoomed(hwnd) != 0: SW_RESTORE else: SW_MAXIMIZE)

proc doCommand(id: int, hwnd = hwndMain, ctrl = ctrlMain) =
  ## a menu command from this window's menu bar: Edit's and Window's act on
  ## that window, the rest on the main window's page, as Electron's do
  if id >= cmdMenuItemBase:
    let ix = id - cmdMenuItemBase
    if ix < menuItemCommands.len: sendCommand(menuItemCommands[ix][0], menuItemCommands[ix][1])
    return
  if id > ord(high(Cmd)): return
  case Cmd(id)
  of cmdAbout:
    messageBox(hwndMain, appName & " for Windows\nVersion " & appVersion &
      "\n\nBased on BonBon 0.6.56 by Dave Winer.\nMIT License, Copyright (c) 2026 Dave Winer.", "About " & appName)
  of cmdQuit: discard PostMessageW(hwndMain, WM_CLOSE, 0, 0)
  of cmdNewTab: sendCommand("newTab")
  of cmdCloseTab: sendCommand("closeTab")
  of cmdOpenDataFolder: openShell(dataFolder())
  of cmdUndo: sendKeys([VK_CONTROL, ord('Z')], ctrl)
  of cmdRedo: sendKeys([VK_CONTROL, VK_SHIFT, ord('Z')], ctrl)
  of cmdCut: sendKeys([VK_CONTROL, ord('X')], ctrl)
  of cmdCopy: sendKeys([VK_CONTROL, ord('C')], ctrl)
  of cmdPaste: sendKeys([VK_CONTROL, ord('V')], ctrl)
  of cmdPasteAndMatchStyle: sendKeys([VK_CONTROL, VK_SHIFT, ord('V')], ctrl)
  of cmdDelete: sendKeys([VK_DELETE], ctrl)
  of cmdSelectAll: sendKeys([VK_CONTROL, ord('A')], ctrl)
  of cmdFind: sendCommand("find")
  of cmdFindNext: sendCommand("findNext")
  of cmdFindPrevious: sendCommand("findPrevious")
  of cmdReload: sendCommand("reload")
  of cmdViewSource: sendCommand("viewSource")
  of cmdDevTools: toggleDevTools()
  of cmdHome: sendCommand("goHome")
  of cmdBack: sendCommand("goBack")
  of cmdForward: sendCommand("goForward")
  of cmdAddBookmark: sendCommand("addBookmark")
  of cmdEditBookmarks: sendCommand("editBookmarks")
  of cmdMinimize: discard ShowWindow(hwnd, SW_MINIMIZE)
  of cmdZoom: toggleZoom(hwnd)
  of cmdNone: discard

# ---------------------------------------------------------------- Inspect

const
  timerInspect = 0xB1
  # the click's guard: for a second the page swallows clicks and notes it did.
  # With the picker on, the click never reaches the page; without it, it's
  # swallowed here, so a link under it isn't followed, and Inspect tries again
  inspectGuard = """(function () {
    window.bonbonInspectMissed = false;
    const types = ["mousedown", "mouseup", "click"];
    const swallow = function (event) {
      window.bonbonInspectMissed = true;
      event.preventDefault ();
      event.stopImmediatePropagation ();
      };
    types.forEach (function (t) {window.addEventListener (t, swallow, true);});
    setTimeout (function () {types.forEach (function (t) {window.removeEventListener (t, swallow, true);});}, 1000);
    })()"""

var
  inspectX, inspectY = 0.0 ## the right-click, in the page
  inspectTicks = 0         ## tenths of a second since Inspect
  inspectKeysAt = -1       ## the tick for the picker's keys, once the DevTools window is there
  inspectFirstWait = 0     ## from the DevTools window to the keys: longer when it has to load
  flInspectRetried = false

proc evaluate(js: string, done: proc (json: string) = nil) =
  callDevToolsProtocolMethod(wvMain, "Runtime.evaluate", $(%*{"expression": js, "returnByValue": true}), done)

proc clickInPage(x, y: float) =
  ## a click the page gets through the DevTools Protocol: no real mouse, so no
  ## window in front of the spot can take it
  for t in ["mouseMoved", "mousePressed", "mouseReleased"]:
    callDevToolsProtocolMethod(wvMain, "Input.dispatchMouseEvent",
      $(%*{"type": t, "x": x, "y": y, "button": "left", "clickCount": 1}))

proc inspectAt(x, y: float) =
  ## Electron's inspectElement: DevTools on the element under the pointer.
  ## WebView2 has no call for it, so it's done the way a person does it:
  ## DevTools' element picker (Ctrl+Shift+C), then a click on the spot
  if wvMain == nil: return
  inspectFirstWait = if devToolsWindow() != 0: 3 else: 20
  openDevToolsWindow(wvMain)
  inspectX = x
  inspectY = y
  inspectTicks = 0
  inspectKeysAt = -1
  flInspectRetried = false
  discard SetTimer(hwndMain, timerInspect, 100, nil)

proc inspectTick() =
  inc inspectTicks
  let dt = devToolsWindow()
  if inspectTicks > 150 or (dt == 0 and inspectKeysAt >= 0): # 15 s without it, or it was closed
    discard KillTimer(hwndMain, timerInspect)
    return
  if dt == 0: return
  # shortcut: a fixed wait for DevTools to load, and one more try after it; slower than that, DevTools opens without the element (the guard keeps the click from the page). Wait for a sign of DevTools being ready if that happens
  if inspectKeysAt < 0: inspectKeysAt = inspectTicks + inspectFirstWait
  let step = inspectTicks - inspectKeysAt
  if step == 0:
    discard SetForegroundWindow(dt)
    sendKeys([VK_CONTROL, VK_SHIFT, ord('C')], nil)
  elif step == 3:
    evaluate(inspectGuard)
    clickInPage(inspectX, inspectY)
  elif step == 6:
    discard KillTimer(hwndMain, timerInspect)
    evaluate("window.bonbonInspectMissed === true", proc (json: string) =
      # the page got the click, so the picker wasn't on yet: DevTools was still loading. Once more, a second later;
      # if the keys did arrive, just late, this turns the picker off again, and DevTools shows without the element
      let missed = try: parseJson(json){"result", "value"}.getBool except CatchableError: false
      if missed and not flInspectRetried and devToolsWindow() != 0:
        flInspectRetried = true
        inspectKeysAt = inspectTicks + 10
        discard SetTimer(hwndMain, timerInspect, 100, nil))

proc showContextMenu(theParams: JsonNode) =
  ## the right-click menu, Chrome's: on a link, open it in a new tab or copy
  ## its address; anywhere, View Page Source and Inspect
  let linkUrl = theParams{"linkUrl"}.getStr
  let m = CreatePopupMenu()
  if linkUrl.len > 0:
    addItem(m, "Open Link in New Tab", 1)
    addItem(m, "Copy Link Address", 2)
    addSeparator(m)
  addItem(m, "View Page Source", 3)
  addItem(m, "Inspect", 4)
  var pt: POINT
  discard GetCursorPos(addr pt)
  let id = TrackPopupMenu(m, TPM_RETURNCMD or TPM_RIGHTBUTTON, pt.x, pt.y, 0, hwndMain, nil)
  discard DestroyMenu(m)
  case id
  of 1: sendCommand("openUrlInNewTab", linkUrl)
  of 2: setClipboardText(hwndMain, linkUrl)
  of 3: sendCommand("viewSource")
  of 4: inspectAt(theParams{"x"}.getFloat, theParams{"y"}.getFloat)
  else: discard

# ---------------------------------------------------------------- View Source

proc encodeHtml(s: string): string = s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"))

proc sourceFile(hwnd: HWND): string =
  ## a View Source window's page, in the BonBon folder in the system's temporary folder
  getTempDir() / "BonBon" / ("source-" & $cast[int](hwnd) & ".html")

proc openSourceWindow(theUrl, theSource: string) =
  ## View Source in its own window: the text as it came, nothing else
  let title = "view-source:" & theUrl
  let htmltext = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>" & encodeHtml(title) &
    "</title><style>body {margin: 0; padding: 20px 24px; font-family: Menlo, Monaco, monospace; font-size: 13px; line-height: 1.5; color: #222; background: #fff;} pre {margin: 0; white-space: pre-wrap; word-break: break-word;} @media (prefers-color-scheme: dark) {:root {color-scheme: dark;} body {color: #e8eaed; background: #202124;}}</style></head><body><pre>" &
    encodeHtml(theSource) & "</pre></body></html>"
  let hwnd = CreateWindowExW(0, classSource, title, WS_OVERLAPPEDWINDOW or WS_CLIPCHILDREN or WS_VISIBLE,
    CW_USEDEFAULT, CW_USEDEFAULT, px(800), px(700), 0, 0, hInst, nil)
  setMenuBar(hwnd)
  darkmode.applyToWindow(hwnd)
  # a file, not NavigateToString, which shows nothing past 2 MB; Electron's data: URL has no such limit
  let path = sourceFile(hwnd)
  try:
    createDir(path.parentDir)
    writeFile(path, htmltext)
  except CatchableError as e:
    discard DestroyWindow(hwnd)
    messageBox(hwndMain, "Can't show the source because it couldn't be saved: " & e.msg, appName, error = true)
    return
  createController(env, hwnd, proc (ctrl: pointer) =
    if ctrl == nil or IsWindow(hwnd) == 0: return
    sourceWindows[hwnd] = ctrl
    setBackgroundColor(ctrl, webViewBackground())
    var rc: RECT
    discard GetClientRect(hwnd, addr rc)
    setBounds(ctrl, rc)
    onAcceleratorKeyPressed(ctrl, pageKeys(hwnd))
    let wv = getWebView(ctrl)
    configure(wv) # an Electron window: no menu of WebView2's on a right-click, no browser keys (Ctrl+P, F5)
    navigate(wv, "file:///" & path.replace('\\', '/')))

proc sourceProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM): LRESULT {.stdcall.} =
  if handleMenuBar(hwnd, msg, wParam, lParam, result): return
  case msg
  of WM_SIZE:
    if hwnd in sourceWindows:
      var rc: RECT
      discard GetClientRect(hwnd, addr rc)
      setBounds(sourceWindows[hwnd], rc)
    return 0
  of WM_SETFOCUS:
    if hwnd in sourceWindows: moveFocus(sourceWindows[hwnd])
    return 0
  of WM_COMMAND:
    doCommand(int(LOWORD(wParam)), hwnd, sourceWindows.getOrDefault(hwnd))
    return 0
  of WM_DESTROY:
    if hwnd in sourceWindows:
      closeController(sourceWindows[hwnd])
      sourceWindows.del hwnd
    try: removeFile(sourceFile(hwnd)) except CatchableError: discard
    return 0
  else: discard
  DefWindowProcW(hwnd, msg, wParam, lParam)

# ---------------------------------------------------------------- PDFs and page handlers

proc openPdfInSystemViewer(p: PageResult): string =
  ## the PDF, saved in a BonBon folder in the system's temporary folder and
  ## opened from there; answers "" or why it couldn't be
  var theName = "document.pdf"
  var theLast = ""
  for c in decodeURIComponent(urlPath(p.url)).extractFilename:
    if c in {'A'..'Z', 'a'..'z', '0'..'9', '.', '_', ' ', '-'}: theLast.add c
  if theLast.len > 0:
    theName = if theLast.toLowerAscii.endsWith(".pdf"): theLast else: theLast & ".pdf"
  let theFile = getTempDir() / "BonBon" / theName
  try:
    createDir(theFile.parentDir)
    writeFile(theFile, p.pdfData)
  except CatchableError as e:
    return "Can't open " & p.url & " in the system's PDF viewer because the file couldn't be saved: " & e.msg
  if ShellExecuteW(0, "open", theFile, nil, nil, SW_SHOWNORMAL) <= 32:
    return "Can't open " & p.url & " in the system's PDF viewer because Windows has no app for PDFs."
  ""

proc pageJson(p: PageResult, flAsItCame: bool): JsonNode =
  ## getPage's answer the way pageRequests.js sends it; a Markdown page comes
  ## as it came, flMarkdown, and bridge.js converts it
  if not p.flOk:
    return %*{"flOk": false, "url": p.url, "status": p.status, "message": p.message}
  result = %*{"flOk": true, "url": p.url}
  if p.urlContentLocation.len > 0: result["urlContentLocation"] = %p.urlContentLocation
  proc addContentType(j: JsonNode) =
    if p.contentType.len > 0: j["contentType"] = %p.contentType
  case p.kind
  of "":
    result["flMarkdown"] = %true
    result["source"] = %p.source
  of "html", "xml", "text":
    result["kind"] = %p.kind
    if p.title.len > 0: result["title"] = %p.title
    result["source"] = %p.source
    addContentType(result)
    let headers = newJObject()
    for (name, value) in p.headers: headers[name] = %value
    result["headers"] = headers
    let theExtension = getExtensionForPage(config, p.url, p.contentType)
    if theExtension.len > 0:
      let theHandler = findHandler(theExtension, cfgInt(config, "ctSecsHandlerTimeout", 5))
      if theHandler != nil: result["handler"] = theHandler
  of "image":
    result["kind"] = %"image"
    result["imageData"] = %toDataUrl(p.imageType, p.imageData)
  of "pdf":
    if cfgBool(config, "flOpenPdfsInSystemViewer") and not flAsItCame:
      let err = openPdfInSystemViewer(p)
      if err.len > 0: return %*{"flOk": false, "url": p.url, "status": 0, "message": err}
      return %*{"flOk": true, "kind": "openedOutside", "url": p.url}
    result["kind"] = %"pdf"
    result["pdfData"] = %toDataUrl("application/pdf", p.pdfData)
  else:
    result["kind"] = %"file"
    addContentType(result)
    if p.size >= 0: result["size"] = %p.size

# ---------------------------------------------------------------- the page's calls

const fnameUserCss = "userCss.css" ## the last stylesheet fetched from urlUserCss

proc submitCall(id: JsonNode, kind: JobKind, url: string, flag = false) =
  pendingCalls[submit(kind, url, flag)] = PendingCall(id: id, urlAsked: url, flAsItCame: flag)

proc jobDone(r: JobResult) =
  if r.id notin pendingCalls: return
  let call = pendingCalls[r.id]
  pendingCalls.del r.id
  case r.kind
  of jkPage: reply(call.id, pageJson(r.page, call.flAsItCame))
  of jkFavicon: reply(call.id, if r.mime.len > 0: %toDataUrl(r.mime, r.text) else: nil)
  of jkToc: reply(call.id, if r.text.len > 0: %r.text else: nil)
  of jkIsMarkdown: reply(call.id, %r.flag)
  of jkUrlStatus:
    let j = %*{"flAvailable": r.status.flAvailable}
    if r.status.urlContentLocation.len > 0: j["urlContentLocation"] = %r.status.urlContentLocation
    reply(call.id, j)
  of jkText: # the user's stylesheet; when its address can't be reached, the copy from last time
    if r.err.len > 0:
      echo "getUserCss: can't get " & call.urlAsked & ", using the cached copy. " & r.err
      reply(call.id, %readText(fnameUserCss)[1])
    else:
      writeText(fnameUserCss, r.text)
      reply(call.id, %r.text)
  else: discard

proc pageCall(message: string) =
  var m: JsonNode
  try: m = parseJson(message)
  except CatchableError: return
  let id = m{"id"}
  let args = m{"args"}
  proc arg(ix: int): JsonNode =
    if args != nil and args.kind == JArray and ix < args.len: args[ix] else: newJNull()
  proc argStr(ix: int): string = arg(ix).getStr
  case m{"name"}.getStr
  of "loaded": # did-finish-load: the links that came early
    flLoaded = true
    for u in urlsWaitingToOpen: sendCommand("openUrlInNewTab", u)
    urlsWaitingToOpen.setLen 0
  of "closeWindow": discard PostMessageW(hwndMain, WM_CLOSE, 0, 0) # window.close (), the last tab closing
  of "getConfig": reply(id, config)
  of "getVersion": reply(id, %appVersion)
  of "getUrlHistory":
    let j = readJson("urlHistory.json")
    reply(id, if j == nil: newJArray() else: j)
  of "saveUrlHistory":
    if arg(0).kind == JArray:
      let theList = newJArray()
      for ix, v in arg(0).getElems:
        if ix >= maxUrlHistory: break
        theList.add v
      writeText("urlHistory.json", $theList)
    reply(id)
  of "toggleDevTools":
    toggleDevTools()
    reply(id)
  of "openDataFolder":
    openShell(dataFolder())
    reply(id)
  of "openSourceWindow":
    openSourceWindow(argStr(0), argStr(1))
    reply(id)
  of "getToc": submitCall(id, jkToc, argStr(0))
  of "isMarkdownUrl": submitCall(id, jkIsMarkdown, argStr(0))
  of "getUrlStatus": submitCall(id, jkUrlStatus, argStr(0))
  of "getFavicon": submitCall(id, jkFavicon, argStr(0))
  of "getPage": submitCall(id, jkPage, argStr(0), arg(1).getBool)
  of "getUserCss":
    let urlUserCss = cfgStr(config, "urlUserCss")
    if urlUserCss.len == 0: # no user CSS, and no cache of it
      try: removeFile(dataFolder() / fnameUserCss) except CatchableError: discard
      reply(id, %"")
    else: submitCall(id, jkText, urlUserCss)
  of "getStylesheets": reply(id, getStylesheets())
  of "getTabs": reply(id, readJson("tabs.json"))
  of "saveTabs":
    writeText("tabs.json", $arg(0))
    reply(id)
  of "getBookmarks":
    let (ok, text) = readText("bookmarks.opml")
    reply(id, if ok: %text else: nil)
  of "saveBookmarks":
    writeText("bookmarks.opml", argStr(0))
    bookmarksOutline = arg(1)
    buildMenu()
    reply(id)
  of "setBookmarksMenu":
    bookmarksOutline = arg(0)
    buildMenu()
    reply(id)
  of "getHistory": reply(id, recentPages)
  of "saveHistory":
    if arg(0).kind == JArray: recentPages = arg(0)
    writeText("history.json", $arg(0))
    buildMenu()
    reply(id)
  of "showContextMenu":
    reply(id) # first: the menu waits for the mouse, the page doesn't have to
    showContextMenu(arg(0))
  of "openInBrowser": # a link to an HTML page opens in the reader's default browser; web addresses only
    let u = argStr(0)
    if u.startsWith("http://") or u.startsWith("https://"): openShell(u)
    reply(id)
  else: reply(id)

# ---------------------------------------------------------------- bon:// links and the one instance

proc openBonUrl(theUrl: string) =
  ## bon:// becomes http://, and the site redirects to https if it wants to
  var u = theUrl.strip
  if u.toLowerAscii.startsWith("bon://"): u = "http://" & u[6 .. ^1]
  elif u.toLowerAscii.startsWith("bon:"): u = "http://" & u[4 .. ^1]
  if not flLoaded:
    urlsWaitingToOpen.add u
    return
  sendCommand("openUrlInNewTab", u)
  if IsIconic(hwndMain) != 0: discard ShowWindow(hwndMain, SW_RESTORE)
  discard SetForegroundWindow(hwndMain)

proc registerBonProtocol() =
  ## the app is the handler for bon:// links, for this user
  let exe = getAppFilename()
  var key: HKEY
  if RegCreateKeyExW(HKEY_CURRENT_USER, "Software\\Classes\\bon", 0, nil, 0, KEY_WRITE, nil, addr key, nil) != ERROR_SUCCESS: return
  proc setValue(k: HKEY, name: string, value: string) =
    let w = +$value
    discard RegSetValueExW(k, if name.len == 0: nil else: (+$name).LPCWSTR, 0, REG_SZ, cast[ptr BYTE](&w), DWORD((w.len + 1) * 2))
  setValue(key, "", "URL:BonBon Protocol")
  setValue(key, "URL Protocol", "")
  discard RegCloseKey(key)
  if RegCreateKeyExW(HKEY_CURRENT_USER, "Software\\Classes\\bon\\shell\\open\\command", 0, nil, 0, KEY_WRITE, nil, addr key, nil) == ERROR_SUCCESS:
    setValue(key, "", "\"" & exe & "\" \"%1\"")
    discard RegCloseKey(key)
  if RegCreateKeyExW(HKEY_CURRENT_USER, "Software\\Classes\\bon\\DefaultIcon", 0, nil, 0, KEY_WRITE, nil, addr key, nil) == ERROR_SUCCESS:
    setValue(key, "", "\"" & exe & "\",0")
    discard RegCloseKey(key)

proc argUrls(): seq[string] =
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a.toLowerAscii.startsWith("bon:") or a.startsWith("http://") or a.startsWith("https://"): result.add a

# ---------------------------------------------------------------- the window

proc fitPage() =
  if ctrlMain == nil: return
  var rc: RECT
  discard GetClientRect(hwndMain, addr rc)
  setBounds(ctrlMain, rc)

proc applyTheme() =
  ## dark or light, as Windows is now, in every window; the pages follow by themselves
  for h in @[hwndMain] & toSeq(sourceWindows.keys): darkmode.applyToWindow(h)
  for ctrl in @[ctrlMain] & toSeq(sourceWindows.values):
    if ctrl != nil: setBackgroundColor(ctrl, webViewBackground())

proc mainProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM): LRESULT {.stdcall.} =
  if handleMenuBar(hwnd, msg, wParam, lParam, result): return
  case msg
  of WM_SIZE:
    fitPage()
    return 0
  of WM_SETTINGCHANGE: # among them the switch between light and dark apps
    if darkmode.update(): applyTheme()
  of WM_MOVE:
    if ctrlMain != nil: notifyParentWindowPositionChanged(ctrlMain)
  of WM_SETFOCUS:
    if ctrlMain != nil: moveFocus(ctrlMain)
    return 0
  of WM_COMMAND:
    doCommand(int(LOWORD(wParam)))
    return 0
  of WM_JOBDONE:
    for r in drainResults(): jobDone(r)
    return 0
  of WM_TIMER:
    if wParam == timerInspect:
      inspectTick()
      return 0
  of WM_COPYDATA: # a bon:// link from a second launch
    let cds = cast[ptr COPYDATASTRUCT](lParam)
    if cds.dwData == 0xB0B0 and cds.cbData > 0:
      var s = newString(int cds.cbData)
      copyMem(addr s[0], cds.lpData, int cds.cbData)
      for u in s.split('\n'):
        if u.len > 0: openBonUrl(u)
    return 1
  of WM_DESTROY:
    for h in toSeq(sourceWindows.keys): discard DestroyWindow(h) # the app quits with its window
    if ctrlMain != nil: closeController(ctrlMain)
    PostQuitMessage(0)
    return 0
  else: discard
  DefWindowProcW(hwnd, msg, wParam, lParam)

proc startPage() =
  ## WebView2 in the window, the shell page in it
  let loaderDll = proc (): string =
    try: unpackLoaderDll(resourcesFolder()) except CatchableError: ""
  let hr = createEnvironment(dataFolder(), loaderDll, proc (e: pointer) =
    if e == nil:
      messageBox(hwndMain, "BonBon needs the Microsoft Edge WebView2 Runtime, and it isn't installed. It comes from https://developer.microsoft.com/microsoft-edge/webview2/", appName, error = true)
      discard DestroyWindow(hwndMain)
      return
    env = e
    createController(env, hwndMain, proc (ctrl: pointer) =
      if ctrl == nil: return
      ctrlMain = ctrl
      setBackgroundColor(ctrl, webViewBackground())
      wvMain = getWebView(ctrl)
      configure(wvMain)
      setVirtualHostNameToFolderMapping(wvMain, hostApp, resourcesFolder() / "app")
      setVirtualHostNameToFolderMapping(wvMain, hostStylesheets, stylesheetsFolder())
      addScriptToExecuteOnDocumentCreated(wvMain, bridgeScript)
      onWebMessageReceived(wvMain, pageCall)
      onDocumentTitleChanged(wvMain, proc () = discard SetWindowTextW(hwndMain, documentTitle(wvMain)))
      onAcceleratorKeyPressed(ctrl, pageKeys(hwndMain))
      fitPage()
      moveFocus(ctrl)
      navigate(wvMain, urlShellPage)))
  if hr != S_OK:
    messageBox(hwndMain, "BonBon can't start WebView2 (error 0x" & toHex(int32 hr) & "). It needs the Microsoft Edge WebView2 Runtime, which comes from https://developer.microsoft.com/microsoft-edge/webview2/", appName, error = true)
    discard DestroyWindow(hwndMain)

proc createWindow() =
  var wc: WNDCLASSEXW
  wc.cbSize = UINT sizeof(wc)
  wc.lpfnWndProc = mainProc
  wc.hInstance = hInst
  wc.hCursor = LoadCursorW(0, IDC_ARROW)
  wc.hbrBackground = GetSysColorBrush(COLOR_WINDOW)
  wc.lpszClassName = classMain
  wc.hIcon = iconApp
  wc.hIconSm = iconApp
  discard RegisterClassExW(addr wc)
  var sc = wc
  sc.lpfnWndProc = sourceProc
  sc.lpszClassName = classSource
  discard RegisterClassExW(addr sc)
  # Electron's way: the size from config.json, the middle of the screen
  let w = px(cfgInt(config, "windowWidth", 1000))
  let h = px(cfgInt(config, "windowHeight", 800))
  var work: RECT
  discard SystemParametersInfoW(SPI_GETWORKAREA, 0, addr work, 0)
  let x = work.left + max(0, (work.right - work.left - w) div 2)
  let y = work.top + max(0, (work.bottom - work.top - h) div 2)
  hwndMain = CreateWindowExW(0, classMain, "Markdown Browser", WS_OVERLAPPEDWINDOW or WS_CLIPCHILDREN,
    x, y, w, h, 0, 0, hInst, nil)
  buildMenu()
  darkmode.applyToWindow(hwndMain)
  discard ShowWindow(hwndMain, SW_SHOWNORMAL)

proc main() =
  hInst = GetModuleHandleW(nil)
  let urls = argUrls()
  # one BonBon at a time: a second launch hands its bon:// links to the first
  discard CreateMutexW(nil, FALSE, classMain)
  if GetLastError() == ERROR_ALREADY_EXISTS:
    let other = FindWindowW(classMain, nil)
    if other != 0:
      var s = urls.join("\n")
      var cds = COPYDATASTRUCT(dwData: 0xB0B0, cbData: DWORD s.len, lpData: if s.len > 0: addr s[0] else: nil)
      discard SendMessageW(other, WM_COPYDATA, 0, cast[LPARAM](addr cds))
      discard ShowWindow(other, SW_RESTORE)
      discard SetForegroundWindow(other)
      return
  discard CoInitializeEx(nil, COINIT_APARTMENTTHREADED)
  initDpi()
  discard darkmode.update()
  config = readConfig()
  reqOptions.maxRedirects = cfgInt(config, "maxRedirects", 10)
  reqOptions.userAgent = "Markdown Browser/" & appVersion
  moveDataFromOldName()
  seedStylesheets()
  seedHandlers()
  let theList = readJson("history.json")
  if theList != nil and theList.kind == JArray: recentPages = theList
  if getEnv("BONBON_E2E").len == 0: registerBonProtocol() # the end-to-end tests leave the registry alone
  iconApp = LoadIconW(hInst, MAKEINTRESOURCEW(1))
  createWindow()
  startWorkers(hwndMain)
  buildAccelerators()
  for u in urls: openBonUrl(u)
  startPage()
  var msg: MSG
  while GetMessageW(addr msg, 0, 0, 0) > 0:
    if TranslateAcceleratorW(hwndMain, hAccel, addr msg) != 0: continue
    discard TranslateMessage(addr msg)
    discard DispatchMessageW(addr msg)

main()
