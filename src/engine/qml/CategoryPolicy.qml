import QtQuick

// Kategorie-Wechsel-Regel für EINEN Zug (turn). local vs. network (generate ~ network).
// Sobald im Zug eine andere Gruppe im Kontext ist, eskaliert die jeweils andere
// Gruppe einmalig auf confirm — bis der Nutzer den Wechsel per "Ja" bestätigt.
QtObject {
    property bool _sawLocal: false
    property bool _sawNetwork: false
    property bool _switchConfirmed: false

    function _isNetwork(cat) { return cat === "network" || cat === "generate" }

    function reset() {
        _sawLocal = false; _sawNetwork = false; _switchConfirmed = false
    }

    // Nach jedem Tool-Ergebnis des Zuges aufrufen.
    function noteResult(category) {
        if (_isNetwork(category)) _sawNetwork = true
        else _sawLocal = true
    }

    // Braucht das nächste Tool dieser Kategorie eine Eskalations-Bestätigung?
    function needsEscalation(nextCategory) {
        if (_switchConfirmed) return false
        if (_isNetwork(nextCategory)) return _sawLocal
        return _sawNetwork
    }

    // Jedes "Ja" gilt als Kategorie-Wechsel-Bestätigung für den Rest des Zuges.
    function confirmSwitch() { _switchConfirmed = true }
}
