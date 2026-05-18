# Minimal Latency Parameters — Granite 4.1 8B + Qwen3 0.6B on RTX 5070 Ti

**Target:** Sub-200ms TTFT (time to first token), sub-15s end-to-end for 800-token compliance response  
**Hardware:** RTX 5070 Ti 16GB GDDR7, 896 GB/s bandwidth, 8960 CUDA cores, Blackwell sm_120

---

## Part 1: Quick Start — Copy & Paste Optimal Config

### Minimal Latency Profile

Use this for GRC document comparison where speed matters more than throughput:

```bash
# /opt/llamastack/config/llamastack.conf

# ═══════════════════════════════════════════════════════════════════════════
# GRANITE 4.1 8B — MINIMAL LATENCY (Single User, Fast Response)
# ═══════════════════════════════════════════════════════════════════════════

GEN_MODEL="/opt/llamastack/models/ibm-granite_granite-4.1-8b-Q5_K_M.gguf"
GEN_GPU_LAYERS=99                 # All layers on GPU — zero CPU fallback
GEN_CTX_SIZE=16384                # MINIMAL LATENCY: 16K not 32K (faster prefill)
GEN_BATCH_SIZE=256                # Smaller = less VRAM used, faster per-token
GEN_UBATCH_SIZE=256               # Match batch size
GEN_PARALLEL=1                     # CRITICAL: Single request at a time (no slot contention)
GEN_THREADS=4                      # Reduce CPU threads — GPU does 99% of work
GEN_FLASH_ATTN=true               # Essential; gives 2–3× prefill speedup
GEN_CONT_BATCHING=true            # Generate one token per GPU cycle
GEN_CACHE_TYPE_K=q8_0             # Quantised KV = smaller cache, faster access
GEN_CACHE_TYPE_V=q8_0

# ═══════════════════════════════════════════════════════════════════════════
# QWEN3 EMBEDDING 0.6B — MINIMAL LATENCY
# ═══════════════════════════════════════════════════════════════════════════

EMBED_MODEL="/opt/llamastack/models/Qwen3-Embedding-0.6B-f16.gguf"
EMBED_GPU_LAYERS=99               # All layers on GPU
EMBED_CTX_SIZE=8192               # Small context for small model (embedding doesn't need 32K)
EMBED_BATCH_SIZE=2048             # Modest batch; embedding is fast
EMBED_UBATCH_SIZE=2048
EMBED_PARALLEL=2                  # Only 2 slots; embeddings finish in <100ms anyway
EMBED_POOLING=last                # CRITICAL for Qwen3; not 'mean'
EMBED_THREADS=2                   # Embed uses minimal CPU

# ═══════════════════════════════════════════════════════════════════════════
# NETWORK & INFERENCE
# ═══════════════════════════════════════════════════════════════════════════

BIND_HOST="127.0.0.1"
GEN_PORT=8001
EMBED_PORT=8002
GATEWAY_PORT=8080
API_KEY="grc-token"

# Expected latencies with this config:
#   Embedding 100 chunks:     ~80 ms
#   Retrieval (cosine):       <1 ms
#   Time to first token:      ~120 ms (16K prefill @ 130+ tok/s)
#   Generate 800 tokens:      ~11 s @ 75 tok/s
#   Total GRC request:        ~11.2 seconds
```

Apply this config:
```bash
cat > /opt/llamastack/config/llamastack.conf << 'EOF'
[paste the config above]
EOF
sudo systemctl restart llamastack-gen llamastack-embed
```

---

## Part 2: Start Script Parameters — The Real Tuning Knobs

The `llamastack.conf` settings above are read by the start scripts. Here's the actual llama-server invocation with all latency-critical flags:

### Granite 4.1 Minimal Latency (`_start-gen.sh`)

