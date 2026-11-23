## workers.nim -- the requests run on worker threads, so the window never
## waits on the network. A job goes in, its result comes back through a
## channel, and the window is told with a message (WM_JOBDONE).
##
## Also the update sockets (LIVE RELOAD): one thread per watched page, a
## WinHTTP WebSocket, as Drummer does it.

import std/[locks, tables, strutils]
import winim/lean, winim/inc/winhttp
import requests, urls

const WM_JOBDONE* = WM_APP + 1

type
  JobKind* = enum
    jkPage, jkFavicon, jkToc, jkIsMarkdown, jkUrlStatus, jkImage, jkText, jkNeighbors,
    jkSocketUpdate, jkSocketClosed
  Job* = object
    id*: int
    kind*: JobKind
    url*: string
    flag*: bool
    extra*: seq[string]
  JobResult* = object
    id*: int
    kind*: JobKind
    url*: string
    page*: PageResult
    text*: string       ## toc opml, favicon or image bytes, text body
    mime*: string
    flag*: bool
    status*: UrlStatus
    err*: string

var
  jobs: Channel[Job]
  results: Channel[JobResult]
  notifyHwnd: HWND
  workerThreads: seq[Thread[int]]
  nextId = 0

proc notify() =
  {.cast(gcsafe).}:
    discard PostMessageW(notifyHwnd, WM_JOBDONE, 0, 0)

proc findNeighbors*(stops: seq[string], urlPage, urlPageFile: string,
                    status: proc (u: string): UrlStatus): (string, string) =
  ## ARROWS FROM THE TABLE OF CONTENTS: the lines before and after this page in
  ## the outline's order, a loop; a line with nothing at its address is skipped,
  ## and a folder's line and its readme's line are one page
  var ixFirst, ixLast = -1
  for ix, s in stops:
    if s == urlPage or s == urlPageFile:
      if ixFirst == -1: ixFirst = ix
      ixLast = ix
  if ixFirst == -1: return
  proc find(ixStart, direction: int): string =
    for ctSteps in 1 ..< stops.len:
      let urlStop = stops[(((ixStart + direction * ctSteps) mod stops.len) + stops.len) mod stops.len]
      if urlStop == urlPage or urlStop == urlPageFile: continue
      let st = status(urlStop)
      let urlStopFile = if st.urlContentLocation.len == 0: urlStop else: urlWithoutHash(st.urlContentLocation)
      if st.flAvailable and urlStopFile != urlPageFile: return urlStop
    ""
  (find(ixFirst, -1), find(ixLast, 1))

proc doJob(j: Job): JobResult =
  result = JobResult(id: j.id, kind: j.kind, url: j.url, flag: j.flag)
  case j.kind
  of jkPage: result.page = getPage(j.url, j.flag)
  of jkFavicon: (result.mime, result.text) = getFavicon(j.url)
  of jkToc: result.text = getToc(j.url)
  of jkIsMarkdown: result.flag = isMarkdownUrl(j.url)
  of jkUrlStatus: result.status = getUrlStatus(j.url)
  of jkNeighbors: # extra: the page's file, then the stops
    let (prev, next) = findNeighbors(j.extra[1 .. ^1], j.url, j.extra[0], getUrlStatus)
    result.text = prev & "\n" & next
  of jkImage, jkText:
    let r = httpGet(j.url, if j.kind == jkImage: "image/*, */*" else: "*/*")
    if r.err.len > 0: result.err = r.err
    elif r.status != 200: result.err = "status " & $r.status
    else:
      result.text = r.body
      result.mime = r.contentType
  else: discard

proc workerLoop(n: int) {.thread.} =
  {.cast(gcsafe).}:
    while true:
      let j = jobs.recv()
      if j.id < 0: break
      var r: JobResult
      try: r = doJob(j)
      except CatchableError as e:
        r = JobResult(id: j.id, kind: j.kind, url: j.url, err: e.msg)
        r.page = PageResult(flOk: false, url: j.url, message: "Can't get " & j.url & " because " & e.msg)
      results.send r
      notify()

proc startWorkers*(hwnd: HWND, n = 8) =
  notifyHwnd = hwnd
  jobs.open()
  results.open()
  workerThreads.setLen n
  for i in 0 ..< n: createThread(workerThreads[i], workerLoop, i)

proc submit*(kind: JobKind, url: string, flag = false, extra: seq[string] = @[]): int =
  inc nextId
  jobs.send Job(id: nextId, kind: kind, url: url, flag: flag, extra: extra)
  nextId

proc drainResults*(): seq[JobResult] =
  while true:
    let (ok, r) = results.tryRecv()
    if not ok: break
    result.add r

# ---------------------------------------------------------------- update sockets

const
  WinHttpOptionUpgradeToWebSocket = 114
  bufUtf8Message = 2
  bufUtf8Fragment = 3
  bufClose = 4

