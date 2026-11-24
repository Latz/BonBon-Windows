## darkmode.nim -- the window's own parts dark when Windows is.
##
## WebView2 draws the page dark when Windows is set to dark apps
## (AppsUseLightTheme 0), and dark.css makes the rest of the page follow.
## This does the same for what Windows draws: the title bar (DWM, documented),
## the drop-down and right-click menus (uxtheme's dark menus, undocumented but
## stable since Windows 10 1903: SetPreferredAppMode and FlushMenuThemes, by
## ordinal) and the menu bar, which Windows draws light even then, so it's
## drawn here (the UAH messages, also undocumented; the way adzm/win32-darkmode
## does it). When a call isn't there, nothing happens and that part stays light.
## Windows has no dark message box, so in dark mode messageBox draws its own.

import winim/lean, winim/inc/winreg
import winutil

const
  colorBar* = 0x00242120'i32       ## #202124 as a COLORREF (0x00BBGGRR): the bar, Chrome's tab strip
  colorHot = 0x00403C3C'i32        ## #3c4043: an item under the mouse or open
  colorText = 0x00EDEAE8'i32       ## #e8eaed
  colorTextGray = 0x00A6A09A'i32   ## #9aa0a6
  WM_UAHDRAWMENU = 0x0091
  WM_UAHDRAWMENUITEM = 0x0092
  DWMWA_USE_IMMERSIVE_DARK_MODE = 20     ## Windows 10 2004 and newer
  DWMWA_USE_IMMERSIVE_DARK_MODE_OLD = 19 ## 1809 to 1909

type
  UAHMENU = object
    hmenu: HMENU
    hdc: HDC
    dwFlags: DWORD
  UAHMENUITEM = object
    iPosition: int32
    metrics: array[8, DWORD]        ## UAHMENUITEMMETRICS, a union of sizes
    popupMetrics: array[5, DWORD]   ## UAHMENUPOPUPMETRICS: four widths and a flag
  UAHDRAWMENUITEM = object
    dis: DRAWITEMSTRUCT
    um: UAHMENU
    umi: UAHMENUITEM

proc DwmSetWindowAttribute(hwnd: HWND, attr: DWORD, value: pointer, size: DWORD): HRESULT {.stdcall, dynlib: "dwmapi", importc.}

var
  flDark = false
  brushBar: HBRUSH
  brushHot: HBRUSH
  fontMenu: HFONT

proc isDark*(): bool = flDark

proc systemIsDark(): bool =
  ## Windows set to dark apps, and not to high contrast, where Windows draws everything itself
  var hc = HIGHCONTRASTW(cbSize: UINT sizeof(HIGHCONTRASTW))
  if SystemParametersInfoW(SPI_GETHIGHCONTRAST, hc.cbSize, addr hc, 0) != 0 and (hc.dwFlags and HCF_HIGHCONTRASTON) != 0:
    return false
  var value: DWORD
  var size = DWORD sizeof(value)
  RegGetValueW(HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
    "AppsUseLightTheme", RRF_RT_REG_DWORD, nil, addr value, addr size) == ERROR_SUCCESS and value == 0

proc uxthemeProc(ordinal: int): pointer =
  let lib = LoadLibraryExW("uxtheme.dll", 0, LOAD_LIBRARY_SEARCH_SYSTEM32)
  if lib != 0: GetProcAddress(lib, cast[LPCSTR](ordinal)) else: nil

proc setMenuMode(dark: bool) =
  ## the drop-down and right-click menus of the whole app
  let setPreferredAppMode = cast[proc (mode: int32): int32 {.stdcall.}](uxthemeProc(135))
  let flushMenuThemes = cast[proc () {.stdcall.}](uxthemeProc(136))
  if setPreferredAppMode != nil: discard setPreferredAppMode(if dark: 2 else: 3) # ForceDark, ForceLight
  if flushMenuThemes != nil: flushMenuThemes()