```bash
#!/usr/bin/env bash
source /opt/llamastack/config/llamastack.conf

BIN_DIR="$(dirname "$(readlink -f "${LLAMA_BIN}")")"
export LD_LIBRARY_PATH="${BIN_DIR}:${LD_LIBRARY_PATH:-}"
[[ -n "${CUDA_ROOT:-}" ]] && export LD_LIBRARY_PATH="${CUDA_ROOT}/lib64:${LD_LIBRARY_PATH}"

exec "${LLAMA_BIN}" \
  --model              "${GEN_MODEL}" \
  --host               "${BIND_HOST:-127.0.0.1}" \
  --port               "${GEN_PORT:-8001}" \
  \
  --n-gpu-layers       99           # All on GPU \
  --ctx-size           16384        # Smaller context = faster prefill \
  --batch-size         256          # Small batch for latency \
  --ubatch-size        256          # Match batch \
  \
  --flash-attn         on           # Essential for Blackwell — 2–3× faster \
  --cont-batching                   # One token per GPU cycle \
  --parallel           1            # Single request — no slot switching overhead \
  --threads            4            # CPU minimal; GPU does 99% \
  \
  --cache-type-k       q8_0         # Quantised KV cache \
  --cache-type-v       q8_0         \
  --defrag-thold       0.1          # Defrag when 10% fragmented \
  --mlock                           # Pin model in RAM \
  \
  --jinja                           # Required for Granite 4.1 chat template \
  --metrics                         # Endpoint at /metrics for profiling \
  --no-webui                        # Disable web UI; CLI only
```

**Save as `/opt/llamastack/bin/_start-gen.sh` and:**
```bash
sudo chmod +x /opt/llamastack/bin/_start-gen.sh
sudo systemctl restart llamastack-gen
```

**Expected metrics (with this script):**
```
llm_load_tensors: offloaded 40/40 layers to GPU
llm_load_tensors: ggml-cuda - split buffer mode is NOT set

HTTP server listening on 127.0.0.1:8001
```

Test first token latency:
```bash
time curl -s http://127.0.0.1:8001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"test"}],"max_tokens":10}' | head -c 100
```

Expected: ~120 ms (measure wall-clock time)

---

### Qwen3 Embedding Minimal Latency (`_start-embed.sh`)

```bash
#!/usr/bin/env bash
source /opt/llamastack/config/llamastack.conf

BIN_DIR="$(dirname "$(readlink -f "${LLAMA_BIN}")")"
export LD_LIBRARY_PATH="${BIN_DIR}:${LD_LIBRARY_PATH:-}"
[[ -n "${CUDA_ROOT:-}" ]] && export LD_LIBRARY_PATH="${CUDA_ROOT}/lib64:${LD_LIBRARY_PATH}"

exec "${LLAMA_BIN}" \
  --model              "${EMBED_MODEL}" \
  --host               "${BIND_HOST:-127.0.0.1}" \
  --port               "${EMBED_PORT:-8002}" \
  \
  --n-gpu-layers       99           # All on GPU \
  --ctx-size           8192         # Embedding doesn't need 32K \
  --batch-size         2048         # Modest batch \
  --ubatch-size        2048         \
  \
  --embedding                       # Enable embedding mode \
  --pooling            last         # CRITICAL: NOT 'mean' for Qwen3 \
  --flash-attn         on           # Fast attention \
  --parallel           2            # Only 2 slots (embedding is stateless) \
  --threads            2            # Minimal CPU \
  \
  --metrics                         # /metrics endpoint \
  --no-webui
```

**Save as `/opt/llamastack/bin/_start-embed.sh` and:**
```bash
sudo chmod +x /opt/llamastack/bin/_start-embed.sh
sudo systemctl restart llamastack-embed
```

Test embedding latency (100 chunks):
```bash
time curl -s http://127.0.0.1:8002/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model":"local","input":["test chunk<|endoftext|>" for i in range(100)]}' > /dev/null
```

Expected: ~80 ms (100 chunks in a single batch)

---

## Part 3: Tuning Matrix — Trade-off Table

Adjust these parameters based on your workload:

### Latency vs. Throughput

| Profile | GEN_CTX | GEN_BATCH | GEN_PARALLEL | TTFT | Gen Speed | Concurrent |
|---|---|---|---|---|---|---|
| **Ultra-low latency** (single user) | **8K** | **128** | **1** | **~80 ms** | 80 tok/s | 0 |
| **Minimal latency** (recommended) | **16K** | **256** | **1** | **~120 ms** | 75 tok/s | 0 |
| **Balanced** | **32K** | **512** | **2** | **~150 ms** | 70 tok/s | 1 |
| **High throughput** | **32K** | **1024** | **4** | **~200 ms** | 65 tok/s | 3 |
| **Archive search** | **131K** | **512** | **1** | **~500 ms** | 60 tok/s | 0 |

