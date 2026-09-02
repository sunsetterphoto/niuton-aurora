import QtQuick
import QtTest
import net.niuton.aurora.engine

Item {
    // Mock-Comfy mit steuerbaren Signalen
    Component {
        id: comfyComp
        QtObject {
            property bool available: true
            property bool busy: false
            property var lastOpts: null
            signal finished(string imagePath, string promptText)
            signal failed(string message)
            function generate(opts) { lastOpts = opts }
        }
    }

    function makeCtx(comfy) {
        return { comfy: comfy, settings: { comfyDefaultModel: "z_image_turbo" } }
    }

    // Cloud-Weg: ctx.genImageFn ist gesetzt (aktives Bildmodell) → das Tool
    // nutzt die Cloud statt ComfyUI. Funktion ruft cb({ok, images, error}).
    function makeCloudCtx(comfy, cloudFn) {
        var ctx = makeCtx(comfy)
        ctx.genImageFn = cloudFn
        return ctx
    }

    GenerateImageTool { id: genTool }

    property var cloudOut: null
    property var cloudEx: null

    TestCase {
        name: "GenerateImageTool"

        function init() { cloudOut = null; cloudEx = null }

        function test_metadata() {
            compare(genTool.name, "generate_image")
            compare(genTool.category, "generate")
        }

        function test_isAvailableFollowsComfy() {
            var c = comfyComp.createObject(null); c.available = false
            compare(genTool.isAvailable(makeCtx(c)), false)
            c.available = true
            compare(genTool.isAvailable(makeCtx(c)), true)
            c.destroy()
        }

        function test_cloudWegNutztGenImageFnStattComfy() {
            var c = comfyComp.createObject(null)
            var cloudArgs = null
            var cloudDone = null
            var ctx = makeCloudCtx(c, function(args, done) { cloudArgs = args; cloudDone = done })
            var out = null
            genTool.execute({ prompt: "a cat" }, ctx, function(t) { out = t })
            compare(cloudArgs.prompt, "a cat")
            compare(c.lastOpts, null)                  // ComfyUI NICHT angerufen
            cloudDone({ "ok": true, "images": ["data:image/png;base64,AAA"] })
            verify(out.indexOf("erfolgreich") >= 0)
            c.destroy()
        }

        function test_cloudWegFehlerMeldetError() {
            var c = comfyComp.createObject(null)
            var cloudDone = null
            genTool.execute({ prompt: "x" }, makeCloudCtx(c, function(args, done) { cloudDone = done }),
                function(t, extra) { cloudOut = t; cloudEx = extra })
            cloudDone({ "ok": false, "images": [], "error": "Cloud 401" })
            verify(cloudOut.indexOf("fehlgeschlagen") >= 0)
            verify(cloudOut.indexOf("Cloud 401") >= 0)
            compare(cloudEx.status, "error")
            c.destroy()
        }

        function test_cloudWegErstWennGenImageFnGesetzt() {
            var c = comfyComp.createObject(null)
            var out = null
            genTool.execute({ prompt: "x" }, makeCtx(c), function(t) { out = t })
            compare(c.lastOpts.prompt, "x")            // weiterhin ComfyUI-Pfad
            c.destroy()
        }

        function test_generateSuccess() {
            var c = comfyComp.createObject(null)
            var out = null
            genTool.execute({ prompt: "a cat", width: 512 }, makeCtx(c), function(t) { out = t })
            compare(c.lastOpts.prompt, "a cat")
            compare(c.lastOpts.model, "z_image_turbo")
            compare(c.lastOpts.width, 512)
            compare(c.lastOpts.height, 1024)      // Default
            c.finished("/path/img.png", "a cat")
            verify(out.indexOf("erfolgreich") >= 0)
            c.destroy()
        }

        function test_generateFailure() {
            var c = comfyComp.createObject(null)
            var out = null, ex = null
            genTool.execute({ prompt: "x" }, makeCtx(c), function(t, extra) { out = t; ex = extra })
            c.failed("MPS OOM")
            verify(out.indexOf("fehlgeschlagen") >= 0)
            verify(out.indexOf("MPS OOM") >= 0)
            compare(ex.status, "error")
            c.destroy()
        }

        function test_busyRejects() {
            var c = comfyComp.createObject(null); c.busy = true
            var out = null
            genTool.execute({ prompt: "x" }, makeCtx(c), function(t) { out = t })
            verify(out.indexOf("läuft bereits") >= 0)
            compare(c.lastOpts, null)     // kein generate() aufgerufen
            c.destroy()
        }

        function test_unavailableRejects() {
            var c = comfyComp.createObject(null); c.available = false
            var out = null
            genTool.execute({ prompt: "x" }, makeCtx(c), function(t) { out = t })
            verify(out.indexOf("nicht verfügbar") >= 0)
            c.destroy()
        }

        function test_onlyOneDoneOnDoubleSignal() {
            var c = comfyComp.createObject(null)
            var count = 0
            genTool.execute({ prompt: "x" }, makeCtx(c), function(t) { count++ })
            c.finished("/a.png", "x")
            c.finished("/a.png", "x")     // zweites Signal darf done nicht erneut auslösen
            compare(count, 1)
            c.destroy()
        }
    }
}
