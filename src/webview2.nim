## webview2.nim -- the few WebView2 calls BonBon makes.
##
## WebView2 is COM: every object is a pointer to a table of functions. The
## numbers below are each function's place in its table, counted in
## WebView2.h from the Microsoft.Web.WebView2 SDK 1.0.4370.26 (the first three
## are always QueryInterface, AddRef, Release). WebView2Loader.dll, from the
## same package, sits beside bonbon.exe and finds the runtime Windows has.

import winim/lean, winim/inc/objbase

type
  Callback* = proc (a, b: pointer): HRESULT {.closure.}
  HandlerObj = object
    vtbl: pointer
    fn: Callback

# ---------------------------------------------------------------- our side: the event handlers

var keepHandlers: seq[ref HandlerObj] # WebView2 holds on to them; so do we, for the life of the app

proc hQueryInterface(this: pointer, riid: pointer, ppv: ptr pointer): HRESULT {.stdcall.} =
  ppv[] = this # each handler object is exactly one interface, the one asked for
  S_OK
proc hAddRef(this: pointer): ULONG {.stdcall.} = 1
proc hRelease(this: pointer): ULONG {.stdcall.} = 1
proc hInvoke(this: ptr HandlerObj, a, b: pointer): HRESULT {.stdcall.} =
  try: this.fn(a, b)
  except CatchableError: S_OK

var handlerVtbl = [cast[pointer](hQueryInterface), cast[pointer](hAddRef), cast[pointer](hRelease), cast[pointer](hInvoke)]

proc handler(fn: Callback): pointer =
  ## any of WebView2's handler interfaces: they all have one method, Invoke, with two arguments
  let h = new HandlerObj
  h.vtbl = addr handlerVtbl
  h.fn = fn
  keepHandlers.add h
  cast[pointer](h)

# ---------------------------------------------------------------- their side: calling into the tables

template fnAt(obj: pointer, ix: int): pointer = cast[ptr UncheckedArray[pointer]](cast[ptr pointer](obj)[])[ix]

proc call0(obj: pointer, ix: int): HRESULT = cast[proc (this: pointer): HRESULT {.stdcall.}](fnAt(obj, ix))(obj)
proc callP(obj: pointer, ix: int, p: pointer): HRESULT = cast[proc (this, p: pointer): HRESULT {.stdcall.}](fnAt(obj, ix))(obj, p)
proc callPP(obj: pointer, ix: int, p, q: pointer): HRESULT = cast[proc (this, p, q: pointer): HRESULT {.stdcall.}](fnAt(obj, ix))(obj, p, q)
proc callB(obj: pointer, ix: int, b: bool): HRESULT = cast[proc (this: pointer, b: BOOL): HRESULT {.stdcall.}](fnAt(obj, ix))(obj, BOOL(b))

proc takeString(p: LPWSTR): string =
  ## a string WebView2 handed us; it's ours to free
  if p == nil: return ""
  let n = WideCharToMultiByte(CP_UTF8, 0, p, -1, nil, 0, nil, nil) # with the 0 at the end
  if n > 1:
    result = newString(n - 1)
    discard WideCharToMultiByte(CP_UTF8, 0, p, -1, cast[LPSTR](addr result[0]), n, nil, nil)
  CoTaskMemFree(p)

proc queryInterface(obj: pointer, iid: GUID): pointer =
  var guid = iid
  if callPP(obj, 0, addr guid, addr result) != S_OK: result = nil

proc addEvent(obj: pointer, ix: int, fn: Callback) =
  var token: int64
  discard callPP(obj, ix, handler(fn), addr token)

# ---------------------------------------------------------------- the environment and the controller

proc CreateCoreWebView2EnvironmentWithOptions(browserExecutableFolder, userDataFolder: LPCWSTR,
  environmentOptions, environmentCreatedHandler: pointer): HRESULT {.stdcall, dynlib: "WebView2Loader.dll", importc.}

proc createEnvironment*(userDataFolder: string, done: proc (env: pointer)): HRESULT =
  ## done gets nil when there's no WebView2 runtime
  CreateCoreWebView2EnvironmentWithOptions(nil, &(+$userDataFolder), nil, handler(proc (a, b: pointer): HRESULT =
    if cast[HRESULT](cast[int](a)) == S_OK and b != nil:
      discard callP(b, 1, nil) # AddRef: we keep it
      done(b)
    else: done(nil)
    S_OK))

proc createController*(env: pointer, hwnd: HWND, done: proc (ctrl: pointer)) =
  discard callPP(env, 3, cast[pointer](hwnd), handler(proc (a, b: pointer): HRESULT =
    if cast[HRESULT](cast[int](a)) == S_OK and b != nil:
      discard callP(b, 1, nil)
      done(b)
    else: done(nil)
    S_OK))

proc setBounds*(ctrl: pointer, rc: RECT) =
  discard cast[proc (this: pointer, r: RECT): HRESULT {.stdcall.}](fnAt(ctrl, 6))(ctrl, rc)
proc setVisible*(ctrl: pointer, fl: bool) = discard callB(ctrl, 4, fl)
proc moveFocus*(ctrl: pointer) =
  discard cast[proc (this: pointer, reason: int32): HRESULT {.stdcall.}](fnAt(ctrl, 12))(ctrl, 0) # programmatic
