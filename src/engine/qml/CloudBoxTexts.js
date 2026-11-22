.pragma library

// Texte des Cloud-Rechners — Werkzeug-Beschreibungen fürs Modell (englisch) und
// Fehlertexte (deutsch). Die Werkzeug-Beschreibungen sind WÖRTLICH aus der
// gemeinsamen Quelle der Apps übernommen (Mobile-Engine, CloudBoxTexts.kt), damit
// das Modell in Web, Android und KDE dieselbe Anleitung bekommt. Bei Änderungen
// dort hier nachziehen.
// previewDomain leer = Domain unbekannt (vor der ersten Verbindung).

var MACHINE = "your own isolated Linux machine, the cloud computer (German: 'Cloud-Rechner'; Debian, user 'aurora', working directory /work which persists between runs)"

function _hosts(previewDomain) {
    return (!previewDomain) ? "server.allowedHosts: true" : "server.allowedHosts ['." + previewDomain + "']"
}

function runCommand(previewDomain) {
    return "Run a bash command in " + MACHINE + ". You may work freely there: create projects, install packages with npm/pip/apt-less tools "
        + "(internet via HTTP/HTTPS only; no access to the user's home network or other machines), run builds and tests. "
        + "Start long-running servers in the background so the command returns, e.g. "
        + "`nohup npm run dev -- --host 0.0.0.0 --port 5173 > dev.log 2>&1 &`, then call preview(port). "
        + "Dev servers must listen on 0.0.0.0 (port >= 1024) and accept foreign host names (Vite: server.host '0.0.0.0', "
        + _hosts(previewDomain) + "). The machine sleeps when idle; afterwards background servers are gone. "
        + "After starting a dev server run exactly ONE quick self-test (`curl -sI http://localhost:<port>/`), then call preview — no further check commands. "
        + "Never use run_command to work around web_fetch: if web_fetch reports a blocked or unreachable address, tell the user that "
        + "this address is not reachable/blocked instead of trying curl here. "
        + "Output is limited (the end is kept). Default timeout 120 s, max 900 s."
}

var READ_FILE = "Read a text file in " + MACHINE + ". Path relative to /work."
var WRITE_FILE = "Create or overwrite a file in " + MACHINE + ". Path relative to /work; parent folders are created."
var LIST_DIR = "List a directory in " + MACHINE + ". Path relative to /work (empty = /work)."

// Abweichung von der Web-Fassung: Die KDE-Version hat keine Arbeitsfläche neben
// dem Chat — die Vorschau öffnet sich im Standard-Browser. Der Rest ist wörtlich.
function preview(previewDomain) {
    return "Show a web app that runs in " + MACHINE + " to the user; it opens in the user's default web browser. Start the server first in the "
        + "background, listening on 0.0.0.0 and a port 1024-65535 and allowing "
        + ((!previewDomain) ? "foreign host names (Vite: server.allowedHosts: true)"
                            : "the host names *." + previewDomain + " (Vite: server.allowedHosts ['." + previewDomain + "'])")
        + ", then call preview with that port. After the machine has slept "
        + "the server is no longer running: check it (e.g. curl -sI http://localhost:<port>/) and restart it before calling "
        + "preview. The optional name gives the app a stable address (same name = same address)."
}

var SCREENSHOT = "Take a screenshot of a web page with Chromium in " + MACHINE + " (usually http://localhost:<port>/ of an app you started) "
    + "and show it in the chat. Use it to check your own work visually."

// Werkzeug-Definition im OpenAI/Ollama-Format; params = [[name, typ, beschreibung, pflicht], …]
function def(name, description, params) {
    var props = {}
    var required = []
    for (var i = 0; i < params.length; i++) {
        props[params[i][0]] = { "type": params[i][1], "description": params[i][2] }
        if (params[i][3]) required.push(params[i][0])
    }
    return { "type": "function",
             "function": { "name": name, "description": description,
                           "parameters": { "type": "object", "properties": props, "required": required } } }
}

var RUN_COMMAND_PARAMS = [
    ["cmd", "string", "The bash command", true],
    ["cwd", "string", "Working directory relative to /work (optional)", false],
    ["timeout_s", "integer", "Timeout in seconds, 1-900 (optional, default 120)", false]
]
var READ_FILE_PARAMS = [["path", "string", "File path relative to /work", true]]
var WRITE_FILE_PARAMS = [["path", "string", "File path relative to /work", true],
                         ["content", "string", "Complete file content", true]]
var LIST_DIR_PARAMS = [["path", "string", "Directory relative to /work (optional)", false]]
var PREVIEW_PARAMS = [["port", "integer", "Port the app listens on (1024-65535)", true],
                      ["name", "string", "Short app name (optional)", false]]
