# Aurora

**Local-first AI assistant for KDE Plasma 6** — available both as a panel widget and a
standalone app, sharing one engine. Aurora talks to a local (or remote) [Ollama](https://ollama.com)
server, generates images via ComfyUI, and supports voice input/output — favouring local, private
processing.

> The user interface is currently in German; Aurora itself replies in the language you write in.

## Features

- **Local & remote models** over the Ollama protocol — one code path. Auto mode picks a local
  model per power profile; an optional remote server (LAN with WLAN fallback) is probed in parallel.
- **Streaming chat** with separate "thinking" output and **tool calling**: web search, read file,
  list directory, fetch URL, run command (with confirmation), and image generation. Per-tool
  permissions (auto / confirm).
- **Image generation** via [ComfyUI](https://github.com/comfyanonymous/ComfyUI) (semantic workflow
  templates), from a chat tool or a dedicated image panel.
- **Voice**: speech-to-text via whisper.cpp and text-to-speech via [Piper](https://github.com/rhasspy/piper).
- **Conversation history** in SQLite, plus a **knowledge base with RAG**: thumbs-up rated
  answers and manually curated entries (links / notes / facts) are embedded; on similar new
  questions the best matches are retrieved into the system prompt, with per-answer source
  attribution (configurable: on/off, top-k, similarity threshold).
- **Slash commands**: `/help`, `/model`, `/new`, `/search`, `/image`, `/memory`, `/knowledge`,
  `/export`, `/compact`.
- **Two front-ends, one engine**: a Plasma 6 panel widget and a standalone Kirigami app share the
  same controller and logic.

## Screenshots

_Coming soon._

## Requirements

- KDE Plasma 6 on Linux (developed and tested on Fedora)
- Qt 6 and KDE Frameworks 6
- [Ollama](https://ollama.com) for local models
- Optional: a remote Ollama server; ComfyUI for image generation; Piper (TTS) and whisper.cpp
  (STT) for voice; a local search backend (ddgs / SearXNG) for `web_search`

## Installation

```bash
git clone https://github.com/sunsetterphoto/niuton-aurora.git
cd niuton-aurora
./install.sh
```

The guided installer:

1. installs the system dependencies (on Fedora via `dnf`; on other distros it lists the packages),
2. builds and runs the test suite,
3. installs the widget and QML modules into `~/.local`, and sets the QML import path,
4. asks for an optional **remote Ollama endpoint** (leave empty for local-only),
5. offers to download models and voices (`setup-assets.sh`, several GB).

Then add the widget (right-click the panel → **Add Widgets** → **Aurora**) or launch the standalone
app (`aurora`).

Run `./install.sh --yes` for a non-interactive install.

## Configuration

- **Remote endpoint**: set during install, or any time via **Settings → Models** (endpoint plus an
  optional fallback).
- **Models**: local model per power profile (auto mode) and the embedding model (default
  `nomic-embed-text`).
- **Tools**: per-tool permission (auto / confirm) under Settings.

Configuration is stored in `~/.config/net.niuton.aurora.rc`; data (conversations, knowledge base,
images, voices) under `~/.local/share/aurora/`.

## Architecture

Three QML modules:

- **`net.niuton.aurora.core`** — C++/QML singletons: `FileIO`, `Http`, `NdjsonStream`,
  `ProcessRunner`, `ConversationStore` (SQLite), `ConfigStore`.
- **`net.niuton.aurora.engine`** — `AuroraController` / `AuroraEngine`, `ModelManager`,
  `ChatController`, `OllamaClient`, prompt/command helpers.
- **`net.niuton.aurora.ui`** — `Theme`, the views (`ChatView`, `Header`, `Sidebar`, `KnowledgeView`,
  `ImagePanel`, …) and `MainView`.

Conversations and the knowledge base live in SQLite (`~/.local/share/aurora/aurora.db`). All model
backends speak the Ollama protocol, so local and remote share one path.

## Bash integration (optional)

`setup-assets.sh` also installs an [aichat](https://github.com/sigoden/aichat)-based backend and
shell functions `ask` (analyse/explain), `act` (generate & run commands), and `code` (developer
helper). See `aurora-bash-functions.sh`.

## Build & test (for development)

```bash
cmake -B build -G Ninja && cmake --build build
ctest --test-dir build --output-on-failure
```

## License

[GPL-3.0](LICENSE).

## Author

Samuel (sunsetterphoto)
