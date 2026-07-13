import QtQuick
import QtTest
import net.niuton.aurora.ui

Item {
    id: root
    width: 400; height: 500
    property string removed: ""
    property int closes: 0

    KnowledgeView {
        id: view
        anchors.fill: parent
        manualEntries: [
            { "id": "k1", "kind": "link", "title": "Fedora Downgrade", "url": "https://example.org/k",
              "content": "dnf downgrade kernel", "hasEmbedding": true, "createdAt": "2026-07-13T09:00:00", "updatedAt": "2026-07-13T09:00:00" },
            { "id": "k2", "kind": "note", "title": "Piper-Pfad", "url": "",
              "content": "aurora/piper", "hasEmbedding": false, "createdAt": "2026-07-13T08:00:00", "updatedAt": "2026-07-13T08:00:00" }
        ]
        examples: [
            { "id": "a1", "question": "Frage eins", "answer": "Antwort eins", "model": "gemma4:e4b", "createdAt": "2026-07-12T10:00:00", "hasEmbedding": true },
            { "id": "a2", "question": "Frage zwei", "answer": "Antwort zwei", "model": "qwen3.5:9b", "createdAt": "2026-07-12T11:00:00", "hasEmbedding": false }
        ]
        onRemoveRequested: function(id) { root.removed = id }
        onCloseRequested: root.closes++
    }

    SignalSpy { id: addSpy; target: view; signalName: "addRequested" }
    SignalSpy { id: editSpy; target: view; signalName: "editRequested" }

    TestCase {
        name: "KnowledgeView"
        when: windowShown

        function test_bindetBeispiele() {
            compare(view.examples.length, 2)
        }
        function test_bindetManuelleEintraege() {
            compare(view.manualEntries.length, 2)
        }
        function test_kuerzenHelfer() {
            compare(view._short("  a   b  ", 10), "a b")
            compare(view._short("abcdefghij", 3), "abc…")
        }
        function test_datumHelfer() {
            verify(view._pretty("2026-07-12T10:00:00").indexOf("12.07.2026") === 0)
            compare(view._pretty("kaputt"), "")
        }
        function test_kindHelfer() {
            compare(view._kindLabel("link"), "Link")
            compare(view._kindLabel("note"), "Notiz")
            compare(view._kindLabel("fact"), "Fakt")
            compare(view._kindIndex("fact"), 2)
            verify(view._kindIcon("link") !== "")
            verify(view._kindIcon("note") !== "")
            verify(view._kindIcon("fact") !== "")
        }
        function test_canSave() {
            verify(!view._canSave("", ""))
            verify(!view._canSave("   ", "  "))
            verify(view._canSave("Titel", ""))
            verify(view._canSave("", "Inhalt"))
        }
        function test_startAdd_undStartEdit_setzenModus() {
            view._startEdit({ "id": "x", "kind": "fact", "title": "T", "url": "U", "content": "C" })
            compare(view._editingId, "x")
            compare(view._formOpen, true)
            view._startAdd()
            compare(view._editingId, "")
            compare(view._formOpen, true)
        }
        function test_emitSave_neu_feuertAddRequested() {
            view._startAdd()
            addSpy.clear()
            view._emitSave("link", "Titel", "http://x", "Inhalt")
            compare(addSpy.count, 1)
            compare(addSpy.signalArguments[0][0], "link")
            compare(addSpy.signalArguments[0][1], "Titel")
            compare(addSpy.signalArguments[0][2], "http://x")
            compare(addSpy.signalArguments[0][3], "Inhalt")
            compare(view._formOpen, false)
        }
        function test_emitSave_bearbeiten_feuertEditRequested() {
            view._startEdit({ "id": "e9", "kind": "note", "title": "alt", "url": "", "content": "alt" })
            editSpy.clear()
            view._emitSave("note", "neu", "", "neu-inhalt")
            compare(editSpy.count, 1)
            compare(editSpy.signalArguments[0][0], "e9")
            compare(editSpy.signalArguments[0][1], "note")
            compare(editSpy.signalArguments[0][2], "neu")
            compare(view._editingId, "")
        }
        function test_emitSave_leer_feuertNicht() {
            view._startAdd()
            addSpy.clear()
            view._emitSave("link", "", "", "")
            compare(addSpy.count, 0)
        }
    }
}
