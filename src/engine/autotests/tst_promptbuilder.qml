import QtQuick
import QtTest
import "../qml/PromptBuilder.js" as PromptBuilder

Item {
    TestCase {
        name: "PromptBuilder"

        function test_containsCoreSections() {
            var p = PromptBuilder.build({
                homeDir: "/home/testuser",
                hostname: "testbox", osName: "Fedora 44", ramGB: "32 GB",
                memory: "Der Nutzer heißt Sam.",
                toolSection: "## Your Tools\n- read_file(path): ...\n"
            })
            verify(p.indexOf("Aurora") >= 0)
            verify(p.indexOf("## Your Tools") >= 0)
            verify(p.indexOf("read_file(path)") >= 0)     // aus toolSection
            verify(p.indexOf("## Rules") >= 0)
            verify(p.indexOf("/home/testuser") >= 0)       // dynamischer Home-Pfad
            verify(p.indexOf("## Context") >= 0)            // Host/OS/RAM jetzt unter ## Context
            verify(p.indexOf("testbox") >= 0)
            verify(p.indexOf("Fedora 44") >= 0)
            verify(p.indexOf("## Memory") >= 0)
            verify(p.indexOf("Der Nutzer heißt Sam.") >= 0)
        }

        function test_omitsEmptySystemAndMemory() {
            var p = PromptBuilder.build({
                homeDir: "/home/x", hostname: "", osName: "", ramGB: "",
                memory: "", toolSection: "## Your Tools\n"
            })
            verify(p.indexOf("## Context") < 0)    // keine Kontext-Felder -> kein Abschnitt
            verify(p.indexOf("## Memory") < 0)     // kein Memory -> kein Abschnitt
            verify(p.indexOf("## Your Tools") >= 0)
        }

        function test_noHardcodedHome() {
            // Der Builder nutzt den übergebenen homeDir, nicht einen fest verdrahteten Pfad.
            var p = PromptBuilder.build({ homeDir: "/home/alpha", hostname: "", osName: "",
                                          ramGB: "", memory: "", toolSection: "" })
            verify(p.indexOf("/home/alpha") >= 0)   // übergebener Pfad wird verwendet
            verify(p.indexOf("/home/beta") < 0)     // kein anderer/fest verdrahteter Pfad
        }

        function test_contextFields() {
            var p = PromptBuilder.build({
                homeDir: "/home/testuser",
                now: "Freitag, 11. Juli 2026, 14:32", timezone: "Europe/Berlin",
                locale: "de_DE", userName: "testuser",
                activeModel: "qwen3.6-27b:q4_k_m", isRemote: true,
                toolSection: "## Your Tools\n"
            })
            verify(p.indexOf("## Context") >= 0)
            verify(p.indexOf("Freitag, 11. Juli 2026, 14:32") >= 0)
            verify(p.indexOf("Europe/Berlin") >= 0)
            verify(p.indexOf("Locale: de_DE") >= 0)
            verify(p.indexOf("User: testuser") >= 0)
            verify(p.indexOf("qwen3.6-27b:q4_k_m") >= 0)
            verify(p.indexOf("(remote)") >= 0)
            verify(p.indexOf("tomorrow") >= 0)        // Datums-Regel vorhanden
            verify(p.indexOf("Environment:") >= 0)    // feste Umgebungszeile
        }

        function test_activeModelLocalAndOmit() {
            var pLocal = PromptBuilder.build({ homeDir: "/home/x", now: "X", activeModel: "gemma4:e4b", isRemote: false })
            verify(pLocal.indexOf("gemma4:e4b (local)") >= 0)
            var pNone = PromptBuilder.build({ homeDir: "/home/x", now: "X", activeModel: "" })
            verify(pNone.indexOf("Active model:") < 0)   // leeres Modell -> keine Zeile
        }

        function test_knowledgeSection() {
            var p = PromptBuilder.build({
                homeDir: "/home/x",
                knowledge: [
                    { source: "rated", question: "Wie boote ich ins BIOS?", answer: "F2 drücken." },
                    { source: "knowledge", kind: "link", title: "Fedora Downgrade",
                      url: "https://example.org/k", content: "dnf downgrade kernel" },
                    { source: "knowledge", kind: "fact", title: "Piper-Pfad", url: "", content: "aurora/piper" }
                ]
            })
            verify(p.indexOf("## Knowledge base") >= 0)
            verify(p.indexOf("- Q: Wie boote ich ins BIOS?") >= 0)
            verify(p.indexOf("  A: F2 drücken.") >= 0)
            verify(p.indexOf("Fedora Downgrade (https://example.org/k): dnf downgrade kernel") >= 0)
            verify(p.indexOf("- Piper-Pfad: aurora/piper") >= 0)
        }

        function test_knowledgeTruncation() {
            var longAnswer = ""
            for (var i = 0; i < 1000; i++) longAnswer += "a"
            var longQuestion = ""
            for (var j = 0; j < 300; j++) longQuestion += "q"
            var p = PromptBuilder.build({
                homeDir: "/home/x",
                knowledge: [{ source: "rated", question: longQuestion, answer: longAnswer }]
            })
            verify(p.indexOf("…") >= 0)
            // gekürzt: 200 bzw. 800 Zeichen + Ellipse, nicht die volle Länge
            verify(p.indexOf(longAnswer) < 0)
            verify(p.indexOf(longQuestion) < 0)
        }

        function test_noKnowledgeSection() {
            var p1 = PromptBuilder.build({ homeDir: "/home/x" })
            verify(p1.indexOf("## Knowledge base") < 0)      // opt fehlt
            var p2 = PromptBuilder.build({ homeDir: "/home/x", knowledge: [] })
            verify(p2.indexOf("## Knowledge base") < 0)      // leeres Array
        }

        function test_knowledgeNewlinesCollapsed() {
            // Rohe Umbrüche aus KB-Inhalten dürfen die Sektions-Struktur nicht
            // verwässern — sie werden zu " / " geglättet.
            var p = PromptBuilder.build({
                homeDir: "/home/x",
                knowledge: [
                    { source: "rated", question: "Zeile 1\nZeile 2", answer: "A1\n\nA2" },
                    { source: "knowledge", kind: "note", title: "Titel\nmit Umbruch", url: "", content: "c" }
                ]
            })
            verify(p.indexOf("Zeile 1 / Zeile 2") >= 0)
            verify(p.indexOf("A1 / A2") >= 0)
            verify(p.indexOf("Titel / mit Umbruch: c") >= 0)
            // keine rohen Umbrüche innerhalb eines Eintrags (nur die der Struktur)
            verify(p.indexOf("- Q: Zeile 1 / Zeile 2\n") >= 0)
        }
    }
}