proc update*(): bool =
  ## reads the setting again; true when it changed. The first call sets it up.
  let dark = systemIsDark()
  result = dark != flDark or brushBar == 0
  flDark = dark
  if brushBar == 0:
    brushBar = CreateSolidBrush(COLORREF colorBar)
    brushHot = CreateSolidBrush(COLORREF colorHot)
    var ncm = NONCLIENTMETRICSW(cbSize: UINT sizeof(NONCLIENTMETRICSW))
    if SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, ncm.cbSize, addr ncm, 0) != 0:
      fontMenu = CreateFontIndirectW(addr ncm.lfMenuFont)
  if result: setMenuMode(dark)

proc applyToWindow*(hwnd: HWND) =
  ## the title bar and the menu bar of one window, as the setting is now
  var on: BOOL = if flDark: TRUE else: FALSE
  if DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, addr on, DWORD sizeof(on)) != S_OK:
    discard DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_OLD, addr on, DWORD sizeof(on))
  discard SetClassLongPtrW(hwnd, GCLP_HBRBACKGROUND, if flDark: cast[LONG_PTR](brushBar) else: cast[LONG_PTR](GetSysColorBrush(COLOR_WINDOW)))
  discard DrawMenuBar(hwnd)
  # the caption is only drawn again when the window's activation changes
  let active = GetActiveWindow() == hwnd
  discard SendMessageW(hwnd, WM_NCACTIVATE, WPARAM(if active: 0 else: 1), 0)
  discard SendMessageW(hwnd, WM_NCACTIVATE, WPARAM(if active: 1 else: 0), 0)
  discard RedrawWindow(hwnd, nil, 0, RDW_FRAME or RDW_INVALIDATE)

proc drawBottomLine(hwnd: HWND) =
  ## the light line Windows draws under the menu bar, painted over in the bar's color
  var rcClient, rcWindow: RECT
  discard GetClientRect(hwnd, addr rcClient)
  discard MapWindowPoints(hwnd, 0, cast[LPPOINT](addr rcClient), 2)
  discard GetWindowRect(hwnd, addr rcWindow)
  discard OffsetRect(addr rcClient, -rcWindow.left, -rcWindow.top)
  var rcLine = rcClient
  rcLine.bottom = rcLine.top
  rcLine.top -= 1
  let hdc = GetWindowDC(hwnd)
  discard FillRect(hdc, addr rcLine, brushBar)
  discard ReleaseDC(hwnd, hdc)

proc handleMenuBar*(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM, answer: var LRESULT): bool =
  ## true when the message was the menu bar's and has been answered here;
  ## only in dark mode, light is Windows' own
  if not flDark: return false
  case msg
  of WM_UAHDRAWMENU:
    let udm = cast[ptr UAHMENU](lParam)
    var mbi = MENUBARINFO(cbSize: DWORD sizeof(MENUBARINFO))
    discard GetMenuBarInfo(hwnd, OBJID_MENU, 0, addr mbi)
    var rcWindow: RECT
    discard GetWindowRect(hwnd, addr rcWindow)
    var rc = mbi.rcBar
    discard OffsetRect(addr rc, -rcWindow.left, -rcWindow.top)
    discard FillRect(udm.hdc, addr rc, brushBar)
    answer = 1
    true
  of WM_UAHDRAWMENUITEM:
    let udmi = cast[ptr UAHDRAWMENUITEM](lParam)
    var text = newWString(256)
    var mii = MENUITEMINFOW(cbSize: UINT sizeof(MENUITEMINFOW), fMask: MIIM_STRING, dwTypeData: &text, cch: 255)
    discard GetMenuItemInfoW(udmi.um.hmenu, UINT udmi.umi.iPosition, TRUE, addr mii)
    let state = udmi.dis.itemState
    var rc = udmi.dis.rcItem
    let hot = (state and (ODS_HOTLIGHT or ODS_SELECTED)) != 0
    discard FillRect(udmi.um.hdc, addr rc, if hot: brushHot else: brushBar)
    var flags = DT_CENTER or DT_SINGLELINE or DT_VCENTER
    if (state and ODS_NOACCEL) != 0: flags = flags or DT_HIDEPREFIX # the underlined letters only after Alt, as Windows does
    discard SetBkMode(udmi.um.hdc, TRANSPARENT)
    discard SetTextColor(udmi.um.hdc, COLORREF(if (state and (ODS_GRAYED or ODS_DISABLED)) != 0: colorTextGray else: colorText))
    let old = if fontMenu != 0: SelectObject(udmi.um.hdc, fontMenu) else: 0
    discard DrawTextW(udmi.um.hdc, &text, -1, addr rc, UINT flags)
    if old != 0: discard SelectObject(udmi.um.hdc, old)
    answer = 1
    true
  of WM_NCPAINT, WM_NCACTIVATE:
    answer = DefWindowProcW(hwnd, msg, wParam, lParam)
    drawBottomLine(hwnd)
    true
  else: false

