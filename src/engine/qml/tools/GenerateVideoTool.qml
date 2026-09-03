import QtQuick
import net.niuton.aurora.engine

// Videogenerierung über OpenRouter (eigene /v1/videos-API, async Job).
// Video ist ein LANGER Job (Minuten) — deshalb kehrt dieses Tool SOFORT mit
// "gestartet" zurück (Chat läuft weiter); die fertige MP4 kommt später über
// appendGeneratedVideo (AuroraController pollt und hängt sie an).
// Die Cloud ist nie automatisch: ctx.videoGenFn existiert nur, wenn OpenRouter
// aktiviert ist und der Nutzer das Tool (explizit) aufruft.
Tool {
    name: "generate_video"
    category: "generate"
    permissionKey: "toolGenerateImage"     // wie generate_image: immer auto

    property var _fn: null
    definition: ({
        "type": "function",
        "function": {
            "name": "generate_video",
            "description": "Generate a short video clip from a text prompt using a cloud video model. Use when the user asks you to create, generate, or render a video.",
            "parameters": {
                "type": "object",
                "properties": {
                    "prompt": { "type": "string", "description": "Detailed English scene description (subject, motion, lighting, style)" },
                    "duration": { "type": "integer", "description": "Duration in seconds, default 6 (model-dependent)" },
                    "aspectRatio": { "type": "string", "description": "e.g. 16:9, 9:16, 1:1; default 16:9" }
                },
                "required": ["prompt"]
            }
        }
    })
    function describe(args) { return "Video generieren: " + (args.prompt || "") }
    function isAvailable(ctx) { return !!(ctx.videoGenFn) }

    function execute(args, ctx, done) {
        if (!ctx.videoGenFn) {
            done("Videogenerierung ist derzeit nicht verfügbar (OpenRouter Cloud-Modell nicht aktiv).", { status: "error" })
            return
        }
        // originConvId wie bei Bild/ComfyUI: der Controller-Guard verwirft das
        // fertige Video, wenn die Konversation inzwischen gewechselt hat.
        ctx.videoGenFn({
            "prompt": args.prompt || "",
            "duration": parseInt(args.duration) || 6,
            "aspectRatio": args.aspectRatio || "16:9",
            "originConvId": (ctx && ctx.conversationId) || ""
        }, function(r) {
            if (r && r.ok && r.started) {
                done("Videogenerierung gestartet — das Video erscheint hier, sobald es fertig ist.", { "status": "ok", "started": true })
            } else {
                var err = (r && r.error) ? r.error : "unbekannter Fehler"
                done("Videogenerierung fehlgeschlagen: " + err, { "status": "error" })
            }
        })
    }

    function abort() { /* Job läuft serverseitig; kein lokaler Abbruch nötig */ }
}