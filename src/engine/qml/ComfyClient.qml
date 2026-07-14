import QtQuick
import net.niuton.aurora.core

// ComfyUI-Client: Workflow einreichen, /history pollen, Bild herunterladen.
Item {
    id: comfy

    property string endpoint: ""
    property bool available: false
    property bool busy: false
    property string statusText: ""
    // Vom Aufrufer VOR generate() gesetzt (params.toolInitiated) — unterscheidet
    // tool- von manuell-initiierten Generierungen auf DERSELBEN Instanz. Steuert
    // im AuroraController-Handler, ob das Bild zusätzlich in die API-History
    // geschoben wird (Tool-Weg: nein, s. appendGeneratedImage) (Task 4).
    property bool toolInitiated: false
    // Konversation, in der DIESE Generierung gestartet wurde (params.originConvId,
    // von BEIDEN Aufrufern gesetzt — manuell wie Tool). Der onFinished-Handler
    // hängt das fertige Bild nur an, wenn die Konversation unverändert ist, sonst
    // wird es verworfen (einheitlicher Guard über beide Wege, Fix 2 nach Re-Review).
    property string originConvId: ""

    // Anzeigename -> Workflow-Template in workflows/
    readonly property var models: [
        { "value": "z_image_turbo", "label": "Z-Image Turbo (schnell)" },
        { "value": "z_image", "label": "Z-Image (Qualität)" }
    ]

    signal finished(string imagePath, string promptText)
    signal failed(string message)

    property string _promptId: ""
    property string _promptText: ""
    property int _pollCount: 0
    readonly property string _imageDir: FileIO.standardPath("appData") + "/images"

    function checkAvailability() {
        if (!endpoint) { available = false; return }
        Http.getJson(endpoint + "/queue", function(res) {
            comfy.available = res.ok
        })
    }

    // Endpoint kann sich zur Laufzeit ändern (ComfyUI aus/an, Adresse editiert) —
    // ohne Neubewertung bliebe "available" bis zum nächsten activate() veraltet.
    onEndpointChanged: checkAvailability()

    // params: { prompt, model, width, height, seed (optional) }
    function generate(params) {
        if (busy) { failed("Es läuft bereits eine Generierung"); return }
        busy = true
        statusText = "Lade Workflow..."
        _promptText = params.prompt
        toolInitiated = !!params.toolInitiated
        originConvId = params.originConvId || ""

        var tplPath = FileIO.standardPath("appData") + "/workflows/" + (params.model || "z_image_turbo") + ".json"
        var tpl = FileIO.readText(tplPath, 262144)
        var wf
        try {
            if (!tpl.ok) throw new Error(tpl.error)
            wf = JSON.parse(tpl.text)
        } catch(e) {
            _fail("Workflow-Template nicht lesbar")
            return
        }
        if (!wf.pos || !wf.pos.inputs || !wf.latent || !wf.latent.inputs || !wf.sampler || !wf.sampler.inputs) {
            _fail("Workflow-Template unpassend (fehlender Node)")
            return
        }
        wf.pos.inputs.text = params.prompt
        wf.latent.inputs.width = params.width || 1024
        wf.latent.inputs.height = params.height || 1024
        wf.sampler.inputs.seed = (params.seed && params.seed > 0)
            ? params.seed : Math.floor(Math.random() * 281474976710656)
        _submit(wf)
    }

    function _submit(wf) {
        statusText = "Sende an ComfyUI..."
        Http.postJson(endpoint + "/prompt", { "prompt": wf }, function(res) {
            if (!res.ok) {
                comfy._fail("ComfyUI nicht erreichbar" + (res.status ? " (HTTP " + res.status + ")" : ""))
                return
            }
            if (!res.data || !res.data.prompt_id) {
                comfy._fail("Unerwartete Antwort von ComfyUI")
                return
            }
            comfy._promptId = res.data.prompt_id
            comfy._pollCount = 0
            comfy.statusText = "Generiere Bild..."
            pollTimer.start()
        })
    }

    Timer {
        id: pollTimer
        interval: 1500
        repeat: true
        onTriggered: comfy._poll()
    }

    function _poll() {
        _pollCount++
        if (_pollCount > 240) {   // ~6 Minuten
            _fail("Zeitüberschreitung bei der Generierung")
            return
        }
        Http.getJson(endpoint + "/history/" + _promptId, function(res) {
            if (!res.ok) return   // einzelner Poll-Fehler: nächster Tick versucht es erneut
            var entry = res.data[comfy._promptId]
            if (!entry) return
            var st = entry.status || {}
            if (st.status_str === "error") {
                comfy._fail("ComfyUI-Fehler bei der Ausführung")
                return
            }
            if (st.completed) {
                pollTimer.stop()
                for (var nid in entry.outputs) {
                    var imgs = entry.outputs[nid].images || []
                    if (imgs.length > 0) {
                        comfy._download(imgs[0])
                        return
                    }
                }
                comfy._fail("Kein Bild in der Ausgabe")
            }
        })
    }

    function _download(img) {
        statusText = "Lade Bild herunter..."
        var url = endpoint + "/view?filename=" + encodeURIComponent(img.filename)
                + "&subfolder=" + encodeURIComponent(img.subfolder || "")
                + "&type=" + (img.type || "output")
        var dest = _imageDir + "/aurora-" + Date.now() + ".png"
        Http.downloadToFile(url, dest, function(res) {
            comfy.busy = false
            comfy.statusText = ""
            if (res.ok) {
                comfy.finished(res.path, comfy._promptText)
            } else {
                comfy.failed("Bild konnte nicht gespeichert werden")
            }
            comfy.toolInitiated = false    // Lauf abgeschlossen -> Markierung zurücksetzen
        }, 60000)
    }

    function _fail(message) {
        pollTimer.stop()
        busy = false
        statusText = ""
        failed(message)
        toolInitiated = false
    }
}