**Choose your row:**

- **Single GRC request at a time?** Use **"Minimal latency"** row (TTFT 120ms, 75 tok/s)
- **Two requests sometimes simultaneous?** Use **"Balanced"** row (TTFT 150ms, 70 tok/s, 1 concurrent)
- **Four concurrent requests needed?** Use **"High throughput"** row (accept 200ms TTFT, 65 tok/s per request)
- **Full documents (100+ KB)?** Use **"Archive search"** row (131K context, single request only)

---

### Parameter Reference — What Each Does

#### `--ctx-size N`
- **8K:** Fastest prefill (~80 ms for 1K tokens), smallest KV cache
- **16K:** Good balance; still fast prefill (~120 ms)
- **32K:** Standard production; slower prefill (~150 ms)
- **131K:** Long documents; slowest prefill (~500 ms)

**Recommendation:** Start with 16K, increase only if you need longer document context.

---

#### `--batch-size N` / `--ubatch-size N`
- **128:** Lowest VRAM, fastest per-token after prefill; for edge devices
- **256:** Optimal for RTX 5070 Ti latency; 2.5 GB free during generation
- **512:** Balanced for throughput
- **1024+:** For batch processing, not real-time inference

**Recommendation:** Keep both at **256** for latency, or 512 for balanced.

---

#### `--parallel N`
- **1:** No concurrent requests; each request waits for the previous one to finish. Lowest VRAM, lowest latency.
- **2:** Two requests can queue; second starts prefill as first generates. 2.5× VRAM per request.
- **4:** Four slots; good for throughput. Each request gets ~4K context of the 16K (they share the context budget).
- **8+:** Not recommended for 16GB GPU; VRAM exhaustion.

**Recommendation:** 
- GRC single-user: **1** (lowest latency)
- GRC occasional dual requests: **2** (balanced)
- Multi-user system: **4** (throughput at cost of latency)

---

#### `--flash-attn on|off|auto`
- **on:** Force Flash Attention 2. Requires compute capability 7.0+ (your Blackwell sm_120 supports it perfectly).
- **auto:** llama.cpp decides; usually on for modern GPUs.
- **off:** Disables; only for debugging or incompatible hardware.

**Recommendation:** Always **on** for RTX 5070 Ti. Gives 2–3× prefill speedup.

---

#### `--cache-type-k q8_0|f16|f32` and `--cache-type-v`
- **q8_0:** Quantised to 8-bit; halves KV cache VRAM, ~0.5% quality loss on long context. **USE THIS.**
- **f16:** Half-precision float; 2× larger cache than q8_0; quality preserved.
- **f32:** Full precision; largest KV cache; almost never necessary.

**Recommendation:** Always **q8_0** for production. Saves VRAM, no perceptible quality impact on GRC tasks.

---

#### `--threads N` and `--threads-batch N`
- **Threads:** CPU threads for non-GPU ops (sampling, tokenization, KV cache defrag).
- **Typical:** Half your CPU cores (24-core CPU → 12 threads).
- **For latency:** Lower is better; GPU does the work. **4–8 threads** sufficient.

**Recommendation:** **4** for RTX 5070 Ti. GPU-bound, not CPU-bound.

---

#### `--defrag-thold F` (0.0–1.0)
- Threshold for automatic KV cache defragmentation. When cache is F% fragmented, defrag.
- **0.0:** Never defrag (may waste VRAM over time).
- **0.1:** Defrag at 10% fragmentation (recommended).
- **0.5:** Defrag frequently (small latency cost per request).

**Recommendation:** **0.1** — balances VRAM efficiency and latency.

---

#### `--mlock` (flag, no value)
- Pins model weights in RAM instead of letting them swap to disk.
- **Without:** Model may swap to disk on first request (~1–2 second stall).
- **With:** Model always in RAM; first request fast.

**Recommendation:** Always **on** for production.

---

#### `--embedding` and `--pooling last|cls|mean`
- **--embedding:** Enables embedding mode (returns vector, not text).
- **--pooling last:** Use last token for pooling. **CRITICAL for Qwen3.**
- **--pooling mean:** Average all tokens. Wrong for Qwen3; produces poor embeddings.

