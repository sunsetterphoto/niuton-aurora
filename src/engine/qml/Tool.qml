import QtQuick

// Basistyp für alle Tools im Engine-Modul. Abgeleitete Tools setzen die
// Properties und überschreiben die Methoden, die sie brauchen (in QML ersetzt
// eine im abgeleiteten Typ definierte function die gleichnamige der Basis).
// System-Primitive kommen ausschließlich über das injizierte ctx — nie direkt
// über Core-Singletons, damit Tools mockbar bleiben.
QtObject {
    id: tool

    property string name: ""
    property var definition: ({})            // { type:"function", function:{...} }
    property string permissionKey: ""        // Config-Key der statischen Stufe
    property string minPermission: "auto"    // auto | confirm | off (Untergrenze)
    property string category: "local"        // local | network | generate | box
    // Wo das Werkzeug arbeitet: "any" (immer), "device" (nur im Modus „dieser
    // Rechner") oder "cloud" (nur im Modus „Cloud-Rechner"). Die Registry
    // schaltet so je Werkzeugname zwischen lokaler und Cloud-Fassung um.
    property string target: "any"

    // Kurzbeschreibung für Chip/Bestätigungs-Bar. Default: der Name.
    function describe(args) { return tool.name }

    // Definition für den Payload; Werkzeuge mit kontextabhängiger Beschreibung
    // (Cloud-Rechner: Vorschau-Domain) überschreiben dies.
    function definitionFor(ctx) { return tool.definition }

    // Umgebungs-Verfügbarkeit (z.B. ComfyUI erreichbar). Default: immer verfügbar.
    function isAvailable(ctx) { return true }

    // Führt das Tool aus und ruft done(text[, extra]) genau einmal.
    function execute(args, ctx, done) { done("ERROR: Tool '" + tool.name + "' nicht implementiert") }

    // Prozess-Tools überschreiben dies, um einen laufenden Prozess abzubrechen.
    function abort() { }
}
