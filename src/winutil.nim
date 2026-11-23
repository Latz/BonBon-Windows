## winutil.nim -- the few Win32 helpers the windows share.

import winim/lean, winim/inc/[commctrl, shellapi]

var dpi* = 96

proc px*(v: int): int32 = int32(v * dpi div 96)   ## design pixels to screen pixels

proc initDpi*() =
  let dc = GetDC(0)
  dpi = GetDeviceCaps(dc, LOGPIXELSX)
  discard ReleaseDC(0, dc)

proc makeFont*(face: string, pt: float, bold = false): HFONT =
  var lf: LOGFONTW
  lf.lfHeight = -int32(pt * dpi.float / 72.0 + 0.5)
  lf.lfWeight = if bold: FW_BOLD else: FW_NORMAL
  lf.lfCharSet = DEFAULT_CHARSET
  lf.lfQuality = CLEARTYPE_QUALITY
  let w = +$face
  for i in 0 ..< min(w.len, 31): lf.lfFaceName[i] = w[i]
  CreateFontIndirectW(addr lf)

proc uiFont*(): HFONT =
  var ncm: NONCLIENTMETRICSW
  ncm.cbSize = UINT sizeof(ncm)
  discard SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, ncm.cbSize, addr ncm, 0)
  CreateFontIndirectW(addr ncm.lfMessageFont)

proc control*(parent: HWND, class, text: string, style: DWORD, id: int, font: HFONT, exStyle: DWORD = 0): HWND =
  result = CreateWindowExW(exStyle, class, text, WS_CHILD or WS_VISIBLE or style, 0, 0, 0, 0,
    parent, HMENU(id), GetModuleHandleW(nil), nil)
  if font != 0: SendMessageW(result, WM_SETFONT, WPARAM(font), TRUE)

proc getText*(h: HWND): string =
  let n = GetWindowTextLengthW(h)
  if n <= 0: return ""
  var w = newWString(n)
  discard GetWindowTextW(h, &w, n + 1)
  $w

proc setText*(h: HWND, s: string) = discard SetWindowTextW(h, s)

proc move*(h: HWND, x, y, w, h2: int) = discard MoveWindow(h, int32 x, int32 y, int32 max(w, 0), int32 max(h2, 0), TRUE)

proc show*(h: HWND, flShow: bool) = discard ShowWindow(h, if flShow: SW_SHOW else: SW_HIDE)

proc enable*(h: HWND, fl: bool) = discard EnableWindow(h, fl.WINBOOL)

proc setClipboardText*(owner: HWND, s: string) =
  let w = +$s
  let bytes = (w.len + 1) * 2
  if OpenClipboard(owner) == 0: return
  discard EmptyClipboard()
  let h = GlobalAlloc(GMEM_MOVEABLE, SIZE_T bytes)
  if h != 0:
    let p = GlobalLock(h)
    copyMem(p, &w, bytes)
    discard GlobalUnlock(h)
    discard SetClipboardData(CF_UNICODETEXT, h)
  discard CloseClipboard()

proc openShell*(target: string) =
  ## a web address in the reader's default browser, a folder or file in its app
  discard ShellExecuteW(0, "open", target, nil, nil, SW_SHOWNORMAL)

proc stockIcon*(id: SHSTOCKICONID): HICON =
  var info: SHSTOCKICONINFO
  info.cbSize = DWORD sizeof(info)
  if SHGetStockIconInfo(id, SHGSI_ICON or SHGSI_SMALLICON, addr info) == S_OK: info.hIcon else: 0

proc menuLabel*(s: string, maxChars = 60): string =
  ## a headline can be any length, a menu item can't; & shows as &
  var t = s
  if t.len > maxChars:
    var n = 0
    var cut = 0
    for i, c in t:
      if (ord(c) and 0xC0) != 0x80:
        if n == maxChars: break
        inc n
      cut = i + 1
    t = t[0 ..< cut] & "…"
  for c in t:
    if c == '&': result.add "&&" else: result.add c
