import QtQuick
import QtTest
import net.niuton.aurora.engine

Item {
    // Ableitung, die nur name/execute überschreibt — testet den Vererbungs-Override
    Component {
        id: derivedComp
        Tool {
            name: "demo"
            minPermission: "confirm"
            category: "network"
            function execute(args, ctx, done) { done("echo:" + args.x) }
        }
    }

    Tool { id: baseTool }   // unveränderte Basis

    TestCase {
        name: "Tool"

        function test_defaults() {
            compare(baseTool.name, "")
            compare(baseTool.minPermission, "auto")
            compare(baseTool.category, "local")
            compare(baseTool.isAvailable({}), true)
            // Default-describe gibt den (leeren) Namen zurück
            compare(baseTool.describe({}), "")
        }

        function test_defaultExecuteReportsNotImplemented() {
            var out = null
            baseTool.execute({}, {}, function(t) { out = t })
            verify(out.indexOf("ERROR") === 0)
        }

        function test_derivedOverridesWin() {
            var d = derivedComp.createObject(null)
            compare(d.name, "demo")
            compare(d.minPermission, "confirm")
            compare(d.category, "network")
            var out = null
            d.execute({ x: "hi" }, {}, function(t) { out = t })
            compare(out, "echo:hi")
            d.destroy()
        }
    }
}
