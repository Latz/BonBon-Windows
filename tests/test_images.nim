import std/[unittest, strutils]
import images, rtf

initImages()

# a 1x1 GIF, the smallest one there is
const gif1x1 = "GIF89a\x01\x00\x01\x00\x80\x00\x00\xff\x00\x00\x00\x00\x00!\xf9\x04\x00\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;"

suite "pictures for the page":
  test "a PNG goes in as it came":
    let png = solidPng((1, 2, 3), 7, 5)
    let (ok, img) = decodeForPage(png)
    check ok and img.blip == "pngblip" and img.w == 7 and img.h == 5 and img.data == png
  test "a GIF becomes a PNG":
    let (ok, img) = decodeForPage(gif1x1)
    check ok and img.blip == "pngblip" and img.w == 1 and img.h == 1
    check img.data.startsWith("\x89PNG")
  test "a picture wider than 1400 is scaled down, keeping its shape":
    let (ok, img) = decodeForPage(solidPng((9, 9, 9), 2800, 2))
    check ok and img.w == 1400 and img.h == 1 and img.data.startsWith("\x89PNG")
  test "what isn't a picture":
    check not decodeForPage("")[0]
    check not decodeForPage("hello, not a picture at all")[0]

suite "site icons":
  test "an icon from a PNG or GIF":
    check iconFromBytes(solidPng((0, 0, 255), 32, 32)) != 0
    check iconFromBytes(gif1x1) != 0
  test "none from nothing":
    check iconFromBytes("") == 0
    check iconFromBytes("<svg xmlns=...></svg>") == 0
