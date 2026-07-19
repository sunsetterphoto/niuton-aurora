import QtQuick
import QtTest
import "../qml/ContextCompactor.js" as CC

TestCase {
    name: "ContextCompactor"

    function _verbatim(n, len) {
        var a = []
        var s = ""; for (var k = 0; k < len; k++) s += "x"
        for (var i = 0; i < n; i++) a.push({ role: "user", content: s })
        return a
    }

    function test_estimateTokens() {
        compare(CC.estimateTokens(""), 0)
        compare(CC.estimateTokens("abcd"), 1)      // 4/4
        compare(CC.estimateTokens("abcdefgh"), 2)  // 8/4
    }

    function test_unterSchwelle_keineKompaktierung() {
        var p = CC.plan({ verbatim: _verbatim(10, 4), summary: "", systemPromptText: "",
                          numCtx: 8192, numPredict: 0, keepRecent: 6,
                          thresholdFraction: 0.75, assumedCtx: 8192, responseReserve: 1024 })
        compare(p.needsCompaction, false)
        compare(p.foldCount, 0)
    }

    function test_ueberSchwelle_kompaktiert() {
        // 30 Nachrichten a 4000 Zeichen = ~30000 Tokens, Budget ~ 8192-1024 = 7168
        var p = CC.plan({ verbatim: _verbatim(30, 4000), summary: "", systemPromptText: "",
                          numCtx: 8192, numPredict: 0, keepRecent: 6,
                          thresholdFraction: 0.75, assumedCtx: 8192, responseReserve: 1024 })
        compare(p.needsCompaction, true)
        compare(p.foldCount, 24)                   // 30 - keepRecent(6)
    }

    function test_wenigNachrichten_nieKompaktieren() {
        var p = CC.plan({ verbatim: _verbatim(4, 100000), summary: "", systemPromptText: "",
                          numCtx: 8192, numPredict: 0, keepRecent: 6,
                          thresholdFraction: 0.75, assumedCtx: 8192, responseReserve: 1024 })
        compare(p.needsCompaction, false)          // 4 <= keepRecent -> KEINE LLM-Synopse
        // Audit-Fix: aber über Budget -> stattdessen älteste Nachrichten verwerfen
        // (trimCount), mindestens 1 bleibt. 4 x 25000 Tokens: nach 3 Drops stoppt
        // die Schleife am Floor (len-1), auch wenn der Rest noch über Budget liegt.
        compare(p.trimCount, 3)
    }

    // Audit-Fix (ContextCompactor.js:30): <= keepRecent Nachrichten, aber über
    // Budget — bisher feuerte die Kompaktierung NIE (Ollama trunkierte still).
    // Jetzt: älteste Nachrichten verwerfen, bis der Rest ins Budget passt.
    function test_wenigeRiesige_trimmtAeltesteInsBudget() {
        // 4 x 10000 Zeichen = 4 x 2500 Tokens = 10000; Budget 7168, Schwelle 5376.
        // Drop 2 aelteste -> 5000 <= 5376.
        var p = CC.plan({ verbatim: _verbatim(4, 10000), summary: "", systemPromptText: "",
                          numCtx: 8192, numPredict: 0, keepRecent: 6,
                          thresholdFraction: 0.75, assumedCtx: 8192, responseReserve: 1024 })
        compare(p.needsCompaction, false)          // zu wenig Material zum Falten
        compare(p.foldCount, 0)
        compare(p.trimCount, 2)
        // Rest-Budget eingehalten: 2 x 2500 <= 0.75 * 7168
        verify(2 * 2500 <= 0.75 * p.budget)
    }

    function test_trim_nieLetzteNachrichtVerwerfen() {
        // Eine einzige riesige Nachricht (aktuelle Frage): nichts zu verwerfen,
        // bewusst kein Content-Kuerzen — Rest faellt wie bisher an Ollama.
        var p = CC.plan({ verbatim: _verbatim(1, 100000), summary: "", systemPromptText: "",
                          numCtx: 8192, numPredict: 0, keepRecent: 6,
                          thresholdFraction: 0.75, assumedCtx: 8192, responseReserve: 1024 })
        compare(p.needsCompaction, false)
        compare(p.trimCount, 0)
        // Zwei riesige: nur die aelteste faellt weg, die aktuelle bleibt.
        var p2 = CC.plan({ verbatim: _verbatim(2, 100000), summary: "", systemPromptText: "",
                           numCtx: 8192, numPredict: 0, keepRecent: 6,
                           thresholdFraction: 0.75, assumedCtx: 8192, responseReserve: 1024 })
        compare(p2.trimCount, 1)
    }

    function test_faltenSchlaegtTrimmen() {
        // > keepRecent UND ueber Budget: unveraendert der Fold-Pfad, kein Trim.
        var p = CC.plan({ verbatim: _verbatim(30, 4000), summary: "", systemPromptText: "",
                          numCtx: 8192, numPredict: 0, keepRecent: 6,
                          thresholdFraction: 0.75, assumedCtx: 8192, responseReserve: 1024 })
        compare(p.needsCompaction, true)
        compare(p.trimCount, 0)
    }

    function test_numCtxUngesetzt_nutztAssumed() {
        var p = CC.plan({ verbatim: _verbatim(30, 4000), summary: "", systemPromptText: "",
                          numCtx: 0, numPredict: 0, keepRecent: 6,
                          thresholdFraction: 0.75, assumedCtx: 8192, responseReserve: 1024 })
        compare(p.budget, 8192 - 0 - 1024)         // assumedCtx greift, responseReserve default
        compare(p.needsCompaction, true)
    }

    function test_force_kompaktiertUnterSchwelle() {
        var p = CC.plan({ verbatim: _verbatim(10, 4), summary: "", systemPromptText: "",
                          numCtx: 8192, numPredict: 0, keepRecent: 6, force: true,
                          thresholdFraction: 0.75, assumedCtx: 8192, responseReserve: 1024 })
        compare(p.needsCompaction, true)           // force, und 10 > keepRecent
        compare(p.foldCount, 4)
    }
}
