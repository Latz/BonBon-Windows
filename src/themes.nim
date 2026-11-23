## themes.nim -- the five stylesheets that ship with BonBon (basic, book,
## classic, mono, newsprint), as values a native renderer can use. The CSS
## files can't be applied without a browser engine; their tokens are here.
## Web fonts (woff2) can't be loaded by GDI, so each names system fonts.

type
  Color* = tuple[r, g, b: int]
  Theme* = object
    name*, title*: string
    bg*, fg*, muted*, rule*, surface*, link*, accent*: Color
    fontBody*, fontHead*, fontCode*: string
    bodyPx*: float          ## body font size in CSS pixels
    lineHeight*: float
    maxWidthPx*: int        ## the reading column
    h1Scale*, h2Scale*, h3Scale*: float
    h1Bold*, h2Bold*: bool
    h2Muted*, h2Upper*: bool

proc hex(s: string): Color =
  proc h(i: int): int =
    for c in s[i .. i + 1]:
      result = result * 16 + (if c in '0'..'9': ord(c) - ord('0') else: (ord(c) or 0x20) - ord('a') + 10)
  (h(1), h(3), h(5))

let allThemes*: seq[Theme] = @[
  Theme(name: "basic", title: "Basic", bg: hex"#ffffff", fg: hex"#1f2328", muted: hex"#656d76",
    rule: hex"#e6e8eb", surface: hex"#f6f7f9", link: hex"#0b63ce", accent: hex"#0b63ce",
    fontBody: "Segoe UI", fontHead: "Segoe UI", fontCode: "Consolas",
    bodyPx: 17, lineHeight: 1.7, maxWidthPx: 704, h1Scale: 2.0 * 16 / 17, h2Scale: 0.95 * 16 / 17,
    h3Scale: 1.35 * 16 / 17, h1Bold: true, h2Bold: true, h2Muted: true),
  Theme(name: "book", title: "Book", bg: hex"#fdfcf9", fg: hex"#2a2520", muted: hex"#857b6e",
    rule: hex"#e3ddd1", surface: hex"#f3f1ec", link: hex"#3b4f8a", accent: hex"#8b3a2f",
    fontBody: "Garamond", fontHead: "Garamond", fontCode: "Consolas",
    bodyPx: 21, lineHeight: 1.55, maxWidthPx: 576, h1Scale: 2.6 * 16 / 21, h2Scale: 0.85 * 16 / 21,
    h3Scale: 1.3, h1Bold: false, h2Bold: false, h2Muted: true, h2Upper: true),
  Theme(name: "classic", title: "Classic", bg: hex"#ffffff", fg: hex"#000000", muted: hex"#808080",
    rule: hex"#e0e0e0", surface: hex"#f5f5f5", link: hex"#0000ee", accent: hex"#cc0000",
    fontBody: "Georgia", fontHead: "Arial", fontCode: "Courier New",
    bodyPx: 17, lineHeight: 1.5, maxWidthPx: 640, h1Scale: 2.2 * 16 / 17, h2Scale: 1.05 * 16 / 17,
    h3Scale: 1.25, h1Bold: true, h2Bold: true, h2Muted: true),
  Theme(name: "mono", title: "Mono", bg: hex"#fbfbf8", fg: hex"#23241f", muted: hex"#7a7b72",
    rule: hex"#dcdcd4", surface: hex"#efefea", link: hex"#0f6b50", accent: hex"#c2410c",
    fontBody: "Consolas", fontHead: "Consolas", fontCode: "Consolas",
    bodyPx: 15, lineHeight: 1.65, maxWidthPx: 608, h1Scale: 1.5 * 16 / 15, h2Scale: 1.0 * 16 / 15,
    h3Scale: 1.1, h1Bold: true, h2Bold: true),
  Theme(name: "newsprint", title: "Newsprint", bg: hex"#f8f5ee", fg: hex"#1e1b16", muted: hex"#6f685c",
    rule: hex"#d9d2c3", surface: hex"#efe9dd", link: hex"#1a4d8f", accent: hex"#a4231e",
    fontBody: "Georgia", fontHead: "Franklin Gothic Medium", fontCode: "Consolas",
    bodyPx: 18, lineHeight: 1.6, maxWidthPx: 672, h1Scale: 2.4 * 16 / 18, h2Scale: 0.8 * 16 / 18,
    h3Scale: 1.3, h1Bold: true, h2Bold: true, h2Muted: true, h2Upper: true)]

const nameDefaultTheme* = "basic"

proc getTheme*(name: string): Theme =
  for t in allThemes:
    if t.name == name: return t
  for t in allThemes:
    if t.name == nameDefaultTheme: return t
  allThemes[0]

proc toColorRef*(c: Color): int32 = int32(c.r or (c.g shl 8) or (c.b shl 16))
