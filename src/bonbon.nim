## BonBon for Windows -- a browser for a web made of Markdown files.
##
## The native port of BonBon 0.6.56 (Electron, by Dave Winer). This file is
## index.js and main.js together: the window, its tabs, the address bar, the
## menus, and the rules for loading a page. The page itself is drawn by
## RichEdit, from the RTF rtf.nim makes of the Markdown.

{.link: "bonbon_res.o".}

import std/[os, strutils, json, tables, sets, times, math, options]
import winim/lean, winim/inc/[commctrl, richedit, shellapi, commdlg, winreg]
import urls, opml, requests, pagetext, rtf, themes, datafolder, workers, images, winutil, bookmarkseditor, shell

# ---------------------------------------------------------------- ids

const
  idTabs = 100
  idNewTab = 101
  idBack = 110
  idForward = 111
  idReload = 112
  idHome = 113
  idAddress = 114
  idSearch = 115
  idSource = 116
  idStyles = 117
  idPrev = 118
  idNext = 119
  idMore = 120
  idBookmarksBar = 130
  idFindEdit = 140
  idFindCount = 141
  idFindPrev = 142
  idFindNext = 143
  idFindClose = 144
  idSearchEdit = 150
  idSearchGo = 151
  idSearchClose = 152
  idPageBase = 1000      ## each tab's RichEdit
  idStatus = 170
  idTypeahead = 171

  cmdNewTab = 10001
  cmdCloseTab = 10002
  cmdOpenDataFolder = 10003
  cmdExit = 10004
  cmdCopy = 10010
  cmdSelectAll = 10011
  cmdFind = 10012
  cmdFindNext = 10013
  cmdFindPrevious = 10014
  cmdReload = 10020
  cmdViewSource = 10021
  cmdToggleSource = 10022
  cmdHome = 10030
  cmdBack = 10031
  cmdForward = 10032
  cmdAddBookmark = 10040
  cmdEditBookmarks = 10041
  cmdDocs = 10050
  cmdSupport = 10051
  cmdAbout = 10052
  cmdFocusAddress = 10060
  cmdNextTab = 10061
  cmdPrevTab = 10062
  cmdSearchSite = 10063
  cmdThemeBase = 11000   ## + index in themes
  cmdHistoryBase = 12000 ## + index in recentPages
  cmdBookmarkBase = 13000  ## + index in menuUrls
  cmdBarBase = 14000     ## + index in barUrls
  cmdContextOpenNewTab = 15001
  cmdContextCopyLink = 15002
  cmdContextCopy = 15003
  cmdContextViewSource = 15004
  cmdContextSelectAll = 15005

  timerSaveTabs = 1
  timerHideTypeahead = 2
  timerLoadBase = 100    ## + the load's serial, the five seconds a page waits for its pictures
  timerSocketBase = 100000 ## + the tab's serial, the wait before an update socket opens again

  titleNewTab = "New tab"
  secsUpdateSocketRetry = 30
  maxTypeaheadRows = 8
  classMain = "BonBonMain"
  classSource = "BonBonSource"

# ---------------------------------------------------------------- state

type
  Load = ref object
    serial: int
    urlAsked: string
    flFromHistory, flKeepPlace, flFromLink, flViewSource: bool
    urlBefore: string
    flShowSourceBefore: bool
    result: PageResult
    waits: int            ## pictures, the table of contents, the arrows
    finished: bool

  Tab = ref object
    serial: int
    hEdit: HWND
    url, title: string
    favicon: HICON
    source: string
    hasSource: bool
    frontMatter: JsonNode
    toc: Outline
    urlContentLocation: string
    neighborPrev, neighborNext: string
    kind: string
    flShowSource: bool
    html, listing: string
    pageImage: RtfImage
    downloadSize: int
    images: Table[string, RtfImage]
    links: seq[(int32, int32, string)]
    anchors: seq[(string, int32)]
    renderedTheme: string
    pageHistory: seq[string]
    ixHistory: int
    load: Load
    watchId: int
    findMatches: seq[(int32, int32)]
    ixFindMatch: int

var
  hInst: HINSTANCE
  hwndMain, hTabs, hNewTab, hBack, hForward, hReload, hHome, hAddress, hSearch, hSource, hStyles,
    hPrev, hNext, hMore, hBookmarksBar, hFindEdit, hFindCount, hFindPrev, hFindNext, hFindClose,
    hSearchEdit, hSearchGo, hSearchClose, hStatus, hTypeahead, hTooltip: HWND
  fontUi, fontIcons, fontAddress: HFONT
  hImages, hBarImages: HIMAGELIST
  iconPage, iconGlobe, iconApp: HICON
  hAccel: HACCEL
  config: JsonNode
  prefs: JsonNode
  theme: Theme
  tabs: seq[Tab]
  ixCurrentTab = -1
  tabSerial = 0
  loadSerial = 0
  callbacks: Table[int, proc (r: JobResult)]
  watchTabs: Table[int, Tab]             ## watchId -> the tab
  tocOutlines: Table[string, Outline]    ## origin -> the parsed table of contents, nil when none
  tocAsked: HashSet[string]
  recentPages: seq[PageVisit]
  urlHistory: seq[PageVisit]
  bookmarks: Outline
  menuUrls: seq[string]
  barUrls: seq[string]
  flFindShowing, flSearchShowing, flAlertShowing: bool
  typeaheadUrls: seq[string]
  urlsWaitingToOpen: seq[string]
  flStarted: bool
  hoverUrl: string
  favCache: Table[string, HICON]         ## origin -> icon, 0 when the site has none

proc dbg(s: string) =
  ## BONBON_LOG=path writes what the loads do, for finding trouble
  let path = getEnv("BONBON_LOG")
  if path.len > 0:
    try:
      let f = open(path, fmAppend)
      f.writeLine now().format("HH:mm:ss'.'fff") & " " & s
      f.close()
    except CatchableError: discard

var settingAddress: bool

proc setAddress(u: string) =
  ## the address the app puts in the bar; not typing, so no typeahead
  settingAddress = true
  setText(hAddress, u)
  settingAddress = false

proc currentTab(): Tab = (if ixCurrentTab >= 0 and ixCurrentTab < tabs.len: tabs[ixCurrentTab] else: nil)

proc request(kind: JobKind, url: string, cb: proc (r: JobResult), flag = false, extra: seq[string] = @[]) =
  callbacks[submit(kind, url, flag, extra)] = cb

proc alertDialog(msg: string) =
  ## one at a time: several up at once fight over the keyboard
  if flAlertShowing: return
  flAlertShowing = true
  discard MessageBoxW(hwndMain, msg, appName, MB_OK or MB_ICONWARNING)
  flAlertShowing = false

proc setStatus(s: string) = discard SendMessageW(hStatus, SB_SETTEXTW, 0, cast[LPARAM](&(+$s)))

# forward declarations
proc loadUrl(tab: Tab, theUrl: string, flFromHistory = false, flKeepPlace = false, flFromLink = false)
proc showCurrentTab()
proc buildTabBar()
proc buildMenu()
proc layout()
proc saveTabs()
proc openUrlInNewTab(theUrl: string, flBackground: bool, flFromLink = false)
proc closeTab(ix: int)
proc findInPage(flFindNext, flForward: bool)
proc watchForUpdates(tab: Tab)
proc pageProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM, id: UINT_PTR, data: DWORD_PTR): LRESULT {.stdcall.}

# ---------------------------------------------------------------- RichEdit

type StreamSrc = object
  data: ptr string
  pos: int

proc streamCb(cookie: DWORD_PTR, buf: LPBYTE, cb: LONG, pcb: ptr LONG): DWORD {.stdcall.} =
  let s = cast[ptr StreamSrc](cookie)
  let n = min(int(cb), s.data[].len - s.pos)
  if n > 0: copyMem(buf, addr s.data[][s.pos], n)
  s.pos += n
  pcb[] = LONG(n)
  0

proc streamRtf(h: HWND, rtfText: string) =
  var src = StreamSrc(data: unsafeAddr rtfText, pos: 0)
  var es: EDITSTREAM
  es.dwCookie = cast[DWORD_PTR](addr src)
  es.pfnCallback = streamCb
  discard SendMessageW(h, EM_STREAMIN, SF_RTF, cast[LPARAM](addr es))

proc textLength(h: HWND): int32 =
  var gtl = GETTEXTLENGTHEX(flags: GTL_NUMCHARS or GTL_PRECISE, codepage: 1200)
  int32 SendMessageW(h, EM_GETTEXTLENGTHEX, cast[WPARAM](addr gtl), 0)

proc pageText(h: HWND): seq[uint16] =
  let n = textLength(h)
  result = newSeq[uint16](n + 1)
  var tr: TEXTRANGEW
  tr.chrg = CHARRANGE(cpMin: 0, cpMax: n)
  tr.lpstrText = cast[LPWSTR](addr result[0])
  let got = SendMessageW(h, EM_GETTEXTRANGE, 0, cast[LPARAM](addr tr))
  result.setLen max(0, int(got))

proc utf16(s: string): seq[uint16] =
  let w = newWideCString(s)
  for i in 0 ..< w.len: result.add uint16(w[i])

proc findIn(hay: seq[uint16], needle: seq[uint16], start: int): int =
  if needle.len == 0: return -1
  var i = max(start, 0)
  while i + needle.len <= hay.len:
    var ok = true
    for k in 0 ..< needle.len:
      if hay[i + k] != needle[k]:
        ok = false
        break
    if ok: return i
    inc i
  -1

proc lowered(s: seq[uint16]): seq[uint16] =
  result = s
  if result.len > 0: discard CharLowerBuffW(cast[LPWSTR](addr result[0]), DWORD result.len)

proc getScroll(h: HWND): POINT = discard SendMessageW(h, EM_GETSCROLLPOS, 0, cast[LPARAM](addr result))
proc setScroll(h: HWND, p: POINT) =
  var q = p
  discard SendMessageW(h, EM_SETSCROLLPOS, 0, cast[LPARAM](addr q))

proc setSel(h: HWND, a, b: int32) =
  var cr = CHARRANGE(cpMin: a, cpMax: b)
  discard SendMessageW(h, EM_EXSETSEL, 0, cast[LPARAM](addr cr))

proc getSel(h: HWND): CHARRANGE = discard SendMessageW(h, EM_EXGETSEL, 0, cast[LPARAM](addr result))

proc selColor(h: HWND): COLORREF =
  var cf: CHARFORMAT2W
  cf.cbSize = UINT sizeof(cf)
  cf.dwMask = CFM_COLOR
  discard SendMessageW(h, EM_GETCHARFORMAT, SCF_SELECTION, cast[LPARAM](addr cf))
  if (cf.dwEffects and CFE_AUTOCOLOR) != 0: COLORREF(-1) else: cf.crTextColor

proc setSelEffects(h: HWND, mask, effects: DWORD, back: COLORREF = 0) =
  var cf: CHARFORMAT2W
  cf.cbSize = UINT sizeof(cf)
  cf.dwMask = mask
  cf.dwEffects = effects
  cf.crBackColor = back
  discard SendMessageW(h, EM_SETCHARFORMAT, SCF_SELECTION, cast[LPARAM](addr cf))

proc isListingTab(tab: Tab): bool =
  tab.flShowSource or tab.kind in ["html", "xml", "text", "handler"]