proc WinHttpWebSocketCompleteUpgrade(hRequest: HINTERNET, pContext: DWORD_PTR): HINTERNET {.stdcall, dynlib: "winhttp", importc.}
proc WinHttpWebSocketSend(hWebSocket: HINTERNET, eBufferType: DWORD, pvBuffer: pointer, dwBufferLength: DWORD): DWORD {.stdcall, dynlib: "winhttp", importc.}
proc WinHttpWebSocketReceive(hWebSocket: HINTERNET, pvBuffer: pointer, dwBufferLength: DWORD, pdwBytesRead: ptr DWORD, peBufferType: ptr DWORD): DWORD {.stdcall, dynlib: "winhttp", importc.}

type WatchArgs = object
  watchId: int
  urlSocket, urlWatched: string

var
  watchLock: Lock
  watchHandles: Table[int, HINTERNET]   ## watchId -> the socket, for stopWatching
  watchThreads: seq[ref Thread[WatchArgs]]
initLock watchLock

proc wideOf(s: string): wstring = +$s

proc watchLoop(a: WatchArgs) {.thread.} =
  {.cast(gcsafe).}:
    var u = a.urlSocket
    if u.startsWith("wss://"): u = "https://" & u[6 .. ^1]
    elif u.startsWith("ws://"): u = "http://" & u[5 .. ^1]
    var hSession, hConnect, hReq, hSocket: HINTERNET
    block connect:
      hSession = WinHttpOpen(&wideOf("BonBon"), 4, nil, nil, 0)
      if hSession == nil: break connect
      let host = wideOf(urlHostname(u))
      var port = if u.startsWith("https"): 443 else: 80
      let origin = urlOrigin(u)
      let ixPort = origin.rfind(':')
      if ixPort > 6:
        try: port = parseInt(origin[ixPort + 1 .. ^1]) except ValueError: discard
      hConnect = WinHttpConnect(hSession, &host, INTERNET_PORT(port), 0)
      if hConnect == nil: break connect
      var path = urlPath(u)
      let ixQ = u.find('?')
      if ixQ != -1: path.add urlWithoutHash(u[ixQ .. ^1])
      let wpath = wideOf(path)
      hReq = WinHttpOpenRequest(hConnect, "GET", &wpath, nil, nil, nil,
        if u.startsWith("https"): WINHTTP_FLAG_SECURE else: 0)
      if hReq == nil: break connect
      if WinHttpSetOption(hReq, WinHttpOptionUpgradeToWebSocket, nil, 0) == 0: break connect
      if WinHttpSendRequest(hReq, nil, 0, nil, 0, 0, 0) == 0: break connect
      if WinHttpReceiveResponse(hReq, nil) == 0: break connect
      hSocket = WinHttpWebSocketCompleteUpgrade(hReq, 0)
      if hSocket == nil: break connect
      discard WinHttpCloseHandle(hReq)
      hReq = nil
      withLock watchLock:
        if a.watchId notin watchHandles: # stopped while connecting
          discard WinHttpCloseHandle(hSocket)
          hSocket = nil
          break connect
        watchHandles[a.watchId] = hSocket
      var msg = "watch " & a.urlWatched
      if WinHttpWebSocketSend(hSocket, bufUtf8Message, addr msg[0], DWORD msg.len) != 0: break connect
      var buf: array[8192, char]
      var message = ""
      while true:
        var got, kind: DWORD
        if WinHttpWebSocketReceive(hSocket, addr buf[0], DWORD buf.len, addr got, addr kind) != 0: break
        if kind == bufClose: break
        if got > 0:
          let old = message.len
          message.setLen old + int(got)
          copyMem(addr message[old], addr buf[0], int(got))
        if kind == bufUtf8Message:
          const updatekey = "update\r"
          if message.startsWith(updatekey):
            results.send JobResult(id: a.watchId, kind: jkSocketUpdate, url: message[updatekey.len .. ^1])
            notify()
          message = ""
        elif kind != bufUtf8Fragment:
          message = ""
    var flStopped: bool
    withLock watchLock:
      flStopped = a.watchId notin watchHandles
      watchHandles.del a.watchId
    if hSocket != nil and not flStopped: discard WinHttpCloseHandle(hSocket) # stopWatching closed it otherwise
    if hReq != nil: discard WinHttpCloseHandle(hReq)
    if hConnect != nil: discard WinHttpCloseHandle(hConnect)
    if hSession != nil: discard WinHttpCloseHandle(hSession)
    if not flStopped: # it dropped; we didn't close it
      results.send JobResult(id: a.watchId, kind: jkSocketClosed)
      notify()

proc startWatching*(urlSocket, urlWatched: string): int =
  ## opens the socket and sends "watch " and the page's address; answers the watch's id
  inc nextId
  let id = nextId
  withLock watchLock:
    watchHandles[id] = nil
  # finished threads are let go
  var i = 0
  while i < watchThreads.len:
    if not watchThreads[i][].running:
      joinThread(watchThreads[i][])
      watchThreads.del i
    else: inc i
  let t = new Thread[WatchArgs]
  watchThreads.add t
  createThread(t[], watchLoop, WatchArgs(watchId: id, urlSocket: urlSocket, urlWatched: urlWatched))
  id

proc stopWatching*(watchId: int) =
  withLock watchLock:
    if watchId in watchHandles:
      let h = watchHandles[watchId]
      watchHandles.del watchId
      if h != nil: discard WinHttpCloseHandle(h) # the receive returns, the thread ends
