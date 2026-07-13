import QtQuick
import QtTest
import net.niuton.aurora.engine

Item {
    // Mock-ctx: zeichnet Aufrufe auf und liefert vorgegebene Rückgaben
    function makeCtx(cfg) {
        return {
            calls: [],
            fileio: {
                _cfg: cfg || {},
                readText: function(path, maxBytes) {
                    return (cfg && cfg.readText) ? cfg.readText(path, maxBytes)
                                                 : { ok: true, text: "INHALT" }
                },
                writeText: function(path, content) {
                    return (cfg && cfg.writeText) ? cfg.writeText(path, content)
                                                  : { ok: true }
                },
                listDir: function(path, showHidden) {
                    return (cfg && cfg.listDir) ? cfg.listDir(path, showHidden)
                                                : { ok: true, entries: [] }
                }
            }
        }
    }

    ReadFileTool { id: readTool }
    ListDirectoryTool { id: listTool }
    WriteFileTool { id: writeTool }

    TestCase {
        name: "FileIOTools"

        function test_metadata() {
            compare(readTool.name, "read_file")
            compare(readTool.category, "local")
            compare(readTool.permissionKey, "toolReadFile")
            compare(writeTool.name, "write_file")
            compare(writeTool.minPermission, "confirm")   // harte Klammer
            compare(writeTool.category, "local")
            compare(listTool.name, "list_directory")
            // Definition hat die richtige Form für Ollama
            compare(readTool.definition.type, "function")
            compare(readTool.definition.function.name, "read_file")
        }

        function test_readOk() {
            var out = null
            readTool.execute({ path: "/etc/hostname" }, makeCtx(), function(t) { out = t })
            compare(out, "INHALT")
        }

        function test_readError() {
            var ctx = makeCtx({ readText: function() { return { ok: false, error: "ENOENT" } } })
            var out = null
            readTool.execute({ path: "/nope" }, ctx, function(t) { out = t })
            verify(out.indexOf("Fehler") >= 0)
            verify(out.indexOf("ENOENT") >= 0)
        }

        function test_readCappedTo5000() {
            var big = ""
            for (var i = 0; i < 6000; i++) big += "x"
            var ctx = makeCtx({ readText: function() { return { ok: true, text: big } } })
            var out = null
            readTool.execute({ path: "/big" }, ctx, function(t) { out = t })
            compare(out.length, 5000)
        }

        function test_listFormatsEntries() {
            var ctx = makeCtx({ listDir: function() { return { ok: true, entries: [
                { name: "a.txt", isDir: false, size: 12 },
                { name: "sub", isDir: true, size: 0 }
            ] } } })
            var out = null
            listTool.execute({ path: "/home" }, ctx, function(t) { out = t })
            verify(out.indexOf("a.txt") >= 0)
            verify(out.indexOf("sub/") >= 0)
        }

        function test_listEmpty() {
            var out = null
            listTool.execute({ path: "/x" }, makeCtx({ listDir: function() { return { ok: true, entries: [] } } }),
                             function(t) { out = t })
            compare(out, "(leer)")
        }

        function test_listError() {                       // Fehler-Branch (early return)
            var ctx = makeCtx({ listDir: function() { return { ok: false, error: "ENOENT" } } })
            var out = null, ex = null
            listTool.execute({ path: "/nope" }, ctx, function(t, extra) { out = t; ex = extra })
            verify(out.indexOf("Fehler") >= 0)
            verify(out.indexOf("ENOENT") >= 0)
            compare(ex.status, "error")
        }

        function test_listCappedTo5000() {                // Kappung (im Global Constraint namentlich)
            var many = []
            for (var i = 0; i < 2000; i++) many.push({ name: "datei_" + i + ".txt", isDir: false, size: 1 })
            var ctx = makeCtx({ listDir: function() { return { ok: true, entries: many } } })
            var out = null
            listTool.execute({ path: "/big" }, ctx, function(t) { out = t })
            compare(out.length, 5000)
        }

        function test_writeOk() {
            var seen = null
            var ctx = makeCtx({ writeText: function(p, c) { seen = { p: p, c: c }; return { ok: true } } })
            var out = null
            writeTool.execute({ path: "/tmp/x", content: "hallo" }, ctx, function(t, extra) { out = t })
            compare(seen.p, "/tmp/x")
            compare(seen.c, "hallo")
            verify(out.indexOf("OK") === 0)
        }

        function test_writeError() {
            var ctx = makeCtx({ writeText: function() { return { ok: false, error: "EACCES" } } })
            var out = null, ex = null
            writeTool.execute({ path: "/root/x", content: "z" }, ctx, function(t, extra) { out = t; ex = extra })
            verify(out.indexOf("FEHLER") >= 0)
            compare(ex.status, "error")
        }

        function test_describe() {
            compare(readTool.describe({ path: "/a/b" }), "Datei lesen: /a/b")
            compare(writeTool.describe({ path: "/a", content: "xyz" }).indexOf("Datei schreiben: /a"), 0)
            compare(listTool.describe({ path: "/d" }), "Verzeichnis: /d")
        }
    }
}
