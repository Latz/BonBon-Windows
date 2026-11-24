import std/[unittest, os, strutils]
import embedded, webview2

suite "the app's files, inside the exe":
  let base = getTempDir() / "bonbon_test_embedded_" & $getCurrentProcessId()
  removeDir(base)

  test "unpacked whole, the first time":
    let folder = unpack(base)
    check folder == base / resourcesId
    check fileExists(folder / ".complete")
    check fileExists(folder / "app" / "index.html")
    check fileExists(folder / "handlers" / "system" / "json" / "handler.js")
    check fileExists(folder / "config.json")
    check fileExists(folder / "LICENSE")
    check not fileExists(folder / "WebView2Loader.dll") # only when it's needed
    for (path, contents) in files:
      check readFile(folder / path) == contents

  test "not again once it's there":
    let folder = base / resourcesId
    writeFile(folder / "app" / "marker.txt", "still here")
    discard unpack(base)
    check fileExists(folder / "app" / "marker.txt")

  test "a start that was cut off is done again, and other builds' folders go":
    let folder = base / resourcesId
    removeFile(folder / ".complete")
    createDir(base / "an-older-build")
    discard unpack(base)
    check fileExists(folder / ".complete")
    check not fileExists(folder / "app" / "marker.txt")
    check not dirExists(base / "an-older-build")

  test "the loader DLL, written when it's asked for":
    let dll = unpackLoaderDll(base / resourcesId)
    check getFileSize(dll) == loaderDll.len

  removeDir(base)

suite "the WebView2 runtime":
  test "found in the registry, its EmbeddedBrowserWebView.dll there": # needs the runtime, as the app does
    let dll = findRuntimeClientDll()
    check dll.len > 0
    check fileExists(dll)
    check dll.endsWith("\\EBWebView\\x64\\EmbeddedBrowserWebView.dll")
