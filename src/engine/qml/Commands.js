.pragma library

// Befehls-Register (Daten). argSource: "" oder "models" (Argument-Wertequelle).
var _commands = [
    { name: "help",    description: "Verfügbare Befehle anzeigen",                argHint: "",              takesArg: false, argSource: "" },
    { name: "compact", description: "Kontext verdichten (Verlauf zusammenfassen)", argHint: "",              takesArg: false, argSource: "" },
    { name: "new",     description: "Neue Konversation starten",                  argHint: "",              takesArg: false, argSource: "" },
    { name: "model",   description: "Modell wechseln",                            argHint: "<name>",        takesArg: true,  argSource: "models" },
    { name: "search",  description: "Web-Suche",                                  argHint: "<suchbegriff>", takesArg: true,  argSource: "" },
    { name: "image",   description: "Bild-Modus einschalten",                     argHint: "",              takesArg: false, argSource: "" },
    { name: "memory",  description: "Erinnerungen (memory.md) öffnen",            argHint: "",              takesArg: false, argSource: "" }
    ,{ name: "export",  description: "Konversation als Markdown exportieren",      argHint: "",              takesArg: false, argSource: "" }
    ,{ name: "knowledge", description: "Wissensbasis (bewertete Antworten) verwalten", argHint: "",          takesArg: false, argSource: "" }
]

function list() { return _commands }

function find(name) {
    for (var i = 0; i < _commands.length; i++)
        if (_commands[i].name === name) return _commands[i]
    return null
}

// "/model gemma" -> {name:"model", arg:"gemma"}; "/new" -> {name:"new", arg:""}.
// Kein führendes / -> null. name = erstes Wort nach /, arg = getrimmter Rest.
function parse(text) {
    if (!text) return null
    var t = String(text).trim()
    if (t.charAt(0) !== "/") return null
    var body = t.substring(1)
    var sp = body.indexOf(" ")
    if (sp === -1) return { name: body, arg: "" }
    return { name: body.substring(0, sp), arg: body.substring(sp + 1).trim() }
}
