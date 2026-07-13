import QtQuick

// Reine Entscheidungsfunktion: statische Stufe + Grant + Kategorie-Eskalation
// -> allow | confirm | disabled. Kein State.
QtObject {
    function decide(staticLevel, opts) {
        var granted = !!(opts && opts.granted)
        var escalate = !!(opts && opts.escalate)
        if (staticLevel === "off") return "disabled"
        if (staticLevel === "auto") return escalate ? "confirm" : "allow"
        // "confirm"
        return (granted && !escalate) ? "allow" : "confirm"
    }
}
