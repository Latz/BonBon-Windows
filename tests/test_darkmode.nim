import std/[unittest, osproc, strutils]
import darkmode

suite "dark mode":
  test "dark when Windows is set to dark apps, as WebView2 is":
    discard darkmode.update()
    let (output, code) = execCmdEx("reg query HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize /v AppsUseLightTheme")
    let darkByRegistry = code == 0 and output.contains("0x0") and not output.contains("0x1")
    check isDark() == darkByRegistry
  test "a second look at an unchanged setting is no change":
    check not darkmode.update()
  test "the background behind a page: white in light mode, the bar's color in dark":
    check webViewBackground() == (if isDark(): 0x242120FF'u32 else: 0xFFFFFFFF'u32)
