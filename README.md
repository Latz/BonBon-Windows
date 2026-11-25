# BonBon for Windows

<i>Writing is so important it deserves its own web.</i>

This is the **Windows version of BonBon**. The original, by Dave Winer, runs on macOS and Linux ([scripting/bonBon](https://github.com/scripting/bonBon)). This version runs on Windows 10 and 11. It has the original's interface, unchanged, and replaces Electron with a small native Windows app.

To get it, download [bonbon.exe](https://github.com/Latz/BonBon-Windows/releases/latest/download/bonbon.exe), a single file that is always the latest version, and see [Installing](#installing) below.

## From the original README

### What is BonBon?

BonBon is the first browser for the Markdown web.

It's an app that runs on MacOs and Linux.

### Who

Dave Winer developed BonBon, with the help of Claude Code. I ported the code to Windows, using Claude, too.

### How to

To get started, get the program from the [Download page](download/).

### Docs

Docs are in the [Docs folder](docs).

### Markdown hosting

GitHub is probably the best place to get free Markdown hosting.

What we really need are a few simple desktop apps that publish Markdown files to publicly-accessible internet servers.

### Questions, comments

Use the [issues section](https://github.com/scripting/bonBon/issues) of the GitHub repository for support.

## The Windows version

BonBon for Windows is a port of BonBon 0.6.56. Questions about BonBon itself belong in the original's issues. This repository is for problems that only happen on Windows.

### Installing

1. Download [bonbon.exe](https://github.com/Latz/BonBon-Windows/releases/latest/download/bonbon.exe), the latest version, and put it anywhere. Every version is also on the [Releases page](https://github.com/Latz/BonBon-Windows/releases), and [windows.zip](https://github.com/Latz/BonBon-Windows/releases/latest/download/windows.zip) has the same exe with the license beside it.
2. Run `bonbon.exe`. The first time, Windows may say "Windows protected your PC", because the app isn't signed. Click "More info", then "Run anyway".

BonBon needs the WebView2 Runtime, which Windows 10 and 11 usually already have. If yours doesn't, get it from [Microsoft](https://developer.microsoft.com/microsoft-edge/webview2/).

## Data

BonBon keeps its data in `%APPDATA%\BonBon`. That's the same folder the Electron version uses on Windows, so tabs, bookmarks and history carry over. The folder holds `config.json`, `tabs.json`, `bookmarks.opml`, `history.json`, `urlHistory.json`, `windowsPrefs.json` (the window's place), `stylesheets\` and `handlers\`. WebView2 keeps its own data, including the page's localStorage, in `EBWebView\`.

The program's own files are unpacked to `%LOCALAPPDATA%\BonBon\resources`, one folder per build. That folder is only a cache: deleting it is harmless, and the next start unpacks it again.

On start, the app registers itself for `bon://` links under `HKCU\Software\Classes\bon`.

BonBon-Windows is under the MIT License, copyright 2026 by Latz: see [LICENSE](LICENSE)