proc setPageRect(tab: Tab) =
  ## the reading column, centered; a listing runs the width of the window
  var rc: RECT
  discard GetClientRect(tab.hEdit, addr rc)
  let w = int(rc.right)
  var left, right: int
  if isListingTab(tab):
    left = int(px(20))
    right = w - int(px(20))
  else:
    let col = int(px(theme.maxWidthPx))
    left = max(int(px(24)), (w - col) div 2)
    right = max(left + int(px(100)), min(w - int(px(24)), left + col))
  var r = RECT(left: int32 left, top: px(24), right: int32 right, bottom: rc.bottom)
  discard SendMessageW(tab.hEdit, EM_SETRECT, 1, cast[LPARAM](addr r))

proc newPageEdit(tab: Tab): HWND =
  result = CreateWindowExW(0, "RICHEDIT50W", "", WS_CHILD or WS_VSCROLL or ES_MULTILINE or ES_READONLY or
    ES_NOOLEDRAGDROP or ES_SAVESEL, 0, 0, 0, 0, hwndMain, HMENU(idPageBase + tab.serial), hInst, nil)
  discard SendMessageW(result, EM_EXLIMITTEXT, 0, 0x7FFFFFFF)
  discard SendMessageW(result, EM_SETEVENTMASK, 0, 0)
  discard SendMessageW(result, EM_SETTYPOGRAPHYOPTIONS, TO_ADVANCEDTYPOGRAPHY, TO_ADVANCEDTYPOGRAPHY)
  discard SendMessageW(result, EM_SETBKGNDCOLOR, 0, LPARAM(toColorRef(theme.bg)))
  discard SendMessageW(result, EM_AUTOURLDETECT, 0, 0)
  discard SetWindowSubclass(result, pageProc, 5, 0)

# ---------------------------------------------------------------- drawing a tab's page

proc renderOptions(tab: Tab): RenderOptions =
  result = RenderOptions(theme: theme, baseUrl: tab.url, frontMatter: tab.frontMatter, images: tab.images,
    columnPx: theme.maxWidthPx)
  if tab.frontMatter != nil and tab.frontMatter.kind == JObject and tab.frontMatter.hasKey("rightMarginImage"):
    result.rightMarginImage = tab.frontMatter["rightMarginImage"].getStr

proc renderTab(tab: Tab): RenderedPage =
  let opt = renderOptions(tab)
  if tab.url.len == 0: return messageToRtf("", opt)
  if tab.flShowSource and tab.hasSource: return listingToRtf(tab.source, opt)
  case tab.kind
  of "": htmlToRtf(tab.html, opt)
  of "html", "xml", "text", "handler", "viewsource": listingToRtf(tab.listing, opt)
  of "image":
    var o = opt
    o.images["image:"] = tab.pageImage
    o.baseUrl = "image:"
    imageToRtf("image:", o)
  of "file": downloadToRtf(tab.url, tab.downloadSize, opt)
  else: messageToRtf("", opt)

proc markLinks(tab: Tab, page: RenderedPage) =
  ## the links and headings, found in the text RichEdit holds, in order; a
  ## link is where its words are in the link color
  tab.links.setLen 0
  tab.anchors.setLen 0
  let h = tab.hEdit
  let text = pageText(h)
  var pos = 0
  for l in page.links:
    let linkColor = COLORREF toColorRef(l.color)
    let needle = utf16(l.text)
    var at = findIn(text, needle, pos)
    while at >= 0:
      setSel(h, int32 at, int32(at + 1))
      if selColor(h) == linkColor: break
      at = findIn(text, needle, at + 1)
    if at < 0: continue
    let a = int32 at
    let b = int32(at + needle.len)
    tab.links.add (a, b, l.url)
    pos = at + needle.len
  pos = 0
  for an in page.anchors:
    let at = findIn(text, utf16(an.text), pos)
    if at >= 0:
      tab.anchors.add (an.id, int32 at)
      pos = at + 1
  setSel(h, 0, 0)

proc linkAt(tab: Tab, cp: int32): string =
  for (a, b, u) in tab.links:
    if cp >= a and cp < b: return u

proc linkAtPoint(tab: Tab, x, y: int32): string =
  ## the link under the mouse; not CFE_LINK, whose look RichEdit imposes over the theme's
  var pt = POINTL(x: x, y: y)
  let cp = int32 SendMessageW(tab.hEdit, EM_CHARFROMPOS, 0, cast[LPARAM](addr pt))
  result = linkAt(tab, cp)
  if result.len == 0: return
  var a, b: POINTL
  discard SendMessageW(tab.hEdit, EM_POSFROMCHAR, cast[WPARAM](addr a), LPARAM cp)
  discard SendMessageW(tab.hEdit, EM_POSFROMCHAR, cast[WPARAM](addr b), LPARAM(cp + 1))
  if x < a.x - 1 or y < a.y or (b.y == a.y and x > b.x + 1): result = "" # past the end of the line

proc drawTab(tab: Tab, flKeepScroll: bool) =
  ## the tab's page into its RichEdit
  let h = tab.hEdit
  let p = getScroll(h)
  discard SendMessageW(h, WM_SETREDRAW, FALSE, 0)
  discard SendMessageW(h, EM_SETBKGNDCOLOR, 0, LPARAM(toColorRef(theme.bg)))
  let page = renderTab(tab)
  discard SendMessageW(h, EM_SETREADONLY, FALSE, 0) # read-only RichEdit drops the pictures it's streamed
  dbg("draw " & tab.url & " images=" & $tab.images.len & " rtf=" & $page.rtf.len & " picts=" & $page.rtf.count("{\pict"))
  if getEnv("BONBON_LOG").len > 0: writeFile(getEnv("BONBON_LOG") & ".rtf", page.rtf)
  streamRtf(h, page.rtf)
  discard SendMessageW(h, EM_SETREADONLY, TRUE, 0)
  markLinks(tab, page)
  tab.renderedTheme = theme.name
  tab.findMatches.setLen 0
  tab.ixFindMatch = -1
  setPageRect(tab)
  setScroll(h, if flKeepScroll: p else: POINT())
  discard SendMessageW(h, WM_SETREDRAW, TRUE, 0)
  discard InvalidateRect(h, nil, TRUE)

proc scrollToAnchor(tab: Tab) =
  ## the part after # names a heading; scroll to it
  let hash = urlHash(tab.url)
  if hash.len <= 1: return
  let name = decodeURIComponent(hash[1 .. ^1])
  for (id, cp) in tab.anchors:
    if id == name:
      var pt: POINTL
      discard SendMessageW(tab.hEdit, EM_POSFROMCHAR, cast[WPARAM](addr pt), LPARAM cp)
      var cur = getScroll(tab.hEdit)
      cur.y = cur.y + pt.y - px(16)
      setScroll(tab.hEdit, cur)
      return

# ---------------------------------------------------------------- the site's table of contents

proc getSiteToc(tab: Tab): tuple[ok: bool, urlSearch, urlUpdateSocket: string, subs: seq[OutlineNode]] =
  if tab != nil: getSiteToc(tab.toc, tab.url) else: (false, "", "", @[])

proc getMirrorUrl(tab: Tab, theUrl: string): string = getMirrorUrl(tab.toc, tab.url, theUrl)

proc getSearchUrl(tab: Tab): string = getSiteToc(tab).urlSearch

proc getSearchQuery(tab: Tab): (bool, string) = getSearchQuery(tab.toc, tab.url)

proc searchSite(tab: Tab, query: string): bool =
  let urlSearch = getSearchUrl(tab)
  let q = query.strip
  if urlSearch.len == 0 or q.len == 0: return false
  loadUrl(tab, urlSearch & "?q=" & encodeURIComponent(q))
  true

# ---------------------------------------------------------------- favicons

proc faviconFor(theUrl: string, cb: proc (icon: HICON)) =
  let origin = urlOrigin(theUrl)
  if origin.len == 0:
    cb(0)
    return
  if origin in favCache:
    cb(favCache[origin])
    return
  request(jkFavicon, theUrl, proc (r: JobResult) =
    var icon: HICON = 0
    if r.text.len > 0: icon = iconFromBytes(r.text, int(px(16)))
    favCache[origin] = icon
    cb(icon))

proc getTabFavicon(tab: Tab) =
  faviconFor(tab.url, proc (icon: HICON) =
    tab.favicon = icon
    buildTabBar())

# ---------------------------------------------------------------- tabs

proc newTab(): Tab =
  inc tabSerial
  result = Tab(serial: tabSerial, title: titleNewTab, ixHistory: -1, downloadSize: -1, ixFindMatch: -1)
  result.hEdit = newPageEdit(result)

proc buildTabBar() =
  discard SendMessageW(hTabs, WM_SETREDRAW, FALSE, 0)
  discard SendMessageW(hTabs, TCM_DELETEALLITEMS, 0, 0)
  discard ImageList_RemoveAll(hImages)
  discard ImageList_AddIcon(hImages, iconPage)
  discard ImageList_AddIcon(hImages, iconGlobe)
  for i, tab in tabs:
    var image: int32 = if tab.url.len == 0: 0 else: 1
    if tab.favicon != 0: image = ImageList_AddIcon(hImages, tab.favicon)
    var title = tab.title
    if tab.load != nil and not tab.load.finished: title = "⌛ " & title
    var w = +$menuLabel(title, 40).replace("&&", "&")
    var item: TCITEMW
    item.mask = TCIF_TEXT or TCIF_IMAGE
    item.pszText = &w
    item.iImage = image
    discard SendMessageW(hTabs, TCM_INSERTITEMW, WPARAM i, cast[LPARAM](addr item))
  discard SendMessageW(hTabs, TCM_SETCURSEL, WPARAM ixCurrentTab, 0)
  discard SendMessageW(hTabs, WM_SETREDRAW, TRUE, 0)
  discard InvalidateRect(hTabs, nil, TRUE)

proc drawTabItem(dis: ptr DRAWITEMSTRUCT) =
  ## the tabs are drawn here so the icon and the title sit in the middle of the
  ## tab; the control itself puts them at the top when the height is fixed
  var buf = newWString(260)
  var item: TCITEMW
  item.mask = TCIF_TEXT or TCIF_IMAGE
  item.pszText = &buf
  item.cchTextMax = 260
  discard SendMessageW(hTabs, TCM_GETITEMW, WPARAM dis.itemID, cast[LPARAM](addr item))
  let dc = dis.hDC
  var rc = dis.rcItem
  let selected = (dis.itemState and ODS_SELECTED) != 0
  discard FillRect(dc, addr rc, GetSysColorBrush(if selected: COLOR_WINDOW else: COLOR_BTNFACE))
  let icon = px(16)
  let pad = px(8)
  # the theme draws a tab that isn't selected lower than its rcItem says
  let mid = if selected: (rc.top + rc.bottom) div 2 else: (rc.top + rc.bottom + px(3)) div 2
  discard ImageList_Draw(hImages, item.iImage, dc, rc.left + pad, mid - icon div 2, ILD_TRANSPARENT)
  var rcText = RECT(left: rc.left + pad + icon + px(6), top: rc.top, right: rc.right - pad, bottom: rc.bottom)
  discard SetBkMode(dc, TRANSPARENT)
  discard SetTextColor(dc, GetSysColor(COLOR_WINDOWTEXT))
  let old = SelectObject(dc, fontUi)
  # centered by eye: the capitals' top to the baseline, not the whole cell with its descender
  var tm: TEXTMETRICW
  discard GetTextMetricsW(dc, addr tm)
  let capH = tm.tmAscent - tm.tmInternalLeading
  let baseline = mid + (capH + 1) div 2
  rcText.top = baseline - tm.tmAscent
  rcText.bottom = rcText.top + tm.tmHeight
  discard DrawTextW(dc, item.pszText, -1, addr rcText, DT_SINGLELINE or DT_TOP or DT_END_ELLIPSIS or DT_NOPREFIX)
  discard SelectObject(dc, old)

