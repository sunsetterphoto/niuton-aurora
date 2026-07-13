pragma Singleton
import QtQuick

// Aurora-Designtokens. Basisfarben kommen immer aus Kirigami.Theme
// (hell/dunkel), diese Akzente sind reine Zierde in niedriger Deckkraft.
QtObject {
    readonly property color auroraGreen:  "#38f5a8"
    readonly property color auroraCyan:   "#37c8e8"
    readonly property color auroraBlue:   "#4d9dff"
    readonly property color auroraViolet: "#8a5cf6"

    // Gradient-Stops für Streifen/Schimmer (vertikal wie ein Nordlicht-Vorhang)
    function gradientStops(alpha) {
        return [
            { pos: 0.0,  color: withAlpha(auroraGreen, alpha) },
            { pos: 0.35, color: withAlpha(auroraCyan, alpha) },
            { pos: 0.7,  color: withAlpha(auroraBlue, alpha) },
            { pos: 1.0,  color: withAlpha(auroraViolet, alpha) }
        ]
    }

    function withAlpha(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a)
    }

    // Mischt zwei Farben (t: 0..1)
    function mix(c1, c2, t) {
        return Qt.rgba(
            c1.r + (c2.r - c1.r) * t,
            c1.g + (c2.g - c1.g) * t,
            c1.b + (c2.b - c1.b) * t,
            c1.a + (c2.a - c1.a) * t
        )
    }
}
