## winutil.nim -- the few Win32 helpers BonBon needs.

import std/[strutils, unicode, os]
import winim/lean, winim/inc/[shellapi, commdlg]

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

proc askSavePath*(owner: HWND, suggested: string): string =
  ## Windows' Save As dialog, starting at the suggested folder and name; "" when it was canceled
  var buf = newWString(32768)
  var name = +$suggested.extractFilename
  if name.len > 0: copyMem(&buf, &name, name.len * 2)
  var dir = +$suggested.parentDir
  let ext = suggested.splitFile.ext
  var defExt = +$(if ext.len > 1: ext[1 .. ^1] else: "")
  var ofn = OPENFILENAMEW(lStructSize: DWORD sizeof(OPENFILENAMEW), hwndOwner: owner,
    lpstrFilter: "All files\0*.*\0\0", lpstrFile: &buf, nMaxFile: DWORD buf.len,
    lpstrInitialDir: &dir, lpstrDefExt: if defExt.len > 0: &defExt else: nil,
    Flags: OFN_OVERWRITEPROMPT or OFN_PATHMUSTEXIST or OFN_NOCHANGEDIR or OFN_EXPLORER)
  if GetSaveFileNameW(addr ofn) != 0: ($buf).split('\0')[0] else: ""

proc openShell*(target: string) =
  ## a web address in the reader's default browser, a folder or file in its app
  discard ShellExecuteW(0, "open", target, nil, nil, SW_SHOWNORMAL)

proc getMenuItemLabel*(theText: string, maxChars = 60): string =
  ## main.js's: a headline can be any length, a menu item can't. & shows as &
  var t = theText.strip
  if t.runeLen > maxChars: t = t.runeSubStr(0, maxChars - 3) & "..."
  t.replace("&", "&&")
