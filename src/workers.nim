## workers.nim -- the requests run on worker threads, so the window never
## waits on the network. A job goes in, its result comes back through a
## channel, and the window is told with a message (WM_JOBDONE).

import winim/lean
import requests

const WM_JOBDONE* = WM_APP + 1

type
  JobKind* = enum
    jkPage, jkFavicon, jkToc, jkIsMarkdown, jkUrlStatus, jkText
  Job* = object
    id*: int
    kind*: JobKind
    url*: string
    flag*: bool
  JobResult* = object
    id*: int
    kind*: JobKind
    url*: string
    page*: PageResult
    text*: string       ## toc opml, favicon bytes, text body
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

proc doJob(j: Job): JobResult =
  result = JobResult(id: j.id, kind: j.kind, url: j.url, flag: j.flag)
  case j.kind
  of jkPage: result.page = getPage(j.url, j.flag)
  of jkFavicon: (result.mime, result.text) = getFavicon(j.url)
  of jkToc: result.text = getToc(j.url)
  of jkIsMarkdown: result.flag = isMarkdownUrl(j.url)
  of jkUrlStatus: result.status = getUrlStatus(j.url)
  of jkText:
    let r = httpGet(j.url, "*/*")
    if r.err.len > 0: result.err = r.err
    elif r.status != 200: result.err = "status " & $r.status
    else:
      result.text = r.body
      result.mime = r.contentType

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

proc submit*(kind: JobKind, url: string, flag = false): int =
  inc nextId
  jobs.send Job(id: nextId, kind: kind, url: url, flag: flag)
  nextId

proc drainResults*(): seq[JobResult] =
  while true:
    let (ok, r) = results.tryRecv()
    if not ok: break
    result.add r
