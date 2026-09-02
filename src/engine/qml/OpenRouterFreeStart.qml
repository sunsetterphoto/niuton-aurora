import QtQml

// Statische Whitelist der derzeit 21 kostenlosen OpenRouter-Modelle. Der
// Model-Picker zeigt sonst alle 425 API-Einträge flach — unbenutzbar. Diese
// Liste ist bewusst durch Edition gepflegt statt generisch-erraten; sie wird
// gegen die Live-API verifiziert (Filter: pricing 0/0, Stand 02.09.2026).
// Ein Eintrag ohne ":free"-Suffix (lyria-*) ist diskretionär kostenlos —
// deshalb zählt er hier mit.
QtObject {
    objectName: "orFreeStart"
    // id -> {name, contextLength} — Name/Kontext sind möglichst klein vom
    // Picker brauchbar, ohne die volle API-Liste zu halten.
    readonly property var models: {
        var m = {}
        var rows = [
            ["cohere/north-mini-code:free", "Cohere: North Mini Code", 256000],
            ["dots-studio/dots-3-note-preview:free", "Dots3-Note Preview", 512000],
            ["google/gemma-4-26b-a4b-it:free", "Google: Gemma 4 26B A4B", 262144],
            ["google/gemma-4-31b-it:free", "Google: Gemma 4 31B", 262144],
            ["google/lyria-3-clip-preview", "Google: Lyria 3 Clip Preview", 1048576],
            ["google/lyria-3-pro-preview", "Google: Lyria 3 Pro Preview", 1048576],
            ["inclusionai/ling-3.0-flash-fin:free", "Ling 3.0 Flash Fin", 262144],
            ["liquid/lfm-2.5-2.6b:free", "LiquidAI: LFM2.5-2.6B", 65536],
            ["minimax/minimax-m2.7:free", "MiniMax: MiniMax M2.7", 196608],
            ["minimax/minimax-m3:free", "MiniMax: MiniMax M3", 1048576],
            ["nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free", "NVIDIA: Nemotron 3 Nano Omni", 256000],
            ["nvidia/nemotron-3-super-120b-a12b:free", "NVIDIA: Nemotron 3 Super", 262144],
            ["nvidia/nemotron-3-ultra-550b-a55b:free", "NVIDIA: Nemotron 3 Ultra", 1000000],
            ["nvidia/nemotron-3.5-content-safety:free", "NVIDIA: Nemotron 3.5 Content Safety", 128000],
            ["nvidia/nemotron-3.5-lightning:free", "NVIDIA: Nemotron 3.5 Lightning", 1000000],
            ["openrouter/free", "Free Models Router", 200000],
            ["poolside/laguna-s-2.1:free", "Poolside: Laguna S 2.1", 262144],
            ["poolside/laguna-xs-2.1:free", "Poolside: Laguna XS 2.1", 262144],
            ["thinkingmachines/inkling-small:free", "Thinking Machines: Inkling Small", 1048576],
            ["thinkingmachines/inkling:free", "Thinking Machines: Inkling", 1048576],
            ["z-ai/glm-5.2:free", "Z.ai: GLM 5.2", 256000]
        ]
        for (var i = 0; i < rows.length; i++) {
            var r = rows[i]
            m[r[0]] = { "name": r[1], "contextLength": r[2] }
        }
        return m
    }
    function isFree(id) { return models[id] !== undefined }
}