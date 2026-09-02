# Übergabe: Backend-Registry, KWallet und OpenRouter

Stand: 02.09.2026 · Branch `feature/openai-backend`

Dieses Dokument ist der Kontext für die Weiterarbeit (z.B. mit opencode/DeepSeek). Es beschreibt,
wo das Projekt steht, was unmittelbar zu tun ist und welche Konventionen gelten.

---

## 1. Sofortlage

```
Branch:   feature/openai-backend  (8 Commits, gepusht nach origin)
main:     unberührt bei c2ac749
```

**Testlage: 45 von 45 Testzielen grün** (davon `tst_modelmanager` 29/29, `tst_keyring` 8/8).

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
- **Fehlersemantik**: Abwesenheit eines Eintrags ist `ok:true` mit leerem `secret` (kein Fehler);
  Open-Fehler (vom Nutzer verneint / Wallet zu) sind echte Fehler; `walletClosed` invalidiert den
  Handle-Cache (nächster Zugriff öffnet neu); parallele Anfragen während des Öffnens werden gequeued.
- **Testbarkeit**: D-Bus-Connection injizierbar; `test_keyring.cpp` startet einen privaten
  `dbus-daemon` (Subprozess) mit Fake-kwalletd6 als `QDBusAbstractAdaptor` (exportiert die echte
  `org.kde.KWallet`-Schnittstelle). Läuft ganz ohne Desktop-Session.
- **UI**: KCM-Sektion „OpenRouter (Cloud)" in `ConfigModels.qml` — explizites Opt-in + Schlüsselfeld
  (schreibt ins Wallet, zeigt den Wert nie, `echoMode: PasswordEchoOnEdit`).

---

## 3. Nächster Schritt: Phase 3 — OpenRouter als Backend

Die Phase braucht die bisherige Arbeit (Registry + KeyRing):

1. **Auth-Header**: der `OpenAiClient` braucht für Cloud-Backends einen
   `Authorization: Bearer <key>`-Header. `Http` und `NdjsonStream.post()` können bereits Header —
   es fehlt die Verdrahtung: `OpenAiClient` bekommt ein injizierbares `keyring` und ein `keyRef`
   (vom ModelManager aus der Registry durchgereicht), löst den Schlüssel asynchron auf und hängt
   den Header an `refreshModels/chat/embed` an.
2. **Favoriten plus Suche**: die OpenRouter-API liefert **423 Modelle**; eine flache Liste im Picker
   ist unbenutzbar. Startset laut Nutzerentscheidung: die **21 kostenlosen Modelle**. Suche im Picker
   (filtert die Cloud-Gruppe), Favoriten als Config-Key.
3. Modell-Metadaten (Kontextlänge, Preis) — nur was der Picker braucht.

**Achtung:** der OpenRouter-Schlüssel liegt noch nicht vor — Phase 3 ist nur gegen die
API-Dokumentation baubar, nicht gegen die echte API verifizierbar.

Danach:

- **Phase 4 — Eingabe-Modalitäten**: Anhänge im Ollama-Format (`message.images` als Base64-Liste)
  vs. OpenAI `content`-Array mit `image_url`. Das Mapping gehört in den `OpenAiClient`, nicht in den
  `ChatController`. (254 der 423 Modelle können Bild-Eingabe.)
- **Phase 5 — Ausgabe und Kosten**: Bild-Ausgabe (11 Modelle) in dieselbe Blase wie ComfyUI-Bilder;
  `usage.cost` je Antwort mitschreiben.

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

Zwei Sackgassen, die nicht erneut geprüft werden müssen:

- **Ollama kann Bonsai nicht laden.** Verifiziert: Ollamas `libggml` kennt `q2_K`, `tq1_0`, `tq2_0`,
  aber **kein `q2_0`**. Deshalb der Umweg über `llama-server` und der ganze `OpenAiClient`.
- **Der PrismML-Fork bringt nichts.** Gemessen: mit `g64` 72,2/6,7 (also minimal langsamer als
  upstream), mit seiner eigenen `g128`-Variante 7,6/2,1 — Faktor 10 schlechter beim Prefill, die
  g128-Kernel sind auf Vulkan nicht optimiert. **Bei upstream llama.cpp + `_g64` bleiben.**
- **Spekulatives Decoding scheitert am Drafter.** Upstream kennt die Architektur `dspark` nicht; der
  Fork kennt sie, stolpert aber über die Tensor-Offsets (`dspark.fc.weight has offset 337718592,
  expected 357584192`) — Fork-HEAD und veröffentlichte Datei passen nicht zusammen. Abhaken, bis
  PrismML nachzieht.

---

## 5. Vom Nutzer getroffene Festlegungen

- **Datensouveränität ist die Leitlinie, nicht der Speicherort.** Eigene Hardware und eine selbst
  betriebene Cloud (Nextcloud) sind gleichrangig; fremde Cloud ist die begründete Ausnahme. Daraus
  folgte der konfigurierbare `dataPath`.
