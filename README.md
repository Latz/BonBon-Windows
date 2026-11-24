# BonBon for Windows

<i>Writing is so important it deserves its own web.</i>

This is the **Windows version of BonBon**. The original, by Dave Winer, runs on macOS and Linux ([scripting/bonBon](https://github.com/scripting/bonBon)). This version runs on Windows 10 and 11. It has the original's interface, unchanged, and replaces Electron with a small native Windows app.

To get it, download [bonbon.exe](https://github.com/Latz/BonBon-Windows/releases/latest/download/bonbon.exe), a single file that is always the latest version, and see [Installing](#installing) below.

## From the original README

### What is BonBon?

BonBon is the first browser for the Markdown web.

It's an app that runs on MacOs and Linux.

### Who

I am Dave Winer, the developer of BonBon, with the help of Claude Code.

This doc, and all other docs on this site were written by humans, unless otherwise stated.

### How to

To get started, get the app from the [Download page](download/).

### Docs

Docs are in the [Docs folder](docs).

### Markdown hosting

GitHub is probably the best place to get free Markdown hosting.

What we really need are a few simple desktop apps that publish Markdown files to publicly-accessible internet servers.

### Questions, comments

We're using the [issues section](https://github.com/scripting/bonBon/issues) of the GitHub repository for support.

### Where we're going

We're going to keep developing BonBon, and will work with developers who want to produce products that interop.

## The Windows version

BonBon for Windows is a port of BonBon 0.6.56. Questions about BonBon itself belong in the original's issues. This repository is for problems that only happen on Windows.

### How it's built

The interface is the original's, unchanged. `index.html`, `index.js`, `index.css`, the stylesheets, marked, js-yaml and DOMPurify are in `resources/app`. They run in WebView2, the browser engine from Edge that comes with Windows.

What `main.js` and `preload.js` do in Electron is done here by a small app in [Nim](https://nim-lang.org): windows, menus, files in the data folder, and the requests. Requests go through WinHTTP, so the Windows certificate store applies; see "WHOSE CERTIFICATES" in the original's `pageRequests.js`. The app is a single `bonbon.exe` of about 3 MB, compared with roughly 200 MB for an Electron app.

### Changes from the original

Added or changed for Windows:

- **One file.** `bonbon.exe` carries everything it needs: the original's interface, the stylesheets, the handlers and the seed of `config.json`. On its first start, and after an update, it unpacks them to `%LOCALAPPDATA%\BonBon\resources`. It finds the WebView2 runtime on its own, the way `WebView2Loader.dll` does, so it needs no DLL beside it. If that ever fails, it falls back to the real `WebView2Loader.dll`, which it also carries.
- **Menus.** The menu bar uses Windows conventions. Alt opens it, and Alt plus a letter opens one menu, even when the page has the focus: Alt+F File, Alt+E Edit, Alt+V View, Alt+S History, Alt+B Bookmarks, Alt+W Window, Alt+O BonBon. AltGr still types characters such as `@`.
- **Ctrl-click.** Ctrl-click on a link, or on an item in the bookmarks bar, opens it in a new tab behind the current one, as Cmd-click does on a Mac. The original asks for the Mac's Cmd key, which on Windows is the Windows key, so the bridge counts Ctrl as Cmd for mouse clicks.
- **View Source windows.** They have the same menu bar as the main window, as every Electron window has the application menu. Edit and Window act on the source window; all other commands act on the main window. A source window has no context menu and no browser keys such as Ctrl+P, as in Electron. Sources over 2 MB are shown too.
- **Inspect.** Inspect on the right-click menu opens DevTools with the element under the pointer selected. WebView2 has no call for this. BonBon turns on DevTools' element picker and clicks the spot. If DevTools is slow to load, BonBon tries again once. If that also fails, DevTools opens without a selection, and the click never reaches the page.
- **One instance.** Only one BonBon runs at a time. A second launch, or a `bon://` link, opens its address in a new tab in the running app. On Windows the original starts a new copy each time.
- **Closing.** Closing the main window also closes any View Source windows and quits. Electron keeps the source windows open.
- **Version.** The app reports its own version, starting at 1.0.0, in the window's corner, the About box and the User-Agent.
- **Redo** shows Ctrl+Shift+Z in the Edit menu, as in the original. Ctrl+Y redoes too, in the page.

Differences that remain:

- **Page handlers.** They run in an invisible frame that is sealed off by `sandbox` and a Content Security Policy. The original runs them in a hidden window with a session of its own. The original's third safeguard, cancelling every request from that session, is missing here.
- **Addresses.** The shell page is served from `http://bonbon.example/`, and the data folder's stylesheets from `http://stylesheets.bonbon.example/`. Because of that, localStorage starts fresh, so the chosen stylesheet and the sidebar state are not carried over from the Electron version.
- **Downloads.** WebView2 saves downloads to the Downloads folder without asking and shows its own download bar. Electron asks with a save dialog.
- **Compression.** WinHTTP unpacks gzip and deflate but not Brotli. A page a server sends with `Content-Encoding: br` without being asked arrives unreadable.
- **Closing the last tab.** The page's `window.close ()` is passed to the app through the bridge, because Chromium won't let a page close its window.

## Installing

1. Download [bonbon.exe](https://github.com/Latz/BonBon-Windows/releases/latest/download/bonbon.exe), the latest version, and put it anywhere. Every version is also on the [Releases page](https://github.com/Latz/BonBon-Windows/releases), and [windows.zip](https://github.com/Latz/BonBon-Windows/releases/latest/download/windows.zip) has the same exe with the license beside it.
2. Run `bonbon.exe`. The first time, Windows may say "Windows protected your PC", because the app isn't signed. Click "More info", then "Run anyway".

BonBon needs the WebView2 Runtime, which Windows 10 and 11 usually already have. If yours doesn't, get it from [Microsoft](https://developer.microsoft.com/microsoft-edge/webview2/).

## Data

BonBon keeps its data in `%APPDATA%\BonBon`. That's the same folder the Electron version uses on Windows, so tabs, bookmarks and history carry over. The folder holds `config.json`, `tabs.json`, `bookmarks.opml`, `history.json`, `urlHistory.json`, `stylesheets\` and `handlers\`. WebView2 keeps its own data, including the page's localStorage, in `EBWebView\`.

The app's own files are unpacked to `%LOCALAPPDATA%\BonBon\resources`, one folder per build. That folder is only a cache: deleting it is harmless, and the next start unpacks it again.

On start, the app registers itself for `bon://` links under `HKCU\Software\Classes\bon`.

## Building

```
nimble install winim
nimble test                      # unit tests (some need the internet)
nimble e2e                       # builds build\bonbon.exe and drives the real app (needs a desktop and WebView2)
                                 # with BONBON_E2E_REAL_INPUT=1 also the test that uses the real mouse and keyboard
nim c -o:bonbon.exe src/bonbon.nim
```

The build reads `resources\` and `build\WebView2Loader.dll` into the exe, so change something there and build again. `WebView2Loader.dll` is the x64 one from the NuGet package [Microsoft.Web.WebView2](https://www.nuget.org/packages/Microsoft.Web.WebView2), folder `build/native/x64`. The vtable indexes in `src/webview2.nim` are counted from the `WebView2.h` of version 1.0.4370.26.

The icon and the manifest are in `src/bonbon_res.o`. After changing `resources/bonbon.rc` or `resources/bonbon.manifest`, regenerate it:

```
cd resources && windres -F pe-x86-64 bonbon.rc -O coff -o ../src/bonbon_res.o
```

## Files

| File | In the original |
|---|---|
| `resources/app/` | index.html, index.js, index.css, stylesheets, marked, js-yaml, DOMPurify (copied unchanged) |
| `src/bridge.js` | preload.js, plus frontMatter.js, markdownConverter.js and the handler sandbox from pageHandlers.js |
| `src/bonbon.nim` | main.js (windows, menus, `window.mdBrowser` calls, View Source, Inspect, PDFs, bon://) |
| `src/requests.nim` | pageRequests.js |
| `src/datafolder.nim` | data folder, config.json, finding handlers |
| `src/workers.nim` | background threads for the requests |
| `src/webview2.nim` | the WebView2 COM calls BonBon uses, and finding the runtime |
| `src/embedded.nim` | `resources\` and WebView2Loader.dll inside the exe, unpacked on the first start |

## License

BonBon is under the MIT License, copyright 2026 Dave Winer: see [LICENSE](LICENSE), the original's. `resources/LICENSE` is a different file: Electron's license, which came along from the Electron build.