proc updateNavButtons() =
  let tab = currentTab()
  if tab == nil: return
  enable(hBack, tab.ixHistory > 0)
  enable(hForward, tab.ixHistory < tab.pageHistory.high)
  enable(hReload, tab.ixHistory >= 0)
  enable(hSearch, getSearchUrl(tab).len > 0)
  enable(hSource, tab.hasSource)
  discard SendMessageW(hSource, BM_SETCHECK, WPARAM(if tab.flShowSource: BST_CHECKED else: BST_UNCHECKED), 0)
  var prev = ""
  var next = ""
  if tab.frontMatter != nil and tab.frontMatter.kind == JObject:
    prev = tab.frontMatter{"urlPrev"}.getStr
    next = tab.frontMatter{"urlNext"}.getStr
  if prev.len == 0 and next.len == 0:
    prev = tab.neighborPrev
    next = tab.neighborNext
  let flArrows = prev.len > 0 or next.len > 0
  show(hPrev, flArrows)
  show(hNext, flArrows)
  enable(hPrev, prev.len > 0)
  enable(hNext, next.len > 0)

proc pageArrowUrl(tab: Tab, flNext: bool): string =
  pageArrowUrl(tab.frontMatter, tab.neighborPrev, tab.neighborNext, tab.url, flNext)

proc showSearchBar(flShow: bool)

proc showCurrentTab() =
  ## put the current tab's page in the window
  let tab = currentTab()
  if tab == nil: return
  for t in tabs:
    if t != tab: show(t.hEdit, false)
  if tab.renderedTheme != theme.name: drawTab(tab, true)
  updateNavButtons() # first: the arrows showing or not changes the layout
  layout()
  show(tab.hEdit, true)
  setAddress(tab.url)
  setText(hwndMain, (if tab.title.len > 0: tab.title & " - " else: "") & appName)
  buildTabBar()
  let (isSearch, q) = getSearchQuery(tab)
  if isSearch:
    setText(hSearchEdit, q)
    var hits = ""
    if tab.frontMatter != nil: hits = tab.frontMatter{"description"}.getStr
    setStatus(hits)
  if tab.url.len == 0: SetFocus(hAddress)
  if flFindShowing:
    tab.findMatches.setLen 0
    findInPage(false, true)

proc switchToTab(ix: int) =
  ixCurrentTab = ix
  showCurrentTab()
  saveTabs()

proc insertTab(tab: Tab, flBackground: bool): Tab =
  ## right after the current one
  let ix = ixCurrentTab + 1
  tabs.insert(tab, ix)
  if flBackground:
    buildTabBar()
    saveTabs()
  else:
    switchToTab(ix)
  tab

proc openNewTab() =
  discard insertTab(newTab(), false)

proc openUrlInNewTab(theUrl: string, flBackground: bool, flFromLink = false) =
  let tab = insertTab(newTab(), flBackground)
  loadUrl(tab, theUrl, false, false, flFromLink)

proc stopWatchingTab(tab: Tab) =
  if tab.watchId != 0:
    watchTabs.del tab.watchId
    stopWatching(tab.watchId)
    tab.watchId = 0

proc closeTab(ix: int) =
  if ix < 0 or ix >= tabs.len: return
  if tabs.len == 1:
    ## THE LAST TAB OFF THE MAC: on Windows closing the last tab closes the
    ## app, as Chrome, Edge and Firefox do. tabs.json isn't touched.
    discard PostMessageW(hwndMain, WM_CLOSE, 0, 0)
    return
  let tab = tabs[ix]
  stopWatchingTab(tab)
  discard DestroyWindow(tab.hEdit)
  tabs.delete ix
  if ix < ixCurrentTab: dec ixCurrentTab
  elif ix == ixCurrentTab: ixCurrentTab = min(ix, tabs.high)
  showCurrentTab()
  saveTabs()

proc saveTabs() =
  ## a second after the last change, so a burst of changes writes once
  discard SetTimer(hwndMain, timerSaveTabs, 1000, nil)

proc writeTabsNow() =
  discard KillTimer(hwndMain, timerSaveTabs)
  var saved: seq[SavedTab]
  for t in tabs: saved.add SavedTab(pageHistory: t.pageHistory, ixHistory: t.ixHistory)
  writeTabs(ixCurrentTab, saved)

# ---------------------------------------------------------------- history

