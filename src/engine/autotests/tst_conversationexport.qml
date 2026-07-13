import QtQuick
import QtTest
import "../qml/ConversationExport.js" as Export

TestCase {
    name: "ConversationExport"

    function test_filename() {
        compare(Export.filename("Mein Chat!", "20260712-143000"), "mein-chat-20260712-143000.md")
        compare(Export.filename("", "20260712-143000"), "aurora-20260712-143000.md")
    }

    function test_toMarkdown() {
        var rows = [
            { role: "user",      content: "Hallo",      mediaPath: "" },
            { role: "assistant", content: "Hi!",        thinking: "denkintern", mediaPath: "" },
            { role: "tool",      content: "toolresult", mediaPath: "" },
            { role: "user",      content: "Bild?",      mediaPath: "/tmp/a.png" }
        ]
        var md = Export.toMarkdown(rows, { title: "T", model: "gemma4:e4b", exportedAt: "X" })
        verify(md.indexOf("# T") >= 0)
        verify(md.indexOf("gemma4:e4b") >= 0)
        verify(md.indexOf("**Du:**") >= 0)
        verify(md.indexOf("**Aurora:**") >= 0)
        verify(md.indexOf("Hallo") >= 0)
        verify(md.indexOf("Hi!") >= 0)
        verify(md.indexOf("denkintern") === -1)         // kein Thinking
        verify(md.indexOf("toolresult") === -1)         // tool-Rolle übersprungen
        verify(md.indexOf("[Bild: /tmp/a.png]") >= 0)   // Bild als Pfad-Notiz
    }

    function test_leereAssistantZeileKeinHeader() {
        var rows = [
            { role: "assistant", content: "", mediaPath: "" },       // reiner Tool-Call -> kein Header
            { role: "assistant", content: "Echte Antwort", mediaPath: "" }
        ]
        var md = Export.toMarkdown(rows, { title: "T", model: "m", exportedAt: "X" })
        // genau EIN **Aurora:**-Header (nicht zwei)
        compare(md.split("**Aurora:**").length - 1, 1)
        verify(md.indexOf("Echte Antwort") >= 0)
    }
}
