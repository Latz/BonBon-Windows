# BonBon for Windows -- a browser for a web made of Markdown files, native, in Nim.
# Port of BonBon 0.6.56 (Electron) by Dave Winer.

version       = "1.0.0"
author        = "Dave Winer (original), Windows port"
description   = "A browser for a web made of Markdown files, native Windows version."
license       = "MIT"
srcDir        = "src"
bin           = @["bonbon"]

requires "nim >= 2.2.0", "winim >= 3.9.4"

task test, "Run the unit tests":
  for f in ["test_urls", "test_opml", "test_requests",
            "test_server", "test_datafolder", "test_misc"]:
    exec "nim c -r --hints:off tests/" & f & ".nim"

task e2e, "Build build/bonbon.exe and run the end-to-end tests (needs a desktop, WebView2 and WebView2Loader.dll in build)":
  exec "nim c --hints:off -o:build/bonbon.exe src/bonbon.nim"
  exec "nim c -r --hints:off tests/e2e.nim"
