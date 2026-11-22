import QtQuick
import net.niuton.aurora.engine

// Gemeinsame Basis der Cloud-Rechner-Werkzeuge (App-API des Aurora-Servers,
// Client über ctx.cloudBox). Nur im Modus „Cloud-Rechner" sichtbar (target);
// dort laufen Befehle und Dateien AUSSCHLIESSLICH im Cloud-Rechner. Fehlt die
// Einrichtung oder scheitert ein Aufruf, bekommt das Modell einen verständlichen
// Werkzeug-Text — nie einen stillen Rückfall auf diesen Rechner.
// CloudBoxTexts kommt als Modul-Skript aus net.niuton.aurora.engine (qmldir).
Tool {
    id: base
    category: "box"
    target: "cloud"

    // Client oder null (dann ist done mit dem Einrichtungs-Hinweis gerufen)
    function _client(ctx, done) {
        var c = ctx ? ctx.cloudBox : null
        if (!c || (c.configured === false)) {
            done(CloudBoxTexts.NOT_SET_UP, { "status": "error" })
            return null
        }
        return c
    }

    function _fail(e, done) { done(CloudBoxTexts.errorText(e), { "status": "error" }) }

    function _domain(ctx) { return (ctx && ctx.cloudBox && ctx.cloudBox.previewDomain) || "" }

    function _str(v) { return (v === undefined || v === null) ? "" : String(v) }
}
