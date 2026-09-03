# Übergabe: Backend-Registry, KWallet, OpenRouter (Phasen 1–5)

Stand: 02.09.2026 · Branch `feature/openai-backend`

Dieses Dokument ist der Kontext für die Weiterarbeit (z.B. mit opencode/DeepSeek). Es beschreibt,
wo das Projekt steht, was unmittelbar zu tun ist und welche Konventionen gelten.

---

## 1. Sofortlage

```
Branch:   feature/openai-backend  (14 Commits, gepusht nach origin)
main:     unberührt bei c2ac749
```

**Testlage: 47 von 47 Testzielen grün** (davon `tst_modelmanager` 35/35, `tst_openaiclient` 35/35,
`tst_keyring` 8/8, `tst_header` 6/6, `test_fileio` 25/25).

```bash
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build          # ctest baut NICHT selbst!
ctest --test-dir build --output-on-failure
```

---

## 2. Erledigt (Stand dieser Welle)

### 2.1 Die zwei roten Tests sind grün — Commit `f12459d`

- **`test_cloudAuswahlWirdAlsSolcheGemeldet`** war ein echter Code-Bug: doppeltes `/v1` in der
  OpenRouter-URL. `AuroraSettings._computeBackends()` setzte `endpoint: "https://openrouter.ai/api/v1"`,
  `OpenAiClient.refreshModels()` hängt `/v1/models` an → `.../api/v1/v1/models`. Der Endpunkt ist jetzt
  `"https://openrouter.ai/api"` (Konvention: der Client hängt das `/v1` an, wie bei llama-server).
  `test_openrouterIstCloudUndOptional` pinnt die URL ohne Suffix.
- **`test_migrationAlterRemoteAuswahl`** war ein unvollständiger Test: `OllamaClient.refreshModels()`
  setzt `models` erst im `/api/ps`-Callback; der Test beantwortete nur das `/api/tags`. Jetzt
  beantwortet er Probe, zweiten `/api/tags` und `/api/ps` (Vorlage:
  `test_gespeicherteRemoteAuswahlNachProbe`).

### 2.2 Schlüsselablage über KWallet — Commit `0179acd` (Phase 2)

- **`KeyRing`**: neue Core-Primitive (QML-Singleton) für die Schlüsselablage. Spricht per QtDBus die
  `org.kde.KWallet`-Schnittstelle auf `org.kde.kwalletd6` — **kein KF6-Dev-Paket nötig**, nur
  `Qt6::DBus`. API: `readSecret/writeSecret/removeSecret(keyRef, cb)` mit `{ok, secret?, error?}`.
- **Wichtig**: kein Schlüssel in `~/.config/net.niuton.aurora.rc` (Modus 644) — die Registry hält nur
  `keyRef`, das Secret liegt im Wallet (Ordner `net.niuton.aurora`).
- **Env-Rückfall**: `AURORA_<KEY>_KEY` (z.B. `AURORA_OPENROUTER_KEY`) wird beim Lesen zuerst geprüft —
  für kopf-losen Betrieb ohne Wallet-Prompt.
- **Testbarkeit**: D-Bus-Connection injizierbar; `test_keyring.cpp` startet einen privaten
  `dbus-daemon` (Subprozess) mit Fake-kwalletd6 als `QDBusAbstractAdaptor` (exportiert die echte
  `org.kde.KWallet`-Schnittstelle). Läuft ganz ohne Desktop-Session.
- **UI**: KCM-Sektion „OpenRouter (Cloud)" in `ConfigModels.qml` — explizites Opt-in + Schlüsselfeld.

### 2.3 Phasen 3–5 — OpenRouter-Backend komplett — `8f53660` … `a02ee34`

**Phase 3a (Auth, `8f53660`):** `OpenAiClient` bekommt injizierbares `keyring` + `keyRef`; löst den
Schlüssel genau einmal auf (Cache, bei `keyRef`-Wechsel invalidiert — kein fremder Key fürs falsche
Backend). `refreshModels/chat/embed` senden `Authorization: Bearer …` nur bei bekanntem Key (kein
Empty-Bearer). `OpenAiChatJob` reicht `headers` an den Stream.

