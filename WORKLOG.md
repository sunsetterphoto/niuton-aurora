# Arbeitstagebuch (persönlich, nicht committen)

## Auftrag
„Niuton Aurora" — local-first KI-Assistent für KDE Plasma 6. Branch `feature/openai-backend`.
Kontext: HANDOVER.md (committed, aktuell). Regeln des Nutzers (seit 2026-09-02):
- Faktenbasiert arbeiten; Vermutungen nur mit Freigabe probieren.
- Arbeit in dieses Log schreiben (Stand jederzeit abrufbar).
- Repo ist öffentlich → niemals private Daten (IPs, Keys, Wallet-Inhalte) committen.
- Unklar → Internet-Recherche oder Nutzer fragen; nicht raten.
- Sicherheitsarchitektur mitdenken (Secrets nie in Config/Logs; Cache-Lücken vermeiden).

## Stand

### Committet (Branch feature/openai-backend, alle gepusht)
- `f12459d` Fix OpenRouter base URL + Remote-Migrationstest (45/45)
- `0179acd` KeyRing (KWallet via QtDBus, Env-Fallback AURORA_OPENROUTER_KEY) + KCM-Feld (45/45)
- `94df4a9` Doku aktualisiert (HANDOVER + README), WORKLOG angelegt

### Phase 3a — Auth-Header ✓ (committet `8f53660`), Phase 3b — Startset ✓ (committet `cc7d34e`?)
Fakten/Besonderheiten dieser Welle:
- OpenRouter-API live verifiziert (ohne Auth erreichbar): 425 Modelle; kostenlos =
  pricing.prompt=="0" && pricing.completion=="0" → exakt 21 (Stand 02.09.2026). Liste + Metadaten
  (name/context_length) aus /tmp/opencode/or_models.json entnommen.
- Neues Engine-Modul `OpenRouterFreeStart.qml` (objectName, models{id→{name,contextLength}},
  isFree(id)); in CMakeLists registriert (sonst "not defined"). NICHT Singleton — als Instanz
  nutzen (Muster AuroraSettings { id: s }).
- ModelManager: nur Cloud-Gruppe filtert über _openRouterFreeStart; Fallback auf alle, wenn
  Startset leer (API-Wechsel) — nichts verschwindet still.
- Test tst_openrouterfreestart.qml (7 Tests) + test_pickerZeigtNurFreieCloudModelle (ModelManager).
- Cloud-Auswahl-Test nutzt jetzt "openrouter/free" statt bezahltem "google/gemini-3.8-flash"
  (wäre sonst vom Filter verdeckt).

### Noch offen Phase 3b/c
- UI-Ebene: Cloud-Gruppe im Picker (Header/ConfigModels) an neue Labels/Filterung anpassen?
  (Picker läuft über ModelManager.pickerEntries — UI konsumiert nur; prüfen, ob Sortierung/
  Anzeige der freien 21 im Header ok ist.)
- Favoriten-Mechanik (Config-Key) — entschieden: Startset reicht erstmal (Nutzerentscheidung).
- Phase 3c: Modell-Metadaten anzeigen (Kontextlänge aus Startset) — kann der Picker nutzen.

### Phase 5 (Bild-Ausgabe + Kosten) — Stand dieser Welle
Committet:
- `cd31322` — Favoriten (openrouterFavorites), cloudSearch, Kontextlängen-Label, Picker-Popup mit
  Suchfeld, Ollama-Bild-Mapping für OpenAI (Phase 4).
- `0230856` — Kosten: usage/generationId aus Stream, per /v1/generation?id= (total_cost, Auth)
  best-effort; ChatController persistiert cost/usage/generationId ins msg.extra.
- (nächster Commit erwartet) Phase 5b Bild-Ausgabe:
  - FileIO.writeBase64 (C++ atomar, QSaveFile, Fehler bei ungültigem Input)
  - OpenAiClient.generateImage: NON-STREAMING (dokumentierter Pfad, modalities
    ["image","text"], message.images[].image_url.url → data-URLs; SSE-Bildstruktur
    offiziell nicht spezifiziert → nicht erraten; Nutzerentscheidung)
  - ModelManager.generateImage (nur aktiver Client mit generateImage; Auto→lokal→Fehler,
    Cloud nie automatisch)
  - GenerateImageTool: Quellenwahl ctx.genImageFn (Cloud) vs. ComfyUI; originConvId-Guard
  - AuroraController: imageGenFn → generateImage + writeBase64 in images-Ordner +
    appendGeneratedImage (dieselbe Blase wie ComfyUI)
  - ChatController._buildCtx: genImageFn; AuroraEngine reicht durch

