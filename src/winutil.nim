## winutil.nim -- the few Win32 helpers BonBon needs.

import std/[strutils, unicode]
import winim/lean, winim/inc/shellapi

var dpi* = 96

proc px*(v: int): int32 = int32(v * dpi div 96)   ## design pixels to screen pixels

proc initDpi*() =
  let dc = GetDC(0)
  dpi = GetDeviceCaps(dc, LOGPIXELSX)
  discard ReleaseDC(0, dc)

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

proc getMenuItemLabel*(theText: string, maxChars = 60): string =
  ## main.js's: a headline can be any length, a menu item can't. & shows as &
  var t = theText.strip
  if t.runeLen > maxChars: t = t.runeSubStr(0, maxChars - 3) & "..."
  t.replace("&", "&&")
