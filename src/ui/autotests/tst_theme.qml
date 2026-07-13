import QtQuick
import QtTest
import net.niuton.aurora.ui

TestCase {
    name: "Theme"
    function test_tokensDefined() {
        verify(Theme.auroraGreen !== undefined)
        verify(Theme.auroraCyan !== undefined)
        verify(Theme.auroraBlue !== undefined)
        verify(Theme.auroraViolet !== undefined)
    }
    function test_withAlpha() {
        var c = Theme.withAlpha(Qt.rgba(1, 0, 0, 1), 0.5)
        compare(c.a, 0.5)
        compare(c.r, 1)
    }
}
