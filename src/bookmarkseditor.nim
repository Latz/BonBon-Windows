## bookmarkseditor.nim -- Edit Bookmarks..., the native stand-in for the
## outliner dialog of Dave's bookmarks menu: the outline in a tree, where
## bookmarks and folders can be renamed, given addresses, moved, indented,
## outdented and deleted. Save hands the outline back.

import winim/lean, winim/inc/commctrl
import opml, winutil, datafolder

const
  idTree = 10
  idNewBookmark = 11
  idNewFolder = 12
  idDelete = 13
  idUp = 14
  idDown = 15
  idIndent = 16
  idOutdent = 17
  idTitle = 18
  idUrl = 19
  idSave = 20
  idCancel = 21

type Editor = object
  dlg, tree, editTitle, editUrl: HWND
  outline: Outline
  items: seq[(HTREEITEM, OutlineNode)]
  selected: OutlineNode
  filling: bool
  onSave: proc (o: Outline)
  saved: bool

var ed: Editor
var font: HFONT

proc nodeOf(h: HTREEITEM): OutlineNode =
  for (k, n) in ed.items:
    if k == h: return n

proc itemOf(n: OutlineNode): HTREEITEM =
  for (k, x) in ed.items:
    if x == n: return k

proc labelOf(n: OutlineNode): string =
  result = n.att("text")
  if result.len == 0: result = n.att("url")
  if result.len == 0: result = "(untitled)"

proc findParent(root, n: OutlineNode): (OutlineNode, int) =
  for i, c in root.subs:
    if c == n: return (root, i)
    let r = findParent(c, n)
    if r[0] != nil: return r
  (nil, -1)

proc insertItems(parent: HTREEITEM, n: OutlineNode) =
  for c in n.subs:
    var label = +$labelOf(c)
    var ins: TVINSERTSTRUCTW
    ins.hParent = parent
    ins.hInsertAfter = TVI_LAST
    ins.union1.item.mask = TVIF_TEXT
    ins.union1.item.pszText = &label
    let h = HTREEITEM(SendMessageW(ed.tree, TVM_INSERTITEMW, 0, cast[LPARAM](addr ins)))
    ed.items.add (h, c)
    insertItems(h, c)
    discard SendMessageW(ed.tree, TVM_EXPAND, TVE_EXPAND, cast[LPARAM](h))

proc fillFields() =
  ed.filling = true
  let n = ed.selected
  setText(ed.editTitle, if n == nil: "" else: n.att("text"))
  setText(ed.editUrl, if n == nil: "" else: n.att("url"))
  enable(ed.editTitle, n != nil)
  enable(ed.editUrl, n != nil and n.subs.len == 0)
  ed.filling = false

proc rebuild(select: OutlineNode) =
  discard SendMessageW(ed.tree, WM_SETREDRAW, FALSE, 0)
  ed.items.setLen 0
  discard SendMessageW(ed.tree, TVM_DELETEITEM, 0, cast[LPARAM](TVI_ROOT))
  insertItems(TVI_ROOT, ed.outline.body)
  discard SendMessageW(ed.tree, WM_SETREDRAW, TRUE, 0)
  ed.selected = select
  let h = itemOf(select)
  if h != 0: discard SendMessageW(ed.tree, TVM_SELECTITEM, TVGN_CARET, cast[LPARAM](h))
  fillFields()

proc setItemLabel(n: OutlineNode) =
  let h = itemOf(n)
  if h == 0: return
  var label = +$labelOf(n)
  var item: TVITEMW
  item.mask = TVIF_TEXT
  item.hItem = h
  item.pszText = &label
  discard SendMessageW(ed.tree, TVM_SETITEMW, 0, cast[LPARAM](addr item))

proc insertNew(n: OutlineNode) =
  ## after the selected line, at its level; at the end when nothing's selected
  if ed.selected == nil:
    ed.outline.body.subs.add n
  else:
    let (parent, ix) = findParent(ed.outline.body, ed.selected)
    if ed.selected.subs.len > 0 or (ed.selected.att("url").len == 0 and ed.selected.att("type") != "bookmark"):
      ed.selected.subs.add n # a folder: into it
    else:
      parent.subs.insert(n, ix + 1)
  rebuild(n)
  SetFocus(ed.editTitle)
  discard SendMessageW(ed.editTitle, EM_SETSEL, 0, -1)

