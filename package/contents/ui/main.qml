import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami
import net.niuton.aurora.core
import net.niuton.aurora.engine
import net.niuton.aurora.ui

PlasmoidItem {
    id: root

    // ==================== Host-State ====================
    property bool isPinned: false
    // Alias hält die compactRepresentation-Canvas byte-gleich (nutzt root.isLoading).
    readonly property bool isLoading: auroraController.busy

    // Angepinnt: Popup bleibt bei Fokusverlust offen (kein Auto-Hide, kein
    // Vordergrund-Zwang) — ersetzt den früheren Qt.callLater-Reopen-Hack.
    hideOnWindowDeactivate: !root.isPinned

    // Der geteilte Controller — die gesamte App-Logik. Der Host bindet nur `active`
    // an seine Sichtbarkeit: `expanded || isPinned`, damit ein gepinntes Widget sein
    // Modell nie entlädt (Parität zum alten onExpandedChanged-early-return).
    // Eigene id (nicht "controller"): MainView hat selbst eine Property "controller",
    // die den gleichnamigen äußeren Bezeichner verdecken würde (QML-Scoping) — die
    // Injektion unten bliebe dann für immer undefined (Selbstreferenz statt Zugriff
    // auf diese Instanz).
    AuroraController {
        id: auroraController
        active: root.expanded || root.isPinned
    }

    // ==================== Lifecycle ====================
    // Einmalige Übernahme der appletsrc-Werte in den geteilten ConfigStore
    // (bleibt Host-only: liest Plasmoid.configuration). Reihenfolge explizit:
    // erst migrieren, dann DB öffnen.
    function _migrateConfigOnce() {
        if (ConfigStore.contains("_migratedFromAppletsrc")) return
        var keys = ["modelLowPower","modelBalanced","modelPerformance","lastSelectedModel",
                    "remoteEnabled","remoteEndpoint","remoteEndpointFallback","unloadSeconds",
                    "twoPhaseToolCalls","toolWebSearch","toolReadFile","toolListDir","toolWebFetch",
                    "toolWriteFile","toolRunCommand","toolMaxRounds","comfyEnabled","comfyEndpoint",
                    "comfyDefaultModel","ttsVoice","ttsAutoSpeak","sttLanguage","sttSource"]
        for (var i = 0; i < keys.length; i++) {
            var v = Plasmoid.configuration[keys[i]]
            if (v === undefined || v === null) continue
            if (keys[i].indexOf("tool") === 0 && v === "disabled") v = "off"
            ConfigStore.setValue(keys[i], v)
        }
        ConfigStore.setValue("_migratedFromAppletsrc", true)
    }

    Component.onCompleted: {
        _migrateConfigOnce()
        auroraController.open()
    }

    onExpandedChanged: {
        // Refresh-Kaskade bei jedem Öffnen. Pin-Reopen entfällt: ein gepinntes
        // Popup kollabiert dank hideOnWindowDeactivate:false gar nicht erst.
        if (root.expanded) auroraController.activate()
    }

    // ==================== Compact Representation ====================

    compactRepresentation: MouseArea {
        id: compactMouse
        onClicked: root.expanded = !root.expanded

        property real _time: 0

        Timer {
            interval: 50
            // Nicht rund um die Uhr mit 20 fps repainten (Idle-Last der
            // plasmashell/Akku): die Animation läuft nur, solange Aurora
            // arbeitet (dann schneller) oder das Popup geöffnet ist. Beim
            // Stoppen ein letzter Frame, damit das Ruhe-Bild (gedimmte
            // Alpha/Border) statt des letzten Lade-Frames stehen bleibt.
            running: root.isLoading || root.expanded
            repeat: true
            onTriggered: {
                compactMouse._time += 0.05
                auroraCanvas.requestPaint()
            }
            onRunningChanged: if (!running) auroraCanvas.requestPaint()
        }

        Canvas {
            id: auroraCanvas
            anchors.fill: parent
            anchors.margins: 1

            onPaint: {
                var ctx = getContext("2d")
                var w = width
                var h = height
                var cx = w / 2
                var cy = h / 2
                var r = Math.min(cx, cy)
                var t = compactMouse._time
                // Speed up when Aurora is working
                var speed = root.isLoading ? 3.0 : 1.0

                ctx.clearRect(0, 0, w, h)

                // Clip to circle
                ctx.save()
                ctx.beginPath()
                ctx.arc(cx, cy, r, 0, Math.PI * 2)
                ctx.clip()

                // Dark background
                ctx.fillStyle = Qt.rgba(0.05, 0.05, 0.12, 1.0)
                ctx.fillRect(0, 0, w, h)

                // Aurora curtains - layered sine waves with shifting colors
                var layers = [
                    { color1: [0.0, 1.0, 0.6], color2: [0.0, 0.8, 0.9], yBase: 0.55, amp: 0.12, freq: 2.5, phase: 0 },
                    { color1: [0.3, 0.7, 1.0], color2: [0.5, 0.2, 0.9], yBase: 0.45, amp: 0.15, freq: 2.0, phase: 1.5 },
                    { color1: [0.5, 0.0, 0.8], color2: [0.8, 0.2, 0.6], yBase: 0.35, amp: 0.10, freq: 3.0, phase: 3.0 }
                ]

                for (var l = 0; l < layers.length; l++) {
                    var layer = layers[l]
                    var c1 = layer.color1
                    var c2 = layer.color2
                    // Animate color blend
                    var blend = (Math.sin(t * speed * 0.7 + layer.phase) + 1) / 2

                    ctx.beginPath()
                    ctx.moveTo(0, h)

                    for (var x = 0; x <= w; x += 2) {
                        var nx = x / w
                        var wave1 = Math.sin(nx * layer.freq * Math.PI + t * speed * 1.2 + layer.phase)
                        var wave2 = Math.sin(nx * layer.freq * 0.7 * Math.PI + t * speed * 0.8 + layer.phase + 1.0)
                        var y = (layer.yBase + wave1 * layer.amp + wave2 * layer.amp * 0.5) * h
                        ctx.lineTo(x, y)
                    }

                    ctx.lineTo(w, h)
                    ctx.closePath()

                    // Gradient fill from aurora color to transparent
                    var gr = ctx.createLinearGradient(0, 0, 0, h)
                    var cr = c1[0] + (c2[0] - c1[0]) * blend
                    var cg = c1[1] + (c2[1] - c1[1]) * blend
                    var cb = c1[2] + (c2[2] - c1[2]) * blend
                    var alpha = root.isLoading ? 0.7 : 0.45
                    gr.addColorStop(0.0, Qt.rgba(cr, cg, cb, alpha))
                    gr.addColorStop(0.4, Qt.rgba(cr, cg, cb, alpha * 0.6))
                    gr.addColorStop(1.0, Qt.rgba(cr * 0.3, cg * 0.3, cb * 0.3, 0.1))
                    ctx.fillStyle = gr
                    ctx.fill()
                }

                ctx.restore()

                // Subtle circle border
                ctx.beginPath()
                ctx.arc(cx, cy, r - 0.5, 0, Math.PI * 2)
                ctx.strokeStyle = Qt.rgba(0.5, 1.0, 0.8, root.isLoading ? 0.5 : 0.2)
                ctx.lineWidth = 1
                ctx.stroke()
            }
        }
    }

    // ==================== Full Representation ====================
    // Die View-Montage lebt in der geteilten MainView (net.niuton.aurora.ui);
    // der Host bindet nur den Controller und reicht host-spezifische Aktionen
    // (Pin/Konfigurieren/Schließen) per Signal an sich selbst zurück.

    fullRepresentation: MainView {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 30
        Layout.preferredHeight: Kirigami.Units.gridUnit * 40
        Layout.minimumWidth: Kirigami.Units.gridUnit * 20
        Layout.minimumHeight: Kirigami.Units.gridUnit * 24
        controller: auroraController
        isPinned: root.isPinned
        onPinToggled: function(on) { root.isPinned = on }
        onConfigureRequested: Plasmoid.internalAction("configure").trigger()
        onCloseRequested: root.expanded = false
    }
}