**Phase 3b (Startset/Favoriten/Suche, `377de21` + `cd31322`):** Live gegen die API verifiziert:
425 OpenRouter-Modelle; kostenlos = `pricing 0/0` → **exakt 21**. Whitelist in
`OpenRouterFreeStart.qml` (id → Name/Kontextlänge, Account-Stand 02.09.2026). Config-Key
`openrouterFavorites` (JSON-Array, Default leer → Startset). Picker zeigt entweder Suchtreffer
(`cloudSearch`, filtert die 425) oder Favoriten/Startset; Kontextlänge als Label-Suffix
(„… · 200K"). **Picker-UI**: `Header.qml` nutzt Button + Popup mit Suchfeld statt ComboBox
(flache Liste wäre unbenutzbar); Suche setzt sich beim Schließen zurück. Signal
`cloudSearchChanged` → `AuroraController.setCloudSearch` → `ModelManager.cloudSearch`.

**Phase 4 (Eingabe-Modalitäten, `cd31322`):** `OpenAiClient._mapMessages`: Ollama-Format
(`message.images` als Base64-Liste) → OpenAI-`content`-Array mit `image_url`-Teilen (MIME-Default
png; Original wird nie mutiert — der ChatController hält dieselbe History in beiden Welten).

**Phase 5a (Kosten, `0230856`):** Fakten (Archiv-Doku): Stream liefert id + finalen usage-Chunk;
Kosten nur über `GET /v1/generation?id=…` (`data.total_cost`, Auth). `OpenAiChatJob` erfasst beides;
bei `fetchCost` (nur Cloud) holt er die Kosten best-effort NACH dem Stream (Timeout 15 s, Fehler
verwirft die Antwort nicht). `ChatController` schreibt usage/cost/generationId ins `extra` der
finalen Message.

**Phase 5b (Bild-Ausgabe, `a02ee34`):** Nutzerentscheidung: **nur explizit** (aktives Bildmodell),
**non-streaming** (SSE-Bildstruktur offiziell nicht spezifiziert; non-streaming ist dokumentiert).
`FileIO.writeBase64` (atomar, Fehler ohne Datei). `OpenAiClient.generateImage`
(`modalities:["image","text"]`). `ModelManager.generateImage` delegiert nur an Clients mit
`generateImage` (Auto-Modus/lokal → Fehler). `GenerateImageTool._nimmCloud`: Quellenwahl
`ctx.genImageFn` (Cloud) vs. ComfyUI; `originConvId`-Guard wie beim ComfyUI-Weg.
`AuroraController.imageGenFn`: Generate → data-URLs → `writeBase64` in den `images`-Ordner →
`appendGeneratedImage` (dieselbe Bubble wie ComfyUI). 11 Modelle mit Bild-Ausgabe (API-verifiziert).

---

## 3. Verifiziert + Roadmap

### 3.1 Live-Verifiziert gegen die echte OpenRouter-API (Key liegt im KWallet, 02.09.2026)

- **Auth**: `GET /v1/models` mit Bearer → 200, 424 Chat-Modelle.
- **Chat + Thinking**: DeepSeek V4 Flash streamt live; Denktext kommt als `delta.reasoning`
  (String) + `reasoning_details`, NICHT `reasoning_content` → gefixt in `98cfe44`.
- **Kosten-Lookup**: `GET /v1/generation?id=…` → `data.total_cost` (verifiziert 5.05e-07 $).
- **Video-API (wichtiger Fund)**: OpenRouter hat eine EIGENSTÄNDIGE Video-Generierung, die NICHT
  in `/v1/models` auftaucht (das ist nur Chat):
  - `GET /v1/videos/models` → **28 Video-Modelle** (Veo 3.1, Sora 2, Kling v3, Wan 2.7/3.0,
    Hailuo 3, FLUX.3 Video, Runway Gen-4.5 …), jedes mit `supported_durations`,
    `supported_aspect_ratios`, `generate_audio`, Preis-SKUs (`pricing_skus`).
  - `POST /v1/videos` → `202 {id, polling_url, status}` (async Job).
  - `GET /v1/videos/{jobId}` → `status` (`pending|in_progress|completed|failed|cancelled|expired`)
    + `unsigned_urls` + `usage.cost`.
  - `GET /v1/videos/{jobId}/content?index=0` → `video/mp4` (Binary; Download auch via
    `unsigned_urls[0]` direkt möglich).
  - Request-Parameter: `model, prompt, aspect_ratio, duration, resolution, frame_images
    (first/last, als image_url), generate_audio, seed`.

### 3.2 Offen / Ausstehend

1. **Video-Generierung (`generate_video`-Tool)** — P1 der Roadmap, als Nächstes.
2. **PR** für `feature/openai-backend` noch nicht eröffnet.
3. **Backup-Branch `backup/vor-ip-bereinigung`** (lokal, mit echten LAN-IPs) nicht pushen —
   löschen, sobald der Stand abgenommen ist.
4. **ComfyUI am LAN-Gerät** war beim Test nicht erreichbar (Gerät aus); Eintrag zeigt korrekt
   „nicht erreichbar".

### 3.3 Roadmap (P1–P6, priorisiert)

| Prio | Feature | Backend | Aufwand |
|---|---|---|---|
| **P1** | `generate_video`-Tool (Veo 3.1 Lite / Kling, async-Job-Polling, Video-Bubble) | OpenRouter `/v1/videos` | groß |
| **P2** | Audio-Generierung (`lyria` kostenlos) + Wiedergabe (`aplay`/Player) | OpenRouter (chat, non-streaming) | mittel |
| **P3** | Audio-Analyse im Chat (46 Modelle; optional statt lokalem Whisper) | OpenRouter | mittel |
| **P4** | Video-Analyse als Anhang (79 Video-in-Modelle; Anhang `video_url`) | OpenRouter | groß |
| **P5** | Lokal weiterentwickeln: img2img in ComfyUI, weitere TTS-Stimmen | lokal | mittel |
| **P6** | Datei-/PDF-Analyse (`structured_outputs` von 340 Modellen) | OpenRouter | klein |

Alle Cloud-Punkte folgen dem Leitprinzip: **nur explizit, nie automatisch**, Kosten sichtbar,
Quellenwahl wie bei Bild (ComfyUI vs. Cloud).

---

## 4. Hardware und Messwerte (dieses Gerät)

Ryzen 7 PRO 7840U · Radeon 780M (gfx1103) · 64 GB LPDDR5-6400, davon 8 GB als VRAM.

**Der entscheidende Fund:** Ollama verwarf die iGPU stillschweigend
(`dropping integrated GPU; to enable, set OLLAMA_IGPU_ENABLE=1`). Behoben über
`/etc/systemd/system/ollama.service.d/gpu.conf` mit `OLLAMA_IGPU_ENABLE=1`; der vorherige
`HSA_OVERRIDE_GFX_VERSION=11.0.0` ist raus (er maskierte gfx1103 fälschlich als gfx1100). Ollama
wählt nun selbst den Vulkan-Pfad.

| qwen3.5:9b Q4 | CPU | Vulkan-iGPU |
|---|---|---|
| Prefill (1152 Tokens) | 43,4 tok/s | **169 tok/s** |
| Decode | 3,8 tok/s | **12,2 tok/s** |
| Default-Kontext | 4096 | **32768** |

Damit war die Annahme „Decode ist bandbreitenlimitiert" **falsch** — es war das CPU-Power-Budget
(15 W im Akkubetrieb). Die iGPU rechnet pro Watt deutlich effizienter.

**Bonsai 27B ternär** (`~/.local/share/aurora/models/Ternary-Bonsai-27B-Q2_g64.gguf`, 7,59 GB) läuft
über `llama-server` auf `:8080` mit **74 tok/s Prefill / 7,1 tok/s Decode** — ein 27B-Modell lokal.

Sackgassen, nicht erneut prüfen:

- **Ollama kann Bonsai nicht laden.** Verifiziert: Ollamas `libggml` kennt `q2_K`, `tq1_0`, `tq2_0`,
  aber **kein `q2_0`**. Deshalb der Umweg über `llama-server` und der ganze `OpenAiClient`.
- **Der PrismML-Fork bringt nichts.** Gemessen: mit `g64` 72,2/6,7 (minimal langsamer als
  upstream), mit eigener `g128`-Variante 7,6/2,1 — Faktor 10 schlechter beim Prefill, g128-Kernel
  sind auf Vulkan nicht optimiert. **Bei upstream llama.cpp + `_g64` bleiben.**
- **Spekulatives Decoding scheitert am Drafter.** Upstream kennt die Architektur `dspark` nicht; der
  Fork kennt sie, stolpert aber über die Tensor-Offsets (`dspark.fc.weight has offset 337718592,
  expected 357584192`). Abhaken, bis PrismML nachzieht.

---

## 5. Vom Nutzer getroffene Festlegungen

- **Datensouveränität ist die Leitlinie, nicht der Speicherort.** Eigene Hardware und eine selbst
  betriebene Cloud (Nextcloud) sind gleichrangig; fremde Cloud ist die begründete Ausnahme.
- **Embeddings werden auf eigenen Backends berechnet**, nie in fremder Cloud.
- **Bild-Erzeugung: ein gemeinsamer Weg mit Quellenwahl** (ComfyUI lokal/entfernt oder Cloud-Modell)
  statt zweier paralleler Pfade — umgesetzt über `generate_image`-Tool mit `ctx.genImageFn`.
- **Auto-Modus greift nie auf ein Cloud-Backend.**
- **Startset OpenRouter: die 21 kostenlosen Modelle** (Favoriten + Suche statt Flachliste).
- **Bild-Ausgabe nur auf expliziten Wunsch** (aktives Bildmodell), **non-streaming** transportiert.

---

## 6. Projektkonventionen

- **Test-getrieben, ohne Ausnahme.** Erst der Test, Fehlschlag beobachten, dann die Implementierung.
  Die Suite muss grün bleiben (47 Ziele).
- **Kommentare auf Deutsch; Commit-Messages und README auf Englisch.** Kommentare erklären das
  *Warum* — nicht das Was.
- **Keine echten privaten IP-Adressen im Repo** (öffentlich); Beispieladressen `192.168.1.10` / `.11`.
- **Primitive sind injizierbar** (`http`, `fileio`, Factories, `keyring`), damit Tests ohne Netz und
  ohne Desktop laufen. Mock-Muster: `tst_ollamaclient_chat.qml`, `tst_servicemanager.qml`,
  `test_keyring.cpp`, `tst_tools_generate.qml`.
- **Bei fehlenden Fakten erst fragen/recherchieren, nicht raten.** (Bsp. Bild-Streaming-Shape.)

---

## 7. Fallen, die in dieser Welle Zeit gekostet haben

- `pgrep -f llama-server` trifft die **eigene** Shell-Kommandozeile mit. `pgrep -x` verwenden.
- Qt schreibt Header-Namen kanonisch um (`HTTP-Referer` → `Http-Referer`). Tests case-insensitiv.
- `qDebug()` ist im Release-Build stumm. `fprintf(stderr, …)` für Test-Diagnose.
- In `tst_servicemanager`: nie beantworteter Mock-Runner schleppte seine Aktionssperre in den
  nächsten Test → Zustands-Isolation in `init()`.
- `git rebase --exec` + `--amend` kann zwei Commits verschmelzen/message schlucken. Historie prüfen.
- **Qt6 `QJSEngine` (6.11)**: `QJSValue::fromVariant()`, `newFunction()` existieren nicht mehr —
  `std::function`-Overloads für testbare C++-Logik (Muster: `KeyRing`).
- **`QDBusServer` ist kein vollwertiger Bus** (kein Hello-Handshake, `connectToBus` blockiert) —
  echten `dbus-daemon` als Subprozess: `--nofork --print-address=1 --session` (`test_keyring.cpp`).
- **`QDBusAbstractAdaptor` + `Q_CLASSINFO("D-Bus Interface", …)`** — ein plain QObject exportiert
  nur `local.<Klassenname>`.
- **`QT_NO_CAST_FROM_ASCII`**: in Core keine rohen `"…"`-Strings an `QString`; `QStringLiteral`.
- **Test-Isolation**: Fake-Zähler in `init()` zurücksetzen; im QML erst Zustand resetten, DANN
  Signal-Spys leeren (sonst zählt der Reset-Bump mit). QML-IDs außerhalb des Objekts nicht
  auflösbar — Test-Hooks als Properties (Muster `tst_header.qml`).