Fakten (verifiziert):
- 11 OpenRouter-Modelle mit Bild-Ausgabe (output_modalities enthält "image")
- Doku (Archiv): Bildgen nur non-streaming belegt; Total-Cost via GET /v1/generation?id=

### Offen danach
- Phase 3b UI-Suche im Picker funktioniert (tst_header); HANDOVER.md auf Stand bringen
- ComfyUI am LAN-Gerät war aus (kein Repo-Inhalt — Beispieladresse siehe Regeln)
- backup/vor-ip-bereinigung löschen, PR eröffnen

### P1 — Video-Generierung (fertig committet)
Fakten: OpenRouter hat EIGENE /v1/videos-API (NICHT /v1/models): POST /v1/videos (async Job,
{polling_url,status}), GET /v1/videos/{jobId} (status pending|in_progress|completed|failed|
cancelled|expired + unsigned_urls + usage.cost), GET /v1/videos/models (28 Modelle: Veo 3.1,
Sora 2, Kling, Wan, Hailuo, FLUX, Runway, Grok; Preise pro Sek.. Veo 3.1 Lite Default).
Umsetzung:
- VideoClient.qml (engine): submit/poll/refreshVideoModels + Auth wie OpenAiClient
- GenerateVideoTool: explizite Quellenwahl über ctx.videoGenFn; KEIN Blockieren — done sofort
  "gestartet", fertiges Video kommt async (Controller pollt alle 5s, Kappe 180×?)
- ChatController: appendGeneratedVideo (mediaType video/mp4, tool-History-Suppression wie Bild)
- AuroraEngine: videoGenFn durchgereicht + appendGeneratedVideo-Stub
- AuroraController: VideoClient-Instanz (baseUrl nur bei openrouterEnabled), videoGenFn,
  Polling-Timer, downloadToFile in appData/videos, originConvId-Guard, Statuszeilen
- MessageBubble: Video-Box (extern öffnen, KEINE QtMultimedia-Abhängigkeit)
- Config-Key videoGenModel (Default google/veo-3.1-lite) + KCM-Feld in ConfigModels
- ToolRegistry: GenerateVideoTool registriert (nur mit videoGenFn im Kontext sichtbar)
Tests: tst_videoclient (9), tst_videotool (6), chatcontroller_activity (+2), messagebubble (+2),
toolregistry (+1) → 49/49 grün. README aktualisiert.
Fertig & grün (45/45):
- OpenAiClient: injizierbares `keyring`, `keyRef`, `_resolveKey` (einmal auflösen, cache;
  Fehler nicht cachen), `_authHeaders()` nur bei bekanntem Key; refreshModels/chat/embed
  warten auf den Key und hängen Authorization-Bearer an (Mock-Stream post(url,body,headers)).
- OpenAiChatJob: Property `headers`, übergibt an stream.post. (Ollama-ChatJob unberührt —
  kein Auth nötig bei Ollama.)
- ModelManager: `keyring`-Property, reicht in `_syncExtraClients` an Clients durch
  (keyRef aus Registry; keyring auch bei bestehenden Clients nachziehen!).
- ONKEYREFCHANGED-RESET (wichtig, Security): Wechsel des keyRef invalidiert `_key`/`_keyState`,
  sonst würde der nächste Request mit dem falschen Backend-Key authentifizieren.
  Dieser Reset heilte zugleich die Test-Interferenz (Datei-Singleton über Tests).

Wissensstand zur Verdrahtung (Fakten):
- `NdjsonStream.post(url, body, headers)` — Header-Support existiert (Core).
- `Http.getJson(url, cb, timeoutMs, headers)`; postJson analog.
- Qt-6.11-QML-Tests: Datei-Singleton `client` lebt über alle Testfunktionen; init() muss
  interne Zustände zurücksetzen (nicht nur Test-Doubles).
- Reihenfolge-Empfindlichkeit: onBackendsChanged erzeugt Clients schon beim Config-SetValue;
  Injektion (`keyring`) VOR dem Backends-Wechsel setzen ODER (besser, umgesetzt)
  keyring in _syncExtraClients immer nachziehen.

### Nächste Schritte Phase 3b — Favoriten + Suche (Startset 21 freie Modelle)
Aufgaben grob:
- Offizielle OpenRouter-API-Dokumentation zu /api/v1/models (filter:isFree=true o.ä.) prüfen
  — URL: https://openrouter.ai/docs/api-reference/list-available-models (internet).
