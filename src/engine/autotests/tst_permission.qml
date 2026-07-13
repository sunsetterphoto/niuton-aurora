import QtQuick
import QtTest
import net.niuton.aurora.engine

Item {
    PermissionResolver { id: resolver }
    GrantStore { id: grants }
    CategoryPolicy { id: policy }

    TestCase {
        name: "Permission"

        // --- PermissionResolver ---
        function test_resolveOff() {
            compare(resolver.decide("off", { granted: true, escalate: false }), "disabled")
        }
        function test_resolveAuto() {
            compare(resolver.decide("auto", { granted: false, escalate: false }), "allow")
            compare(resolver.decide("auto", { granted: false, escalate: true }), "confirm")
        }
        function test_resolveConfirm() {
            compare(resolver.decide("confirm", { granted: false, escalate: false }), "confirm")
            compare(resolver.decide("confirm", { granted: true, escalate: false }), "allow")
            compare(resolver.decide("confirm", { granted: true, escalate: true }), "confirm")  // Eskalation schlägt Grant
        }

        // --- GrantStore ---
        function test_grants() {
            compare(grants.hasGrant("c1", "run_command"), false)
            grants.grant("c1", "run_command")
            compare(grants.hasGrant("c1", "run_command"), true)
            compare(grants.hasGrant("c2", "run_command"), false)   // pro Konversation
            compare(grants.hasGrant("c1", "write_file"), false)    // pro Tool
            grants.clearConversation("c1")
            compare(grants.hasGrant("c1", "run_command"), false)
        }

        // --- CategoryPolicy ---
        function test_noEscalationSameCategory() {
            policy.reset()
            policy.noteResult("local")
            compare(policy.needsEscalation("local"), false)
        }
        function test_escalationOnCategorySwitch() {
            policy.reset()
            policy.noteResult("network")               // network-Ergebnis im Kontext
            compare(policy.needsEscalation("local"), true)   // local nach network -> Eskalation
        }
        function test_generateCountsAsNetwork() {
            policy.reset()
            policy.noteResult("generate")
            compare(policy.needsEscalation("local"), true)   // generate ~ network
            policy.reset()
            policy.noteResult("local")
            compare(policy.needsEscalation("generate"), true)
        }
        function test_confirmSwitchSuppressesForRestOfTurn() {
            policy.reset()
            policy.noteResult("network")
            compare(policy.needsEscalation("local"), true)
            policy.confirmSwitch()                     // Nutzer hat "Ja" gesagt
            compare(policy.needsEscalation("local"), false)   // Rest des Zuges frei
        }
        function test_resetClearsState() {
            policy.reset()
            policy.noteResult("network"); policy.confirmSwitch()
            policy.reset()
            policy.noteResult("network")
            compare(policy.needsEscalation("local"), true)   // neuer Zug eskaliert erneut
        }
    }
}
