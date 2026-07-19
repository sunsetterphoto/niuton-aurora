#!/usr/bin/env bash
# Aurora - Build & Installation (idempotent).
# Modelle/Stimmen/aichat: ./setup-assets.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
ENV_FILE="$HOME/.config/plasma-workspace/env/path.sh"
QML_PATHS="$PREFIX/lib64/qml:$PREFIX/lib/qml"
PLASMOID_DIR="$PREFIX/share/plasma/plasmoids/org.kde.aurora"
STAGE="$SCRIPT_DIR/build/stage"

echo "=== Aurora Installation (Prefix: $PREFIX) ==="

echo "[1/5] Prüfe Build-Abhängigkeiten..."
missing=()
for pkg in gcc-c++ cmake ninja-build extra-cmake-modules rsync \
           qt6-qtbase-devel qt6-qtdeclarative-devel libplasma-devel \
           kf6-kdbusaddons-devel kf6-kcoreaddons-devel kf6-ki18n-devel \
           kf6-kirigami-devel kf6-syntax-highlighting; do
    rpm -q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "  FEHLT: ${missing[*]}"
    echo "  Bitte installieren: sudo dnf install ${missing[*]}"
    exit 1
fi

echo "[2/5] Baue und teste..."
# KDE_INSTALL_USE_QT_SYS_PATHS=OFF ist defensiv: Wurde build/ zuvor ohne
# -DCMAKE_INSTALL_PREFIX konfiguriert (Prefix /usr, z.B. Schnelltest-Build aus
# CLAUDE.md), cached ECM die Option als ON und ein Re-Configure mit anderem
# Prefix installiert das QML-Modul weiter nach /usr/lib64/qt6/qml (schlägt ohne
# root fehl). Das explizite OFF überschreibt den Cache und erzwingt $PREFIX.
cmake -B "$SCRIPT_DIR/build" -S "$SCRIPT_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DKDE_INSTALL_USE_QT_SYS_PATHS=OFF >/dev/null
cmake --build "$SCRIPT_DIR/build"
ctest --test-dir "$SCRIPT_DIR/build" --output-on-failure

echo "[3/5] Installiere Plasmoid + QML-Module (Staging)..."
# Atomarer als rm-vor-install: erst vollständig nach build/stage installieren
# (kann gefahrlos fehlschlagen), dann synchronisieren. --delete nur in den
# beiden Aurora-eigenen Bäumen, damit verwaiste Dateien verschwinden, ohne
# fremde Dateien unter $PREFIX anzufassen.
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
# Alles Übrige (App-Binary, .desktop, Icon; falls künftige Phasen neue
# Install-Roots ergänzen) ohne --delete:
rsync -a "$STAGE$PREFIX/" "$PREFIX/"
# Desktop-Datenbank aktualisieren, damit die App im Menü erscheint (best-effort).
update-desktop-database "$PREFIX/share/applications" 2>/dev/null || true

echo "[4/5] Hilfsskripte + QML-Importpfad..."
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

echo "[5/5] Starte plasmashell neu..."
systemctl --user restart plasma-plasmashell.service

echo ""
echo "=== Fertig ==="
echo "Erstinstallation? Assets holen mit: ./setup-assets.sh"
echo "Widget hinzufügen: Rechtsklick auf Panel > Widgets > 'Aurora'"