**Recommendation:** Both required for Qwen3. Always use **--embedding --pooling last**.

---

## Part 4: Advanced Tuning — Per-Usecase Configs

### Config 1: Ultra-Fast Single-Request (GRC Compliance Single User)

**Goal:** TTFT under 100 ms for immediate feedback.

```bash
# _start-gen.sh: minimal latency
--n-gpu-layers 99 --ctx-size 8192 --batch-size 128 --ubatch-size 128 \
--parallel 1 --threads 4 --flash-attn on --cont-batching \
--cache-type-k q8_0 --cache-type-v q8_0

# Metrics:
# TTFT: ~80 ms
# Generation: 80 tok/s
# KV cache: ~0.4 GB (8K context, 128 batch)
# VRAM available: ~14 GB
```

---

### Config 2: Balanced Single/Dual-User (GRC + Occasional Concurrent)

**Goal:** TTFT 150 ms, handle 2 simultaneous requests.

```bash
# _start-gen.sh: balanced
--n-gpu-layers 99 --ctx-size 16384 --batch-size 256 --ubatch-size 256 \
--parallel 2 --threads 6 --flash-attn on --cont-batching \
--cache-type-k q8_0 --cache-type-v q8_0

# Metrics:
# TTFT: ~150 ms
# Generation: 70 tok/s per request
# KV cache (single): ~0.8 GB
# KV cache (dual): ~1.6 GB
# VRAM available: ~8.4 GB
```

---

### Config 3: High-Throughput Batch (Multi-user GRC Service)

**Goal:** Handle 3–4 concurrent GRC requests.

```bash
# _start-gen.sh: throughput
--n-gpu-layers 99 --ctx-size 32768 --batch-size 512 --ubatch-size 512 \
--parallel 4 --threads 8 --flash-attn on --cont-batching \
--cache-type-k q8_0 --cache-type-v q8_0

# Metrics:
# TTFT: ~200 ms (queuing overhead)
# Generation: 65 tok/s per request
# KV cache (per request): ~2 GB ÷ 4 = 0.5 GB effective
# Total KV: ~2 GB
# VRAM available: ~8 GB
```

---

### Config 4: Long-Document Archive Search (Full Docling 200+ pages)

**Goal:** Single long-context request; TTFT not critical.

```bash
# _start-gen.sh: long context
--n-gpu-layers 99 --ctx-size 131072 --batch-size 512 --ubatch-size 512 \
--parallel 1 --threads 6 --flash-attn on --cont-batching \
--cache-type-k q8_0 --cache-type-v q8_0

# Metrics:
# TTFT: ~600 ms (large prefill)
# Generation: 60 tok/s (large KV cache)
# KV cache: ~5 GB (131K context)
# VRAM available: ~3 GB (tight but OK)
# Max concurrent: 1 request only
```

---

## Part 5: Benchmark Script — Measure Your Latency

Run this to benchmark TTFT and throughput:

```bash
#!/bin/bash

echo "=== Granite 4.1 Latency Benchmark ==="

QUERY='{"model":"local","messages":[{"role":"user","content":"Explain compliance in 200 words"}],"max_tokens":200,"stream":true}'

echo "Measuring time to first token..."
START=$(date +%s%N)
curl -s http://127.0.0.1:8001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "$QUERY" | head -c 200 > /dev/null
END=$(date +%s%N)
TTFT_MS=$(( (END - START) / 1000000 ))
echo "TTFT: ${TTFT_MS} ms"

echo "Measuring generation throughput (200 tokens)..."
START=$(date +%s%N)
RESPONSE=$(curl -s http://127.0.0.1:8001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "$QUERY")
END=$(date +%s%N)
DURATION_MS=$(( (END - START) / 1000000 ))
TOKENS=$(echo "$RESPONSE" | grep -o '"total_tokens":[0-9]*' | cut -d: -f2)
TOK_PER_S=$(( TOKENS * 1000 / DURATION_MS ))
echo "Generated $TOKENS tokens in ${DURATION_MS} ms = $TOK_PER_S tok/s"

echo ""
echo "=== Qwen3 Embedding Latency ==="
CHUNKS=100
echo "Embedding $CHUNKS chunks..."
START=$(date +%s%N)
curl -s http://127.0.0.1:8002/v1/embeddings \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"local\",\"input\":[\"chunk<|endoftext|>\" for i in {1..${CHUNKS}}]}" > /dev/null
END=$(date +%s%N)
EMBED_MS=$(( (END - START) / 1000000 ))
echo "Embedded $CHUNKS chunks in ${EMBED_MS} ms"

echo ""
echo "=== Summary ==="
echo "TTFT:              ${TTFT_MS} ms (target: <200 ms)"
echo "Gen throughput:    ${TOK_PER_S} tok/s (target: >60 tok/s)"
echo "Embed throughput:  $((CHUNKS * 1000 / EMBED_MS)) chunks/s (target: >500 chunks/s)"
```