proc command(id: int) =
  let n = ed.selected
  case id
  of idNewBookmark: insertNew(newBookmark("New bookmark", "https://"))
  of idNewFolder: insertNew(newOutlineNode({"text": "New folder", "created": nowUtcString()}))
  of idDelete:
    if n == nil: return
    let (parent, ix) = findParent(ed.outline.body, n)
    if parent == nil: return
    if n.subs.len > 0 and MessageBoxW(ed.dlg, "Delete \"" & labelOf(n) & "\" and everything in it?", "BonBon",
        MB_YESNO or MB_ICONQUESTION) != IDYES: return
    parent.subs.delete ix
    rebuild(if parent.subs.len == 0: (if parent == ed.outline.body: nil else: parent)
            else: parent.subs[min(ix, parent.subs.high)])
  of idUp, idDown:
    if n == nil: return
    let (parent, ix) = findParent(ed.outline.body, n)
    let ixTo = if id == idUp: ix - 1 else: ix + 1
    if parent == nil or ixTo < 0 or ixTo > parent.subs.high: return
    swap(parent.subs[ix], parent.subs[ixTo])
    rebuild(n)
  of idIndent: # under the line above it
    if n == nil: return
    let (parent, ix) = findParent(ed.outline.body, n)
    if parent == nil or ix == 0: return
    parent.subs.delete ix
    parent.subs[ix - 1].subs.add n
    rebuild(n)
  of idOutdent: # after its parent, one level up
    if n == nil: return
    let (parent, ix) = findParent(ed.outline.body, n)
    if parent == nil or parent == ed.outline.body: return
    let (grand, ixParent) = findParent(ed.outline.body, parent)
    parent.subs.delete ix
    grand.subs.insert(n, ixParent + 1)
    rebuild(n)
  of idSave:
    ed.outline.setHead("dateModified", nowUtcString())
    ed.saved = true
    let cb = ed.onSave
    let o = ed.outline
    discard DestroyWindow(ed.dlg)
    cb(o)
  of idCancel: discard DestroyWindow(ed.dlg)
  else: discard

proc layout() =
  var rc: RECT
  discard GetClientRect(ed.dlg, addr rc)
  let w = int(rc.right)
  let h = int(rc.bottom)
  let m = px(10)
  let bw = px(130)
  let bh = px(28)
  let rowH = px(26)
  let treeW = w - 3 * m - bw
  let fieldsTop = h - m - bh - m - 2 * (rowH + px(6))
  move(ed.tree, m, m, treeW, fieldsTop - 2 * m)
  var y = m
  for id in [idNewBookmark, idNewFolder, idDelete, -1, idUp, idDown, idIndent, idOutdent]:
    if id == -1:
      y += px(12)
      continue
    move(GetDlgItem(ed.dlg, int32 id), w - m - bw, y, bw, bh)
    y += bh + px(6)
  let labelW = px(50)
  move(GetDlgItem(ed.dlg, 101), m, fieldsTop + px(4), labelW, rowH)
  move(ed.editTitle, m + labelW, fieldsTop, w - 2 * m - labelW, rowH)
  move(GetDlgItem(ed.dlg, 102), m, fieldsTop + rowH + px(10), labelW, rowH)
  move(ed.editUrl, m + labelW, fieldsTop + rowH + px(6), w - 2 * m - labelW, rowH)
  move(GetDlgItem(ed.dlg, idCancel), w - m - px(100), h - m - bh, px(100), bh)
  move(GetDlgItem(ed.dlg, idSave), w - 2 * m - px(200), h - m - bh, px(100), bh)

proc dlgProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM): LRESULT {.stdcall.} =
  case msg
  of WM_SIZE:
    if ed.tree != 0: layout()
    return 0
  of WM_GETMINMAXINFO:
    let mmi = cast[ptr MINMAXINFO](lParam)
    mmi.ptMinTrackSize = POINT(x: px(480), y: px(380))
    return 0
  of WM_COMMAND:
    let id = int(LOWORD(wParam))
    let code = HIWORD(wParam)
    if (id == idTitle or id == idUrl) and code == EN_CHANGE and not ed.filling and ed.selected != nil:
      if id == idTitle: ed.selected.setAtt("text", getText(ed.editTitle))
      else:
        ed.selected.setAtt("url", getText(ed.editUrl))
        if ed.selected.att("type").len == 0: ed.selected.setAtt("type", "bookmark")
      setItemLabel(ed.selected)
    elif code == BN_CLICKED or id in [IDOK, IDCANCEL]:
      command(if id == IDCANCEL: idCancel elif id == IDOK: idSave else: id)
    return 0
  of WM_NOTIFY:
    let hdr = cast[ptr NMHDR](lParam)
    if hdr.idFrom == idTree:
      if hdr.code == TVN_SELCHANGEDW:
        let nm = cast[ptr NMTREEVIEWW](lParam)
        ed.selected = nodeOf(nm.itemNew.hItem)
        fillFields()
      elif hdr.code == TVN_BEGINLABELEDITW:
        return 0
      elif hdr.code == TVN_ENDLABELEDITW:
        let di = cast[ptr NMTVDISPINFOW](lParam)
        if di.item.pszText != nil:
          let n = nodeOf(di.item.hItem)
          if n != nil:
            n.setAtt("text", $cast[WideCString](di.item.pszText))
            if n == ed.selected: fillFields()
            return 1
        return 0
    return 0
  of WM_CLOSE:
    discard DestroyWindow(hwnd)
    return 0
  else: discard
  DefWindowProcW(hwnd, msg, wParam, lParam)

