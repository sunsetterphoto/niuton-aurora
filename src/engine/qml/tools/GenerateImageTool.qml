import QtQuick
import net.niuton.aurora.engine

Tool {
    name: "generate_image"
    category: "generate"
    permissionKey: "toolGenerateImage"     // kein Config-Key (immer auto, s. Registry-Default)
    property var _onFinished: null
    property var _onFailed: null
    property var _comfy: null
    definition: ({
        "type": "function",
        "function": {
            "name": "generate_image",
            "description": "Generate an image from a text prompt using a local diffusion model. Use when the user asks you to draw, paint, create, or generate a picture or image.",
            "parameters": {
                "type": "object",
                "properties": {
                    "prompt": { "type": "string", "description": "Detailed English image description (subject, style, lighting)" },
                    "width": { "type": "integer", "description": "Image width in pixels, default 1024" },
                    "height": { "type": "integer", "description": "Image height in pixels, default 1024" }
                },
                "required": ["prompt"]
            }
        }
    })
    function describe(args) { return "Bild generieren: " + (args.prompt || "") }
    function isAvailable(ctx) { return !!(ctx.comfy && ctx.comfy.available) }

    function _disconnect() {
        if (_comfy && _onFinished) _comfy.finished.disconnect(_onFinished)
        if (_comfy && _onFailed) _comfy.failed.disconnect(_onFailed)
        _onFinished = null; _onFailed = null; _comfy = null
    }

    function execute(args, ctx, done) {
        var comfy = ctx.comfy
        if (!comfy || !comfy.available) { done("Bildgenerierung ist derzeit nicht verfügbar (ComfyUI offline).", { status: "error" }); return }
        if (comfy.busy) { done("Bildgenerierung läuft bereits — bitte warten, bis sie abgeschlossen ist.", { status: "error" }); return }

        _comfy = comfy
        _onFinished = function(imagePath, promptText) {
            _disconnect()
            done("Bild wurde erfolgreich generiert und dem Nutzer angezeigt.", { status: "ok" })
        }
        _onFailed = function(message) {
            _disconnect()
            done("Bildgenerierung fehlgeschlagen: " + message, { status: "error" })
        }
        comfy.finished.connect(_onFinished)
        comfy.failed.connect(_onFailed)
        comfy.generate({
            "prompt": args.prompt || "",
            "model": (ctx.settings && ctx.settings.comfyDefaultModel) || "z_image_turbo",
            "width": parseInt(args.width) || 1024,
            "height": parseInt(args.height) || 1024
        })
    }

    function abort() { _disconnect() }
}
