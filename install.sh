#!/usr/bin/env bash
# Aurora — geführter Installer (idempotent).
#
# Installiert System-Abhängigkeiten, baut & installiert das Plasmoid, richtet den
# QML-Importpfad ein, fragt den (optionalen) Remote-Ollama-Endpoint ab und lädt
# auf Wunsch Modelle & Stimmen (setup-assets.sh).
#
# Optionen:
#   -y, --yes   Alle Rückfragen mit „Ja" beantworten (nicht-interaktiv/CI).
#
# Getestete Plattform: Fedora Linux mit KDE Plasma 6. Auf anderen Distributionen
# werden fehlende Pakete nur aufgelistet (kein automatisches Installieren).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
ENV_FILE="$HOME/.config/plasma-workspace/env/path.sh"
QML_PATHS="$PREFIX/lib64/qml:$PREFIX/lib/qml"
PLASMOID_DIR="$PREFIX/share/plasma/plasmoids/org.kde.aurora"
STAGE="$SCRIPT_DIR/build/stage"
CONFIG_FILE="$HOME/.config/net.niuton.aurora.rc"

ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=1 ;;
        *) echo "Unbekannte Option: $arg" >&2; exit 2 ;;
    esac
done

# confirm "Frage?" -> Exit 0 (ja) / 1 (nein). Nicht-interaktiv: nur bei --yes ja.
confirm() {
    if [ "$ASSUME_YES" = 1 ]; then return 0; fi
    if [ ! -t 0 ]; then return 1; fi
    local ans
    read -r -p "$1 [j/N] " ans
    [[ "$ans" =~ ^[JjYy] ]]
}

echo "=== Aurora Installer (Prefix: $PREFIX) ==="

# ---------------------------------------------------------------------------
echo "[1/7] System-Abhängigkeiten..."
BUILD_PKGS=(gcc-c++ cmake ninja-build extra-cmake-modules rsync
            qt6-qtbase-devel qt6-qtdeclarative-devel libplasma-devel
            kf6-kdbusaddons-devel kf6-kcoreaddons-devel kf6-ki18n-devel
            kf6-kirigami-devel)
RUNTIME_PKGS=(kf6-qqc2-desktop-style pipewire-utils alsa-utils python3-pip curl git
              kf6-kconfig)
if command -v dnf >/dev/null 2>&1; then
    missing=()
    for pkg in "${BUILD_PKGS[@]}" "${RUNTIME_PKGS[@]}"; do
        rpm -q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "  Fehlende Pakete: ${missing[*]}"
        if confirm "  Jetzt per 'sudo dnf install' installieren?"; then
            sudo dnf install -y "${missing[@]}"
        else
            echo "  Übersprungen. Manuell: sudo dnf install ${missing[*]}"
            echo "  (Der Build kann ohne die Build-Pakete fehlschlagen.)"
        fi
    else
        echo "  Alle Pakete vorhanden."
    fi
else
    echo "  Kein dnf gefunden — bitte die Entsprechungen dieser Pakete installieren:"
    echo "    Build:   ${BUILD_PKGS[*]}"
    echo "    Laufzeit: ${RUNTIME_PKGS[*]}"
    confirm "  Trotzdem fortfahren?" || exit 1
fi

# ---------------------------------------------------------------------------
echo "[2/7] Ollama (lokale KI-Laufzeit)..."
if command -v ollama >/dev/null 2>&1; then
    echo "  ollama vorhanden ($(command -v ollama))."
else
    echo "  ollama nicht gefunden. Offizielle Installation: curl -fsSL https://ollama.com/install.sh | sh"
    if confirm "  Diesen Befehl jetzt ausführen?"; then
        curl -fsSL https://ollama.com/install.sh | sh
    else
        echo "  Übersprungen — ohne ollama funktioniert das lokale Modell nicht."
    fi
fi

# ---------------------------------------------------------------------------
echo "[3/7] Bauen & testen..."
# KDE_INSTALL_USE_QT_SYS_PATHS=OFF ist defensiv: Wurde build/ zuvor ohne
# -DCMAKE_INSTALL_PREFIX konfiguriert, cached ECM die Option als ON und ein
# Re-Configure mit anderem Prefix installiert das QML-Modul weiter nach
# /usr/lib64/qt6/qml (schlägt ohne root fehl). Das explizite OFF erzwingt $PREFIX.
cmake -B "$SCRIPT_DIR/build" -S "$SCRIPT_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DKDE_INSTALL_USE_QT_SYS_PATHS=OFF >/dev/null
cmake --build "$SCRIPT_DIR/build"
ctest --test-dir "$SCRIPT_DIR/build" --output-on-failure

# ---------------------------------------------------------------------------
echo "[4/7] Installiere Plasmoid + QML-Module (Staging)..."
# Atomarer als rm-vor-install: erst vollständig nach build/stage installieren,
# dann synchronisieren. --delete nur in den beiden Aurora-eigenen Bäumen, damit
# verwaiste Dateien verschwinden, ohne fremde Dateien unter $PREFIX anzufassen.
rm -rf "$STAGE"
DESTDIR="$STAGE" cmake --install "$SCRIPT_DIR/build" >/dev/null
mkdir -p "$PLASMOID_DIR"
rsync -a --delete "$STAGE$PREFIX/share/plasma/plasmoids/org.kde.aurora/" "$PLASMOID_DIR/"
for libdir in lib64 lib; do
    if [ -d "$STAGE$PREFIX/$libdir/qml/net/niuton/aurora" ]; then
        mkdir -p "$PREFIX/$libdir/qml/net/niuton/aurora"
        rsync -a --delete "$STAGE$PREFIX/$libdir/qml/net/niuton/aurora/" \
                          "$PREFIX/$libdir/qml/net/niuton/aurora/"
    fi
