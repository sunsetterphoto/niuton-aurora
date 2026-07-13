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
        compare(p.needsCompaction, false)          // 4 <= keepRecent, trotz Überschreitung
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