- **Embeddings werden auf eigenen Backends berechnet**, nie in fremder Cloud. Der Speicherort der
  Datenbank ist davon unabhängig und frei wählbar.
- **Bild-Erzeugung: ein gemeinsamer Weg mit Quellenwahl** (ComfyUI lokal/entfernt oder Cloud-Modell)
  statt zweier paralleler Pfade.
- **Auto-Modus greift nie auf ein Cloud-Backend.**
- **Startset OpenRouter: die 21 kostenlosen Modelle** (Favoriten + Suche statt Flachliste).

---

## 6. Projektkonventionen

- **Test-getrieben, ohne Ausnahme.** Erst der Test, Fehlschlag beobachten, dann die Implementierung.
  Die Suite muss grün bleiben.
- **Kommentare auf Deutsch, Commit-Messages und README auf Englisch.** Kommentare erklären das
  *Warum* (oft mit dem Bug, der zu der Zeile führte) — nicht das Was.
- **Keine echten privaten IP-Adressen im Repo.** Das Repo ist öffentlich; Beispieladressen sind
  `192.168.1.10` / `.11`. In einer früheren Session wurde die Historie deshalb einmal umgeschrieben.
- **Primitive sind injizierbar** (`http`, `fileio`, Factories, `keyring`), damit Tests ohne Netz und
  ohne `systemctl`/Desktop laufen. Siehe die Mock-Muster in `tst_ollamaclient_chat.qml`,
  `tst_servicemanager.qml` und `test_keyring.cpp`.

### Build und Test

```bash
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build --output-on-failure

# Einzelnes Ziel, mit Namen der Testfunktionen:
ctest --test-dir build -R modelmanager -V 2>&1 | grep -E "PASS|FAIL"

# Installieren (baut, testet, startet plasmashell neu):
./install.sh
```

**Achtung:** `ctest` baut nicht selbst. Nach einer QML-Änderung erst `cmake --build build`, sonst
läuft der Test gegen das alte Modul.

---

## 7. Offene Punkte beim Nutzer

- **Backup-Branch `backup/vor-ip-bereinigung`** existiert nur lokal und enthält die alte Fassung
  **mit echten LAN-IPs**. Nicht pushen. Löschen, sobald der aktuelle Stand abgenommen ist.
- **OpenRouter-Schlüssel** liegt noch nicht vor. Ohne ihn lässt sich Phase 3 nur nach Dokumentation
  bauen statt gegen die echte API zu verifizieren.
- **Pull Request** für `feature/openai-backend` ist noch nicht eröffnet.
- **Ausstehende Hardware-Verifikation**: ComfyUI auf einem anderen Rechner im LAN war beim Test
  nicht erreichbar (Gerät aus). Der Eintrag zeigt dann korrekt „nicht erreichbar (anderer Rechner)".

---

## 8. Fallen, die in dieser Welle Zeit gekostet haben

- `pgrep -f llama-server` trifft die **eigene** Shell-Kommandozeile mit und killt die Session.
  `pgrep -x llama-server` verwenden.
- Qt schreibt Header-Namen kanonisch um (`HTTP-Referer` → `Http-Referer`). RFC-konform; Tests
  müssen case-insensitiv vergleichen.
- `qDebug()` ist im Release-Build stumm. Für Test-Diagnose `fprintf(stderr, ...)` nutzen.
- In `tst_servicemanager` musste eine Zustands-Isolation in `init()` ergänzt werden: ein nie
  beantworteter Mock-Runner schleppte seine Aktionssperre (`busyOf`) in den nächsten Test.
- `git rebase --exec` mit `git commit --amend` kann zwei Commits verschmelzen und eine
  Commit-Message verschlucken. Beim Umschreiben der Historie hinterher `git log` prüfen.
- **Qt6 `QJSEngine` (6.11)**: `QJSValue::fromVariant()`, `QJSValue::newFunction()` und
  `QJSEngine::newFunction()` existieren nicht mehr — für testbare C++-Logik `std::function`-Overloads
  anbieten statt via QJSValue zu testen (Muster: `KeyRing`).
- **`QDBusServer` ist kein vollwertiger Bus**: er beantwortet keinen `Hello`-Handshake —
  `connectToBus` blockiert. Für D-Bus-Tests einen echten `dbus-daemon` als Subprozess starten
  (`--nofork --print-address=1 --session`), siehe `test_keyring.cpp`.
- **QDBusAbstractAdaptor respektiert `Q_CLASSINFO("D-Bus Interface", ...)`** — ein plain QObject
  exportiert nur `local.<Klassenname>`; ohne den Adaptor findet der Client die Schnittstelle nicht.
- **`QT_NO_CAST_FROM_ASCII`** (KF6-Kompilat): in Core-Quellen keine rohen `"..."`-Strings an
  `QString`-Parameter; `QStringLiteral` verwenden.
- **Env-Variablen in Tests**: `openCalls` und ähnliche Fake-Zähler in `init()` zurücksetzen, sonst
  schleppt ein Test Zustand in den nächsten (Interferenz nur in der Gesamtsuite, isoliert grün).