done
# Alles Übrige (App-Binary, .desktop, Icon) ohne --delete:
rsync -a "$STAGE$PREFIX/" "$PREFIX/"
update-desktop-database "$PREFIX/share/applications" 2>/dev/null || true

# ---------------------------------------------------------------------------
echo "[5/7] Hilfsskripte + QML-Importpfad..."
mkdir -p "$PREFIX/bin"
cp "$SCRIPT_DIR/scripts/aurora-transcribe" "$PREFIX/bin/"
chmod +x "$PREFIX/bin/aurora-transcribe"

# ComfyUI-Workflow-Templates in den Datenpfad (ComfyClient liest sie von dort)
mkdir -p "$HOME/.local/share/aurora/workflows"
cp "$SCRIPT_DIR"/src/engine/workflows/*.json "$HOME/.local/share/aurora/workflows/"

mkdir -p "$(dirname "$ENV_FILE")"
if ! grep -qs "QML_IMPORT_PATH" "$ENV_FILE" 2>/dev/null; then
    printf 'export QML_IMPORT_PATH="%s:${QML_IMPORT_PATH:-}"\n' "$QML_PATHS" >>"$ENV_FILE"
    echo "  QML_IMPORT_PATH in $ENV_FILE eingetragen (gilt ab nächstem Login)"
fi
# Sofort aktivieren, ohne Re-Login — vorhandenen Wert anreichern statt überschreiben:
current="$(systemctl --user show-environment | sed -n 's/^QML_IMPORT_PATH=//p')"
case ":$current:" in
    *":$PREFIX/lib64/qml:"*) : ;;  # schon gesetzt
    *) systemctl --user set-environment QML_IMPORT_PATH="$QML_PATHS${current:+:$current}" ;;
esac

# ---------------------------------------------------------------------------
echo "[6/7] Remote-Ollama-Endpoint..."
# Aurora läuft ohne Remote rein lokal. Optional lässt sich ein Remote-Ollama-
# Server (gleiches Protokoll, Port 11434) eintragen. Der Wert landet in der
# QSettings-INI, dieselbe, die die Widget-Einstellungen nutzen -> jederzeit auch
# über Einstellungen > Modelle änderbar.
if command -v kwriteconfig6 >/dev/null 2>&1 && { [ -t 0 ] || [ "$ASSUME_YES" = 1 ]; }; then
    if [ "$ASSUME_YES" = 1 ]; then
        echo "  (--yes: überspringe Endpoint-Abfrage, bleibt bei aktueller/lokaler Einstellung.)"
    else
        read -r -p "  Remote-Ollama-Endpoint (z. B. http://192.168.1.50:11434, leer = nur lokal): " REMOTE
        if [ -n "${REMOTE:-}" ]; then
            kwriteconfig6 --file "$CONFIG_FILE" --group General --key remoteEnabled true
            kwriteconfig6 --file "$CONFIG_FILE" --group General --key remoteEndpoint "$REMOTE"
            read -r -p "  Fallback-Endpoint (optional, leer = keiner): " REMOTE2
            [ -n "${REMOTE2:-}" ] && kwriteconfig6 --file "$CONFIG_FILE" --group General --key remoteEndpointFallback "$REMOTE2"
            read -r -p "  ComfyUI-Endpoint für Bildgenerierung (optional, z. B. http://192.168.1.50:8000): " COMFY
            [ -n "${COMFY:-}" ] && kwriteconfig6 --file "$CONFIG_FILE" --group General --key comfyEndpoint "$COMFY"
            echo "  Gespeichert in $CONFIG_FILE."
        else
            echo "  Kein Remote gesetzt — Aurora nutzt das lokale Modell."
        fi
    fi
else
    echo "  (kwriteconfig6 fehlt oder nicht-interaktiv — Remote später über Einstellungen > Modelle setzen.)"
fi

# ---------------------------------------------------------------------------
echo "[7/7] Modelle & Stimmen..."
if confirm "  Jetzt Modelle & Stimmen herunterladen (setup-assets.sh, mehrere GB)?"; then
    bash "$SCRIPT_DIR/setup-assets.sh"
else
    echo "  Übersprungen. Später nachholen: ./setup-assets.sh"
fi

# ---------------------------------------------------------------------------
if confirm "plasmashell jetzt neu starten (übernimmt das Widget)?"; then
    systemctl --user restart plasma-plasmashell.service
else
    echo "Hinweis: plasmashell später neu starten oder neu anmelden, damit das Widget erscheint."
fi

echo ""
echo "=== Fertig ==="
echo "Widget hinzufügen: Rechtsklick auf Panel > Widgets > 'Aurora'"
echo "Standalone-App:    aurora (aus dem Anwendungsmenü oder Terminal)"