# ---------------------------------------------------------------- message boxes

const
  classMessage = "BonBonMessage"
  colorDialog = 0x002D2A29'i32 ## #292a2d, the dialogs' color in dark.css
  colorLine = 0x0068635F'i32   ## #5f6368

var
  messageText: string    ## the one message box showing; it's modal, so there's only ever one
  messageIcon: HICON
  messageDone = true
  brushDialog, brushLine: HBRUSH
  fontMessage: HFONT

proc footerHeight(): int32 = px(52)

proc messageProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM): LRESULT {.stdcall.} =
  case msg
  of WM_PAINT:
    var ps: PAINTSTRUCT
    let hdc = BeginPaint(hwnd, addr ps)
    var rc: RECT
    discard GetClientRect(hwnd, addr rc)
    var rcFooter = rc
    rcFooter.top = rc.bottom - footerHeight()
    var rcBody = rc
    rcBody.bottom = rcFooter.top
    discard FillRect(hdc, addr rcBody, brushDialog)
    discard FillRect(hdc, addr rcFooter, brushBar) # the footer, as in the page's dialogs
    discard DrawIconEx(hdc, px(20), px(20), messageIcon, px(32), px(32), 0, 0, DI_NORMAL)
    discard SetBkMode(hdc, TRANSPARENT)
    discard SetTextColor(hdc, COLORREF colorText)
    let old = SelectObject(hdc, fontMessage)
    var rcText = RECT(left: px(68), top: px(20), right: rc.right - px(20), bottom: rcFooter.top - px(12))
    discard DrawTextW(hdc, messageText, -1, addr rcText, DT_WORDBREAK or DT_NOPREFIX)
    discard SelectObject(hdc, old)
    discard EndPaint(hwnd, addr ps)
    return 0
  of WM_DRAWITEM: # the OK button
    let dis = cast[ptr DRAWITEMSTRUCT](lParam)
    var rc = dis.rcItem
    discard FillRect(dis.hDC, addr rc, if (dis.itemState and ODS_SELECTED) != 0: brushLine else: brushHot)
    discard FrameRect(dis.hDC, addr rc, if (dis.itemState and ODS_FOCUS) != 0: brushLine else: brushHot)
    discard SetBkMode(dis.hDC, TRANSPARENT)
    discard SetTextColor(dis.hDC, COLORREF colorText)
    let old = SelectObject(dis.hDC, fontMessage)
    discard DrawTextW(dis.hDC, "OK", -1, addr rc, DT_CENTER or DT_VCENTER or DT_SINGLELINE)
    discard SelectObject(dis.hDC, old)
    return TRUE
  of WM_COMMAND: # OK, Enter or Escape
    if int(LOWORD(wParam)) in [IDOK, IDCANCEL]: discard DestroyWindow(hwnd)
    return 0
  of WM_DESTROY:
    messageDone = true
    return 0
  else: discard
  DefWindowProcW(hwnd, msg, wParam, lParam)

