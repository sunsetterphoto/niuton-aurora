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