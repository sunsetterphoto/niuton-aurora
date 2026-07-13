import QtQuick
import QtTest
import "../qml/Commands.js" as Commands

TestCase {
    name: "Commands"

    function test_list_undFind() {
        var l = Commands.list()
        verify(l.length >= 7)
        compare(Commands.find("model").argSource, "models")
        compare(Commands.find("new").argSource, "")
        compare(Commands.find("model").takesArg, true)
        compare(Commands.find("image").takesArg, false)
        verify(Commands.find("nope") === null)
        compare(Commands.find("export").takesArg, false)
        verify(Commands.find("export") !== null)
        compare(Commands.find("knowledge").takesArg, false)
        verify(Commands.find("knowledge") !== null)
    }

    function test_parse() {
        var a = Commands.parse("/model gemma4:e4b")
        compare(a.name, "model"); compare(a.arg, "gemma4:e4b")
        var b = Commands.parse("/new")
        compare(b.name, "new"); compare(b.arg, "")
        var c = Commands.parse("/model")
        compare(c.name, "model"); compare(c.arg, "")
        var d = Commands.parse("/search Kino morgen")
        compare(d.name, "search"); compare(d.arg, "Kino morgen")
        verify(Commands.parse("hallo") === null)
        verify(Commands.parse("") === null)
    }
}
