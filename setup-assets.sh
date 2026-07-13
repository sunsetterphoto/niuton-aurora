#!/usr/bin/env bash
# Aurora - Assets: Ollama-Modelle, Piper-Stimmen, Whisper-Modell, aichat, Service.
# Getrennt von install.sh, weil hier große Downloads passieren.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AICHAT_DIR="$HOME/.config/aichat"
SYSTEMD_DIR="$HOME/.config/systemd/user"
AURORA_DATA="$HOME/.local/share/aurora"

echo "=== Aurora Assets ==="

echo "[1/4] aichat-Konfiguration..."
mkdir -p "$AICHAT_DIR/roles"
cp "$SCRIPT_DIR/aichat-config.yaml" "$AICHAT_DIR/config.yaml"
cp "$SCRIPT_DIR/aurora-safe.md" "$AICHAT_DIR/roles/"
cp "$SCRIPT_DIR/aurora-all.md" "$AICHAT_DIR/roles/"

echo "[2/4] systemd-Service (aichat --serve für Bash-Funktionen)..."
mkdir -p "$SYSTEMD_DIR"
cp "$SCRIPT_DIR/aurora-serve.service" "$SYSTEMD_DIR/"
systemctl --user daemon-reload
systemctl --user enable aurora-serve.service
systemctl --user restart aurora-serve.service

echo "[3/4] Ollama-Modelle..."
for model in gemma4:e4b gemma4:e2b qwen3.5:2b qwen3.5:9b qwen3.5:0.8b; do
    if ! ollama list 2>/dev/null | grep -q "^${model}"; then
        echo "  Lade $model herunter..."
        ollama pull "$model"
    else
        echo "  $model bereits vorhanden"
    fi
done

echo "[4/4] Sprache: Piper TTS + Whisper STT..."
mkdir -p "$AURORA_DATA/piper" "$AURORA_DATA/whisper" "$AURORA_DATA/images"

if ! command -v piper >/dev/null 2>&1; then
    echo "  Installiere piper-tts (pip)..."
    pip install --user piper-tts
fi
if ! python3 -c "import pywhispercpp" >/dev/null 2>&1; then
    echo "  Installiere pywhispercpp (pip)..."
    pip install --user pywhispercpp
fi

PIPER_BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE"
for voice in "thorsten/high/de_DE-thorsten-high" "kerstin/low/de_DE-kerstin-low"; do
    name="$(basename "$voice")"
    if [ ! -f "$AURORA_DATA/piper/$name.onnx" ]; then
        echo "  Lade Piper-Stimme $name..."
        curl -sL -o "$AURORA_DATA/piper/$name.onnx" "$PIPER_BASE/$voice.onnx"
        curl -sL -o "$AURORA_DATA/piper/$name.onnx.json" "$PIPER_BASE/$voice.onnx.json"
    fi
done

if [ ! -f "$AURORA_DATA/whisper/ggml-small.bin" ]; then
    echo "  Lade Whisper-Modell (ggml-small, ~466 MB)..."
    curl -sL -o "$AURORA_DATA/whisper/ggml-small.bin" \
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
fi

echo "=== Assets fertig ==="
echo "Bash-Funktionen manuell einbinden: siehe $SCRIPT_DIR/aurora-bash-functions.sh"