var SCREENSHOT_PARAMS = [["url", "string", "URL to open, e.g. http://localhost:5173/", true]]

// Werkzeug-Antwort, wenn Adresse/Schlüssel fehlen. Bewusst KEIN Rückfall auf
// den eigenen Rechner: im Modus „Cloud-Rechner" läuft lokal nichts.
var NOT_SET_UP = "(Der Cloud-Rechner ist nicht eingerichtet: Server-Adresse oder Geräte-Schlüssel fehlen in den Einstellungen. "
    + "Sag dem Nutzer, er soll ihn unter Einstellungen → Cloud-Rechner eintragen. Befehle und Dateien laufen nicht auf diesem Rechner.)"

// Fehler der App-API ({status, code, message, retryAfterS}) als verständlicher
// Werkzeug-Text fürs Modell (Fassung der Apps, CloudBoxTool.errorText).
function errorText(e) {
    e = e || {}
    var status = e.status || 0
    var code = e.code || ""
    var msg = e.message || ""
    if (code === "no_key" || code === "not_configured") return NOT_SET_UP
    if (status === 401 || code === "unauthorized" || code === "device_unauthorized")
        return "Fehler: Der Geräte-Schlüssel wurde nicht angenommen (widerrufen oder falsch). Sag dem Nutzer, er soll in den Einstellungen → Cloud-Rechner einen neuen Schlüssel eintragen."
    if (code === "box_disabled") return "Fehler: Der Cloud-Rechner ist für dieses Konto abgeschaltet."
    if (code === "box_blocked" || status === 423) return "Fehler: Der Cloud-Rechner ist für heute gesperrt (Tageslaufzeit/-menge erreicht)."
    if (code === "too_many_execs") return "Fehler: Zu viele gleichzeitige Befehle in diesem Cloud-Rechner — bitte warten, bis einer fertig ist."
    if (status === 429 || code === "too_many_requests")
        return "Fehler: Zu viele Anfragen an den Cloud-Rechner" + (e.retryAfterS ? " — in " + e.retryAfterS + " Sekunden erneut versuchen" : "") + "."
    if (code === "too_large" || status === 413) return "Fehler: zu groß (Dateien höchstens 20 MB; große Ausgaben in eine Datei schreiben und gezielt lesen)."
    if (code === "invalid_path") return "Fehler: ungültiger Pfad (nur relativ zu /work, kein '..')."
    if (code === "not_found" || status === 404) return "Fehler: nicht gefunden."
    if (code === "preview_not_ready") return "Die Vorschau-Adresse wird noch eingerichtet (Zertifikat), in etwa einer Minute erneut öffnen."
    if (code === "too_many_previews") return "Fehler: Höchstzahl der Vorschauen erreicht — erst eine alte Vorschau löschen oder denselben Namen wiederverwenden."
    if (code === "too_many_new_names") return "Fehler: Heute sind keine neuen Vorschau-Namen mehr möglich — einen bestehenden Namen wiederverwenden."
    if (code === "unreachable") return "Fehler: Der Server des Cloud-Rechners ist nicht erreichbar (keine Verbindung?). " + msg
    if (code === "timeout") return "Fehler: Der Server des Cloud-Rechners hat nicht rechtzeitig geantwortet. Bei Bedarf erneut versuchen."
    if (code === "stream_broken") return "Fehler: Die Verbindung zum Cloud-Rechner ist abgerissen; das Ergebnis ist unvollständig. Bei Bedarf erneut versuchen."
    if (code === "box_unavailable" || status >= 500) return "Fehler: Der Cloud-Rechner ist gerade nicht erreichbar."
    return "Fehler im Cloud-Rechner (" + code + "): " + msg
}

// Kurzfassung für die Einstellungsseite („Verbindung prüfen").
function userMessage(e) {
    e = e || {}
    if (e.code === "unreachable") return "Server nicht erreichbar"
    if (e.code === "timeout") return "Server antwortet nicht (Zeitüberschreitung)"
    if (e.code === "invalid_endpoint") return "Ungültige Server-Adresse (muss mit https:// beginnen)"
    if (e.code === "no_key") return "Kein Geräte-Schlüssel eingetragen"
    if (e.status === 401 || e.code === "unauthorized")
        return "Schlüssel ungültig oder widerrufen — im Web unter Einstellungen → Geräte einen neuen erzeugen"
    if (e.code === "box_disabled") return "Cloud-Rechner ist für dieses Konto abgeschaltet"
    if (e.status === 429 || e.code === "too_many_requests") return "Zu viele Anfragen — bitte kurz warten"
    return e.message || ("Fehler " + (e.code || e.status || ""))
}