proc addToUrlHistory(tab: Tab) =
  ## the page goes to the top of the typeahead's list; one entry per address
  var list = @[PageVisit(url: tab.url, title: tab.title, `when`: now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'"))]
  for v in urlHistory:
    if v.url != tab.url: list.add v
  if list.len > maxUrlHistory: list.setLen maxUrlHistory
  urlHistory = list
  writeUrlHistory(urlHistory)

proc addToHistory(tab: Tab) =
  ## the History menu: newest first, maxHistoryMenuItems long
  var list = @[PageVisit(url: tab.url, title: tab.title, `when`: now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'"))]
  for v in recentPages:
    if v.url != tab.url: list.add v
  let max = cfgInt(config, "maxHistoryMenuItems", 25)
  if list.len > max: list.setLen max
  recentPages = list
  writeHistory(recentPages, max)
  buildMenu()

# ---------------------------------------------------------------- loading a page

proc openPdfOutside(r: PageResult): string =
  ## the PDF, saved in a BonBon folder in the temporary folder and opened from
  ## there; answers the error, "" when it opened
  var name = lastPathName(r.url)
  var clean = ""
  for c in name:
    if c in {'A'..'Z', 'a'..'z', '0'..'9', '.', '_', ' ', '-'}: clean.add c
  if clean.len == 0: clean = "document.pdf"
  elif not clean.toLowerAscii.endsWith(".pdf"): clean.add ".pdf"
  let folder = getTempDir() / appName
  try:
    createDir(folder)
    writeFile(folder / clean, r.pdfData)
  except CatchableError as e:
    return "Can't open " & r.url & " in the system's PDF viewer because the file couldn't be saved: " & e.msg
  if ShellExecuteW(hwndMain, "open", folder / clean, nil, nil, SW_SHOWNORMAL) <= 32:
    return "Can't open " & r.url & " in the system's PDF viewer because no app opens PDF files."
  ""

proc finishLoad(tab: Tab, ld: Load) =
  ## the page goes in the window all at once, when everything it needs has arrived
  if ld.finished or tab.load != ld: return
  ld.finished = true
  discard KillTimer(hwndMain, UINT_PTR(timerLoadBase + ld.serial))
  drawTab(tab, ld.flKeepPlace)
  if tab == currentTab():
    showCurrentTab()
    if not ld.flKeepPlace: setScroll(tab.hEdit, POINT())
    scrollToAnchor(tab)
    setStatus("")
  else:
    buildTabBar()
  saveTabs()
  let r = ld.result
  if r.flOk and not ld.flViewSource and tab.kind == "":
    watchForUpdates(tab)

proc oneWaitDone(tab: Tab, ld: Load) =
  dec ld.waits
  if ld.waits <= 0: finishLoad(tab, ld)

proc askForToc(tab: Tab, ld: Load) =
  ## the site's table of contents, then the arrows from it for a page that names none
  let origin = urlOrigin(tab.url)
  proc gotOutline(o: Outline) =
    if tab.load != ld: return
    tab.toc = o
    let flOwn = tab.frontMatter != nil and tab.frontMatter.kind == JObject and
      (tab.frontMatter{"urlPrev"}.getStr.len > 0 or tab.frontMatter{"urlNext"}.getStr.len > 0)
    let site = getSiteToc(tab)
    if flOwn or not site.ok or tab.url.len == 0:
      oneWaitDone(tab, ld)
      return
    let stops = tocStops(site.subs, tab.url)
    let urlPage = urlWithoutHash(tab.url)
    let urlPageFile = if tab.urlContentLocation.len == 0: urlPage else: urlWithoutHash(tab.urlContentLocation)
    if urlPage notin stops and urlPageFile notin stops:
      oneWaitDone(tab, ld)
      return
    request(jkNeighbors, urlPage, proc (r: JobResult) =
      if tab.load != ld: return
      let parts = r.text.split('\n')
      tab.neighborPrev = parts[0]
      tab.neighborNext = if parts.len > 1: parts[1] else: ""
      oneWaitDone(tab, ld), extra = @[urlPageFile] & stops)
  if origin in tocAsked:
    gotOutline(tocOutlines.getOrDefault(origin))
  else:
    request(jkToc, tab.url, proc (r: JobResult) =
      var o: Outline = nil
      if r.text.len > 0:
        try: o = parseOpml(r.text)
        except CatchableError: o = nil
      tocAsked.incl origin
      tocOutlines[origin] = o
      if tab.load == ld: gotOutline(o))

proc fetchPicture(tab: Tab, ld: Load, theUrl: string) =
  ## its own proc, so each callback keeps its own address
  request(jkImage, theUrl, proc (ir: JobResult) =
    if tab.load != ld or ld.finished: return
    if ir.err.len == 0:
      let (ok, img) = decodeForPage(ir.text)
      if ok: tab.images[theUrl] = img
      dbg("picture " & theUrl & " bytes=" & $ir.text.len & " decoded=" & $ok)
    else: dbg("picture " & theUrl & " " & ir.err)
    oneWaitDone(tab, ld))

proc gotPage(tab: Tab, ld: Load, res: PageResult) =
  var r = res
  if tab.load != ld: return # a newer load took the tab
  if r.flOk and r.kind == "pdf" and not ld.flViewSource:
    if cfgBool(config, "flOpenPdfsInSystemViewer"):
      let err = openPdfOutside(r)
      r = if err.len > 0: PageResult(flOk: false, url: r.url, message: err) else: PageResult(flOk: true, kind: "openedOutside", url: r.url)
    else:
      ## no PDF viewer in the window: the system's viewer shows it
      let err = openPdfOutside(r)
      r = if err.len > 0: PageResult(flOk: false, url: r.url, message: err) else: PageResult(flOk: true, kind: "openedOutside", url: r.url)
  handlePage(r, config)
  ld.result = r
  let flOpenedOutside = r.flOk and r.kind == "openedOutside"
  let flToBrowser = flOpenedOutside or (r.flOk and ld.flFromLink and not ld.flViewSource and r.kind == "html")
  if flToBrowser or not r.flOk:
    ## two ways the tab stays on the page it had: the page didn't come, or it went elsewhere
    ld.finished = true
    tab.load = nil
    if ld.urlBefore.len == 0 and not flToBrowser:
      tab.title = tab.url
    else:
      tab.url = ld.urlBefore
      tab.flShowSource = ld.flShowSourceBefore
    if flToBrowser:
      if not flOpenedOutside: openShell(r.url)
      if ld.urlBefore.len == 0:
        closeTab(tabs.find(tab))
        return
      elif tab == currentTab():
        setAddress(ld.urlBefore)
    else:
      if tab == currentTab() and not ld.flKeepPlace:
        setStatus("")
        alertDialog(r.message)
    if ld.urlBefore.len > 0 and tab.hasSource and tab.kind == "": watchForUpdates(tab)
    buildTabBar()
    saveTabs()
    return

  tab.url = if ld.flViewSource: prefixViewSource & r.url else: r.url
  if not ld.flFromHistory:
    tab.pageHistory.setLen tab.ixHistory + 1 # drop anything ahead of where we are
    tab.pageHistory.add tab.url
    tab.ixHistory = tab.pageHistory.high
  tab.urlContentLocation = r.urlContentLocation
  tab.neighborPrev = ""
  tab.neighborNext = ""
  tab.images.clear()
  if r.handlerError.len > 0 and tab == currentTab() and not ld.flKeepPlace:
    alertDialog(r.handlerError)
  if ld.flViewSource:
    tab.kind = "viewsource"
    tab.listing = r.source
    tab.hasSource = false
    tab.source = ""
    tab.frontMatter = nil
    tab.title = tab.url
    tab.favicon = 0
  elif r.kind.len > 0:
    tab.kind = r.kind
    tab.frontMatter = nil
    tab.hasSource = false
    tab.source = ""
    case r.kind
    of "image":
      let (ok, img) = decodeForPage(r.imageData)
      tab.pageImage = if ok: img else: RtfImage()
    of "file": tab.downloadSize = r.size
    of "handler":
      tab.listing = htmlListingText(r.html)
      tab.source = r.source
      tab.hasSource = true
    else:
      tab.listing = r.source
      tab.source = r.source
      tab.hasSource = true
    tab.title = if r.title.len > 0: r.title else: r.url
    if not ld.flFromHistory: addToHistory(tab)
    addToUrlHistory(tab)
    getTabFavicon(tab)
  else:
    tab.kind = ""
    tab.html = r.html
    tab.source = r.source
    tab.hasSource = true
    try: tab.frontMatter = parseJson(r.frontMatter)
    except CatchableError: tab.frontMatter = newJObject()
    let t = tab.frontMatter{"title"}
    tab.title = if t != nil and t.kind == JString and t.getStr.len > 0: t.getStr else: r.url
    if not ld.flFromHistory: addToHistory(tab)
    addToUrlHistory(tab)
    getTabFavicon(tab)

  ## everything the page needs before it's drawn: its pictures, its table of contents
  ld.waits = 1 # this proc's own, released at the end
  if not ld.flViewSource and tab.kind == "":
    var urls = imageUrlsIn(tab.html, tab.url)
    if tab.frontMatter.kind == JObject and tab.frontMatter{"rightMarginImage"}.getStr.len > 0:
      let u = resolveUrl(tab.url, tab.frontMatter{"rightMarginImage"}.getStr)
      if u.len > 0 and u notin urls: urls.add u
    for u in urls:
      inc ld.waits
      fetchPicture(tab, ld, u)
    if urls.len > 0:
      discard SetTimer(hwndMain, UINT_PTR(timerLoadBase + ld.serial), 5000, nil) # a slow picture shouldn't hold the page forever
  if not ld.flViewSource:
    inc ld.waits
    askForToc(tab, ld)
  oneWaitDone(tab, ld)

proc loadUrl(tab: Tab, theUrl: string, flFromHistory = false, flKeepPlace = false, flFromLink = false) =
  ## the result lands in the tab it was asked for, which may not be the current one by the time it arrives
  let u = fixUrl(theUrl)
  inc loadSerial
  let ld = Load(serial: loadSerial, urlAsked: u, flFromHistory: flFromHistory, flKeepPlace: flKeepPlace,
    flFromLink: flFromLink, urlBefore: tab.url, flShowSourceBefore: tab.flShowSource)
  stopWatchingTab(tab)
  tab.url = u
  if urlAsksForMarkdown(u): tab.flShowSource = true
  elif not flFromHistory: tab.flShowSource = false
  if tab == currentTab():
    setAddress(u)
    setStatus("Loading " & u & "…")
  ld.flViewSource = u.startsWith(prefixViewSource)
  let urlToGet = if ld.flViewSource: u[prefixViewSource.len .. ^1] else: u
  tab.load = ld
  buildTabBar()
  request(jkPage, urlToGet, proc (r: JobResult) = gotPage(tab, ld, r.page), ld.flViewSource)

proc followLink(tab: Tab, theUrl: string, flNewTab: bool) =
  ## a click on a link: when it points at a site this domain mirrors and the
  ## Markdown version is there, that's the page; otherwise the link's own
  proc go(u: string) =
    if flNewTab: openUrlInNewTab(u, true, true)
    else: loadUrl(tab, u, false, false, true)
  let urlMirror = getMirrorUrl(tab, theUrl)
  if urlMirror.len == 0:
    go(theUrl)
  else:
    request(jkIsMarkdown, urlMirror, proc (r: JobResult) = go(if r.flag: urlMirror else: theUrl))

proc clickLink(tab: Tab, theUrl: string, flNewTab: bool) =
  if theUrl.startsWith("bonbon-download:"):
    let u = theUrl["bonbon-download:".len .. ^1]
    var name = lastPathName(u)
    if name.len == 0: name = "download"
    var buf = newWString(1024)
    let w = +$name
    copyMem(&buf, &w, min(w.len, 1000) * 2)
    var ofn: OPENFILENAMEW
    ofn.lStructSize = DWORD sizeof(ofn)
    ofn.hwndOwner = hwndMain
    ofn.lpstrFile = &buf
    ofn.nMaxFile = 1024
    ofn.Flags = OFN_OVERWRITEPROMPT or OFN_PATHMUSTEXIST
    if GetSaveFileNameW(addr ofn) != 0:
      let path = $cast[WideCString](&buf)
      setStatus("Downloading " & name & "…")
      request(jkText, u, proc (r: JobResult) =
        if r.err.len > 0:
          setStatus("")
          alertDialog("Can't download " & u & " because " & r.err & ".")
        else:
          try:
            writeFile(path, r.text)
            setStatus("Downloaded " & path)
          except CatchableError as e:
            setStatus("")
            alertDialog("Can't save " & path & " because " & e.msg))
    return
  if '#' in theUrl and tab.url.len > 0 and urlWithoutHash(theUrl) == urlWithoutHash(tab.url) and not flNewTab:
    tab.url = theUrl # a link to a place in this page
    setAddress(tab.url)
    scrollToAnchor(tab)
    saveTabs()
    return
  followLink(tab, theUrl, flNewTab)

proc goBack() =
  let tab = currentTab()
  if tab.ixHistory > 0:
    dec tab.ixHistory
    loadUrl(tab, tab.pageHistory[tab.ixHistory], true)

proc goForward() =
  let tab = currentTab()
  if tab.ixHistory < tab.pageHistory.high:
    inc tab.ixHistory
    loadUrl(tab, tab.pageHistory[tab.ixHistory], true)

proc reload() =
  let tab = currentTab()
  if tab.ixHistory >= 0:
    loadUrl(tab, tab.pageHistory[tab.ixHistory], true, true)

proc goHome() =
  let home = cfgStr(config, "urlHomePage")
  if home.len > 0: loadUrl(currentTab(), home)

proc toggleSourceCommand() =
  ## THE MARKDOWN BUTTON: the page's text, or the page; a display switch
  let tab = currentTab()
  if not tab.hasSource: return
  tab.flShowSource = not tab.flShowSource
  drawTab(tab, false)
  showCurrentTab()

# ---------------------------------------------------------------- live reload

proc watchForUpdates(tab: Tab) =
  ## LIVE RELOAD, Drummer's way: when the page the tab shows is rebuilt, the tab reloads it
  stopWatchingTab(tab)
  let site = getSiteToc(tab)
  if not site.ok or site.urlUpdateSocket.len == 0 or tab.url.startsWith(prefixViewSource): return
  tab.watchId = startWatching(site.urlUpdateSocket, urlWithoutHash(tab.url))
  watchTabs[tab.watchId] = tab

proc socketMessage(r: JobResult) =
  if r.id notin watchTabs: return
  let tab = watchTabs[r.id]
  if r.kind == jkSocketUpdate:
    if r.url == urlWithoutHash(tab.url):
      loadUrl(tab, tab.url, true, true)
  else: # it dropped; open it again after a while, if the tab still shows the page
    watchTabs.del r.id
    tab.watchId = 0
    discard SetTimer(hwndMain, UINT_PTR(timerSocketBase + tab.serial), secsUpdateSocketRetry * 1000, nil)

# ---------------------------------------------------------------- find in page

proc showFindCount() =
  let tab = currentTab()
  if tab.findMatches.len == 0:
    setText(hFindCount, if getText(hFindEdit).len == 0: "" else: "0/0")
  else:
    setText(hFindCount, $(tab.ixFindMatch + 1) & "/" & $tab.findMatches.len)

proc clearFindMatches(tab: Tab) =
  if tab.findMatches.len > 0:
    drawTab(tab, true)
  tab.findMatches.setLen 0
  tab.ixFindMatch = -1

proc showFindMatch(tab: Tab, ix: int) =
  let h = tab.hEdit
  discard SendMessageW(h, WM_SETREDRAW, FALSE, 0)
  let p = getScroll(h)
  if tab.ixFindMatch >= 0:
    let (a, b) = tab.findMatches[tab.ixFindMatch]
    setSel(h, a, b)
    setSelEffects(h, CFM_BACKCOLOR, 0, RGB(255, 240, 120))
  tab.ixFindMatch = ix
  let (a, b) = tab.findMatches[ix]
  setSel(h, a, b)
  setSelEffects(h, CFM_BACKCOLOR, 0, RGB(255, 150, 50))
  setSel(h, a, a)
  setScroll(h, p)
  discard SendMessageW(h, WM_SETREDRAW, TRUE, 0)
  discard InvalidateRect(h, nil, TRUE)
  # the match, centered when it's out of view
  var pt: POINTL
  discard SendMessageW(h, EM_POSFROMCHAR, cast[WPARAM](addr pt), LPARAM a)
  var rc: RECT
  discard GetClientRect(h, addr rc)
  if pt.y < 0 or pt.y > rc.bottom - px(30):
    var cur = getScroll(h)
    cur.y = max(0, cur.y + pt.y - rc.bottom div 2)
    setScroll(h, cur)
  showFindCount()

proc markFindMatches(tab: Tab, text: string) =
  clearFindMatches(tab)
  let h = tab.hEdit
  let hay = lowered(pageText(h))
  let needle = lowered(utf16(text))
  var at = findIn(hay, needle, 0)
  while at >= 0:
    tab.findMatches.add (int32 at, int32(at + needle.len))
    at = findIn(hay, needle, at + needle.len)
  if tab.findMatches.len == 0: return
  discard SendMessageW(h, WM_SETREDRAW, FALSE, 0)
  let p = getScroll(h)
  for (a, b) in tab.findMatches:
    setSel(h, a, b)
    setSelEffects(h, CFM_BACKCOLOR, 0, RGB(255, 240, 120))
  setSel(h, 0, 0)
  setScroll(h, p)
  discard SendMessageW(h, WM_SETREDRAW, TRUE, 0)
  discard InvalidateRect(h, nil, TRUE)

proc findInPage(flFindNext, flForward: bool) =
  ## a new search marks the matches and goes to the first; next and previous wrap around
  let tab = currentTab()
  let text = getText(hFindEdit)
  if text.len == 0:
    clearFindMatches(tab)
  elif not flFindNext or tab.findMatches.len == 0:
    markFindMatches(tab, text)
    if tab.findMatches.len > 0: showFindMatch(tab, 0)
  else:
    let ct = tab.findMatches.len
    showFindMatch(tab, if flForward: (tab.ixFindMatch + 1) mod ct else: (tab.ixFindMatch - 1 + ct) mod ct)
  showFindCount()

proc findCommand() =
  flFindShowing = true
  layout()
  SetFocus(hFindEdit)
  discard SendMessageW(hFindEdit, EM_SETSEL, 0, -1)
  findInPage(false, true)

proc closeFind() =
  flFindShowing = false
  clearFindMatches(currentTab())
  layout()
  SetFocus(currentTab().hEdit)

proc showSearchBar(flShow: bool) =
  flSearchShowing = flShow
  layout()
  if flShow:
    SetFocus(hSearchEdit)
    discard SendMessageW(hSearchEdit, EM_SETSEL, 0, -1)

# ---------------------------------------------------------------- bookmarks

proc addBarButton(text, u: string) =
  let ix = barUrls.len
  barUrls.add u
  var label = +$menuLabel(if text.strip.len > 0: text.strip else: u, 30).replace("&&", "&")
  var b: TBBUTTON
  b.iBitmap = 0
  b.idCommand = int32(cmdBarBase + ix)
  b.fsState = TBSTATE_ENABLED
  b.fsStyle = BYTE(BTNS_BUTTON or BTNS_AUTOSIZE or BTNS_SHOWTEXT or BTNS_NOPREFIX)
  b.iString = cast[INT_PTR](&label)
  discard SendMessageW(hBookmarksBar, TB_ADDBUTTONSW, 1, cast[LPARAM](addr b))
  faviconFor(u, proc (icon: HICON) =
    if icon != 0 and ix < barUrls.len and barUrls[ix] == u:
      let image = ImageList_AddIcon(hBarImages, icon)
      var info: TBBUTTONINFOW
      info.cbSize = UINT sizeof(info)
      info.dwMask = TBIF_IMAGE
      info.iImage = image
      discard SendMessageW(hBookmarksBar, TB_SETBUTTONINFOW, WPARAM(cmdBarBase + ix), cast[LPARAM](addr info)))

proc buildBookmarksBar() =
  ## Chrome's bar, under the address bar: the sub-heads of the Bookmarks bar headline
  while SendMessageW(hBookmarksBar, TB_BUTTONCOUNT, 0, 0) > 0:
    discard SendMessageW(hBookmarksBar, TB_DELETEBUTTON, 0, 0)
  discard ImageList_RemoveAll(hBarImages)
  discard ImageList_AddIcon(hBarImages, iconGlobe)
  barUrls.setLen 0
  let folder = if bookmarks == nil: nil else: getBookmarksBarFolder(bookmarks, false)
  if folder != nil:
    for n in folder.subs:
      if n.att("url").len > 0: addBarButton(n.att("text"), n.att("url"))
  discard SendMessageW(hBookmarksBar, TB_AUTOSIZE, 0, 0)
  layout()

proc saveBookmarksOutline(o: Outline) =
  bookmarks = o
  writeBookmarks(toOpml(o))
  buildMenu()
  buildBookmarksBar()

proc startBookmarks() =
  let text = readBookmarks()
  if text.len > 0:
    try: bookmarks = parseOpml(text)
    except CatchableError: bookmarks = nil
  if bookmarks == nil: # the first run, there's no bookmarks file yet
    bookmarks = startingBookmarks(cfgStr(config, "urlHomePage"))
    writeBookmarks(toOpml(bookmarks))
  buildMenu()
  buildBookmarksBar()

proc editBookmarksCommand(select: OutlineNode = nil) =
  editBookmarks(hwndMain, bookmarks, select, proc (o: Outline) = saveBookmarksOutline(o))

proc addBookmarkCommand() =
  let tab = currentTab()
  if tab.url.len == 0:
    alertDialog("Can't add a bookmark because this tab has no page in it.")
    return
  if MessageBoxW(hwndMain, "Add \"" & tab.title & "\" to the Bookmarks menu?", appName, MB_OKCANCEL or MB_ICONQUESTION) != IDOK:
    return
  let n = newBookmark(tab.title, tab.url)
  bookmarks.body.subs.add n
  saveBookmarksOutline(bookmarks)
  editBookmarksCommand(n)

# ---------------------------------------------------------------- menus

proc addItem(m: HMENU, id: int, label: string, flags: UINT = 0) =
  discard AppendMenuW(m, MF_STRING or flags, UINT_PTR id, label)

proc addSeparator(m: HMENU) = discard AppendMenuW(m, MF_SEPARATOR, 0, nil)

proc themesMenu(): HMENU =
  result = CreatePopupMenu()
  for i, t in allThemes:
    addItem(result, cmdThemeBase + i, t.title, if t.name == theme.name: MF_CHECKED else: 0)

proc bookmarkItems(m: HMENU, subs: seq[OutlineNode]) =
  for n in subs:
    let text = if n.att("text").len > 0: n.att("text") else: n.att("url")
    if n.subs.len > 0:
      let sub = CreatePopupMenu()
      bookmarkItems(sub, n.subs)
      discard AppendMenuW(m, MF_POPUP, cast[UINT_PTR](sub), menuLabel(text))
    elif n.att("url").len > 0:
      menuUrls.add n.att("url")
      addItem(m, cmdBookmarkBase + menuUrls.high, menuLabel(text))

proc buildMenu() =
  let bar = CreateMenu()
  let file = CreatePopupMenu()
  addItem(file, cmdNewTab, "New &Tab\tCtrl+T")
  addItem(file, cmdCloseTab, "&Close Tab\tCtrl+W")
  addSeparator(file)
  addItem(file, cmdOpenDataFolder, "Open &Data Folder")
  addSeparator(file)
  addItem(file, cmdExit, "E&xit")
  let edit = CreatePopupMenu()
  addItem(edit, cmdCopy, "&Copy\tCtrl+C")
  addItem(edit, cmdSelectAll, "Select &All\tCtrl+A")
  addSeparator(edit)
  addItem(edit, cmdFind, "&Find...\tCtrl+F")
  addItem(edit, cmdFindNext, "Find &Next\tCtrl+G")
  addItem(edit, cmdFindPrevious, "Find &Previous\tCtrl+Shift+G")
  addSeparator(edit)
  addItem(edit, cmdSearchSite, "&Search This Site...")
  let view = CreatePopupMenu()
  addItem(view, cmdReload, "&Reload This Page\tCtrl+R")
  addSeparator(view)
  addItem(view, cmdToggleSource, "Show &Markdown Source")
  addItem(view, cmdViewSource, "View &Source\tCtrl+Alt+U")
  addSeparator(view)
  discard AppendMenuW(view, MF_POPUP, cast[UINT_PTR](themesMenu()), "S&tylesheet")
  let history = CreatePopupMenu()
  addItem(history, cmdHome, "&Home\tCtrl+Shift+H")
  addItem(history, cmdBack, "&Back\tAlt+Left")
  addItem(history, cmdForward, "&Forward\tAlt+Right")
  if recentPages.len > 0:
    addSeparator(history)
    for i, p in recentPages:
      if i >= cfgInt(config, "maxHistoryMenuItems", 25): break
      addItem(history, cmdHistoryBase + i, menuLabel(if p.title.len > 0: p.title else: p.url))
  let bm = CreatePopupMenu()
  menuUrls.setLen 0
  addItem(bm, cmdAddBookmark, "&Add Bookmark...\tCtrl+D")
  if bookmarks != nil and bookmarks.body.subs.len > 0:
    addSeparator(bm)
    bookmarkItems(bm, bookmarks.body.subs)
  addSeparator(bm)
  addItem(bm, cmdEditBookmarks, "&Edit Bookmarks...")
  let help = CreatePopupMenu()
  addItem(help, cmdDocs, "BonBon &Docs")
  addItem(help, cmdSupport, "&Support")
  addSeparator(help)
  addItem(help, cmdAbout, "&About BonBon")
  for (m, label) in [(file, "&File"), (edit, "&Edit"), (view, "&View"), (history, "Hi&story"), (bm, "&Bookmarks"), (help, "&Help")]:
    discard AppendMenuW(bar, MF_POPUP, cast[UINT_PTR](m), label)
  let old = GetMenu(hwndMain)
  discard SetMenu(hwndMain, bar)
  if old != 0: discard DestroyMenu(old)
  discard DrawMenuBar(hwndMain)

proc buildAccelerators() =
  proc acc(flags: int, key: int, cmd: int): ACCEL = ACCEL(fVirt: BYTE(FVIRTKEY or flags), key: WORD key, cmd: WORD cmd)
  var table = [
    acc(FCONTROL, ord('T'), cmdNewTab), acc(FCONTROL, ord('W'), cmdCloseTab), acc(FCONTROL, VK_F4, cmdCloseTab),
    acc(FCONTROL, ord('D'), cmdAddBookmark), acc(FCONTROL, ord('F'), cmdFind),
    acc(FCONTROL, ord('G'), cmdFindNext), acc(FCONTROL or FSHIFT, ord('G'), cmdFindPrevious),
    acc(0, VK_F3, cmdFindNext), acc(FSHIFT, VK_F3, cmdFindPrevious),
    acc(FCONTROL, ord('R'), cmdReload), acc(0, VK_F5, cmdReload),
    acc(FCONTROL or FALT, ord('U'), cmdViewSource), acc(FCONTROL, ord('U'), cmdViewSource),
    acc(FCONTROL or FSHIFT, ord('H'), cmdHome), acc(FALT, VK_HOME, cmdHome),
    acc(FCONTROL, VK_OEM_4, cmdBack), acc(FCONTROL, VK_OEM_6, cmdForward),
    acc(FALT, VK_LEFT, cmdBack), acc(FALT, VK_RIGHT, cmdForward), acc(0, VK_BROWSER_BACK, cmdBack),
    acc(0, VK_BROWSER_FORWARD, cmdForward), acc(FCONTROL, ord('L'), cmdFocusAddress), acc(FALT, ord('D'), cmdFocusAddress),
    acc(FCONTROL, VK_TAB, cmdNextTab), acc(FCONTROL or FSHIFT, VK_TAB, cmdPrevTab),
    acc(FCONTROL, VK_NEXT, cmdNextTab), acc(FCONTROL, VK_PRIOR, cmdPrevTab)]
  hAccel = CreateAcceleratorTableW(addr table[0], int32 table.len)

# ---------------------------------------------------------------- view source window

proc sourceProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM): LRESULT {.stdcall.} =
  case msg
  of WM_SIZE:
    let child = GetWindow(hwnd, GW_CHILD)
    if child != 0: move(child, 0, 0, int(LOWORD(lParam)), int(HIWORD(lParam)))
    return 0
  else: discard
  DefWindowProcW(hwnd, msg, wParam, lParam)

proc viewSourceCommand() =
  ## VIEW SOURCE: the page's text as it came from the server, in its own window
  let tab = currentTab()
  if not tab.hasSource: return
  let w = CreateWindowExW(0, classSource, prefixViewSource & tab.url, WS_OVERLAPPEDWINDOW,
    CW_USEDEFAULT, CW_USEDEFAULT, px(800), px(700), 0, 0, hInst, nil)
  let e = CreateWindowExW(0, "RICHEDIT50W", "", WS_CHILD or WS_VISIBLE or WS_VSCROLL or WS_HSCROLL or
    ES_MULTILINE or ES_READONLY or ES_NOHIDESEL, 0, 0, 0, 0, w, HMENU 1, hInst, nil)
  discard SendMessageW(e, EM_EXLIMITTEXT, 0, 0x7FFFFFFF)
  discard SendMessageW(e, EM_SETTARGETDEVICE, 0, 0) # wrap at the window's edge
  streamRtf(e, listingToRtf(tab.source, RenderOptions(theme: getTheme("basic"), columnPx: 800)).rtf)
  var rc: RECT
  discard GetClientRect(w, addr rc)
  move(e, 0, 0, rc.right, rc.bottom)
  discard ShowWindow(w, SW_SHOW)

# ---------------------------------------------------------------- the typeahead

proc hideTypeahead() =
  show(hTypeahead, false)
  typeaheadUrls.setLen 0

proc showTypeahead() =
  ## TYPEAHEAD, Chrome's way: the pages you've visited whose address or title contains what you typed
  let text = getText(hAddress).strip.toLowerAscii
  discard SendMessageW(hTypeahead, LB_RESETCONTENT, 0, 0)
  typeaheadUrls.setLen 0
  if text.len == 0:
    hideTypeahead()
    return
  for v in urlHistory:
    if typeaheadUrls.len >= maxTypeaheadRows: break
    if text in v.url.toLowerAscii or text in v.title.toLowerAscii:
      typeaheadUrls.add v.url
      let row = if v.title.len == 0 or v.title == v.url: v.url else: v.title & "  —  " & v.url
      discard SendMessageW(hTypeahead, LB_ADDSTRING, 0, cast[LPARAM](&(+$row)))
  if typeaheadUrls.len == 0:
    hideTypeahead()
    return
  var rc: RECT
  discard GetWindowRect(hAddress, addr rc)
  let rowH = int(SendMessageW(hTypeahead, LB_GETITEMHEIGHT, 0, 0))
  discard SetWindowPos(hTypeahead, HWND_TOP, rc.left, rc.bottom, rc.right - rc.left,
    int32(rowH * typeaheadUrls.len + 4), SWP_NOACTIVATE or SWP_SHOWWINDOW)

proc typeaheadSelection(): string =
  if IsWindowVisible(hTypeahead) == 0: return ""
  let ix = int(SendMessageW(hTypeahead, LB_GETCURSEL, 0, 0))
  if ix >= 0 and ix < typeaheadUrls.len: typeaheadUrls[ix] else: ""

proc addressEnter() =
  let sel = typeaheadSelection()
  hideTypeahead()
  let tab = currentTab()
  let text = getText(hAddress)
  if sel.len > 0:
    loadUrl(tab, sel)
  elif text.strip.len > 0:
    # a word is a search of this site; on a site with no search it's tried as an address
    if looksLikeAddress(text) or not searchSite(tab, text):
      loadUrl(tab, text)
  SetFocus(tab.hEdit)

proc addressProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM, id: UINT_PTR, data: DWORD_PTR): LRESULT {.stdcall.} =
  case msg
  of WM_KEYDOWN:
    case int(wParam)
    of VK_RETURN:
      addressEnter()
      return 0
    of VK_ESCAPE:
      if IsWindowVisible(hTypeahead) != 0: hideTypeahead()
      else:
        setAddress(currentTab().url)
        discard SendMessageW(hAddress, EM_SETSEL, 0, -1)
      return 0
    of VK_DOWN, VK_UP:
      if IsWindowVisible(hTypeahead) != 0:
        var ix = int(SendMessageW(hTypeahead, LB_GETCURSEL, 0, 0))
        ix = if int(wParam) == VK_DOWN: min(ix + 1, typeaheadUrls.high) else: max(ix - 1, -1)
        discard SendMessageW(hTypeahead, LB_SETCURSEL, WPARAM ix, 0)
        return 0
    else: discard
  of WM_CHAR:
    if int(wParam) in [VK_RETURN, VK_ESCAPE]: return 0 # no beep
  of WM_SETFOCUS:
    discard PostMessageW(hwnd, EM_SETSEL, 0, -1) # a click in the bar selects the whole address
  of WM_KILLFOCUS:
    discard SetTimer(hwndMain, timerHideTypeahead, 150, nil)
  else: discard
  DefSubclassProc(hwnd, msg, wParam, lParam)

proc typeaheadProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM, id: UINT_PTR, data: DWORD_PTR): LRESULT {.stdcall.} =
  case msg
  of WM_MOUSEACTIVATE: return MA_NOACTIVATE
  of WM_LBUTTONUP:
    let r = DefSubclassProc(hwnd, msg, wParam, lParam)
    let sel = typeaheadSelection()
    hideTypeahead()
    if sel.len > 0: loadUrl(currentTab(), sel)
    return r
  else: discard
  DefSubclassProc(hwnd, msg, wParam, lParam)

proc barEditProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM, id: UINT_PTR, data: DWORD_PTR): LRESULT {.stdcall.} =
  ## the find and search bars: Return and Escape
  if msg == WM_KEYDOWN:
    let shift = GetKeyState(VK_SHIFT) < 0
    if int(wParam) == VK_RETURN:
      if hwnd == hFindEdit: findInPage(true, not shift)
      else:
        if searchSite(currentTab(), getText(hSearchEdit)): showSearchBar(false)
      return 0
    if int(wParam) == VK_ESCAPE:
      if hwnd == hFindEdit: closeFind() else: showSearchBar(false)
      return 0
  if msg == WM_CHAR and int(wParam) in [VK_RETURN, VK_ESCAPE]: return 0
  DefSubclassProc(hwnd, msg, wParam, lParam)

