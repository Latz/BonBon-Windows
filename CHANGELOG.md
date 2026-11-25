# Changes
## 1.0.4

Security fixes, from an audit of the app.

- **The window never leaves the shell.** A server could answer the download page's link with an HTML page instead of the file, and that page took the shell's place, with all of BonBon's calls at its disposal: the history, the bookmarks, the tabs, and requests to any address, the reader's own network included. Now a navigation away from the shell is stopped. A file still downloads, with the Save As dialog; a page goes nowhere.
- **The app answers only the shell.** A message from any other page is ignored, and the bridge isn't set up in one.
- `window.open` and a middle-click open the reader's default browser, not a bare WebView2 window.
- **A page's title can't run script.** It was put into the Add Bookmark dialog as HTML; now it's text.
- **No answer is read past 50 MB.** A server that never stops sending used to fill the memory until the app crashed; now it's an error message.

## 1.0.3

- **A single file.** `bonbon.exe` carries everything it needs. `WebView2Loader.dll` and the `resources` folder next to the exe are gone.
- The app finds the WebView2 runtime itself, the way `WebView2Loader.dll` does. If that ever fails, it uses the real `WebView2Loader.dll`, which it also carries.
- On the first start of a new version, the app unpacks its own files to `%LOCALAPPDATA%\BonBon\resources`. That's only a cache and can safely be deleted.
- The About dialog names the original and its MIT license.

## 1.0.2

- Redo shows Ctrl+Shift+Z in the Edit menu, as in the original. Ctrl+Y still redoes in the page.

## 1.0.1

- Ctrl+click on a link or a bookmark in the bar opens it in a new tab, like Cmd+click on the Mac. On Windows this used to work only through the right-click menu.
- The documentation (README, docs, download) is adapted to Windows.

## 1.0.0

- The first Windows version: BonBon 0.6.56's interface unchanged, in WebView2, with a small native app in Nim instead of Electron.
- Tabs, history, bookmarks with an editor and a bookmarks bar, five stylesheets, find in page, Markdown source, PDFs in the tab, page handlers (JSON, JS).
- A menu bar with shortcuts and Alt+letter, in the source window too; View Source in its own window, also for sources over 2 MB; Inspect on the element under the right-click.
- Only one running instance: a second start or a `bon://` link opens the address as a new tab in the open window.