proc editBookmarks*(owner: HWND, outline: Outline, select: OutlineNode, onSave: proc (o: Outline)) =
  ## modal: the owner waits until Save or Cancel
  var wc: WNDCLASSEXW
  wc.cbSize = UINT sizeof(wc)
  wc.lpfnWndProc = dlgProc
  wc.hInstance = GetModuleHandleW(nil)
  wc.hCursor = LoadCursorW(0, IDC_ARROW)
  wc.hbrBackground = GetSysColorBrush(COLOR_BTNFACE)
  wc.lpszClassName = "BonBonBookmarksEditor"
  wc.hIcon = LoadIconW(wc.hInstance, MAKEINTRESOURCEW(1))
  discard RegisterClassExW(addr wc)
  if font == 0: font = uiFont()
  ed = Editor(outline: Outline(head: outline.head, body: copyNode(outline.body)), onSave: onSave)
  var selectCopy: OutlineNode = nil
  if select != nil: # the same place in the copy
    proc path(root, n: OutlineNode, acc: var seq[int]): bool =
      for i, c in root.subs:
        acc.add i
        if c == n or path(c, n, acc): return true
        discard acc.pop()
    var p: seq[int]
    if path(outline.body, select, p):
      selectCopy = ed.outline.body
      for i in p: selectCopy = selectCopy.subs[i]
  var rcOwner: RECT
  discard GetWindowRect(owner, addr rcOwner)
  let w = px(640)
  let h = px(520)
  ed.dlg = CreateWindowExW(WS_EX_DLGMODALFRAME, "BonBonBookmarksEditor", "Edit Bookmarks",
    WS_POPUP or WS_CAPTION or WS_SYSMENU or WS_THICKFRAME or WS_CLIPCHILDREN,
    rcOwner.left + (rcOwner.right - rcOwner.left - w) div 2, rcOwner.top + px(60), w, h,
    owner, 0, wc.hInstance, nil)
  ed.tree = control(ed.dlg, WC_TREEVIEWW, "", WS_BORDER or WS_TABSTOP or TVS_HASLINES or TVS_LINESATROOT or
    TVS_HASBUTTONS or TVS_EDITLABELS or TVS_SHOWSELALWAYS, idTree, font)
  for (id, label) in [(idNewBookmark, "New Bookmark"), (idNewFolder, "New Folder"), (idDelete, "Delete"),
                      (idUp, "Move Up"), (idDown, "Move Down"), (idIndent, "Indent →"), (idOutdent, "← Outdent")]:
    discard control(ed.dlg, "BUTTON", label, WS_TABSTOP or BS_PUSHBUTTON, id, font)
  discard control(ed.dlg, "STATIC", "Title:", 0, 101, font)
  ed.editTitle = control(ed.dlg, "EDIT", "", WS_BORDER or WS_TABSTOP or ES_AUTOHSCROLL, idTitle, font)
  discard control(ed.dlg, "STATIC", "URL:", 0, 102, font)
  ed.editUrl = control(ed.dlg, "EDIT", "", WS_BORDER or WS_TABSTOP or ES_AUTOHSCROLL, idUrl, font)
  discard control(ed.dlg, "BUTTON", "Save", WS_TABSTOP or BS_DEFPUSHBUTTON, idSave, font)
  discard control(ed.dlg, "BUTTON", "Cancel", WS_TABSTOP or BS_PUSHBUTTON, idCancel, font)
  layout()
  rebuild(selectCopy)
  discard EnableWindow(owner, FALSE)
  discard ShowWindow(ed.dlg, SW_SHOW)
  SetFocus(ed.tree)
  var msg: MSG
  while IsWindow(ed.dlg) != 0 and GetMessageW(addr msg, 0, 0, 0) > 0:
    if msg.message == WM_KEYDOWN and msg.wParam == VK_ESCAPE and
        SendMessageW(ed.tree, TVM_GETEDITCONTROL, 0, 0) == 0:
      discard DestroyWindow(ed.dlg)
      continue
    if IsDialogMessageW(ed.dlg, addr msg) == 0:
      discard TranslateMessage(addr msg)
      discard DispatchMessageW(addr msg)
  discard EnableWindow(owner, TRUE)
  discard SetForegroundWindow(owner)
  if msg.message == WM_QUIT: PostQuitMessage(int32 msg.wParam)
