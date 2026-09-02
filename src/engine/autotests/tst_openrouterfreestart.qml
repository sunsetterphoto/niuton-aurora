import QtQuick
import QtTest
import net.niuton.aurora.engine

// Statische Whitelist der kostenlosen OpenRouter-Modelle: Der Picker zeigt
// sonst alle 425 API-Einträge. Die Tests halten die Liste konsistent (Anzahl,
// Sortierung, Felder) — Verifizierung gegen die Live-API bleibt manuell
// (Stand 02.09.2026: pricing 0/0 = 21 Einträge).
TestCase {
    name: "OpenRouterFreeStart"

    OpenRouterFreeStart { id: start }

    function test_startsetHat21Eintraege() {
        var ids = Object.keys(start.models)
        compare(ids.length, 21)
    }

    // Sortierung ist Design: der Picker zeigt die Liste so, wie sie hier
    // steht — Unsortiertes wäre Zufall.
    function test_idsSortiert() {
        var ids = Object.keys(start.models)
        for (var i = 1; i < ids.length; i++)
            verify(ids[i - 1] < ids[i], ids[i - 1] + " >= " + ids[i])
    }

    // isFree ist der Kern: nur wirklich gelistete IDs dürfen true liefern.
    function test_isFreeNurGelistete() {
        verify(start.isFree("google/gemma-4-31b-it:free"))
        verify(start.isFree("openrouter/free"))
        verify(!start.isFree("openai/gpt-4o"))
        verify(!start.isFree("google/gemma-4-31b-it"))
        verify(!start.isFree(""))
    }

    function test_metadatenProEintrag() {
        var ids = Object.keys(start.models)
        for (var i = 0; i < ids.length; i++) {
            var m = start.models[ids[i]]
            verify(typeof m.name === "string" && m.name !== "")
            verify(typeof m.contextLength === "number" && m.contextLength > 0)
        }
    }

    // Stichprobe gegen die Live-API-Werte (Stand 02.09.2026)
    function test_stichprobeMetadaten() {
        compare(start.models["openrouter/free"].name, "Free Models Router")
        compare(start.models["openrouter/free"].contextLength, 200000)
        compare(start.models["z-ai/glm-5.2:free"].name, "Z.ai: GLM 5.2")
        compare(start.models["z-ai/glm-5.2:free"].contextLength, 256000)
    }
}