proc pageProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM, id: UINT_PTR, data: DWORD_PTR): LRESULT {.stdcall.} =
  ## links: the address under the mouse lower left, every browser since MSIE;
  ## a click loads it here, ctrl-click or the middle button in a new tab behind this one
  var tab: Tab = nil
  for t in tabs:
    if t.hEdit == hwnd: tab = t
  if tab == nil: return DefSubclassProc(hwnd, msg, wParam, lParam)
  let x = int32(cast[int16](LOWORD(lParam)))
  let y = int32(cast[int16](HIWORD(lParam)))
  case msg
  of WM_MOUSEMOVE:
    let u = linkAtPoint(tab, x, y)
    if u != hoverUrl:
      hoverUrl = u
      setStatus(if u.startsWith("bonbon-download:"): u["bonbon-download:".len .. ^1] else: u)
  of WM_SETCURSOR:
    if hoverUrl.len > 0 and LOWORD(lParam) == HTCLIENT:
      discard SetCursor(LoadCursorW(0, IDC_HAND))
      return 1
  of WM_LBUTTONUP:
    let r = DefSubclassProc(hwnd, msg, wParam, lParam)
    let u = linkAtPoint(tab, x, y)
    let sel = getSel(hwnd)
    if u.len > 0 and sel.cpMax == sel.cpMin: # not the end of a drag to select
      clickLink(tab, u, (wParam and MK_CONTROL) != 0)
    return r
  of WM_MBUTTONUP:
    let u = linkAtPoint(tab, x, y)
    if u.len > 0 and not u.startsWith("bonbon-download:"): openUrlInNewTab(u, true, true)
    return 0
  of WM_SIZE:
    let r = DefSubclassProc(hwnd, msg, wParam, lParam)
    setPageRect(tab)
    return r
  of WM_KEYDOWN:
    if int(wParam) == VK_ESCAPE and flFindShowing:
      closeFind()
      return 0
  else: discard
  DefSubclassProc(hwnd, msg, wParam, lParam)

