.pragma library

// Grobe Token-Schätzung ohne echten Tokenizer: ~4 Zeichen je Token.
function estimateTokens(text) {
    return Math.ceil((text ? String(text).length : 0) / 4)
}

// Reine Planungs-Entscheidung für die Kontext-Kompaktierung. Kein Zustand, kein
// Modell-Aufruf — nur: passt der (Synopse + wörtliche) Verlauf ins Budget, und
// wenn nicht, wie viele der ältesten wörtlichen Nachrichten falten wir?
// opts: { verbatim:[{role,content}], summary, systemPromptText, numCtx, numPredict,
//         keepRecent, thresholdFraction, assumedCtx, responseReserve, force }
function plan(opts) {
    var keepRecent = (opts.keepRecent !== undefined) ? opts.keepRecent : 6
    var assumedCtx = opts.assumedCtx || 8192
    var responseReserve = opts.responseReserve || 1024
    var thresholdFraction = opts.thresholdFraction || 0.75
    var ctx = (opts.numCtx && opts.numCtx > 0) ? opts.numCtx : assumedCtx
    var reserve = (opts.numPredict && opts.numPredict > 0) ? opts.numPredict : responseReserve
    var budget = ctx - estimateTokens(opts.systemPromptText) - reserve
    if (budget < 1) budget = 1

    var verbatim = opts.verbatim || []
    var est = estimateTokens(opts.summary || "")
    for (var i = 0; i < verbatim.length; i++)
        est += estimateTokens(verbatim[i] ? verbatim[i].content : "")

    var over = est > thresholdFraction * budget
    var canFold = verbatim.length > keepRecent
    var needsCompaction = (over || opts.force === true) && canFold
    var foldCount = needsCompaction ? (verbatim.length - keepRecent) : 0
    return { budget: budget, estimatedTokens: est, needsCompaction: needsCompaction, foldCount: foldCount }
}
