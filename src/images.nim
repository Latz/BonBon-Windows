## images.nim -- pictures through GDI+: a page's images become PNG or JPEG
## bytes RichEdit can hold, a site's icon becomes a 16x16 HICON.

import winim/lean, winim/inc/[gdiplus, objbase]
import rtf

const maxImagePx = 1400   ## wider pictures are scaled down before they go in the page

var gdipToken: ULONG_PTR

proc initImages*() =
  var input = GdiplusStartupInput(GdiplusVersion: 1)
  discard GdiplusStartup(addr gdipToken, addr input, nil)

proc streamOf(bytes: string): ptr IStream =
  let h = GlobalAlloc(GMEM_MOVEABLE, SIZE_T(max(bytes.len, 1)))
  if h == 0: return nil
  let p = GlobalLock(h)
  if bytes.len > 0: copyMem(p, unsafeAddr bytes[0], bytes.len)
  discard GlobalUnlock(h)
  if CreateStreamOnHGlobal(h, TRUE, addr result) != S_OK:
    discard GlobalFree(h)
    result = nil

proc bytesOf(stm: ptr IStream): string =
  var h: HGLOBAL
  if GetHGlobalFromStream(stm, addr h) != S_OK: return ""
  var pos: ULARGE_INTEGER
  var zero: LARGE_INTEGER
  discard stm.Seek(zero, STREAM_SEEK_CUR, addr pos)
  let n = int(pos.QuadPart)
  let p = GlobalLock(h)
  result = newString(n)
  if n > 0: copyMem(addr result[0], p, n)
  discard GlobalUnlock(h)

proc loadBitmap(bytes: string): ptr GpBitmap =
  let stm = streamOf(bytes)
  if stm == nil: return nil
  if GdipCreateBitmapFromStream(stm, addr result) != Ok: result = nil
  discard stm.Release()

proc sizeOf(bmp: ptr GpBitmap): (int, int) =
  var w, h: UINT
  discard GdipGetImageWidth(cast[ptr GpImage](bmp), addr w)
  discard GdipGetImageHeight(cast[ptr GpImage](bmp), addr h)
  (int(w), int(h))

proc scaled(bmp: ptr GpBitmap, w, h: int): ptr GpBitmap =
  if GdipCreateBitmapFromScan0(INT w, INT h, 0, pixelFormat32bppARGB, nil, addr result) != Ok: return nil
  var g: ptr GpGraphics
  if GdipGetImageGraphicsContext(cast[ptr GpImage](result), addr g) == Ok:
    discard GdipSetInterpolationMode(g, interpolationModeHighQualityBicubic)
    discard GdipDrawImageRectI(g, cast[ptr GpImage](bmp), 0, 0, INT w, INT h)
    discard GdipDeleteGraphics(g)

proc encode(bmp: ptr GpBitmap, png: bool): string =
  var clsid = if png: DEFINE_GUID("557CF406-1A04-11D3-9A73-0000F81EF32E")
              else: DEFINE_GUID("557CF401-1A04-11D3-9A73-0000F81EF32E")
  var stm: ptr IStream
  if CreateStreamOnHGlobal(0, TRUE, addr stm) != S_OK: return ""
  if GdipSaveImageToStream(cast[ptr GpImage](bmp), stm, addr clsid, nil) == Ok:
    result = bytesOf(stm)
  discard stm.Release()

proc decodeForPage*(bytes: string): (bool, RtfImage) =
  ## a picture's bytes, as RichEdit can draw them: PNG and JPEG go in as they
  ## came, anything else GDI+ reads (GIF, BMP, ICO, TIFF) becomes PNG
  if bytes.len < 8: return
  let bmp = loadBitmap(bytes)
  if bmp == nil: return
  defer: discard GdipDisposeImage(cast[ptr GpImage](bmp))
  let (w, h) = sizeOf(bmp)
  if w <= 0 or h <= 0: return
  let isPng = bytes[0] == '\x89' and bytes[1 .. 3] == "PNG"
  let isJpeg = bytes[0] == '\xFF' and bytes[1] == '\xD8'
  if w > maxImagePx:
    let h2 = max(1, h * maxImagePx div w)
    let small = scaled(bmp, maxImagePx, h2)
    if small == nil: return
    defer: discard GdipDisposeImage(cast[ptr GpImage](small))
    let data = encode(small, not isJpeg)
    if data.len == 0: return
    return (true, RtfImage(blip: if isJpeg: "jpegblip" else: "pngblip", data: data, w: maxImagePx, h: h2))
  if isPng: return (true, RtfImage(blip: "pngblip", data: bytes, w: w, h: h))
  if isJpeg: return (true, RtfImage(blip: "jpegblip", data: bytes, w: w, h: h))
  let data = encode(bmp, true)
  if data.len > 0: result = (true, RtfImage(blip: "pngblip", data: data, w: w, h: h))

proc iconFromBytes*(bytes: string, size = 16): HICON =
  ## a site's icon, at the size the tab strip draws; 0 when GDI+ can't read it
  if bytes.len < 8: return 0
  let bmp = loadBitmap(bytes)
  if bmp == nil: return 0
  defer: discard GdipDisposeImage(cast[ptr GpImage](bmp))
  let small = scaled(bmp, size, size)
  if small == nil: return 0
  defer: discard GdipDisposeImage(cast[ptr GpImage](small))
  discard GdipCreateHICONFromBitmap(small, addr result)