proc notifyParentWindowPositionChanged*(ctrl: pointer) = discard call0(ctrl, 23)
proc closeController*(ctrl: pointer) = discard call0(ctrl, 24)
proc getWebView*(ctrl: pointer): pointer = discard callP(ctrl, 25, addr result)

proc setBackgroundWhite*(ctrl: pointer) =
  ## what's behind a page that sets no background: white, Electron's, not
  ## WebView2's, which can be dark
  let ctrl2 = queryInterface(ctrl, DEFINE_GUID("c979903e-d4ca-4228-92eb-47ee3fa96eab")) # ICoreWebView2Controller2
  if ctrl2 == nil: return
  discard cast[proc (this: pointer, color: uint32): HRESULT {.stdcall.}](fnAt(ctrl2, 27))(ctrl2, 0xFFFFFFFF'u32) # put_DefaultBackgroundColor, A R G B
  discard call0(ctrl2, 2)

const
  keyDown* = 0'i32
  systemKeyDown* = 2'i32

proc onAcceleratorKeyPressed*(ctrl: pointer, fn: proc (kind: int32, vk: UINT, lParam: int32): bool) =
  ## fn answers true when it took the key, and the page doesn't get it
  addEvent(ctrl, 19, proc (a, args: pointer): HRESULT =
    var kind, lp: int32
    var vk: UINT
    discard callP(args, 3, addr kind)
    discard callP(args, 4, addr vk)
    discard callP(args, 5, addr lp)
    if fn(kind, vk, lp): discard callB(args, 8, true)
    S_OK)

# ---------------------------------------------------------------- the settings

proc configure*(wv: pointer) =
  ## no menu of its own on a right-click (the page asks for ours), no status
  ## bubble, and the browser's own keys off: Ctrl+F, Ctrl+R and F5 are the
  ## app's commands, as they are in Electron
  var settings: pointer
  if callP(wv, 3, addr settings) != S_OK or settings == nil: return
  discard callB(settings, 14, false) # put_AreDefaultContextMenusEnabled
  discard callB(settings, 10, false) # put_IsStatusBarEnabled
  discard callB(settings, 12, true)  # put_AreDevToolsEnabled
  let settings3 = queryInterface(settings, DEFINE_GUID("fdb5ab74-af33-4854-84f0-0a631deb5eba")) # ICoreWebView2Settings3
  if settings3 != nil:
    discard callB(settings3, 24, false) # put_AreBrowserAcceleratorKeysEnabled
    discard call0(settings3, 2)
  discard call0(settings, 2)

# ---------------------------------------------------------------- the page

proc navigate*(wv: pointer, url: string) = discard callP(wv, 5, &(+$url))
proc navigateToString*(wv: pointer, html: string) = discard callP(wv, 6, &(+$html))
proc addScriptToExecuteOnDocumentCreated*(wv: pointer, js: string) = discard callPP(wv, 27, &(+$js), nil)
proc executeScript*(wv: pointer, js: string) = discard callPP(wv, 29, &(+$js), nil)
proc postWebMessageAsJson*(wv: pointer, json: string) = discard callP(wv, 32, &(+$json))
proc openDevToolsWindow*(wv: pointer) = discard call0(wv, 51)
proc callDevToolsProtocolMethod*(wv: pointer, meth, paramsJson: string, done: proc (json: string) = nil) =
  ## a DevTools Protocol call on the page; done gets its answer, JSON, "" when it failed
  let h = handler(proc (errorCode, resultJson: pointer): HRESULT =
    if done != nil:
      done(if cast[int32](errorCode) < 0 or resultJson == nil: "" else: $cast[WideCString](resultJson)) # resultJson is WebView2's, not ours to free
    S_OK)
  discard cast[proc (this, m, p, h: pointer): HRESULT {.stdcall.}](fnAt(wv, 36))(wv, &(+$meth), &(+$paramsJson), h)
proc documentTitle*(wv: pointer): string =
  var p: LPWSTR
  discard callP(wv, 48, addr p)
  takeString(p)

proc onWebMessageReceived*(wv: pointer, fn: proc (json: string)) =
  addEvent(wv, 34, proc (sender, args: pointer): HRESULT =
    var p: LPWSTR
    discard callP(args, 4, addr p) # get_WebMessageAsJson
    fn(takeString(p))
    S_OK)

proc onDocumentTitleChanged*(wv: pointer, fn: proc ()) =
  addEvent(wv, 46, proc (sender, args: pointer): HRESULT =
    fn()
    S_OK)

proc setVirtualHostNameToFolderMapping*(wv: pointer, host, folder: string) =
  ## the folder's files, served at http://host/ and https://host/
  let wv3 = queryInterface(wv, DEFINE_GUID("A0D6DF20-3B92-416D-AA0C-437A9C727857")) # ICoreWebView2_3
  if wv3 == nil: return
  discard cast[proc (this: pointer, host, folder: LPCWSTR, access: int32): HRESULT {.stdcall.}](fnAt(wv3, 71))(
    wv3, &(+$host), &(+$folder), 1) # COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW
  discard call0(wv3, 2)
