# llamastack v2

**Offline, OpenAI-compatible inference engine for Linux and macOS.**  
Wraps [llama.cpp](https://github.com/ggml-org/llama.cpp) into a production-grade installable service with automatic GPU detection, model management, systemd/launchd integration, and an Nginx gateway — all controlled through a single `llamastack` CLI.

---

## Table of contents

1. [Requirements](#requirements)
2. [Package contents](#package-contents)
3. [Installation](#installation)
4. [Post-install setup](#post-install-setup)
5. [CLI reference](#cli-reference)
6. [Configuration reference](#configuration-reference)
7. [Model management](#model-management)
8. [Nginx gateway](#nginx-gateway)
9. [Connecting your tools](#connecting-your-tools)
10. [Optimisation guide](#optimisation-guide)
11. [Troubleshooting](#troubleshooting)
12. [Known issues and fixes](#known-issues-and-fixes)
13. [Uninstalling](#uninstalling)
14. [GRC compliance notes](#grc-compliance-notes)
15. [Directory layout](#directory-layout)

---

## Requirements

| | Linux | macOS |
|---|---|---|
| OS | Ubuntu 20.04+, Debian 11+, Fedora 38+, Arch, Rocky/Alma | macOS 12+ |
| RAM | 16 GB minimum | 16 GB+ unified memory |
| GPU | NVIDIA CUDA 12+ (CUDA 13+ for RTX 5000 Blackwell) | Apple Metal built-in |
| Disk | 10 GB+ | 10 GB+ |

> **RTX 5000 Blackwell (sm_120):** Requires CUDA 13+ toolkit — NOT the Ubuntu
> packaged `nvidia-cuda-toolkit`. Install from NVIDIA directly:
> ```bash
> wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
> sudo dpkg -i cuda-keyring_1.1-1_all.deb && sudo apt update
> sudo apt install -y cuda-toolkit-13-2
> ```

---

## Package contents

```
llamastack/
├── install.sh       ← single-file installer (CLI embedded inside as heredoc)
├── uninstall.sh     ← clean removal with keep-models option
└── docs/
    └── README.md    ← this file
```

The installer is **self-contained** — the entire CLI is a heredoc inside
`install.sh`. Copy the single file to any machine and it works.

---

## Installation

### Standard (builds llama.cpp from source)

```bash
sudo ./install.sh
```

### Pre-built binary (recommended if you already compiled llama.cpp)

```bash
sudo LLAMASTACK_PREBUILT=/path/to/llama.cpp/build ./install.sh
```

Copies `llama-server` and all companion `.so` shared libraries, registers with
`ldconfig`, writes config and service units.

### All options

```
sudo ./install.sh [options]

  --prefix PATH      Install directory   (default: /opt/llamastack)
  --no-gpu           Force CPU-only mode
  --skip-build       Skip compilation; binary at PREFIX/bin/llama-server
  -y, --yes          Non-interactive
  -h, --help         This help

Environment variables:
  LLAMASTACK_PREFIX      Override install prefix
  LLAMASTACK_PREBUILT    Path to existing llama.cpp build dir
  LLAMASTACK_CUDA_ROOT   Override CUDA toolkit detection
                         e.g. sudo LLAMASTACK_CUDA_ROOT=/usr/local/cuda-13.2 ./install.sh
```

### What the installer does

1. Detects OS, CPU arch, GPU backend (CUDA / Metal / CPU)
2. Installs system dependencies via apt / dnf / pacman / brew
3. Clones and compiles llama.cpp **or** copies a pre-built binary + `.so` files
4. Registers shared libraries with `ldconfig`
5. Creates `/opt/llamastack/{bin,config,models,logs,run,src,docs}`
6. Creates locked-down `llamastack` service user (Linux)
7. Writes `llamastack.conf` with hardware-tuned defaults
8. Writes `models.conf` — 17 pre-registered model aliases
9. Writes complete `nginx-gateway.conf` with `http{}` wrapper
10. Writes `_start-gen.sh`, `_start-embed.sh` launcher scripts with `LD_LIBRARY_PATH`
11. Writes `_check-gen.sh`, `_check-embed.sh` pre-start validation scripts
12. Installs systemd units (Linux) or launchd plists (macOS)
13. Installs `llamastack` CLI to `/usr/local/bin/`

---

## Post-install setup

### 1. Fix config after a pre-built install

```bash
sudo llamastack fix-config
```

Detects GPU, sets `GPU_BACKEND=cuda`, `GEN_GPU_LAYERS=40` (or 99 for 16 GB+
VRAM), and resolves any `${PREFIX}` / `${MODEL_DIR}` literal strings.

### 2. Place your models

```bash
# Pull from Hugging Face by alias
llamastack models list
llamastack pull gen   granite4.1-8b
llamastack pull embed nomic

# Or point at a file already on disk
llamastack use gen /path/to/<downloaded-model>.gguf
llamastack use embed /path/to/<downloaded-embed-model>.gguf
```

> **Important — model file permissions:**  
> Models in `/opt/llamastack/models/` work automatically.  
> Models elsewhere need to be readable by the `llamastack` service user:
> ```bash
> # Make parent directories traversable
> sudo chmod o+x /home/user /home/user/models
> # Make model file readable
> sudo chmod o+r /home/user/models/model.gguf
> # OR move into /opt/llamastack/models/ (recommended)
> sudo mv /path/to/model.gguf /opt/llamastack/models/gen-model.gguf
> sudo chown llamastack:llamastack /opt/llamastack/models/gen-model.gguf
> llamastack use gen /opt/llamastack/models/gen-model.gguf
> ```

### 3. Start and verify

```bash
llamastack start
llamastack status
llamastack chat "Explain GRC compliance"
```

---

## CLI reference

### Service control

| Command | Description |
|---|---|
| `llamastack start [gen\|embed]` | Start one or both servers |
| `llamastack stop [gen\|embed]` | Stop one or both |
| `llamastack restart [gen\|embed]` | Stop then start |
| `llamastack status` | State, health check, VRAM, active models |

### Model management

| Command | Description |
|---|---|
| `llamastack models list` | All aliases; marks currently active ones |
| `llamastack models add <alias> gen\|embed <repo> <file> [desc]` | Add to registry |
| `llamastack models remove <alias>` | Remove from registry |
| `llamastack pull gen <alias>` | Download generative model |
| `llamastack pull embed <alias>` | Download embedding model |
| `llamastack use gen <alias\|/path>` | Switch gen model (no re-download) |
| `llamastack use embed <alias\|/path>` | Switch embed model |

### Testing

| Command | Description |
|---|---|
| `llamastack chat "prompt"` | Stream a chat completion to terminal |
| `llamastack embed "text"` | Show embedding dimensions and L2 norm |

### Configuration and healing

| Command | Description |
|---|---|
| `llamastack config` | Print all config values |
| `llamastack config KEY VALUE` | Update one value, shows restart hint |
| `llamastack fix-config` | Auto-detect GPU/CUDA, heal unexpanded variables |
| `llamastack fix-bin [/path]` | Set or find the llama-server binary path |
| `llamastack fix-libs [/build]` | Copy .so libs + update ldconfig |
| `llamastack fix-models-dir` | Fix models/ permissions + path variables |

### Diagnostics and maintenance

| Command | Description |
|---|---|
| `llamastack diagnose` | Full health check — start here on any problem |
| `llamastack version` | Versions, binary path, live GPU info |
| `llamastack logs [gen\|embed] [N]` | Tail last N lines (default: gen 50) |
| `llamastack update` | Pull latest llama.cpp source and recompile |
| `llamastack nginx-start` | Start Nginx gateway on :8080 |
| `llamastack nginx-stop` | Stop Nginx |
| `llamastack uninstall` | Interactive removal |

---

## Configuration reference

File: `/opt/llamastack/config/llamastack.conf`  
Edit and run `llamastack restart` to apply.

### Core paths (must be absolute — no shell variables)

```bash
PREFIX="/opt/llamastack"
LLAMA_BIN="/opt/llamastack/bin/llama-server"
MODEL_DIR="/opt/llamastack/models"
GEN_MODEL="/opt/llamastack/models/gen-model.gguf"
EMBED_MODEL="/opt/llamastack/models/embed-model.gguf"
```

### Network

```bash
BIND_HOST="127.0.0.1"   # 0.0.0.0 to expose on LAN
GEN_PORT=8001
EMBED_PORT=8002
GATEWAY_PORT=8080
API_KEY=""               # non-empty enables Bearer token auth
```

### Generative server

```bash
GEN_GPU_LAYERS=40        # 0=CPU, 99=all layers on GPU
GEN_CTX_SIZE=8192        # context window tokens
GEN_BATCH_SIZE=512
GEN_PARALLEL=4           # concurrent request slots
GEN_THREADS=8
GEN_FLASH_ATTN=true
GEN_CONT_BATCHING=true
GEN_CACHE_REUSE=256
```

### Embedding server

```bash
EMBED_GPU_LAYERS=99      # embed models are small — all layers on GPU
EMBED_CTX_SIZE=2048
EMBED_PARALLEL=8
EMBED_POOLING="mean"     # mean | cls | last
```

---

## Model management

### Built-in aliases

```bash
llamastack models list    # shows all 17 pre-registered models
```

Key aliases:

| Alias | Size | VRAM | Notes |
|---|---|---|---|
| `mistral-7b` | 4.1 GB | 5 GB | Best general-purpose default |
| `llama3.1-8b` | 4.9 GB | 6 GB | Strong instruction following |
| `llama3.2-3b` | 1.9 GB | 2.5 GB | Lightweight, very fast |
| `deepseek-r1-7b` | 4.9 GB | 6 GB | Reasoning chains |
| `nomic` | 280 MB | 0.5 GB | Best general embedding (768-dim) |
| `mxbai` | 670 MB | 1 GB | MTEB leader (1024-dim) |
| `bge-small` | 130 MB | 0.3 GB | Ultra-fast (384-dim) |

### IBM Granite 4 (recommended for GRC)

```bash
llamastack models add granite4.1-8b gen \
  bartowski/ibm-granite_granite-4.1-8b-GGUF \
  ibm-granite_granite-4.1-8b-Q5_K_M.gguf \
  "IBM Granite 4.1 8B Q5_K_M — GRC/compliance"

llamastack pull gen granite4.1-8b
```

> Granite 4 models require `--jinja` in the start script (already included in
> the default `_start-gen.sh` written by the installer).

### Custom models

```bash
# Any GGUF from HuggingFace
llamastack models add my-model gen \
  TheBloke/MyModel-GGUF my-model-Q4_K_M.gguf "Description"
llamastack pull gen my-model

# Any GGUF already on disk
llamastack use gen /data/models/custom.gguf
```

---

## Nginx gateway

Routes both servers through a single port:

```
:8080/v1/chat/completions  →  :8001 (gen)
:8080/v1/completions       →  :8001 (gen)
:8080/v1/embeddings        →  :8002 (embed)
:8080/v1/models            →  :8001 (gen)
:8080/health               →  :8001 (gen)
```

```bash
llamastack nginx-start
curl -s http://127.0.0.1:8080/health
llamastack nginx-stop
```

---

## Connecting your tools

```python
import openai
client = openai.OpenAI(base_url="http://localhost:8080/v1", api_key="any-string")

# Chat
resp = client.chat.completions.create(
    model="local",
    messages=[{"role": "user", "content": "Summarise ISO 27001"}],
    max_tokens=512
)

# Embeddings
emb = client.embeddings.create(model="local", input=["audit log entry"])
print(len(emb.data[0].embedding))  # 768
```

LangChain: `ChatOpenAI(base_url="http://localhost:8080/v1", api_key="x")`  
LlamaIndex: `OpenAI(api_base="http://localhost:8080/v1", api_key="x")`

---

## Optimisation guide

### RTX 5070 Ti (16 GB GDDR7) — optimal start script

```bash
sudo tee /opt/llamastack/bin/_start-gen.sh > /dev/null << 'EOF'
#!/usr/bin/env bash
source /opt/llamastack/config/llamastack.conf
BIN_DIR="$(dirname "$(readlink -f "${LLAMA_BIN}")")"
export LD_LIBRARY_PATH="${BIN_DIR}:${LD_LIBRARY_PATH:-}"
[[ -n "${CUDA_ROOT:-}" ]] && export LD_LIBRARY_PATH="${CUDA_ROOT}/lib64:${LD_LIBRARY_PATH}"
exec "${LLAMA_BIN}" \
  --model        "${GEN_MODEL}"           \
  --host         "${BIND_HOST:-127.0.0.1}"\
  --port         "${GEN_PORT:-8001}"      \
  --n-gpu-layers 99    \
  --ctx-size     32768 \
  --batch-size   512   \
  --ubatch-size  512   \
  --flash-attn   on    \
  --cont-batching      \
  --parallel     4     \
  --threads      8     \
  --cache-type-k q8_0  \
  --cache-type-v q8_0  \
  --defrag-thold 0.1   \
  --mlock              \
  --jinja              \
  --metrics            \
  --no-webui
EOF
sudo chmod +x /opt/llamastack/bin/_start-gen.sh
sudo systemctl restart llamastack-gen
```

### Performance by model on RTX 5070 Ti

| Model | VRAM | Expected tok/s |
|---|---|---|
| Llama 3.2 3B Q4_K_M | 2 GB | 120–150 |
| Mistral 7B Q4_K_M | 4.1 GB | 80–100 |
| Granite 4.1 8B Q5_K_M | 5.7 GB | **70–90** |
| Granite 4.0 H-Small Q4_K_M | 6 GB | 60–80 |

### Monitor GPU during inference

```bash
watch -n 0.5 'nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total \
  --format=csv,noheader,nounits | \
  awk -F, "{printf \"GPU: %s%%  VRAM: %s/%s MB\n\",\$1,\$2,\$3}"'
```

---

## Troubleshooting

### Step 1 — always run diagnose first

```bash
llamastack diagnose
```

Checks every layer: config, binary, model files, service state, HTTP health,
GPU detection, model path resolution. Shows a fix hint for each failure.

---

### Step 2 — check logs

```bash
llamastack logs gen 50
# or directly:
sudo journalctl -u llamastack-gen -n 50 --no-pager
# live watch:
sudo journalctl -fu llamastack-gen
```

---

### Error reference

| Error in journal | Cause | Fix |
|---|---|---|
| `Model not found: /path/to/model` | Config path wrong or file not there | `llamastack use gen /correct/path.gguf` |
| `libmtmd.so.0: cannot open shared object file` | .so files not copied or not in ldconfig | `llamastack fix-libs /path/to/llama.cpp/build` |
| `error: invalid argument: --flash-attn` | Flag needs explicit value in new builds | `sed -i 's/--flash-attn$/--flash-attn on/'` in `_start-gen.sh` |
| `error: invalid argument: --log-format` | Flag removed in new llama.cpp builds | Remove `--log-format` from `_start-gen.sh` |
| `Failed to set up mount namespacing: /data` | `ReadWritePaths` lists a non-existent dir | Rewrite service unit without `/data /mnt /projects` |
| `bad substitution: MODEL=${$MVAR:-}` | Old broken check script | Overwrite `_check-gen.sh` — see Known Issues |
| `Permission denied` reading model | Service user can't traverse home dir | `sudo chmod o+x` each dir in path, `o+r` on file |
| `CUDA Toolkit not found` | nvcc not installed or not found | `sudo LLAMASTACK_CUDA_ROOT=/usr/local/cuda-13.2 ./install.sh` |
| `Unsupported gpu architecture compute_120` | System nvcc is too old for Blackwell | Install CUDA 13+ from NVIDIA — see Requirements |
| `upstream directive not allowed here` | Nginx config missing `http{}` wrapper | Overwrite nginx-gateway.conf — see Nginx section |
| `Job for llamastack-gen.service failed` (no detail) | Check `ExecStartPre` | Run `_check-gen.sh` manually: `sudo -u llamastack /opt/llamastack/bin/_check-gen.sh` |

---

### Chat returns nothing / `Chat → default`

```bash
# Is the server up?
llamastack status

# Is it still loading the model? (can take 10-60s for large models)
llamastack logs gen 10

# Test API directly
curl -s http://127.0.0.1:8001/health
curl -s http://127.0.0.1:8001/v1/models | python3 -m json.tool

# Raw chat request
curl -s http://127.0.0.1:8001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"hi"}],"max_tokens":10}'
```

---

### Journal logs printing in terminal after chat

Background `journalctl -fu` still running from a previous debug session:

```bash
kill %1 2>/dev/null || pkill -f "journalctl.*llamastack"
```

---

### GPU shows as `cpu` after prebuilt install

```bash
sudo llamastack fix-config
llamastack config GEN_GPU_LAYERS 99
llamastack restart gen
```

---

### Slow inference despite GPU present

```bash
# Confirm layers are on GPU
ldd /opt/llamastack/bin/llama-server | grep -i cuda   # should show libcuda.so
grep GEN_GPU_LAYERS /opt/llamastack/config/llamastack.conf  # should be 40 or 99

# Watch GPU utilisation during a request
nvidia-smi dmon -s u -d 1 &
llamastack chat "test"
```

---

## Known issues and fixes

### `_check-gen.sh: bad substitution` (v1 installer bug)

```bash
sudo tee /opt/llamastack/bin/_check-gen.sh > /dev/null << 'EOF'
#!/usr/bin/env bash
source /opt/llamastack/config/llamastack.conf
[[ -f "${GEN_MODEL}" ]] || { echo "ERROR: Model not found: ${GEN_MODEL}"; echo "Run: llamastack use gen /path/to/model.gguf"; exit 1; }
echo "Model OK: ${GEN_MODEL}"
EOF

sudo tee /opt/llamastack/bin/_check-embed.sh > /dev/null << 'EOF'
#!/usr/bin/env bash
source /opt/llamastack/config/llamastack.conf
[[ -f "${EMBED_MODEL}" ]] || { echo "WARN: Embed model not found: ${EMBED_MODEL}"; exit 0; }
echo "Model OK: ${EMBED_MODEL}"
EOF

sudo chmod +x /opt/llamastack/bin/_check-gen.sh /opt/llamastack/bin/_check-embed.sh
sudo systemctl restart llamastack-gen llamastack-embed
```

---

### Config contains literal `${PREFIX}` strings

```bash
sudo sed -i \
  -e 's|${PREFIX}|/opt/llamastack|g' \
  -e 's|${MODEL_DIR}|/opt/llamastack/models|g' \
  /opt/llamastack/config/llamastack.conf

# Or use the built-in healer
sudo llamastack fix-models-dir
```

---

### `libmtmd.so.0` missing

```bash
# Find .so files in your build
find //path/to -name "*.so*" 2>/dev/null | sort

# Copy with archive mode (preserves symlinks)
sudo cp -a /path/to/llama.cpp/build/bin/*.so* /opt/llamastack/bin/

# Register
echo "/opt/llamastack/bin" | sudo tee /etc/ld.so.conf.d/llamastack.conf
sudo ldconfig
ldconfig -p | grep libmtmd    # should show an entry

sudo systemctl restart llamastack-gen
```

---

### `--flash-attn` swallowing `--cont-batching`

Recent llama.cpp changed the flag from boolean to valued:

```bash
sudo sed -i 's|--flash-attn on||; s|--flash-attn$|--flash-attn on|' \
  /opt/llamastack/bin/_start-gen.sh
# Then re-add it properly in the right position — see Optimisation section above
```

---

### Service unit namespace failure (`/data: No such file`)

```bash
sudo tee /etc/systemd/system/llamastack-gen.service > /dev/null << 'EOF'
[Unit]
Description=llamastack generative inference server
After=network.target

[Service]
Type=simple
User=llamastack
Group=llamastack
EnvironmentFile=/opt/llamastack/config/llamastack.conf
ExecStartPre=/opt/llamastack/bin/_check-gen.sh
ExecStart=/opt/llamastack/bin/_start-gen.sh
Restart=always
RestartSec=5
TimeoutStartSec=120
StandardOutput=journal
StandardError=journal
SyslogIdentifier=llamastack-gen
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/llamastack-embed.service > /dev/null << 'EOF'
[Unit]
Description=llamastack embedding inference server
After=network.target

[Service]
Type=simple
User=llamastack
Group=llamastack
EnvironmentFile=/opt/llamastack/config/llamastack.conf
ExecStartPre=/opt/llamastack/bin/_check-embed.sh
ExecStart=/opt/llamastack/bin/_start-embed.sh
Restart=always
RestartSec=5
TimeoutStartSec=120
StandardOutput=journal
StandardError=journal
SyslogIdentifier=llamastack-embed
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl start llamastack-gen llamastack-embed
```

---

## Uninstalling

```bash
# Interactive — prompts about models
sudo ./uninstall.sh

# Keep models, remove everything else
sudo ./uninstall.sh --keep-models

# Fully silent
sudo ./uninstall.sh --yes
```

### What gets removed

- Stops and disables `llamastack-gen.service` and `llamastack-embed.service`
- Removes `/etc/systemd/system/llamastack-*.service`
- Removes `/usr/local/bin/llamastack`
- Removes `llamastack` service user
- Cleans `git config safe.directory` entries
- Removes `/etc/ld.so.conf.d/llamastack.conf` and runs `ldconfig`
- Removes `PREFIX/{bin,config,src,logs,run,docs}`
- Optionally removes `PREFIX/models/`

### Manual cleanup if uninstaller fails

```bash
sudo systemctl stop disable llamastack-gen llamastack-embed 2>/dev/null
sudo rm -f /etc/systemd/system/llamastack-{gen,embed}.service
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/llamastack
sudo rm -f /etc/ld.so.conf.d/llamastack.conf && sudo ldconfig
sudo userdel llamastack 2>/dev/null
sudo rm -rf /opt/llamastack
```

---

## GRC compliance notes

| Control | Implementation |
|---|---|
| No outbound data | Inference processes have no internet access; all weights are local GGUF files |
| Air-gap deployment | `LLAMASTACK_PREBUILT` + pre-downloaded GGUFs — zero network access needed at runtime |
| Audit logging | All requests logged to systemd journald with 90-day retention (`LOG_RETAIN_DAYS`) |
| Authentication | `API_KEY` in config enables Bearer token on all endpoints |
| Service isolation | `llamastack` system user, no shell, `NoNewPrivileges=true` |
| Local-only by default | `BIND_HOST=127.0.0.1` — unreachable from network unless explicitly changed |
| Model provenance | IBM Granite 4 is ISO/IEC 42001:2023 certified and cryptographically signed |

---

## Directory layout

```
/opt/llamastack/
├── bin/
│   ├── llamastack            ← CLI (all subcommands embedded)
│   ├── llama-server          ← inference engine binary
│   ├── lib*.so*              ← companion shared libs (libmtmd, libggml, libllama...)
│   ├── _start-gen.sh         ← generative server launcher (edit for custom flags)
│   ├── _start-embed.sh       ← embedding server launcher
│   ├── _check-gen.sh         ← ExecStartPre: validates GEN_MODEL exists
│   └── _check-embed.sh       ← ExecStartPre: validates EMBED_MODEL (exit 0 if missing)
├── config/
│   ├── llamastack.conf       ← main config (edit + llamastack restart)
│   ├── models.conf           ← model alias registry
│   └── nginx-gateway.conf    ← complete standalone Nginx config
├── models/
│   ├── gen-model.gguf
│   └── embed-model.gguf
├── logs/
├── run/
├── src/llama.cpp/
└── docs/README.md

/etc/systemd/system/
    llamastack-gen.service
    llamastack-embed.service

/etc/ld.so.conf.d/llamastack.conf    ← registers /opt/llamastack/bin

/usr/local/bin/llamastack            ← symlink
```

---

## Changelog

### v2.0
- `fix-config`, `fix-bin`, `fix-libs`, `fix-models-dir` healing commands
- `diagnose` command with per-layer health checks and fix hints
- CLI fully embedded in installer — single-file package
- `--flash-attn on` explicit value (breaking change in llama.cpp b8800+)
- Removed `--log-format` flag (removed from llama.cpp)
- Nginx config now a complete standalone file with `events{}` and `http{}` blocks
- `ExecStartPre` replaced with simple `_check-gen.sh` bash scripts
- `ProtectSystem=strict` removed — was blocking external model paths
- `ReadWritePaths` no longer includes non-existent directories
- Config heredoc expanded to literal paths at write time
- `_copy_prebuilt` copies all `.so` files with `-a` (preserves symlinks)
- `LD_LIBRARY_PATH` set in launcher scripts — survives ldconfig cache misses
- IBM Granite 4 registry entries + `--jinja` flag support
- `cmd_chat` shows actionable errors instead of silent `Chat → default`
- `cmd_status` reads GPU live from nvidia-smi not stale config

### v1.0
- Initial release
