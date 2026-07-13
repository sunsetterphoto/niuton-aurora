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

    GenerateImageTool { id: genTool }

    TestCase {
        name: "GenerateImageTool"

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
