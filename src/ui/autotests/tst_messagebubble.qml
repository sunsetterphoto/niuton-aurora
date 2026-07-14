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

    // ---------- Sicherheit: kein modell-getriebener Remote-Bild-Fetch ----------
    // Sicherheits-Property: nach _neutralizeImages darf KEIN Bild-Knoten ("![")
    // mehr entstehen -> Text.MarkdownText fetcht nie eine externe Ressource.
    // Die URL bleibt legitim als (klick-schema-gefiltertes) Link-Ziel erhalten,
    // daher wird auf "kein ![" geprüft, nicht auf "keine URL".

    function test_neutralizeImagesInlineForm() {
        var b = bubbleComp.createObject(null, {})
        verify(b._neutralizeImages("![a](http://x)").indexOf("![") === -1)
        b.destroy()
    }

    function test_neutralizeImagesReferenzForm() {
        // Referenz-Stil ![alt][1] mit [1]: url an anderer Stelle -> löste beim
        // alten Inline-Regex weiterhin einen Fetch aus (Reviewer-Bypass).
        var b = bubbleComp.createObject(null, {})
        verify(b._neutralizeImages("![alt][1]").indexOf("![") === -1)
        b.destroy()
    }

    function test_neutralizeImagesVerschachtelterAltText() {
        // Verschachtelte Klammern im Alt-Text ![a[b]c](u) -> zweiter
        // Reviewer-Bypass des alten Regex.
        var b = bubbleComp.createObject(null, {})
        verify(b._neutralizeImages("![a[b]c](u)").indexOf("![") === -1)
        b.destroy()
    }

    function test_neutralizeImagesMehrereFormenImSegment() {
        var b = bubbleComp.createObject(null, {})
        var out = b._neutralizeImages("![x](http://a) und ![y][2] und ![z]")
        verify(out.indexOf("![") === -1)
        b.destroy()
    }

    function test_neutralizeImagesLaesstNormalenLinkUnveraendert() {
        var b = bubbleComp.createObject(null, {})
        var out = b._neutralizeImages("Siehe [KDE](https://kde.org) für Details.")
        compare(out, "Siehe [KDE](https://kde.org) für Details.")
        b.destroy()
    }

    function test_neutralizeImagesLaesstNormaleTextformatierungUnveraendert() {
        var b = bubbleComp.createObject(null, {})
        var out = b._neutralizeImages("**fett** und `inline code` und - Listenpunkt")
        compare(out, "**fett** und `inline code` und - Listenpunkt")
        b.destroy()
    }

    // ---------- Sicherheit: nur http/https/mailto-Links öffnen ----------

    function test_isSafeLinkErlaubtHttpHttpsMailto() {
        var b = bubbleComp.createObject(null, {})
        verify(b._isSafeLink("https://kde.org"))
        verify(b._isSafeLink("http://kde.org"))
        verify(b._isSafeLink("mailto:foo@example.org"))
        verify(b._isSafeLink("HTTPS://KDE.ORG"))
        b.destroy()
    }

    function test_isSafeLinkVerbietetAndereSchemata() {
        var b = bubbleComp.createObject(null, {})
        verify(!b._isSafeLink("file:///etc/passwd"))
        verify(!b._isSafeLink("custom://foo"))
        verify(!b._isSafeLink("javascript:alert(1)"))
        b.destroy()
    }
}