# ---------------------------------------------------------------- layout

proc layout() =
  if hwndMain == 0 or hTabs == 0: return
  var rc: RECT
  discard GetClientRect(hwndMain, addr rc)
  let w = int(rc.right)
  let h = int(rc.bottom)
  discard SendMessageW(hStatus, WM_SIZE, 0, 0)
  var rcStatus: RECT
  discard GetWindowRect(hStatus, addr rcStatus)
  let statusH = int(rcStatus.bottom - rcStatus.top)
  var parts = [int32(w - px(90)), -1'i32]
  discard SendMessageW(hStatus, SB_SETPARTS, 2, cast[LPARAM](addr parts[0]))
  discard SendMessageW(hStatus, SB_SETTEXTW, 1, cast[LPARAM](&(+$("v" & appVersion))))
  let m = int(px(6))
  let b = int(px(32))
  let tabsH = int(px(30))
  move(hTabs, m, m div 2, w - 2 * m - b, tabsH)
  move(hNewTab, w - m - b + px(2), m div 2 + px(2), b - px(4), tabsH - px(4))
  var y = m div 2 + tabsH + px(4)
  let rowH = int(px(30))
  var x = m
  for hb in [hBack, hForward, hReload, hHome]:
    move(hb, x, y, b, rowH)
    x += b + px(2)
  let rights = [hSearch, hSource, hStyles, hPrev, hNext, hMore]
  var rightW = 0
  for hb in rights:
    if IsWindowVisible(hb) != 0 or hb notin [hPrev, hNext]: rightW += b + px(2)
  move(hAddress, x + px(4), y, w - x - px(4) - rightW - m - px(4), rowH)
  var xr = w - m - rightW
  for hb in rights:
    if hb in [hPrev, hNext] and IsWindowVisible(hb) == 0: continue
    move(hb, xr, y, b, rowH)
    xr += b + px(2)
  y += rowH + px(4)
  let flBar = cfgBool(config, "flBookmarksBar", true) and SendMessageW(hBookmarksBar, TB_BUTTONCOUNT, 0, 0) > 0
  show(hBookmarksBar, flBar)
  if flBar:
    let barH = int(HIWORD(SendMessageW(hBookmarksBar, TB_GETBUTTONSIZE, 0, 0))) + px(2)
    move(hBookmarksBar, m, y, w - 2 * m, barH)
    y += barH + px(2)
  for hc in [hFindEdit, hFindCount, hFindPrev, hFindNext, hFindClose]: show(hc, flFindShowing)
  if flFindShowing:
    let fw = int(px(260))
    var fx = w - m - fw - px(60) - 3 * b
    move(hFindEdit, fx, y, fw, rowH)
    fx += fw + px(4)
    move(hFindCount, fx, y + px(6), px(56), rowH - px(6))
    fx += px(60)
    for hc in [hFindPrev, hFindNext, hFindClose]:
      move(hc, fx, y, b, rowH)
      fx += b
    y += rowH + px(4)
  for hc in [hSearchEdit, hSearchGo, hSearchClose]: show(hc, flSearchShowing)
  if flSearchShowing:
    let sw = int(px(320))
    var sx = w - m - sw - px(80) - b
    move(hSearchEdit, sx, y, sw, rowH)
    sx += sw + px(4)
    move(hSearchGo, sx, y, px(76), rowH)
    move(hSearchClose, sx + px(80), y, b, rowH)
    y += rowH + px(4)
  let tab = currentTab()
  if tab != nil:
    move(tab.hEdit, 0, y, w, h - y - statusH)

# ---------------------------------------------------------------- commands

proc themeChosen(ix: int) =
  theme = allThemes[ix]
  prefs["nameStylesheet"] = %theme.name
  writePrefs(prefs)
  for t in tabs:
    discard SendMessageW(t.hEdit, EM_SETBKGNDCOLOR, 0, LPARAM(toColorRef(theme.bg)))
  let tab = currentTab()
  drawTab(tab, true)
  showCurrentTab()
  buildMenu()

proc popupMenu(m: HMENU, anchor: HWND) =
  var rc: RECT
  discard GetWindowRect(anchor, addr rc)
  discard TrackPopupMenu(m, TPM_RIGHTALIGN or TPM_TOPALIGN, rc.right, rc.bottom, 0, hwndMain, nil)
  discard DestroyMenu(m)

proc moreMenu() =
  ## the three-dots menu, Chrome's spot
  let m = CreatePopupMenu()
  addItem(m, cmdFind, "Find on page\tCtrl+F")
  addSeparator(m)
  addItem(m, cmdAddBookmark, "Add Bookmark...\tCtrl+D")
  addItem(m, cmdEditBookmarks, "Edit Bookmarks...")
  addSeparator(m)
  addItem(m, cmdViewSource, "View Markdown source\tCtrl+U")
  addSeparator(m)
  addItem(m, cmdOpenDataFolder, "Data folder")
  addItem(m, cmdAbout, "About BonBon")
  popupMenu(m, hMore)

proc command(id: int) =
  let tab = currentTab()
  case id
  of cmdNewTab, idNewTab: openNewTab()
  of cmdCloseTab: closeTab(ixCurrentTab)
  of cmdOpenDataFolder: openShell(dataFolder())
  of cmdExit: discard PostMessageW(hwndMain, WM_CLOSE, 0, 0)
  of cmdCopy, cmdContextCopy: discard SendMessageW(GetFocus(), WM_COPY, 0, 0)
  of cmdSelectAll, cmdContextSelectAll:
    let f = GetFocus()
    if f == hAddress or f == hFindEdit or f == hSearchEdit: discard SendMessageW(f, EM_SETSEL, 0, -1)
    else: setSel(tab.hEdit, 0, -1)
  of cmdFind: findCommand()
  of cmdFindNext, idFindNext:
    if flFindShowing: findInPage(true, true) else: findCommand()
  of cmdFindPrevious, idFindPrev:
    if flFindShowing: findInPage(true, false) else: findCommand()
  of idFindClose: closeFind()
  of cmdReload, idReload: reload()
  of cmdViewSource, cmdContextViewSource: viewSourceCommand()
  of cmdToggleSource, idSource: toggleSourceCommand()
  of cmdHome, idHome: goHome()
  of cmdBack, idBack: goBack()
  of cmdForward, idForward: goForward()
  of cmdAddBookmark: addBookmarkCommand()
  of cmdEditBookmarks: editBookmarksCommand()
  of cmdDocs: loadUrl(tab, urlDocs, false, false, true)
  of cmdSupport: loadUrl(tab, urlSupport, false, false, true)
  of cmdAbout:
    discard MessageBoxW(hwndMain, appName & " " & appVersion & " for Windows\n\nA browser for a web made of Markdown files.\n\n" &
      "Original app by Dave Winer, MIT license.\nNative Windows version written in Nim.\n\nData folder: " & dataFolder(),
      "About " & appName, MB_OK or MB_ICONINFORMATION)
  of cmdFocusAddress:
    SetFocus(hAddress)
    discard SendMessageW(hAddress, EM_SETSEL, 0, -1)
  of cmdNextTab: switchToTab((ixCurrentTab + 1) mod tabs.len)
  of cmdPrevTab: switchToTab((ixCurrentTab - 1 + tabs.len) mod tabs.len)
  of cmdSearchSite, idSearch:
    if getSearchUrl(tab).len > 0: showSearchBar(not flSearchShowing or GetFocus() != hSearchEdit)
  of idSearchGo:
    if searchSite(tab, getText(hSearchEdit)): showSearchBar(false)
  of idSearchClose: showSearchBar(false)
  of idStyles: popupMenu(themesMenu(), hStyles)
  of idMore: moreMenu()
  of idPrev, idNext:
    let u = pageArrowUrl(tab, id == idNext)
    if u.len > 0:
      if GetKeyState(VK_CONTROL) < 0: openUrlInNewTab(u, true, true) else: clickLink(tab, u, false)
  else:
    if id >= cmdThemeBase and id < cmdThemeBase + allThemes.len: themeChosen(id - cmdThemeBase)
    elif id >= cmdHistoryBase and id < cmdHistoryBase + recentPages.len:
      loadUrl(tab, recentPages[id - cmdHistoryBase].url) # a page from the History menu opens in this tab
    elif id >= cmdBookmarkBase and id < cmdBookmarkBase + menuUrls.len:
      loadUrl(tab, menuUrls[id - cmdBookmarkBase], false, false, true) # a bookmark is a link
    elif id >= cmdBarBase and id < cmdBarBase + barUrls.len:
      let u = barUrls[id - cmdBarBase]
      if GetKeyState(VK_CONTROL) < 0: openUrlInNewTab(u, true, true)
      else: loadUrl(tab, u, false, false, true)

var contextLink: string

proc contextMenu(tab: Tab, x, y: int32) =
  ## the right-click menu; with the link's commands when the click was on a link
  var pt = POINT(x: x, y: y)
  if x == -1 and y == -1:
    var rc: RECT
    discard GetWindowRect(tab.hEdit, addr rc)
    pt = POINT(x: rc.left + px(40), y: rc.top + px(40))
  var client = pt
  discard ScreenToClient(tab.hEdit, addr client)
  var ptl = POINTL(x: client.x, y: client.y)
  let cp = int32 SendMessageW(tab.hEdit, EM_CHARFROMPOS, 0, cast[LPARAM](addr ptl))
  contextLink = linkAt(tab, cp)
  let m = CreatePopupMenu()
  if contextLink.len > 0:
    addItem(m, cmdContextOpenNewTab, "Open Link in New Tab")
    addItem(m, cmdContextCopyLink, "Copy Link Address")
    addSeparator(m)
  let sel = getSel(tab.hEdit)
  addItem(m, cmdContextCopy, "Copy", if sel.cpMax > sel.cpMin: 0 else: MF_GRAYED)
  addItem(m, cmdContextSelectAll, "Select All")
  addSeparator(m)
  addItem(m, cmdContextViewSource, "View Page Source", if tab.hasSource: 0 else: MF_GRAYED)
  let id = TrackPopupMenu(m, TPM_RETURNCMD or TPM_RIGHTBUTTON, pt.x, pt.y, 0, hwndMain, nil)
  discard DestroyMenu(m)
  case id
  of cmdContextOpenNewTab: openUrlInNewTab(contextLink, true)
  of cmdContextCopyLink: setClipboardText(hwndMain, contextLink)
  of cmdContextCopy:
    SetFocus(tab.hEdit)
    discard SendMessageW(tab.hEdit, WM_COPY, 0, 0)
  of cmdContextSelectAll:
    SetFocus(tab.hEdit)
    setSel(tab.hEdit, 0, -1)
  of cmdContextViewSource: viewSourceCommand()
  else: discard

# ---------------------------------------------------------------- bon:// links and the one instance

proc openBonUrl(theUrl: string) =
  ## bon:// becomes http://, and the site redirects to https if it wants to
  var u = theUrl.strip
  if u.toLowerAscii.startsWith("bon://"): u = "http://" & u[6 .. ^1]
  elif u.toLowerAscii.startsWith("bon:"): u = "http://" & u[4 .. ^1]
  if not flStarted:
    urlsWaitingToOpen.add u
    return
  openUrlInNewTab(u, false)
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

proc mainProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM): LRESULT {.stdcall.} =
  case msg
  of WM_SIZE:
    layout()
    return 0
  of WM_GETMINMAXINFO:
    let mmi = cast[ptr MINMAXINFO](lParam)
    mmi.ptMinTrackSize = POINT(x: px(520), y: px(360))
    return 0
  of WM_DRAWITEM:
    let dis = cast[ptr DRAWITEMSTRUCT](lParam)
    if dis.CtlType == ODT_TAB:
      drawTabItem(dis)
      return 1
  of WM_COMMAND:
    let id = int(LOWORD(wParam))
    let code = HIWORD(wParam)
    if id == idAddress:
      if code == EN_CHANGE and GetFocus() == hAddress and not settingAddress: showTypeahead()
      return 0
    if id in [idFindEdit, idSearchEdit]:
      if id == idFindEdit and code == EN_CHANGE: findInPage(false, true)
      return 0
    command(id)
    return 0
  of WM_NOTIFY:
    let hdr = cast[ptr NMHDR](lParam)
    if hdr.hwndFrom == hTabs:
      if hdr.code == TCN_SELCHANGE:
        switchToTab(int(SendMessageW(hTabs, TCM_GETCURSEL, 0, 0)))
      return 0
    if hdr.code == TTN_GETDISPINFOW:
      let di = cast[ptr NMTTDISPINFOW](lParam)
      let tips = {idBack: "Back", idForward: "Forward", idReload: "Reload", idHome: "Home", idNewTab: "New tab",
        idSearch: "Search this site", idSource: "Show the Markdown source", idStyles: "Choose a stylesheet",
        idPrev: "Previous", idNext: "Next", idMore: "More", idFindPrev: "Previous", idFindNext: "Next",
        idFindClose: "Close", idSearchClose: "Close"}
      let id = int(GetDlgCtrlID(HWND(hdr.idFrom)))
      for (k, v) in tips:
        if k == id:
          var w {.global.}: wstring
          w = +$v
          di.lpszText = &w
      return 0
    return 0
  of WM_CONTEXTMENU:
    let tab = currentTab()
    if tab != nil and HWND(wParam) == tab.hEdit:
      contextMenu(tab, int32(cast[int16](LOWORD(lParam))), int32(cast[int16](HIWORD(lParam))))
      return 0
    if HWND(wParam) == hTabs:
      var pt: POINT
      discard GetCursorPos(addr pt)
      var hit: TCHITTESTINFO
      hit.pt = pt
      discard ScreenToClient(hTabs, addr hit.pt)
      let ix = int(SendMessageW(hTabs, TCM_HITTEST, 0, cast[LPARAM](addr hit)))
      if ix >= 0:
        let m = CreatePopupMenu()
        addItem(m, 1, "Reload")
        addItem(m, 2, "Close Tab")
        let id = TrackPopupMenu(m, TPM_RETURNCMD or TPM_RIGHTBUTTON, pt.x, pt.y, 0, hwndMain, nil)
        discard DestroyMenu(m)
        if id == 1 and tabs[ix].ixHistory >= 0: loadUrl(tabs[ix], tabs[ix].pageHistory[tabs[ix].ixHistory], true, true)
        elif id == 2: closeTab(ix)
      return 0
  of WM_TIMER:
    let t = int(wParam)
    if t == timerSaveTabs: writeTabsNow()
    elif t == timerHideTypeahead:
      discard KillTimer(hwnd, timerHideTypeahead)
      if GetFocus() != hAddress: hideTypeahead()
    elif t >= timerSocketBase:
      discard KillTimer(hwnd, UINT_PTR t)
      for tab in tabs:
        if tab.serial == t - timerSocketBase and tab.watchId == 0 and tab.kind == "" and tab.hasSource: watchForUpdates(tab)
    elif t >= timerLoadBase:
      discard KillTimer(hwnd, UINT_PTR t)
      for tab in tabs:
        if tab.load != nil and tab.load.serial == t - timerLoadBase: finishLoad(tab, tab.load)
    return 0
  of WM_JOBDONE:
    for r in drainResults():
      if r.kind in [jkSocketUpdate, jkSocketClosed]:
        socketMessage(r)
      elif r.id in callbacks:
        let cb = callbacks[r.id]
        callbacks.del r.id
        cb(r)
    return 0
  of WM_COPYDATA: # a bon:// link from a second launch
    let cds = cast[ptr COPYDATASTRUCT](lParam)
    if cds.dwData == 0xB0B0 and cds.cbData > 0:
      var s = newString(int cds.cbData)
      copyMem(addr s[0], cds.lpData, int cds.cbData)
      for u in s.split('\n'):
        if u.len > 0: openBonUrl(u)
    return 1
  of WM_ACTIVATE:
    if LOWORD(wParam) == WA_INACTIVE: hideTypeahead()
  of WM_MOVE:
    hideTypeahead()
  of WM_CLOSE:
    writeTabsNow()
    var placement: WINDOWPLACEMENT
    placement.length = UINT sizeof(placement)
    discard GetWindowPlacement(hwnd, addr placement)
    let r = placement.rcNormalPosition
    prefs["window"] = %*{"x": r.left, "y": r.top, "w": r.right - r.left, "h": r.bottom - r.top,
      "maximized": placement.showCmd == SW_SHOWMAXIMIZED}
    writePrefs(prefs)
    for t in tabs: stopWatchingTab(t)
    discard DestroyWindow(hwnd)
    return 0
  of WM_DESTROY:
    PostQuitMessage(0)
    return 0
  else: discard
  DefWindowProcW(hwnd, msg, wParam, lParam)