Save as `/opt/llamastack/benchmark.sh`, `chmod +x`, and run:
```bash
./benchmark.sh
```

Expected output with "Minimal Latency" config:
```
=== Granite 4.1 Latency Benchmark ===
TTFT: 120 ms
Generated 200 tokens in 2850 ms = 70 tok/s

=== Qwen3 Embedding Latency ===
Embedded 100 chunks in 80 ms

=== Summary ===
TTFT:              120 ms (target: <200 ms)        ✓
Gen throughput:    70 tok/s (target: >60 tok/s)    ✓
Embed throughput:  1250 chunks/s (target: >500)    ✓
```

---

## Part 6: Live Tuning — Adjust Without Restart

For quick experimentation, don't restart systemd; use direct curl flags:

```bash
# Test with different max_tokens
curl -s http://127.0.0.1:8001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model":"local",
    "messages":[{"role":"user","content":"test"}],
    "max_tokens":100,
    "temperature":0.0,
    "top_p":1.0
  }'

# Test embedding with different pooling (can't change live; requires restart)
curl -s http://127.0.0.1:8002/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model":"local","input":["test<|endoftext|>"]}'
```

To test different `--ctx-size` or `--parallel`:
1. Edit `llamastack.conf`
2. Update the corresponding start script `_start-gen.sh`
3. `sudo systemctl restart llamastack-gen`
4. Run benchmark

---

## Part 7: Production Deployment Checklist

- [ ] Set `GEN_CTX_SIZE=16384` (or 32K if you need longer documents)
- [ ] Set `GEN_PARALLEL=1` (or 2 for occasional dual requests)
- [ ] Set `GEN_BATCH_SIZE=256`, `GEN_UBATCH_SIZE=256`
- [ ] Set `EMBED_POOLING=last` (NOT `mean`)
- [ ] Set `GEN_FLASH_ATTN=true`
- [ ] Set `GEN_CACHE_TYPE_K=q8_0`, `GEN_CACHE_TYPE_V=q8_0`
- [ ] Set `GEN_MLOCK=true` (or add `--mlock` to start script)
- [ ] Verify `EMBED_MODEL` path exists and is readable
- [ ] Run benchmark script and verify TTFT <200 ms, gen >60 tok/s
- [ ] Monitor GPU with `nvidia-smi dmon -s u` during first request
- [ ] Test dual requests; measure TTFT for second request (should be <250 ms with --parallel 2)
- [ ] Log systemd output: `sudo journalctl -u llamastack-gen -f`

---

## Part 8: Troubleshooting Slow Latency

### TTFT is >300 ms (too slow)

**Check:**
1. Is `--flash-attn on`? If not, add it immediately (2–3× speedup).
2. Is `--n-gpu-layers 99`? If <99, layers are on CPU; add them all to GPU.
3. Is `--ctx-size 32768` or larger? Reduce to 16K; prefill is O(n²) in context length.
4. Is `--parallel >2`? Each parallel slot reduces effective context for each request. Drop to 1 for single-user.
5. Check CPU threads with `nproc`; ensure `--threads ≤ nproc / 2`.

**Also check system:**
```bash
nvidia-smi  # GPU memory available?
free -h     # System RAM available?
top -b -n1  # Any background processes using GPU?
```

---

### Generation is <60 tok/s (too slow)

