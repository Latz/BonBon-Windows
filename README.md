# BonBon für Windows (Nim + WebView2)

Windows-Version von BonBon 0.6.56 (Dave Winer, MIT), einem Browser für ein Web aus Markdown-Dateien.
Die Oberfläche ist die des Originals, unverändert: `index.html`, `index.js`, `index.css` und die Stylesheets
liegen in `resources/app` und laufen in WebView2, der Browser-Engine von Edge, die Windows mitbringt.
Was in Electron `main.js` und `preload.js` erledigen, macht hier eine kleine Nim-App: Fenster, Menüs, Dateien im
Datenordner, und die Anfragen über WinHTTP (dadurch gilt der Windows-Zertifikatsspeicher, siehe „WHOSE CERTIFICATES“ im Original).

## Bauen

```
nimble install winim
nimble test                      # Unit-Tests (ein Teil braucht Internet)
nimble e2e                       # baut build\bonbon.exe und testet die echte App (Desktop, WebView2, build\WebView2Loader.dll)
nim c -o:bonbon.exe src/bonbon.nim
```

Neben `bonbon.exe` müssen liegen:

- `WebView2Loader.dll` (x64) aus dem NuGet-Paket [Microsoft.Web.WebView2](https://www.nuget.org/packages/Microsoft.Web.WebView2),
  Ordner `build/native/x64`. Die Vtable-Indizes in `src/webview2.nim` sind aus dem `WebView2.h` von Version 1.0.4370.26 gezählt.
- der Ordner `resources\` (oder einer darüber).

Zur Laufzeit braucht Windows die WebView2-Runtime; Windows 10 und 11 haben sie in der Regel schon.
Icon und Manifest stecken in `src/bonbon_res.o`; nach Änderungen an `resources/bonbon.rc` neu erzeugen:
`cd resources && windres bonbon.rc -O coff -o ../src/bonbon_res.o`.

## Daten

`%APPDATA%\BonBon`, derselbe Ordner wie bei der Electron-Version unter Windows: `config.json`, `tabs.json`, `bookmarks.opml`,
`history.json`, `urlHistory.json`, `stylesheets\`, `handlers\`. WebView2 legt seine Daten (localStorage der Seite) in `EBWebView\` ab.
Beim Start registriert sich die App für `bon://`-Links unter `HKCU\Software\Classes\bon`.

## Dateien

| Datei | Original |
|---|---|
| `resources/app/` | index.html, index.js, index.css, stylesheets, marked, js-yaml, DOMPurify (unverändert kopiert) |
| `src/bridge.js` | preload.js, dazu frontMatter.js, markdownConverter.js und die Handler-Sandbox aus pageHandlers.js |
| `src/bonbon.nim` | main.js (Fenster, Menüs, `window.mdBrowser`-Aufrufe, View Source, PDFs, bon://) |
| `src/requests.nim` | pageRequests.js |
| `src/datafolder.nim` | Datenordner, config.json, Handler finden |
| `src/workers.nim` | Hintergrund-Threads für die Anfragen |
| `src/webview2.nim` | die benutzten WebView2-COM-Aufrufe |

## Unterschiede zum Original

- „Inspect“ öffnet die Entwicklerwerkzeuge, aber nicht auf dem Element unter der Maus (kann WebView2 nicht).
- Das View-Source-Fenster hat keine Menüleiste; Quelltexte über 2 MB zeigt es nicht an.
- Seiten-Handler laufen in einem unsichtbaren, per `sandbox` und Content-Security-Policy abgeschotteten Frame statt in einem
  eigenen versteckten Fenster mit eigener Session; die dritte Sperre des Originals (jede Anfrage der Session abbrechen) fehlt.
- Die Seite liegt unter `http://bonbon.example/`, die Stylesheets des Datenordners unter `http://stylesheets.bonbon.example/`.
  Darum fängt localStorage (gewähltes Stylesheet, Seitenleiste) neu an.
- Downloads speichert WebView2 ohne Rückfrage in „Downloads“ und zeigt seine Download-Leiste; Electron fragt mit einem Speichern-Dialog.
- WinHTTP entpackt gzip und deflate, aber kein Brotli; eine Seite, die ein Server ungefragt mit `Content-Encoding: br` schickt, kommt unlesbar an.
- Es läuft nur eine BonBon zur Zeit; ein zweiter Start und `bon://`-Links gehen an die laufende. Das Original öffnet unter Windows jeweils eine neue.
- `window.close ()` (letzter Tab geschlossen) wird über die Brücke an die App gemeldet, weil Chromium es einer Seite sonst verbietet.