proc iconButton(glyph: string, id: int, style: DWORD = 0): HWND =
  result = control(hwndMain, "BUTTON", glyph, WS_TABSTOP or BS_PUSHBUTTON or style, id, fontIcons)

proc addTooltip(h: HWND) =
  var ti: TTTOOLINFOW
  ti.cbSize = UINT sizeof(ti)
  ti.uFlags = TTF_IDISHWND or TTF_SUBCLASS
  ti.hwnd = hwndMain
  ti.uId = cast[UINT_PTR](h)
  ti.lpszText = LPSTR_TEXTCALLBACKW
  discard SendMessageW(hTooltip, TTM_ADDTOOLW, 0, cast[LPARAM](addr ti))

proc createWindow() =
  var wc: WNDCLASSEXW
  wc.cbSize = UINT sizeof(wc)
  wc.lpfnWndProc = mainProc
  wc.hInstance = hInst
  wc.hCursor = LoadCursorW(0, IDC_ARROW)
  wc.hbrBackground = GetSysColorBrush(COLOR_BTNFACE)
  wc.lpszClassName = classMain
  wc.hIcon = iconApp
  wc.hIconSm = iconApp
  discard RegisterClassExW(addr wc)
  var sc = wc
  sc.lpfnWndProc = sourceProc
  sc.lpszClassName = classSource
  discard RegisterClassExW(addr sc)

  var x, y: int32 = CW_USEDEFAULT
  var w = px(cfgInt(config, "windowWidth", 1000))
  var h = px(cfgInt(config, "windowHeight", 800))
  var flMax = false
  let wp = prefs{"window"}
  if wp != nil and wp.kind == JObject:
    x = int32 wp{"x"}.getInt
    y = int32 wp{"y"}.getInt
    w = int32 wp{"w"}.getInt(w)
    h = int32 wp{"h"}.getInt(h)
    flMax = wp{"maximized"}.getBool
    var rc = RECT(left: x, top: y, right: x + w, bottom: y + h)
    if MonitorFromRect(addr rc, MONITOR_DEFAULTTONULL) == 0: # the monitor it was on is gone
      x = CW_USEDEFAULT
      y = CW_USEDEFAULT
  hwndMain = CreateWindowExW(0, classMain, appName, WS_OVERLAPPEDWINDOW or WS_CLIPCHILDREN,
    x, y, w, h, 0, 0, hInst, nil)

  hTooltip = CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, nil, WS_POPUP or TTS_ALWAYSTIP,
    0, 0, 0, 0, hwndMain, 0, hInst, nil)
  hTabs = control(hwndMain, WC_TABCONTROLW, "", TCS_FOCUSNEVER or TCS_SINGLELINE or TCS_FIXEDWIDTH or TCS_OWNERDRAWFIXED or WS_CLIPSIBLINGS, idTabs, fontUi)
  hImages = ImageList_Create(px(16), px(16), ILC_COLOR32 or ILC_MASK, 8, 8)
  discard SendMessageW(hTabs, TCM_SETIMAGELIST, 0, cast[LPARAM](hImages))
  discard SendMessageW(hTabs, TCM_SETITEMSIZE, 0, MAKELPARAM(WORD px(200), WORD px(26)))
  discard SendMessageW(hTabs, TCM_SETPADDING, 0, MAKELPARAM(WORD px(8), WORD px(4)))
  hNewTab = iconButton("", idNewTab)
  hBack = iconButton("", idBack)
  hForward = iconButton("", idForward)
  hReload = iconButton("", idReload)
  hHome = iconButton("", idHome)
  hAddress = control(hwndMain, "EDIT", "", WS_BORDER or WS_TABSTOP or ES_AUTOHSCROLL, idAddress, fontAddress, WS_EX_CLIENTEDGE)
  discard SendMessageW(hAddress, EM_SETCUEBANNER, 1, cast[LPARAM](&(+$"Enter the URL of a Markdown page")))
  discard SendMessageW(hAddress, EM_SETMARGINS, EC_LEFTMARGIN or EC_RIGHTMARGIN, MAKELPARAM(WORD px(6), WORD px(6)))
  hSearch = iconButton("", idSearch)
  hSource = control(hwndMain, "BUTTON", "M↓", WS_TABSTOP or BS_AUTOCHECKBOX or BS_PUSHLIKE, idSource, fontUi)
  hStyles = iconButton("", idStyles)
  hPrev = iconButton("", idPrev)
  hNext = iconButton("", idNext)
  hMore = iconButton("", idMore)
  hBookmarksBar = CreateWindowExW(0, TOOLBARCLASSNAMEW, nil, WS_CHILD or WS_VISIBLE or TBSTYLE_FLAT or TBSTYLE_LIST or
    TBSTYLE_TOOLTIPS or CCS_NORESIZE or CCS_NODIVIDER or CCS_NOPARENTALIGN, 0, 0, 0, 0, hwndMain, HMENU idBookmarksBar, hInst, nil)
  discard SendMessageW(hBookmarksBar, TB_BUTTONSTRUCTSIZE, WPARAM sizeof(TBBUTTON), 0)
  discard SendMessageW(hBookmarksBar, WM_SETFONT, WPARAM fontUi, TRUE)
  discard SendMessageW(hBookmarksBar, TB_SETEXTENDEDSTYLE, 0, TBSTYLE_EX_MIXEDBUTTONS)
  hBarImages = ImageList_Create(px(16), px(16), ILC_COLOR32 or ILC_MASK, 8, 8)
  discard SendMessageW(hBookmarksBar, TB_SETIMAGELIST, 0, cast[LPARAM](hBarImages))
  hFindEdit = control(hwndMain, "EDIT", "", WS_BORDER or WS_TABSTOP or ES_AUTOHSCROLL, idFindEdit, fontUi, WS_EX_CLIENTEDGE)
  discard SendMessageW(hFindEdit, EM_SETCUEBANNER, 1, cast[LPARAM](&(+$"Find in page")))
  hFindCount = control(hwndMain, "STATIC", "", SS_CENTER, idFindCount, fontUi)
  hFindPrev = iconButton("", idFindPrev)
  hFindNext = iconButton("", idFindNext)
  hFindClose = iconButton("", idFindClose)
  hSearchEdit = control(hwndMain, "EDIT", "", WS_BORDER or WS_TABSTOP or ES_AUTOHSCROLL, idSearchEdit, fontUi, WS_EX_CLIENTEDGE)
  discard SendMessageW(hSearchEdit, EM_SETCUEBANNER, 1, cast[LPARAM](&(+$"Search this site")))
  hSearchGo = control(hwndMain, "BUTTON", "Search", WS_TABSTOP or BS_PUSHBUTTON, idSearchGo, fontUi)
  hSearchClose = iconButton("", idSearchClose)
  hStatus = CreateWindowExW(0, STATUSCLASSNAMEW, nil, WS_CHILD or WS_VISIBLE or SBARS_SIZEGRIP, 0, 0, 0, 0,
    hwndMain, HMENU idStatus, hInst, nil)
  discard SendMessageW(hStatus, WM_SETFONT, WPARAM fontUi, TRUE)
  hTypeahead = CreateWindowExW(WS_EX_TOOLWINDOW or WS_EX_NOACTIVATE or WS_EX_TOPMOST, "LISTBOX", nil,
    WS_POPUP or WS_BORDER or LBS_NOTIFY or LBS_NOINTEGRALHEIGHT, 0, 0, 0, 0, hwndMain, 0, hInst, nil)
  discard SendMessageW(hTypeahead, WM_SETFONT, WPARAM fontUi, TRUE)
  for hb in [hNewTab, hBack, hForward, hReload, hHome, hSearch, hSource, hStyles, hPrev, hNext, hMore,
             hFindPrev, hFindNext, hFindClose, hSearchClose]: addTooltip(hb)
  discard SetWindowSubclass(hAddress, addressProc, 1, 0)
  discard SetWindowSubclass(hTypeahead, typeaheadProc, 2, 0)
  discard SetWindowSubclass(hFindEdit, barEditProc, 3, 0)
  discard SetWindowSubclass(hSearchEdit, barEditProc, 4, 0)
  show(hPrev, false)
  show(hNext, false)
  discard SendMessageW(hStatus, SB_SETTEXTW, 1, cast[LPARAM](&(+$("v" & appVersion))))
  discard ShowWindow(hwndMain, if flMax: SW_SHOWMAXIMIZED else: SW_SHOWNORMAL)

