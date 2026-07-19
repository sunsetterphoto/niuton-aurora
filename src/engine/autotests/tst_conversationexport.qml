import QtQuick
import QtTest
import "../qml/ConversationExport.js" as Export

TestCase {
    name: "ConversationExport"

    function test_filename() {
        compare(Export.filename("Mein Chat!", "20260712-143000"), "mein-chat-20260712-143000.md")
        compare(Export.filename("", "20260712-143000"), "aurora-20260712-143000.md")
    }

    // Nicht-lateinische Titel sluggen zu "" — statt der Kollision auf
    // "aurora-<ts>.md" hängt filename() dann einen stabilen Titel-Hash an.
    function test_filenameNichtLateinischBekommtHash() {
        var f1 = Export.filename("日本語のタイトル", "20260719-120000")
        verify(/^aurora-[0-9a-f]{6}-20260719-120000\.md$/.test(f1))

        // gleicher Titel -> gleicher (deterministischer) Hash
        compare(Export.filename("日本語のタイトル", "20260719-120000"), f1)

        // verschiedene Titel, gleiche Sekunde -> KEINE Dateinamens-Kollision
        var f2 = Export.filename("別のタイトル", "20260719-120000")
        verify(/^aurora-[0-9a-f]{6}-20260719-120000\.md$/.test(f2))
        verify(f2 !== f1)

        // kyrillisch ebenso
        var f3 = Export.filename("Привет мир", "20260719-120000")
        verify(/^aurora-[0-9a-f]{6}-20260719-120000\.md$/.test(f3))
        verify(f3 !== f1 && f3 !== f2)

        // lateinischer Titel: unverändert Slug OHNE Hash
        compare(Export.filename("Mein Chat", "20260719-120000"), "mein-chat-20260719-120000.md")
        // leerer Titel: unverändert generischer Name OHNE Hash
        compare(Export.filename("", "20260719-120000"), "aurora-20260719-120000.md")
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