- Startset: die 21 kostenlosen Modelle als statische Whitelist (Fakt: Nutzerentscheidung).
- Picker: Cloud-Gruppe filterbar (Suchfeld) + Favoriten (Config-Key). UI-Ebene beachten:
  ModelManager.pickerEntries baut Gruppen; Suche/Favorit vermutlich dort oder im Header.
- Danach Phase 4 (Eingabe-Modalitäten) & Phase 5 (Ausgabe/Kosten) laut HANDOVER.

### Werkzeuge/Wissen
- Build: `cmake --build build`; Test-Suite: `ctest --test-dir build --output-on-failure`.
- qmltestrunner direkt: `/usr/lib64/qt6/bin/qmltestrunner -input <abs. Datei> -import <abs. build/bin>`
  mit `QT_QPA_PLATFORM=offscreen`, cwd = build/src/engine. (Funktionsfilter-PosArg scheint ignoriert;
  läuft dann alle.)
- qDebug im Release stumm; für Diagnose Zusatz-compare/QCOMPARE in Tests einbauen und wieder rausnehmen.

---

## Stolpersteine dieser Session (2026-09-03, Merkliste)

1. **Config-Datei durch externes Tool zerlegt**: `~/.config/net.niuton.aurora.rc` war mit
   lowercase-Keys (`remoteendpoint`) + doppelten Einträgen + `openrouterFavorites=[...]` OHNE
   Quotes geschrieben → QSettings parst `[...]` als Sektionskopf, ConfigStore (CamelCase) fand
   nichts mehr. Fix: Datei sauber neu (CamelCase + Favoriten **gequotet**, QSettings liefert den
   Wert inkl. Quotes = exakt das JSON, das `_parseFavorites` erwartet). Backup erstellen.

2. **Plasmashell "Neustart" greift nicht bei manuell gestartetem Prozess**: `install.sh` restartet
   nur die systemd-Unit/transiente; wenn plasmashell manuell läuft (nohup), bleibt die alte PID.
   Dann: `pkill -x plasmashell` + selbst neu starten (`nohup plasmashell & disown`) — er kommt
   NICHT automatisch zurück. PID danach verifizieren.

3. **`readonly`-Property über Funktionsaufruf auf internem Zustand wertet nie neu aus**:
   `readonly property var effortChoices: modelManager ? modelManager.activeEfforts() : []` —
   readonly bindet nur an `modelManager` (statisch), nicht an activeModel/Models → Dropdown blieb
   unsichtbar. Fix: mutable Property + `_refreshEffortChoices()` bei `onSelectedModelChanged`/
   `onActiveModelChanged`/`Component.onCompleted`.

4. **`QQC2.ComboBox` verwaltet `visible` intern**: deklarative `visible:`-Bindung schlägt nicht
   zuverlässig durch (in Tests blieb false). Lösung: Item-Container mit `visible`+`enabled`.

5. **QML-Test `when: windowShown` nötig** für sichtbarkeits-/klick-abhängige Tests; programmatisches
   `checked=`/`toggle()` feuert KEIN `toggled/clicked` (Mausklick im offscreen fragil) → Tests
   lieber auf deterministische Properties/Funktionen setzen. `QTRY_VERIFY` existiert in QML NICHT
   (nur `wait` + erneutes Lesen).

6. **llama.cpp Router-Modus**:
   - `/v1/models` kann beim ERSTEN Aufruf `[]` liefern (load-on-startup noch nicht fertig) —
     Race beim Start; Aurora muss das beim Polling verkraften (neu proben).
   - `/models/unload` → 200 `{"success":true}`, aber Status erst nach `stop-timeout` (10s)
     `unloaded` — NICHT sofort.
   - Autoload: neuer Chat nach Unload lädt das Modell automatisch wieder (verifiziert).
   - Preset-Pfade: `%h` wird in llama.cpp-Presets **nicht** expandiert → Beispiel mit
     `<HOME>`-Platzhalter + `install.sh` sed; echte absolute Pfade NIE ins öffentliche Repo
     (Preset als `.example` ausliefern).

