<p align="center">
  <img src="package/contents/icons/aurora.png" alt="Aurora logo" width="128">
</p>

# Aurora

**Local-first AI assistant for KDE Plasma 6** — available both as a panel widget and a
standalone app, sharing one engine. Aurora talks to [Ollama](https://ollama.com) and to
OpenAI-compatible servers such as [llama.cpp](https://github.com/ggml-org/llama.cpp)'s
`llama-server`, generates images via ComfyUI, and supports voice input/output.

Data sovereignty is the guiding rule, not physical location: your own machine, your own LAN and
your own cloud storage rank equally; a third-party cloud is the deliberate exception.

> The user interface is currently in German; Aurora itself replies in the language you write in.

## Features

- **Several model backends, one interface**: local Ollama, Ollama on your LAN (probed in parallel,
  with fallback), OpenAI-compatible servers (`llama-server`, vLLM), and — as an explicit,
  never-automatic exception — OpenRouter in the cloud. Auto mode picks a local model per power
  profile and never reaches for a cloud backend on its own.
- **Streaming chat** with separate "thinking" output and **tool calling**: web search, read file,
  list directory, fetch URL, run command (with confirmation), and image generation. Per-tool
  permissions (auto / confirm).
- **Markdown rendering with syntax-highlighted code blocks** (Kate engine via
  `org.kde.syntaxhighlighting`, follows the light/dark color scheme).
- **File attachments** via file dialog or drag & drop onto the chat — images go to
  vision-capable models, text files are inlined into the message.
- **Image generation** via [ComfyUI](https://github.com/comfyanonymous/ComfyUI) (semantic workflow
  templates), from a chat tool or a dedicated image panel; optionally an OpenRouter image model
  (explicitly chosen, never automatic).
- **Video generation** via OpenRouter's `/v1/videos` API (e.g. Veo 3.1 Lite, Kling) as an explicit,
  asynchronous chat tool — the finished clip appears in the chat and opens in your default player.
- **Voice**: speech-to-text via whisper.cpp and text-to-speech via [Piper](https://github.com/rhasspy/piper).
- **Conversation history** in SQLite with **full-text search** (FTS5 over titles and
  message contents, with result snippets), plus a **knowledge base with RAG**: thumbs-up rated
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
- KWallet (`kf6-kwallet`) if you store cloud API keys (the OpenRouter key is never written to the
  config file)
- Optional: a remote Ollama server; ComfyUI for image generation; Piper (TTS) and whisper.cpp
  (STT) for voice; a local search backend (ddgs / SearXNG) for `web_search`

## Installation

```bash
git clone https://github.com/sunsetterphoto/niuton-aurora.git
cd niuton-aurora
./install.sh
```

The installer is non-interactive and idempotent:

1. checks the build dependencies (and lists the `dnf` command if any are missing),
2. builds and runs the test suite — it stops on a failing test,
3. installs the widget, QML modules and the `aurora` binary into `~/.local`, sets the QML import
   path, and restarts plasmashell.

Then add the widget (right-click the panel → **Add Widgets** → **Aurora**) or launch the standalone
app (`aurora`). Models and voices are fetched separately via `./setup-assets.sh` (several GB).

`./install.sh --with-quadlets` additionally copies the Podman quadlets for ComfyUI and Speaches to
`~/.config/containers/systemd/`. Existing files are never overwritten, and the units carry no
`[Install]` section — nothing autostarts.

## Configuration

- **Backends**: an Ollama endpoint on your LAN plus an optional fallback under
  **Settings → Models**; an OpenAI-compatible endpoint (`openaiEndpoint`) for `llama-server` and
  friends.
- **Models**: local model per power profile (auto mode) and the embedding model (default
  `nomic-embed-text`).
- **Tools**: per-tool permission (auto / confirm) under Settings.
- **Data directory**: **Settings → Advanced → Datenordner** moves `aurora.db` anywhere you like —
  a synced folder of your own cloud, for instance. Empty means the default path. If you do use a
  sync folder: exclude `aurora.db-wal` and `aurora.db-shm` from syncing (SQLite runs in WAL mode)
  and do not run Aurora against the same folder from two machines at once.

Configuration is stored in `~/.config/net.niuton.aurora.rc`; data (conversations, knowledge base,
images, voices) under `~/.local/share/aurora/` unless you moved it. Secrets stay out of these
files: the OpenRouter API key lives in the KWallet (`net.niuton.aurora` folder, accessed over the
org.kde.kwalletd6 D-Bus API), with the `AURORA_OPENROUTER_KEY` environment variable as a
headless fallback.

### Ports

| Port | Service |
|------|---------|
| 11434 | Ollama |
| 8080 | `llama-server` (OpenAI-compatible), see `aurora-llama-server.service` |
| 8188 | ComfyUI |
| 8000 | Speaches (speech) |
| 8001 | `aichat --serve` (optional bash integration) |

## Architecture

Three QML modules:

- **`net.niuton.aurora.core`** — C++/QML singletons: `FileIO`, `Http`, `NdjsonStream`,
  `ProcessRunner`, `ConversationStore` (SQLite), `ConfigStore`.
- **`net.niuton.aurora.engine`** — `AuroraController` / `AuroraEngine`, `ModelManager`,
  `ChatController`, the backend clients (`OllamaClient`, `OpenAiClient`) and their job objects,
  prompt/command helpers.
- **`net.niuton.aurora.ui`** — `Theme`, the views (`ChatView`, `Header`, `Sidebar`, `KnowledgeView`,
  `ImagePanel`, …) and `MainView`.

Conversations and the knowledge base live in one SQLite database (`aurora.db`; the directory is
configurable).

Backends are held in a registry derived from the settings. Each entry names its `kind`, and that
decides which client serves it — `OllamaClient` or `OpenAiClient`. The order carries meaning:
probing takes the lowest index that answers, so local Ollama comes first and anything marked
`cloud` comes last. The flag marks the trust boundary, not the protocol: a `llama-server` on your
own machine speaks the OpenAI protocol but is not cloud.

`OpenAiClient` mirrors the `OllamaClient` surface so the manager can hold both interchangeably. It
reassembles the fragmented delta format on the way in: OpenAI streams tool-call arguments as a JSON
*string* over arbitrarily many chunks, while `ChatController` expects Ollama's shape (arguments as
an object).

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
