import QtQuick

// Laufzeit-Grants pro Konversation (conversationId -> Set(toolName)).
// Nur im Speicher; übersteht Chat-Wechsel, nie persistiert.
QtObject {
    property var _byConv: ({})     // { convId: { toolName: true } }

    function grant(convId, toolName) {
        if (!_byConv[convId]) _byConv[convId] = {}
        _byConv[convId][toolName] = true
    }
    function hasGrant(convId, toolName) {
        return !!(_byConv[convId] && _byConv[convId][toolName])
    }
    function clearConversation(convId) {
        if (_byConv[convId]) delete _byConv[convId]
    }
}
