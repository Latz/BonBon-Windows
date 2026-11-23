# BonBon für Windows (Nim)

Native Windows-Version von BonBon 0.6.56 (Dave Winer, MIT), einem Browser für ein Web aus Markdown-Dateien.
Kein Electron und keine Browser-Engine: Win32 über [winim](https://github.com/khchen/winim), die Seiten zeichnet RichEdit,
die Anfragen laufen über WinHTTP (dadurch gilt der Windows-Zertifikatsspeicher, siehe „WHOSE CERTIFICATES“ im Original).

## Bauen

```
nimble install winim yaml
nimble test                      # Unit-Tests (ein Teil braucht Internet)
nim c -o:bonbon.exe src/bonbon.nim
```

`bonbon.exe` braucht zur Laufzeit `pcre64.dll` daneben (von nim-markdowns `std/re`) und den Ordner `resources\`.
Icon und Manifest stecken in `src/bonbon_res.o`; nach Änderungen an `resources/bonbon.rc` neu erzeugen:
`cd resources && windres bonbon.rc -O coff -o ../src/bonbon_res.o`.

## Daten

`%APPDATA%\BonBon`: `config.json`, `tabs.json`, `bookmarks.opml`, `history.json`, `urlHistory.json`
(dieselben Dateien wie die Electron-Version unter Windows) plus `windowsPrefs.json` (Stylesheet, Fensterposition).
Beim Start registriert sich die App für `bon://`-Links unter `HKCU\Software\Classes\bon`.
`BONBON_LOG=<datei>` schreibt ein Lade-Log und das zuletzt erzeugte RTF.

## Module

| Datei | Original |
|---|---|
| `requests.nim` | pageRequests.js |
| `pagetext.nim` | frontMatter.js, markdownConverter.js, json/js-Handler, Makros |
| `rtf.nim` | Seitenaufbau aus index.js (Bilder, Bildunterschriften, Makros, Überschriften-IDs) |
| `bonbon.nim` | index.js + main.js (Tabs, Adressleiste, Menüs, Laden, Suche, Live-Reload, bon://) |
| `bookmarkseditor.nim` | der Outliner-Dialog von „Edit Bookmarks…“ |
| `workers.nim` | Hintergrund-Threads, Update-Sockets, TOC-Nachbarn |
| `themes.nim` | die fünf Stylesheets als Werte |

## Unterschiede zum Original

- Eigene CSS-Dateien und `urlUserCss` wirken nicht (keine CSS-Engine); stattdessen die fünf Stylesheets als eingebaute Themes, Web-Fonts durch Systemschriften ersetzt.
- JavaScript-Page-Handler im Ordner `handlers\user` laufen nicht; json und js sind eingebaut.
- PDFs öffnen immer im System-Viewer; keine Syntaxfärbung; keine DevTools; Randbilder stehen rechts über dem Absatz statt umflossen.
- Kein Kalender in der Seitenleiste (im Original standardmäßig aus), kein Hit-Counter, kein Ziehen von Tabs/Links.
- `vendor/markdown.nim`: nim-markdown 0.8.8 mit einem Fix (verschlucktes Zeichen nach Inline-Bildern).