7. **Edit-Fallen am Edit-Tool**: mehrfach durch zu kleine `oldString`-Blöcke versehentlich
   Funktionsköpfe/Zeilen zerstört (`function test_generateImage...()` Kopf, `if (busy) return`,
   `chatFn`-Zeile, `ToolTipAvoid: {}`-Fremdkörper). Lektion: bei größeren Umbauten die betroffene
   Region NACH dem Edit lesen; nicht mit einzelnem `}`-Matching arbeiten (Kollisionsgefahr).

8. **`usage.completion_tokens_details.reasoning_tokens`** = empirischer Reasoning-Nachweis
   (DeepSeek/OpenRouter live verifiziert); 0/fehlend = kein Badge (kein Fake).

9. **DeepSeek V4 Flash**: Modell-ID `~deepseek/deepseek-v4-flash-latest` (Tilde-Präfix ist gültig);
   `supported_efforts: ["max","high","low"]`, default "high", NOT mandatory → effort-Filter im UI
   nötig; `reasoning_effort` + `reasoning:{enabled}` sind pro Request erlaubt (llama-server
   akzeptiert `reasoning_effort` ebenfalls pro Request laut Doku).

10. **`git push`-Reihenfolge**: erst feature pushen, dann merge nach main (FF) + push main —
    danach `git ls-remote` zur Verifikation. main und feature zeigen sonst unterschiedlich.
---

## 19.09.2026 — Phase 6: Routinen (geplante Selbstläufe)

Auftrag: Aurora soll fällige/überfällige Routinen selbstständig ausführen (auch als
Hintergrund-Widget), sich Routineeinträge per Chat selbst anlegen („Prüfe den Brent-Preis jeden
Tag um 12 Uhr"), und die Einträge in der Seitenleiste OBERHALB der Chats zeigen — beide Sektionen
einklappbar, Routinen einsehbar/bearbeitbar/anlegbar.

Umsetzung (54/54 Tests grün):
- **Schema v6**: Tabelle `routines` (kind/time_of_day/weekday/interval_minutes/enabled/
  next_run/last_run als ms-Epoch/last_status/last_conversation/claim_token), Migration additiv,
  sweepOnOpen gibt hängende Läufe frei. `routines()`-Read + `addRoutine/updateRoutine/
  deleteRoutine/claimRoutines`-Writes; `claimRoutines` atomar (UPDATE + SELECT in einer
  BEGIN-IMMEDIATE-Transaktion, RETURNING-artig über claim_token) → Widget+App doppeln nicht.
  **Falle**: `next_run <= :now` mit isoNow-String als `:now` trifft JEDE Zeile (SQLite-
  Typenordnung INTEGER < TEXT) — nowMs als Zahl binden.
- **RoutineScheduler.qml**: 30-s-Takt, läuft am Widget-Root (unabhängig von `active`), eigene
  AuroraEngine-Instanz (kein Konflikt mit dem UI-Chat), je Lauf eine eigene Konversation
  (Titel `⟳ …`, Touch NACH send() enqueued — sonst Überschreiber _maybeSetTitle).
  computeNextRun in Lokalzeit (daily/weekly/interval/once); once deaktiviert sich; überfällige
  Läufe genau einmal nachholen. **Falle (Re-Entrancy)**: onBusyChanged feuert mitten in der
  `state="idle"`-Zuweisung von _finalizeAssistant — direkter Finish überschreibt den
  nachfolgenden Lauf → `Qt.callLater`.
- **RoutineTool (manage_routines)**: create/list/update/delete/run_now; ctx.routines über
  ChatController._buildCtx + AuroraEngine durchgereicht (beide Engines teilen den Scheduler).
  Permission `toolManageRoutines`, Default auto (KCM ConfigTools ergänzt).
- **UI**: Sidebar mit Routinen-Sektion (Zeilen: Titel, Zeitplan · nächster Lauf, ⚠-Badge bei
  Fehler, „läuft …" während aktiven Laufs; Play/Edit/Delete-Zwei-Klick) + Chats-Sektionsheader;
  RoutineDialog als Overlay (KEIN fensterbasiertes QQC2.Dialog — Widget-Popup!). Toggles
  persistiert (routinesOpen/chatsOpen im ConfigStore).
- **Tests**: test_conversationstore (Schema/CRUD/Claim/Sweep), tst_routinescheduler (15),
  tst_sidebar (10), tst_routinedialog (11). **QML-Test-Fallen**: qmltestrunner hält die
  Testwurzel unsichtbar → `.visible` immer false → `visible = true` in init(); Änderungen an
  QML-Modulquellen brauchen `cmake --build` (qmlcache), sonst läuft beim Test der alte Stand.
