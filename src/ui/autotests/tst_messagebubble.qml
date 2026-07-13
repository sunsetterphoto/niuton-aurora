import QtQuick
import QtTest
import net.niuton.aurora.ui

TestCase {
    name: "MessageBubble"

    Component {
        id: bubbleComp
        MessageBubble {
            width: 400
            text: "Hallo"
            isUser: false
            thinking: ""
            streaming: false
            ts: "12:00"
            mediaPath: ""
            mediaType: ""
            status: "final"
            toolActivity: ""
            msgId: ""
            rating: 0
        }
    }

    function test_letzteBubbleZeigtAktionen() {
        var b = bubbleComp.createObject(null, { "isLast": true })
        verify(b._actionsShown)          // letzte Bubble -> Aktionen an (ohne Hover)
        b.destroy()
    }

    function test_aeltereBubbleOhneHoverVerborgen() {
        var b = bubbleComp.createObject(null, { "isLast": false })
        verify(!b._actionsShown)         // nicht letzte, kein Hover -> aus
        b.destroy()
    }

    function test_streamingUnterdruecktAktionen() {
        var b = bubbleComp.createObject(null, { "isLast": true, "streaming": true })
        verify(!b._actionsShown)         // während Streaming aus, auch wenn isLast
        b.destroy()
    }

    function test_bodyloseBubbleHatKeinenBody() {
        var b = bubbleComp.createObject(null, { "text": "", "isLast": false })
        verify(!b._hasBody)              // leere Assistant-Bubble -> kein Body -> Aktionszeile kollabiert
        b.destroy()
    }

    function test_bubbleMitTextHatBody() {
        var b = bubbleComp.createObject(null, { "text": "Hallo" })
        verify(b._hasBody)
        b.destroy()
    }

    function test_ratingRolleErreichbar() {
        var b = bubbleComp.createObject(null, { "msgId": "m1", "rating": 1 })
        compare(b.rating, 1)
        compare(b.msgId, "m1")
        b.destroy()
    }
}
