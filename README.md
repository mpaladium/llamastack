# llamastack

**Offline, OpenAI-compatible inference engine for Linux and macOS.**  
Wraps [llama.cpp](https://github.com/ggerganov/llama.cpp) into a production-grade, installable service — auto-detects your GPU, manages model downloads, and exposes the same API surface as OpenAI so existing tools need zero code changes.

---

## What it does

- Runs a **generative model** server (`/v1/chat/completions`, `/v1/completions`)
- Runs an **embedding model** server (`/v1/embeddings`)
- Routes both through a single **Nginx gateway** on `:8080`
- Manages services via **systemd** (Linux) or **launchd** (macOS)
- Downloads and switches models by **alias** — no manual URLs
- Supports **any quantized GGUF** from Hugging Face or local disk
- Fully **air-gap capable** — no outbound connections from inference processes

---

## Requirements

| | Linux | macOS |
|---|---|---|
| OS | Ubuntu 20.04+, Debian 11+, Fedora 38+, Arch | macOS 12+ (Intel or Apple Silicon) |
| RAM | 16 GB minimum, 32 GB+ recommended | 16 GB+ (unified memory) |
| GPU (optional) | NVIDIA with CUDA 12+ | Apple Metal (built-in) |
| Disk | 10 GB+ for models | 10 GB+ for models |
| Tools | `build-essential`, `cmake`, `git`, `curl` | Xcode CLI tools, Homebrew |

---

## Installation

```bash
git clone https://github.com/yourorg/llamastack
cd llamastack
sudo ./install.sh
```

### Options

```
--prefix PATH    Install to a custom directory (default: /opt/llamastack)
--no-gpu         Force CPU-only mode (disables CUDA/Metal detection)
--skip-build     Skip llama.cpp compilation (use if binary already present)
-y, --yes        Non-interactive — skip confirmation prompts
```

### Examples

```bash
# Standard install
sudo ./install.sh

# Custom prefix, no interaction
sudo ./install.sh --prefix /srv/llamastack --yes

# CPU-only on a headless server
sudo ./install.sh --no-gpu --yes
```

The installer:
1. Detects your OS, architecture, and GPU (CUDA / Metal / CPU)
2. Installs system dependencies (apt / dnf / pacman / brew)
3. Clones and compiles llama.cpp with correct GPU flags
4. Creates directory layout under the prefix
5. Writes `llamastack.conf` with hardware-tuned defaults
6. Registers systemd units (Linux) or launchd plists (macOS)
7. Installs the `llamastack` CLI to `/usr/local/bin`

---

## Quick start

```bash
# 1. Download models
llamastack pull gen   mistral-7b     # ~4.1 GB
llamastack pull embed nomic          # ~280 MB

# 2. Start services
llamastack start

# 3. Check status
llamastack status

# 4. Test
llamastack chat "Summarise SOC 2 Type II requirements"
llamastack embed "audit log: user accessed PII record"
```

---

## CLI reference

### Service control

```bash
llamastack start              # Start gen + embed servers
llamastack start gen          # Start only the generative server
llamastack stop               # Stop all
llamastack restart            # Restart all
llamastack restart embed      # Restart only embed server
llamastack status             # Health check, VRAM usage, active models
```

### Models

```bash
# List all aliases in the registry
llamastack models list

# Download a model by alias
llamastack pull gen   mistral-7b
llamastack pull embed nomic

# Switch to an already-downloaded model (no re-download)
llamastack use gen llama3.1-8b

# Point at any GGUF file on disk
llamastack use gen /data/my-custom-model.gguf

# Add a model to the registry
llamastack models add my-model gen TheBloke/SomeModel-GGUF some-model-Q4_K_M.gguf "My custom model"

# Remove from registry
llamastack models remove my-model
```

### Testing

```bash
llamastack chat "What is zero trust architecture?"
llamastack embed "this sentence will be embedded"
```

### Configuration

```bash
llamastack config                          # Print all settings
llamastack config GEN_CTX_SIZE 16384       # Change context window
llamastack config BIND_HOST 0.0.0.0        # Expose on LAN
llamastack config API_KEY my-secret-key    # Enable bearer auth
llamastack restart                         # Apply changes
```

### Logs

```bash
llamastack logs              # Last 50 lines of gen server
llamastack logs embed 100    # Last 100 lines of embed server
```

### Gateway

```bash
llamastack nginx-start       # Start standalone Nginx on :8080
llamastack nginx-stop        # Stop it
```

### Maintenance

```bash
llamastack update            # Pull latest llama.cpp and recompile
llamastack version           # Show version info
llamastack uninstall         # Remove everything
```

---

## Available model aliases

### Generative models

| Alias | Model | VRAM | Notes |
|---|---|---|---|
| `mistral-7b` | Mistral 7B Instruct Q4_K_M | ~4 GB | **Default — best general purpose** |
| `mistral-7b-q8` | Mistral 7B Instruct Q8 | ~7 GB | Max quality at 7B |
| `llama3.1-8b` | Llama 3.1 8B Instruct Q4_K_M | ~5 GB | Strong instruction following |
| `llama3.1-8b-q8` | Llama 3.1 8B Instruct Q8 | ~9 GB | Higher quality |
| `llama3.2-3b` | Llama 3.2 3B Q4_K_M | ~2 GB | Fast, lightweight |
| `phi3.5-mini` | Phi-3.5 Mini 3.8B Q4_K_M | ~2.5 GB | Efficient reasoning |
| `qwen2.5-7b` | Qwen 2.5 7B Instruct Q4_K_M | ~5 GB | Strong structured output |
| `gemma2-9b` | Gemma 2 9B Instruct Q4_K_M | ~6 GB | Google, well-rounded |
| `deepseek-r1-7b` | DeepSeek R1 Distill 7B Q4_K_M | ~5 GB | Reasoning chains |
| `mistral-nemo` | Mistral Nemo 12B Q4_K_M | ~8 GB | 128k context |
| `llama3.1-70b-q2` | Llama 3.1 70B IQ2_M | ~22 GB | Large model, CPU+GPU split |

### Embedding models

| Alias | Model | Dimensions | Notes |
|---|---|---|---|
| `nomic` | Nomic Embed Text v1.5 F16 | 768 | **Default — excellent general embedding** |
| `nomic-q8` | Nomic Embed Text v1.5 Q8 | 768 | Smaller footprint |
| `mxbai` | MixedBread mxbai-embed-large | 1024 | MTEB leaderboard leader |
| `bge-small` | BGE Small EN v1.5 | 384 | Ultra-fast, minimal VRAM |
| `bge-large` | BGE Large EN v1.5 | 1024 | Strong semantic similarity |
| `e5-large` | E5-large-v2 | 1024 | Multilingual capable |

---

## Using custom / any GGUF model

You can use **any GGUF file** from Hugging Face or local disk:

```bash
# From disk
llamastack use gen /path/to/my-model-Q5_K_M.gguf

# Add to registry for repeat use
llamastack models add mixtral-8x7b gen \
  TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF \
  mixtral-8x7b-instruct-v0.1.Q4_K_M.gguf \
  "Mixtral MoE 8x7B Instruct Q4"

llamastack pull gen mixtral-8x7b
```

### Quantisation guide

| Quant | VRAM | Quality | Notes |
|---|---|---|---|
| `Q2_K` / `IQ2_M` | Lowest | ⭐⭐ | For RAM-limited; noticeably degraded |
| `Q4_K_M` | Medium | ⭐⭐⭐⭐ | **Sweet spot** — default recommendation |
| `Q5_K_M` | Medium+ | ⭐⭐⭐⭐½ | Marginal quality gain over Q4_K_M |
| `Q8_0` | High | ⭐⭐⭐⭐⭐ | Near-lossless; 2× VRAM of Q4 |
| `F16` | Highest | ⭐⭐⭐⭐⭐ | Full precision; only for embed models |

---

## Connecting your tools

The gateway runs on `http://localhost:8080/v1` and is drop-in compatible with any OpenAI client.

### Python / openai-python

```python
import openai

client = openai.OpenAI(
    base_url="http://localhost:8080/v1",
    api_key="llamastack"   # any non-empty string
)

# Chat
resp = client.chat.completions.create(
    model="mistral-7b",    # or any alias
    messages=[{"role": "user", "content": "Explain GDPR Article 17."}]
)
print(resp.choices[0].message.content)

# Embeddings
emb = client.embeddings.create(
    model="nomic",
    input=["audit log: access to PII record 2024-01-15"]
)
print(len(emb.data[0].embedding))  # 768
```

### LangChain

```python
from langchain_openai import ChatOpenAI, OpenAIEmbeddings

llm = ChatOpenAI(
    base_url="http://localhost:8080/v1",
    api_key="llamastack",
    model="mistral-7b"
)

embeddings = OpenAIEmbeddings(
    base_url="http://localhost:8080/v1",
    api_key="llamastack",
    model="nomic"
)
```

### LlamaIndex

```python
from llama_index.llms.openai import OpenAI
from llama_index.embeddings.openai import OpenAIEmbedding

llm = OpenAI(api_base="http://localhost:8080/v1", api_key="x", model="mistral-7b")
embed = OpenAIEmbedding(api_base="http://localhost:8080/v1", api_key="x", model="nomic")
```

### curl

```bash
# Chat
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mistral-7b","messages":[{"role":"user","content":"Hello"}]}'

# Embed
curl http://localhost:8080/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model":"nomic","input":"text to embed"}'

# List models
curl http://localhost:8080/v1/models
```

---

## Configuration reference

Edit `${PREFIX}/config/llamastack.conf` then run `llamastack restart`.

| Key | Default | Description |
|---|---|---|
| `BIND_HOST` | `127.0.0.1` | `0.0.0.0` to expose on network |
| `GEN_PORT` | `8001` | Internal gen server port |
| `EMBED_PORT` | `8002` | Internal embed server port |
| `GATEWAY_PORT` | `8080` | Nginx gateway port |
| `API_KEY` | *(empty)* | Bearer token — leave empty to disable |
| `GEN_GPU_LAYERS` | auto | Layers on GPU; `0` = CPU, `999` = all |
| `GEN_CTX_SIZE` | `8192` | Context window tokens |
| `GEN_PARALLEL` | `4` | Concurrent request slots |
| `GEN_FLASH_ATTN` | `true` | Flash attention (CUDA/Metal) |
| `GEN_CONT_BATCHING` | `true` | Continuous batching (throughput) |
| `EMBED_POOLING` | `mean` | `mean`, `cls`, or `last` |
| `LOG_FORMAT` | `json` | `json` or `text` |
| `LOG_RETAIN_DAYS` | `90` | Journal/log file retention |

---

## GRC compliance notes

- **No outbound network access** from inference processes (`NoNewPrivileges`, `RestrictAddressFamilies` on Linux)
- All model weights stored in `${PREFIX}/models/` — no runtime downloads
- Services run under a dedicated locked-down `llamastack` user (Linux)
- JSON structured logs via journald (Linux) or log files (macOS) with configurable retention
- API key authentication via `API_KEY` in config
- Nginx gateway enforces connection timeouts; internal ports bound to `127.0.0.1` by default
- Air-gap deployment: run `install.sh --skip-build` with pre-built binary + pre-downloaded GGUF

---

## Directory layout

```
/opt/llamastack/
├── bin/
│   ├── llamastack          ← CLI
│   ├── llama-server        ← inference engine (built by installer)
│   ├── _start-gen.sh       ← service launcher (generative)
│   └── _start-embed.sh     ← service launcher (embedding)
├── config/
│   ├── llamastack.conf     ← main configuration
│   ├── models.conf         ← model alias registry
│   └── nginx-gateway.conf  ← Nginx virtual host
├── models/
│   ├── gen-model.gguf      ← active generative model
│   └── embed-model.gguf    ← active embedding model
├── logs/                   ← macOS log files
├── run/                    ← PID files
├── src/llama.cpp/          ← source (for updates)
└── docs/                   ← this documentation
```

---

## Troubleshooting

**Service fails to start**
```bash
llamastack logs gen 100          # check error output
llamastack status                # see health state
```
Most common causes: model file missing (`llamastack pull gen <alias>`) or VRAM exhaustion (reduce `GEN_CTX_SIZE` or `GEN_GPU_LAYERS` in config).

**Out of VRAM**
```bash
llamastack config GEN_GPU_LAYERS 20    # offload fewer layers
llamastack config GEN_CTX_SIZE 4096   # reduce context
llamastack restart gen
```

**Slow performance (CPU fallback)**
Check that `GPU_BACKEND` in config is `cuda` or `metal`. If not, reinstall without `--no-gpu`.

**Port already in use**
```bash
llamastack config GEN_PORT 9001
llamastack config EMBED_PORT 9002
llamastack restart
```

**Model checksum / corrupt download**
Delete `${PREFIX}/models/gen-model.gguf` and re-run `llamastack pull gen <alias>`.

---

## Updating

```bash
llamastack update         # pulls latest llama.cpp and recompiles
llamastack restart        # applies updated binary
```

---

## Uninstalling

```bash
sudo llamastack uninstall           # interactive — prompts about models
sudo ./uninstall.sh --keep-models   # remove binaries, keep downloaded models
```

---

## License

MIT. llama.cpp is MIT-licensed. Model weights are subject to their respective licenses (Meta, Mistral, Google, etc.) — verify for your use case before deploying in production.
