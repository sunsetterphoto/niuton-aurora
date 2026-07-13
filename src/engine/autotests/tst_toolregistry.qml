import QtQuick
import QtTest
import net.niuton.aurora.engine

Item {
    // settings-Mock: Permission-Properties je Tool
    QtObject {
        id: settingsMock
        property string toolWebSearch: "auto"
        property string toolReadFile: "auto"
        property string toolListDir: "auto"
        property string toolWebFetch: "auto"
        property string toolWriteFile: "confirm"
        property string toolRunCommand: "confirm"
    }

    function makeCtx(comfyAvailable) {
        return {
            comfy: { available: comfyAvailable === true, busy: false,
                     generate: function() {}, finished: { connect: function(){}, disconnect: function(){} },
                     failed: { connect: function(){}, disconnect: function(){} } },
            settings: settingsMock,
            fileio: { readText: function() { return { ok: true, text: "X" } } }
        }
    }

    ToolRegistry { id: reg; settings: settingsMock }

    TestCase {
        name: "ToolRegistry"

        // Geteiltes settingsMock je Test auf Defaults zurücksetzen (Konvention wie
        // die Schwester-Suiten, z.B. tst_modelmanager.qml) — hält die Tests isoliert.
        function init() {
            settingsMock.toolWebSearch = "auto"
            settingsMock.toolReadFile = "auto"
            settingsMock.toolListDir = "auto"
            settingsMock.toolWebFetch = "auto"
            settingsMock.toolWriteFile = "confirm"
            settingsMock.toolRunCommand = "confirm"
        }

        function test_toolByName() {
            verify(reg.toolByName("read_file") !== null)
            compare(reg.toolByName("read_file").name, "read_file")
            compare(reg.toolByName("gibtsnicht"), null)
        }

        function test_permissionForNormalizesAndClamps() {
            settingsMock.toolReadFile = "auto"
            compare(reg.permissionFor("read_file"), "auto")
            settingsMock.toolReadFile = "disabled"                 // Legacy -> off
            compare(reg.permissionFor("read_file"), "off")
            settingsMock.toolReadFile = ""                          // leer -> auto
            compare(reg.permissionFor("read_file"), "auto")
            settingsMock.toolWriteFile = "auto"                     // harte Klammer
            compare(reg.permissionFor("write_file"), "confirm")
            settingsMock.toolWriteFile = "off"                      // off darf strenger sein
            compare(reg.permissionFor("write_file"), "off")
            settingsMock.toolRunCommand = "auto"
            compare(reg.permissionFor("run_command"), "confirm")
        }

        function test_permissionForUnknown() {
            compare(reg.permissionFor("gibtsnicht"), "off")   // unbekannt -> off (Modell sieht es nicht)
        }

        function test_definitionsFilterOff() {
            settingsMock.toolReadFile = "off"
            settingsMock.toolWebSearch = "auto"
            var defs = reg.definitions(makeCtx(false))
            var names = defs.map(function(d) { return d.function.name })
            verify(names.indexOf("web_search") >= 0)
            verify(names.indexOf("read_file") < 0)             // off gefiltert (init() setzt zurück)
        }

        function test_definitionsFilterUnavailable() {
            var defsNo = reg.definitions(makeCtx(false)).map(function(d) { return d.function.name })
            verify(defsNo.indexOf("generate_image") < 0)       // Comfy offline
            var defsYes = reg.definitions(makeCtx(true)).map(function(d) { return d.function.name })
            verify(defsYes.indexOf("generate_image") >= 0)     // Comfy online
        }

        function test_executeDispatches() {
            var out = null
            reg.execute("read_file", { path: "/x" }, makeCtx(false), function(t) { out = t })
            compare(out, "X")
        }

        function test_executeUnknownTool() {
            var out = null
            reg.execute("halluzi", {}, makeCtx(false), function(t) { out = t })
            verify(out.indexOf("Unbekanntes Tool") >= 0)
        }

        function test_describeDispatches() {
            compare(reg.describe("read_file", { path: "/a" }), "Datei lesen: /a")
        }

        function test_promptSectionListsAvailableTools() {
            var s = reg.promptSection(makeCtx(false))
            verify(s.indexOf("read_file") >= 0)
            verify(s.indexOf("web_search") >= 0)
            verify(s.indexOf("generate_image") < 0)            // offline -> nicht gelistet
            settingsMock.toolReadFile = "off"
            var s2 = reg.promptSection(makeCtx(false))
            verify(s2.indexOf("read_file(") < 0)               // off -> nicht gelistet (init() setzt zurück)
        }
    }
}
