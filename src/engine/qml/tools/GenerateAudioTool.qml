import QtQuick
import net.niuton.aurora.engine

// Audiogenerierung über OpenRouter (Chat-API mit modalities ["text","audio"],
// freies google/lyria-Modell). Streaming-Job: Das Tool bestätigt SOFORT
// „gestartet" (kein Blockieren), die fertige WAV spielt der AuroraController
// ab und hängt eine Audio-Bubble an.
// Die Cloud ist nie automatisch: ctx.audioGenFn existiert nur, wenn OpenRouter
// aktiviert ist und der Nutzer das Tool explizit aufruft.
Tool {
    name: "generate_audio"
    category: "generate"
    permissionKey: "toolGenerateImage"     // wie generate_image/video: immer auto

    definition: ({
        "type": "function",
        "function": {
            "name": "generate_audio",
            "description": "Generate a short audio clip (music, sound, voice) from a text prompt using a cloud audio model. Use when the user asks you to create, generate, or play audio or music.",
            "parameters": {
                "type": "object",
                "properties": {
                    "prompt": { "type": "string", "description": "Detailed description of the audio to generate (style, mood, instruments)" }
                },
                "required": ["prompt"]
            }
        }
    })
    function describe(args) { return "Audio generieren: " + (args.prompt || "") }
    function isAvailable(ctx) { return !!(ctx.audioGenFn) }

    function execute(args, ctx, done) {
        if (!ctx.audioGenFn) {
            done("Audiogenerierung ist derzeit nicht verfügbar (OpenRouter Cloud-Modell nicht aktiv).", { status: "error" })
            return
        }
        ctx.audioGenFn({ "prompt": args.prompt || "",
                         "originConvId": (ctx && ctx.conversationId) || "" },
                       function(r) {
            if (r && r.ok && r.started) {
                done("Audiogenerierung gestartet — das Audio erscheint hier, sobald es fertig ist.", { "status": "ok", "started": true })
            } else {
                var err = (r && r.error) ? r.error : "unbekannter Fehler"
                done("Audiogenerierung fehlgeschlagen: " + err, { "status": "error" })
            }
        })
    }

    function abort() { /* Stream serverseitig; kein lokal-bindender Abbruch nötig */ }
}