proc messageBox*(owner: HWND, text, caption: string, error = false) =
  ## a message with an OK button, modal over owner: Windows' own in light
  ## mode, one drawn here in dark mode, since Windows has no dark one
  if not flDark:
    discard MessageBoxW(owner, text, caption, UINT(MB_OK or (if error: MB_ICONERROR else: MB_ICONINFORMATION)))
    return
  let hInst = GetModuleHandleW(nil)
  if brushDialog == 0:
    brushDialog = CreateSolidBrush(COLORREF colorDialog)
    brushLine = CreateSolidBrush(COLORREF colorLine)
    var ncm = NONCLIENTMETRICSW(cbSize: UINT sizeof(NONCLIENTMETRICSW))
    if SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, ncm.cbSize, addr ncm, 0) != 0:
      fontMessage = CreateFontIndirectW(addr ncm.lfMessageFont)
    var wc = WNDCLASSEXW(cbSize: UINT sizeof(WNDCLASSEXW), lpfnWndProc: messageProc, hInstance: hInst,
      hCursor: LoadCursorW(0, IDC_ARROW), hbrBackground: brushDialog, lpszClassName: classMessage)
    discard RegisterClassExW(addr wc)
  messageText = text
  messageIcon = LoadIconW(0, if error: IDI_ERROR else: IDI_INFORMATION)
  # the size: the text wrapped at a reasonable width, the icon at its left, the footer with the button under it
  let hdc = GetDC(0)
  let old = SelectObject(hdc, fontMessage)
  var rcText = RECT(left: 0, top: 0, right: px(360), bottom: 0)
  discard DrawTextW(hdc, text, -1, addr rcText, DT_WORDBREAK or DT_NOPREFIX or DT_CALCRECT)
  discard SelectObject(hdc, old)
  discard ReleaseDC(0, hdc)
  var rc = RECT(left: 0, top: 0, right: max(px(68) + rcText.right + px(20), px(300)),
    bottom: px(20) + max(rcText.bottom, px(32)) + px(20) + footerHeight())
  let style = DWORD(WS_POPUP or WS_CAPTION or WS_SYSMENU)
  let exStyle = DWORD(WS_EX_DLGMODALFRAME)
  let clientW = rc.right
  let clientH = rc.bottom
  discard AdjustWindowRectEx(addr rc, style, FALSE, exStyle)
  let w = rc.right - rc.left
  let h = rc.bottom - rc.top
  var rcOwner: RECT
  if owner == 0 or IsWindowVisible(owner) == 0 or GetWindowRect(owner, addr rcOwner) == 0:
    discard SystemParametersInfoW(SPI_GETWORKAREA, 0, addr rcOwner, 0)
  let x = rcOwner.left + (rcOwner.right - rcOwner.left - w) div 2
  let y = rcOwner.top + (rcOwner.bottom - rcOwner.top - h) div 2
  let hwnd = CreateWindowExW(exStyle, classMessage, caption, style, x, y, w, h, owner, 0, hInst, nil)
  if hwnd == 0: # can't make one: Windows' own, light
    discard MessageBoxW(owner, text, caption, UINT(MB_OK or (if error: MB_ICONERROR else: MB_ICONINFORMATION)))
    return
  let button = CreateWindowExW(0, "BUTTON", "OK", WS_CHILD or WS_VISIBLE or WS_TABSTOP or BS_OWNERDRAW,
    clientW - px(20) - px(88), clientH - footerHeight() + px(12), px(88), px(28), hwnd, HMENU IDOK, hInst, nil)
  var on: BOOL = TRUE
  if DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, addr on, DWORD sizeof(on)) != S_OK:
    discard DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_OLD, addr on, DWORD sizeof(on))
  if owner != 0: discard EnableWindow(owner, FALSE)
  discard ShowWindow(hwnd, SW_SHOW)
  discard SetFocus(button)
  messageDone = false
  var m: MSG
  while not messageDone:
    let r = GetMessageW(addr m, 0, 0, 0)
    if r <= 0:
      if r == 0: PostQuitMessage(int32 m.wParam) # the app is quitting: let the main loop see it too
      break
    if IsDialogMessageW(hwnd, addr m) == 0: # Enter and Escape become OK and Cancel
      discard TranslateMessage(addr m)
      discard DispatchMessageW(addr m)
  if owner != 0:
    discard EnableWindow(owner, TRUE)
    discard SetForegroundWindow(owner)

proc webViewBackground*(): uint32 =
  ## what's behind a page that has no background: white as in Electron, the bar's color in dark
  ## mode so nothing flashes white; COREWEBVIEW2_COLOR, the bytes A, R, G, B
  if flDark: 0x242120FF'u32 else: 0xFFFFFFFF'u32