proc restoreTabs() =
  ## the tabs from the last run; each one fetches its page again
  let (ixSaved, saved) = readTabs()
  if saved.len == 0 and ixSaved == -1:
    # a fresh install: the first tab opens the home page
    tabs = @[newTab()]
    ixCurrentTab = 0
    showCurrentTab()
    goHome()
    return
  for s in saved:
    let t = newTab()
    t.pageHistory = s.pageHistory
    t.ixHistory = s.ixHistory
    tabs.add t
  if tabs.len == 0: tabs.add newTab()
  ixCurrentTab = min(max(ixSaved, 0), tabs.high)
  showCurrentTab()
  for t in tabs:
    if t.ixHistory >= 0: loadUrl(t, t.pageHistory[t.ixHistory], true)

proc main() =
  hInst = GetModuleHandleW(nil)
  let urls = argUrls()
  # one BonBon at a time: a second launch hands its bon:// links to the first
  discard CreateMutexW(nil, FALSE, "BonBonForWindowsSingleInstance")
  if GetLastError() == ERROR_ALREADY_EXISTS:
    let other = FindWindowW(classMain, nil)
    if other != 0:
      var s = urls.join("\n")
      var cds = COPYDATASTRUCT(dwData: 0xB0B0, cbData: DWORD s.len, lpData: if s.len > 0: addr s[0] else: nil)
      discard SendMessageW(other, WM_COPYDATA, 0, cast[LPARAM](addr cds))
      discard ShowWindow(other, SW_RESTORE)
      discard SetForegroundWindow(other)
      return
  initDpi()
  var icc = TINITCOMMONCONTROLSEX(dwSize: DWORD sizeof(TINITCOMMONCONTROLSEX),
    dwICC: ICC_TAB_CLASSES or ICC_BAR_CLASSES or ICC_TREEVIEW_CLASSES or ICC_STANDARD_CLASSES or ICC_WIN95_CLASSES)
  discard InitCommonControlsEx(addr icc)
  discard LoadLibraryW("Msftedit.dll")
  initImages()
  config = readConfig()
  prefs = readPrefs()
  theme = getTheme(if prefs{"nameStylesheet"}.getStr.len > 0: prefs{"nameStylesheet"}.getStr
                   else: cfgStr(config, "nameDefaultStylesheet", nameDefaultTheme))
  reqOptions.maxRedirects = cfgInt(config, "maxRedirects", 10)
  reqOptions.userAgent = "Markdown Browser/" & appVersion
  seedHandlers()
  recentPages = readHistory()
  urlHistory = readUrlHistory()
  registerBonProtocol()
  fontUi = uiFont()
  fontIcons = makeFont("Segoe MDL2 Assets", 10)
  fontAddress = makeFont("Segoe UI", 11)
  iconPage = stockIcon(SIID_DOCNOASSOC)
  iconGlobe = stockIcon(SIID_WORLD)
  iconApp = LoadIconW(hInst, MAKEINTRESOURCEW(1))
  createWindow()
  startWorkers(hwndMain)
  buildAccelerators()
  startBookmarks()
  restoreTabs()
  flStarted = true
  for u in urls: openBonUrl(u)
  for u in urlsWaitingToOpen: openUrlInNewTab(u, false)
  urlsWaitingToOpen.setLen 0
  var msg: MSG
  while GetMessageW(addr msg, 0, 0, 0) > 0:
    if TranslateAcceleratorW(hwndMain, hAccel, addr msg) != 0: continue
    discard TranslateMessage(addr msg)
    discard DispatchMessageW(addr msg)

main()
