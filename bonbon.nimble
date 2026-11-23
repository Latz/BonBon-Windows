# BonBon for Windows -- a browser for a web made of Markdown files, native, in Nim.
# Port of BonBon 0.6.56 (Electron) by Dave Winer.

version       = "0.6.56"
author        = "Dave Winer (original), Windows port"
description   = "A browser for a web made of Markdown files, native Windows version."
license       = "MIT"
srcDir        = "src"
bin           = @["bonbon"]

requires "nim >= 2.2.0", "winim >= 3.9.4", "yaml >= 2.0.0"

task test, "Run the unit tests":
  for f in ["test_urls", "test_opml", "test_requests", "test_pagetext", "test_rtf", "test_workers"]:
    exec "nim c -r --hints:off tests/" & f & ".nim"
