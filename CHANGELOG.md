# Änderungen

Jede Version hat einen Abschnitt `## <Version>`. `nimble release` nimmt den Abschnitt der Version aus `bonbon.nimble` als Text für das Release auf GitHub.

## 1.0.3

- **Eine einzige Datei.** `bonbon.exe` bringt alles mit, was sie braucht. `WebView2Loader.dll` und der Ordner `resources` neben der exe entfallen.
- Die App findet die WebView2-Runtime selbst, so wie es `WebView2Loader.dll` tut. Falls das einmal nicht klappt, nimmt sie die echte `WebView2Loader.dll`, die sie ebenfalls mitbringt.
- Ihre eigenen Dateien packt die App beim ersten Start einer neuen Version nach `%LOCALAPPDATA%\BonBon\resources` aus. Das ist nur ein Zwischenspeicher, den man gefahrlos löschen kann.
- Der About-Dialog nennt das Original und seine MIT-Lizenz.

## 1.0.2

- Wiederholen (Redo) zeigt im Bearbeiten-Menü Strg+Umschalt+Z, wie im Original. Strg+Y wiederholt in der Seite weiterhin.

## 1.0.1

- Strg+Klick auf einen Link oder ein Lesezeichen der Leiste öffnet es in einem neuen Tab, wie Cmd+Klick auf dem Mac. Bisher ging das unter Windows nur über das Rechtsklick-Menü.
- Die Dokumentation (README, docs, download) ist an Windows angepasst.

## 1.0.0

- Die erste Windows-Version: die Oberfläche von BonBon 0.6.56 unverändert, in WebView2, mit einer kleinen nativen App in Nim statt Electron.
- Tabs, Verlauf, Lesezeichen mit Editor und Lesezeichenleiste, fünf Stylesheets, Suchen auf der Seite, Markdown-Quelltext, PDFs im Tab, Seiten-Handler (JSON, JS).
- Menüleiste mit Tastenkürzeln und Alt+Buchstabe, auch im Quelltextfenster; View Source in eigenem Fenster, auch für Quellen über 2 MB; Inspect auf dem Element unter dem Rechtsklick.
- Nur eine laufende Instanz: ein zweiter Start oder ein `bon://`-Link öffnet die Adresse als neuen Tab im offenen Fenster.