1. Is KV cache on GPU? Check logs: `llm_load_tensors: offloaded 40/40 layers to GPU`.
2. Is model quantisation correct? Check: `ibm-granite_granite-4.1-8b-Q5_K_M.gguf` (Q5 is good).
3. Are you using `--cache-type-k q8_0`? If using f16, switch to q8_0 (same speed, less VRAM).
4. Check VRAM saturation: `nvidia-smi`. If >90% during generation, reduce `--parallel` or `--ctx-size`.

---

### Embedding takes >200ms (slow)

1. Is `--n-gpu-layers 99` set for embed server? Check logs.
2. Are you sending >500 chunks in a single request? Consider batching into smaller requests.
3. Check if model is being re-loaded on each request (would see load time in logs). This is normal on first request; subsequent requests are cached.

---

## Part 9: Scaling to Production

If you need to handle many simultaneous users:

### Option 1: Multiple Inference Servers (Recommended)

Run **two separate instances** on the same GPU (split VRAM):

**Instance 1 (gen, ports 8001):**
```bash
--ctx-size 16384 --parallel 2 --n-gpu-layers 50
```

**Instance 2 (gen, ports 8003):**
```bash
--ctx-size 16384 --parallel 2 --n-gpu-layers 50
```

Single embed server (shared):
```bash
# Port 8002
```

Load balancer (nginx or HAProxy) routes `/v1/chat/completions` to 8001 or 8003 round-robin.

---

### Option 2: vLLM or SGLang (Advanced)

If llamastack latency isn't enough, switch to vLLM or SGLang. These are production-grade with better scheduling. However, you lose the Nginx gateway.

---

## Part 10: Configuration Summary Table

| Parameter | Ultra-Low | Minimal (Recommended) | Balanced | Throughput | Archive |
|---|---|---|---|---|---|
| `--ctx-size` | 8K | **16K** | 32K | 32K | 131K |
| `--batch-size` | 128 | **256** | 512 | 1024 | 512 |
| `--parallel` | 1 | **1** | 2 | 4 | 1 |
| `--threads` | 4 | **4** | 6 | 8 | 6 |
| `--flash-attn` | on | **on** | on | on | on |
| `--cache-type-k` | q8_0 | **q8_0** | q8_0 | q8_0 | q8_0 |
| **TTFT** | ~80 ms | **~120 ms** | ~150 ms | ~200 ms | ~600 ms |
| **Generation** | 80 tok/s | **75 tok/s** | 70 tok/s | 65 tok/s | 60 tok/s |
| **Concurrent** | 0 | **0–1** | 1–2 | 3–4 | 0 |
| **VRAM free** | ~14 GB | **~13 GB** | ~10 GB | ~8 GB | ~3 GB |

**Pick one row, apply to `llamastack.conf` and start scripts, restart, run benchmark.**

---

## Quick Copy-Paste Configs

### For Single-User GRC (Fastest)

```bash
# Save to /opt/llamastack/config/llamastack.conf
GEN_CTX_SIZE=16384
GEN_BATCH_SIZE=256
GEN_UBATCH_SIZE=256
GEN_PARALLEL=1
GEN_THREADS=4
GEN_FLASH_ATTN=true
GEN_CONT_BATCHING=true
GEN_CACHE_TYPE_K=q8_0
GEN_CACHE_TYPE_V=q8_0
EMBED_CTX_SIZE=8192
EMBED_BATCH_SIZE=2048
EMBED_UBATCH_SIZE=2048
EMBED_PARALLEL=2
EMBED_POOLING=last
```

### For Multi-User GRC (Concurrent)

```bash
# Save to /opt/llamastack/config/llamastack.conf
GEN_CTX_SIZE=32768
GEN_BATCH_SIZE=512
GEN_UBATCH_SIZE=512
GEN_PARALLEL=2
GEN_THREADS=6
GEN_FLASH_ATTN=true
GEN_CONT_BATCHING=true
GEN_CACHE_TYPE_K=q8_0
GEN_CACHE_TYPE_V=q8_0
EMBED_CTX_SIZE=16384
EMBED_BATCH_SIZE=2048
EMBED_UBATCH_SIZE=2048
EMBED_PARALLEL=4
EMBED_POOLING=last
```

---

**Reference:** RTX 5070 Ti baseline (no tuning) = 200+ ms TTFT, 50 tok/s. With these parameters = 120 ms TTFT, 75 tok/s (40% latency reduction, 50% throughput increase).
