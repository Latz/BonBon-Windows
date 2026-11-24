## embedded.nim -- the app's own files, inside bonbon.exe, so the app is one file.
##
## resources/app (the original's shell page), resources/handlers, the seed of
## config.json, the license and WebView2Loader.dll are read when bonbon.exe
## is built. The first start of a build unpacks them to a folder of their own
## (see resourcesFolder in datafolder.nim), where the app finds them the way
## it found the resources folder beside the exe.

import std/[os, hashes, strutils]

const
  root = currentSourcePath.parentDir.parentDir
  pathLoaderDll = root / "build" / "WebView2Loader.dll" ## x64, from the NuGet package Microsoft.Web.WebView2

static: doAssert fileExists(pathLoaderDll), "bonbon.exe carries WebView2Loader.dll; put it at " & pathLoaderDll

proc collect(): seq[(string, string)] {.compileTime.} =
  let res = root / "resources"
  for sub in ["app", "handlers"]:
    for f in walkDirRec(res / sub, relative = true):
      result.add (sub / f, staticRead(res / sub / f))
  result.add ("config.json", staticRead(res / "config.json"))
  result.add ("LICENSE", staticRead(root / "LICENSE"))

const
  files* = collect()                     ## (path relative to the folder, contents)
  loaderDll* = staticRead(pathLoaderDll) ## unpacked only when the app's own loader can't find the runtime, see webview2.nim
  resourcesId* = toHex(hash(files) !& hash(loaderDll)) ## names the folder; a build with other files gets its own

proc unpack*(base: string): string =
  ## base\<resourcesId> with every file in it, unpacked the first time: into a
  ## folder of its own, renamed when it's whole, so a start that's cut off
  ## leaves nothing half done. Folders of other builds go.
  result = base / resourcesId
  if fileExists(result / ".complete"): return
  let tmp = result & ".tmp" & $getCurrentProcessId()
  removeDir(tmp)
  for (path, contents) in files:
    createDir((tmp / path).parentDir)
    writeFile(tmp / path, contents)
  writeFile(tmp / ".complete", "")
  removeDir(result)
  moveDir(tmp, result)
  for kind, path in walkDir(base):
    if kind == pcDir and path != result:
      try: removeDir(path) except CatchableError: discard # one that's in use stays until next time

proc unpackLoaderDll*(folder: string): string =
  ## WebView2Loader.dll in the folder, written if it isn't there
  result = folder / "WebView2Loader.dll"
  if not fileExists(result) or getFileSize(result) != loaderDll.len:
    writeFile(result, loaderDll)
