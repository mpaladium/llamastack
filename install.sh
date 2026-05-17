#!/usr/bin/env bash
# =============================================================================
#  llamastack installer
#  Supported: Ubuntu 20.04+, Debian 11+, Fedora 38+, Arch, macOS 12+
#  Usage:  sudo ./install.sh [options]
# =============================================================================
set -euo pipefail
# NOTE: IFS is intentionally left at default (' \t\n') so package-list
# strings word-split correctly when passed to apt-get / dnf / pacman.

# ── Defaults ──────────────────────────────────────────────────────────────────
PREFIX="${LLAMASTACK_PREFIX:-/opt/llamastack}"
SVC_USER="llamastack"
VERSION="1.0.0"
FORCE_CPU=0
YES=0
SKIP_BUILD=0       # --skip-build: reuse existing llama.cpp binary
SUDO_CMD=""

# ── Colours ───────────────────────────────────────────────────────────────────
R='\033[0;31m' Y='\033[1;33m' G='\033[0;32m' C='\033[0;36m' B='\033[1m' D='\033[0m'
log()  { echo -e "${C}[llamastack]${D} $*"; }
ok()   { echo -e "${G}  ✓${D} $*"; }
warn() { echo -e "${Y}  !${D} $*"; }
die()  { echo -e "${R}  ✗${D} $*" >&2; exit 1; }
hdr()  { echo -e "\n${B}$*${D}\n$(printf '─%.0s' {1..56})"; }

# ── Args ──────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --prefix)     PREFIX="$2"; shift 2 ;;
    --no-gpu)     FORCE_CPU=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    -y|--yes)     YES=1; shift ;;
    -h|--help)
      cat <<HELP
Usage: sudo ./install.sh [options]

  --prefix PATH      Install directory (default: /opt/llamastack)
  --no-gpu           Force CPU-only mode
  --skip-build       Skip build; binary must already exist at PREFIX/bin/llama-server
  -y, --yes          Non-interactive
  -h, --help         Show this help

Environment variables:
  LLAMASTACK_PREFIX      Override install prefix
  LLAMASTACK_PREBUILT    Path to existing llama.cpp build dir (skips clone+build)
                         e.g. LLAMASTACK_PREBUILT=/projects/llamacppstack/llama.cpp/build
  LLAMASTACK_CUDA_ROOT   Path to CUDA toolkit root (overrides auto-detection)
                         e.g. LLAMASTACK_CUDA_ROOT=/usr/local/cuda-13.2

Examples:
  # Standard install (builds from source)
  sudo ./install.sh

  # Use your existing build at /projects/llamacppstack/llama.cpp/build
  sudo LLAMASTACK_PREBUILT=/projects/llamacppstack/llama.cpp/build ./install.sh

  # Install to custom prefix, non-interactive
  sudo ./install.sh --prefix /srv/llamastack --yes

  # CPU-only on a headless server
  sudo ./install.sh --no-gpu --yes
HELP
      exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
done

# ── Platform ──────────────────────────────────────────────────────────────────
hdr "Detecting platform"
OS=$(uname -s)
ARCH=$(uname -m)

case "$OS" in
  Linux)
    PLATFORM=linux
    [[ -f /etc/os-release ]] && source /etc/os-release && DISTRO="${ID:-unknown}" || DISTRO="unknown"
    INIT=$(ps -p 1 -o comm= 2>/dev/null || echo unknown)
    [[ $EUID -ne 0 ]] && die "Run as root on Linux: sudo $0"
    ;;
  Darwin)
    PLATFORM=macos
    DISTRO=macos
    MACOS_VER=$(sw_vers -productVersion)
    [[ $EUID -ne 0 ]] && { warn "Not root — will use sudo for system paths"; SUDO_CMD=sudo; }
    ;;
  *) die "Unsupported OS: $OS (Linux and macOS only)" ;;
esac

case "$ARCH" in
  x86_64|amd64)  ARCH=x86_64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "Unsupported architecture: $ARCH" ;;
esac

log "OS: $OS ($PLATFORM) | Arch: $ARCH | Distro: $DISTRO"

# ── GPU detection ─────────────────────────────────────────────────────────────
hdr "Detecting GPU"
GPU_BACKEND=cpu
GPU_LABEL="None (CPU mode)"
CMAKE_CUDA_ARCH=""
CUDA_ROOT=""

# ── Locate the CUDA toolkit (nvcc may not be on PATH even if installed) ───────
# Allow operator to hard-override CUDA root (useful when auto-detect picks wrong version)
# Usage: sudo LLAMASTACK_CUDA_ROOT=/usr/local/cuda-13.2 ./install.sh
if [[ -n "${LLAMASTACK_CUDA_ROOT:-}" ]]; then
  if [[ -x "${LLAMASTACK_CUDA_ROOT}/bin/nvcc" ]]; then
    log "Using LLAMASTACK_CUDA_ROOT override: ${LLAMASTACK_CUDA_ROOT}"
    export PATH="${LLAMASTACK_CUDA_ROOT}/bin:${PATH}"
    export LD_LIBRARY_PATH="${LLAMASTACK_CUDA_ROOT}/lib64:${LD_LIBRARY_PATH:-}"
    CUDA_ROOT="${LLAMASTACK_CUDA_ROOT}"
  else
    die "LLAMASTACK_CUDA_ROOT set to '${LLAMASTACK_CUDA_ROOT}' but no nvcc found there."
  fi
fi

_nvcc_supports_arch() {
  # Test whether a given nvcc binary can compile for the requested arch.
  # Usage: _nvcc_supports_arch /path/to/nvcc 120
  local nvcc_bin="$1" arch="$2"
  echo "__global__ void f(){}" |     "$nvcc_bin" -x cu --generate-code "arch=compute_${arch},code=sm_${arch}"     -o /dev/null - &>/dev/null
}

_find_cuda() {
  # Priority order:
  #   1. /usr/local/cuda-XX.Y versioned dirs  — newest first, avoids stale Ubuntu pkg
  #   2. /usr/local/cuda symlink              — distro-managed active version
  #   3. Debian/Ubuntu package paths
  #   4. whatever is on PATH (last resort — may be old)
  #
  # Within each candidate we also verify the nvcc can actually compile for
  # the requested arch (CMAKE_CUDA_ARCH), so an old nvcc that doesn't know
  # sm_120 is skipped in favour of a newer one.

  local candidates=()

  # Collect all versioned /usr/local/cuda-XX.Y dirs, sorted newest-first
  local versioned
  versioned=$(ls -d /usr/local/cuda-*/bin/nvcc 2>/dev/null | sort -t- -k2 -V -r || true)
  for nvcc_path in $versioned; do
    [[ -x "$nvcc_path" ]] && candidates+=("$(dirname "$(dirname "$nvcc_path")")")
  done

  # Symlink
  [[ -x /usr/local/cuda/bin/nvcc ]] && candidates+=(/usr/local/cuda)

  # Debian package paths
  for d in /usr/lib/cuda /usr/lib/nvidia-cuda-toolkit; do
    [[ -x "${d}/bin/nvcc" ]] && candidates+=("$d")
  done

  # PATH fallback
  if command -v nvcc &>/dev/null; then
    candidates+=("$(dirname "$(dirname "$(command -v nvcc)")")")
  fi

  # Deduplicate while preserving order
  local seen=()
  for root in "${candidates[@]}"; do
    local already=0
    for s in "${seen[@]:-}"; do [[ "$s" == "$root" ]] && already=1 && break; done
    [[ $already -eq 1 ]] && continue
    seen+=("$root")

    local nvcc_bin="${root}/bin/nvcc"
    [[ ! -x "$nvcc_bin" ]] && continue

    local ver
    ver=$("$nvcc_bin" --version 2>/dev/null | grep -oP "release \K[0-9.]+" || echo "?")
    log "Checking nvcc: ${nvcc_bin}  (version ${ver})"

    # If we already know the target arch, verify this nvcc supports it
    if [[ -n "${CMAKE_CUDA_ARCH:-}" ]]; then
      if _nvcc_supports_arch "$nvcc_bin" "$CMAKE_CUDA_ARCH"; then
        CUDA_ROOT="$root"
        log "Selected nvcc ${ver} at ${root}  [supports sm_${CMAKE_CUDA_ARCH}]"
        return 0
      else
        warn "nvcc ${ver} at ${root} does NOT support sm_${CMAKE_CUDA_ARCH} — skipping"
      fi
    else
      # No arch constraint yet — take the first working nvcc
      CUDA_ROOT="$root"
      log "Selected nvcc ${ver} at ${root}"
      return 0
    fi
  done

  return 1
}

if [[ $FORCE_CPU -eq 1 ]]; then
  warn "GPU disabled via --no-gpu"
elif [[ $PLATFORM == macos ]]; then
  if [[ $ARCH == arm64 ]]; then
    GPU_BACKEND=metal; GPU_LABEL="Apple Silicon (Metal)"
  elif system_profiler SPDisplaysDataType 2>/dev/null | grep -qi metal; then
    GPU_BACKEND=metal; GPU_LABEL="Intel Mac + Metal"
  fi
elif command -v nvidia-smi &>/dev/null; then
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
  GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || true)
  COMPUTE=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d '.' || echo 86)

  if [[ -n "$GPU_NAME" ]]; then
    # Try to locate CUDA toolkit
    # Derive target arch from nvidia-smi BEFORE calling _find_cuda so
    # the arch-validation test inside _find_cuda can skip incompatible nvcc binaries.
    case "$COMPUTE" in
      12*) CMAKE_CUDA_ARCH=120 ;;  # Blackwell  — RTX 5000 series (CUDA 13+)
      89*|90*) CMAKE_CUDA_ARCH=89 ;;  # Ada        — RTX 4000 / H100
      86*|87*) CMAKE_CUDA_ARCH=86 ;;  # Ampere     — RTX 3000
      80*)     CMAKE_CUDA_ARCH=80 ;;
      75*)     CMAKE_CUDA_ARCH=75 ;;  # Turing     — RTX 2000
      *)       CMAKE_CUDA_ARCH=86 ;;  # safe default
    esac
    log "GPU compute cap: $COMPUTE → target sm_${CMAKE_CUDA_ARCH}"

    if _find_cuda; then
      # Inject the selected nvcc onto PATH for this process and all children.
      # This overrides /usr/bin/nvcc (Ubuntu pkg) with the correct toolkit.
      export PATH="${CUDA_ROOT}/bin:${PATH}"
      export LD_LIBRARY_PATH="${CUDA_ROOT}/lib64:${LD_LIBRARY_PATH:-}"

      GPU_BACKEND=cuda
      GPU_LABEL="${GPU_NAME} (${GPU_VRAM}MB VRAM)"
      log "CUDA toolkit → ${CUDA_ROOT}  nvcc: $(${CUDA_ROOT}/bin/nvcc --version 2>/dev/null | grep -oP 'release \K[0-9.]+' || echo unknown)"
    else
      # CUDA toolkit not found — nvidia-smi only reports the driver's *maximum*
      # supported CUDA version, not that the toolkit is installed.
      # Attempt to install the correct toolkit from the official NVIDIA repo.
      warn "CUDA toolkit (nvcc) not found — driver reports CUDA ${CUDA_DRIVER_VER:-13.x}."
      warn "Attempting to install CUDA toolkit from NVIDIA repository..."

      CUDA_PKG_INSTALLED=0
      _install_cuda_toolkit() {
        # Derive major version from nvidia-smi CUDA field (e.g. "13.2" → "13")
        local cuda_major
        cuda_major=$(nvidia-smi 2>/dev/null           | grep -oP "CUDA Version: \K[0-9]+" | head -1 || echo "13")

        log "Target CUDA major version: ${cuda_major}"

        if command -v apt-get &>/dev/null; then
          # ── Debian/Ubuntu: add official NVIDIA keyring + repo ──────────────
          local codename arch_deb
          codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-jammy}}")
          arch_deb=$(dpkg --print-architecture 2>/dev/null || echo amd64)

          local keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${codename/./}/${arch_deb}/cuda-keyring_1.1-1_all.deb"
          local keyring_deb="/tmp/cuda-keyring.deb"

          log "Adding NVIDIA CUDA apt repository (${codename} / ${arch_deb})..."
          if curl -fsSL "$keyring_url" -o "$keyring_deb" 2>/dev/null ||              wget -q "$keyring_url" -O "$keyring_deb" 2>/dev/null; then
            dpkg -i "$keyring_deb" 2>/dev/null || true
            rm -f "$keyring_deb"
            apt-get update -qq
            # Install the exact major-version toolkit metapackage
            DEBIAN_FRONTEND=noninteractive apt-get install -y               "cuda-toolkit-${cuda_major}-$(nvidia-smi 2>/dev/null | grep -oP "CUDA Version: [0-9]+\.\K[0-9]+" | head -1 || echo 2)"               2>/dev/null ||             DEBIAN_FRONTEND=noninteractive apt-get install -y               "cuda-toolkit-${cuda_major}" 2>/dev/null ||             DEBIAN_FRONTEND=noninteractive apt-get install -y               cuda-toolkit 2>/dev/null || true
          else
            warn "Could not reach NVIDIA apt repo — no internet or proxy needed."
            return 1
          fi

        elif command -v dnf &>/dev/null; then
          # ── RHEL/Fedora/Rocky: NVIDIA dnf repo ──────────────────────────────
          local distro_dnf
          distro_dnf=$(. /etc/os-release && echo "${ID:-rhel}")
          local ver_dnf
          ver_dnf=$(. /etc/os-release && echo "${VERSION_ID:-8}" | cut -d. -f1)
          local repo_url="https://developer.download.nvidia.com/compute/cuda/repos/${distro_dnf}${ver_dnf}/x86_64/cuda-${distro_dnf}${ver_dnf}.repo"
          log "Adding NVIDIA CUDA dnf repository..."
          dnf config-manager --add-repo "$repo_url" 2>/dev/null || true
          dnf install -y "cuda-toolkit-${cuda_major}" 2>/dev/null ||           dnf install -y cuda-toolkit 2>/dev/null || true
        fi
      }

      _install_cuda_toolkit && _find_cuda && CUDA_PKG_INSTALLED=1

      if [[ $CUDA_PKG_INSTALLED -eq 1 ]]; then
        export PATH="${CUDA_ROOT}/bin:${PATH}"
        export LD_LIBRARY_PATH="${CUDA_ROOT}/lib64:${LD_LIBRARY_PATH:-}"
        GPU_BACKEND=cuda
        GPU_LABEL="${GPU_NAME} (${GPU_VRAM}MB VRAM) [toolkit installed]"
        log "CUDA toolkit ready → ${CUDA_ROOT}"
        log "nvcc: $(${CUDA_ROOT}/bin/nvcc --version 2>/dev/null | grep -oP "release \K[0-9.]+" || echo unknown)"
      else
        # ── Toolkit install failed — print exact manual steps ──────────────────
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  CUDA toolkit not installed — manual action required"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  Your RTX 5070 Ti (Blackwell sm_120) needs CUDA 13."
        echo "  nvidia-smi shows the driver supports it, but nvcc is missing."
        echo ""
        echo "  Run these commands, then re-run the installer:"
        echo ""
        echo "  # Ubuntu/Debian:"
        echo "  wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb"
        echo "  sudo dpkg -i cuda-keyring_1.1-1_all.deb"
        echo "  sudo apt-get update"
        echo "  sudo apt-get install -y cuda-toolkit-13-2"
        echo ""
        echo "  # Then verify:"
        echo "  nvcc --version   # should say release 13.2"
        echo "  ls /usr/local/cuda-13.2/bin/nvcc"
        echo ""
        echo "  # Or point installer at existing toolkit dir:"
        echo "  sudo LLAMASTACK_CUDA_ROOT=/usr/local/cuda-13.2 ./install.sh"
        echo ""
        echo "  # Or build without GPU:"
        echo "  sudo ./install.sh --no-gpu"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        warn "Falling back to CPU-only build for this run."
      fi
    fi
  fi
fi

log "GPU backend: ${GPU_LABEL}"
[[ -n "$CUDA_ROOT" ]] && log "CUDA root:   ${CUDA_ROOT}"

# ── Confirm ───────────────────────────────────────────────────────────────────
if [[ $YES -eq 0 ]]; then
  echo ""
  echo -e "${B}llamastack $VERSION${D}"
  echo "  Install prefix : $PREFIX"
  echo "  Platform       : $PLATFORM / $ARCH"
  echo "  GPU backend    : $GPU_LABEL"
  echo ""
  read -rp "Proceed? [Y/n] " ans
  [[ ${ans:-Y} =~ ^[Nn] ]] && { echo "Aborted."; exit 0; }
fi

# ── Dependencies ──────────────────────────────────────────────────────────────
hdr "Installing dependencies"

# Packages as arrays — immune to IFS and quoting issues
APT_PKGS=(build-essential cmake git curl wget libcurl4-openssl-dev ninja-build pkg-config)
DNF_PKGS=(gcc gcc-c++ cmake git curl wget libcurl-devel make ninja-build)
PAC_PKGS=(base-devel cmake git curl wget ninja)
ZYP_PKGS=(gcc gcc-c++ cmake git curl wget libcurl-devel make ninja)

_apt() {
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PKGS[@]}"
}
_dnf() { dnf install -y "${DNF_PKGS[@]}"; }
_pac() { pacman -Sy --noconfirm "${PAC_PKGS[@]}"; }
_zyp() { zypper install -y "${ZYP_PKGS[@]}"; }

case $PLATFORM in
  linux)
    # Normalise distro string: strip version suffix, lowercase
    DISTRO_BASE=$(echo "${DISTRO:-unknown}" | tr '[:upper:]' '[:lower:]' | sed 's/[0-9].*//')
    case "$DISTRO_BASE" in
      ubuntu|debian|linuxmint|pop|elementary|kali|raspbian|neon)
        _apt ;;
      fedora|nobara)
        _dnf ;;
      arch|manjaro|endeavouros|garuda|artix)
        _pac ;;
      opensuse|sles)
        _zyp ;;
      rhel|centos|rocky|almalinux|ol|scientific)
        dnf install -y epel-release 2>/dev/null || true
        _dnf ;;
      *)
        # Last-resort: try whatever package manager exists
        warn "Unrecognised distro '${DISTRO}' — probing package managers..."
        if   command -v apt-get &>/dev/null; then _apt
        elif command -v dnf     &>/dev/null; then _dnf
        elif command -v pacman  &>/dev/null; then _pac
        elif command -v zypper  &>/dev/null; then _zyp
        else die "No supported package manager found. Install manually: ${APT_PKGS[*]}"
        fi ;;
    esac ;;
  macos)
    if ! command -v brew &>/dev/null; then
      log "Installing Homebrew..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null || true)"
    fi
    brew install cmake git curl wget ninja ;;
esac
ok "Dependencies ready"

# ── Directories ───────────────────────────────────────────────────────────────
hdr "Creating directory layout"
for d in bin config models logs run src; do
  ${SUDO_CMD} mkdir -p "${PREFIX}/${d}"
done

if [[ $PLATFORM == linux ]]; then
  if ! id "$SVC_USER" &>/dev/null; then
    useradd -r -s /bin/false -d "$PREFIX" -c "llamastack service" "$SVC_USER"
    ok "Service user created: $SVC_USER"
  fi
  chown -R "${SVC_USER}:${SVC_USER}" "$PREFIX"
  chmod 755 "$PREFIX"
  # Allow the current (installing) user's primary group to write models
  chown "${SVC_USER}:$(id -gn)" "${PREFIX}/models" 2>/dev/null || true
  chmod 775 "${PREFIX}/models"    # service user + sudo-group readable/writable
else
  ${SUDO_CMD} chown -R "$(whoami)" "$PREFIX"
fi
ok "Layout: $PREFIX/{bin,config,models,logs,run,src}"

# ── Build / locate llama.cpp ──────────────────────────────────────────────────
hdr "Setting up llama.cpp"

# Resolved nvcc path — used in cmake args and RPATH
NVCC_BIN=""
[[ -n "${CUDA_ROOT:-}" ]] && NVCC_BIN="${CUDA_ROOT}/bin/nvcc"

_cmake_build() {
  # Build llama.cpp from $SRC into $SRC/build, then copy llama-server to PREFIX/bin.
  # Uses the exact cmake invocation from the official llama.cpp build docs:
  #   https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md
  local src="$1"
  local jobs
  jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

  local cmake_args=(
    -DCMAKE_BUILD_TYPE=Release
    -DLLAMA_CURL=ON
    "-DCMAKE_INSTALL_PREFIX=${PREFIX}"
  )

  case $GPU_BACKEND in
    cuda)
      cmake_args+=(
        -DGGML_CUDA=ON
        "-DCMAKE_CUDA_ARCHITECTURES=${CMAKE_CUDA_ARCH}"
        "-DCMAKE_CUDA_COMPILER=${NVCC_BIN}"
        # RPATH so llama-server finds libcuda/libcublas at runtime without LD_LIBRARY_PATH
        "-DCMAKE_INSTALL_RPATH=${CUDA_ROOT}/lib64;\$ORIGIN/../lib"
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
      )
      # Belt-and-suspenders: also set CUDAToolkit_ROOT for CMake's FindCUDAToolkit
      cmake_args+=("-DCUDAToolkit_ROOT=${CUDA_ROOT}")
      ;;
    metal)
      cmake_args+=(-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON)
      ;;
    cpu)
      cmake_args+=(-DGGML_CUDA=OFF -DGGML_METAL=OFF)
      [[ $ARCH == x86_64 ]] && cmake_args+=(-DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON)
      [[ $ARCH == arm64  ]] && cmake_args+=(-DGGML_NEON=ON)
      ;;
  esac

  # Forward CUDA env vars explicitly — sudo often sanitises PATH
  local env_prefix=()
  if [[ -n "${CUDA_ROOT:-}" ]]; then
    env_prefix+=(
      "PATH=${CUDA_ROOT}/bin:${PATH}"
      "LD_LIBRARY_PATH=${CUDA_ROOT}/lib64:${LD_LIBRARY_PATH:-}"
    )
  fi

  log "cmake configure (backend: ${GPU_BACKEND}, arch: ${CMAKE_CUDA_ARCH:-n/a})..."
  log "nvcc: ${NVCC_BIN:-none}"
  env "${env_prefix[@]}" cmake -B "${src}/build" "${cmake_args[@]}" "$src"

  log "cmake build (jobs: ${jobs})..."
  env "${env_prefix[@]}" cmake --build "${src}/build" --config Release -j"$jobs"

  log "cmake install → ${PREFIX}..."
  env "${env_prefix[@]}" cmake --install "${src}/build"
}

_copy_prebuilt() {
  # Copy llama-server AND all companion shared libs from a pre-built tree.
  # llama.cpp splits into multiple .so files (libggml.so, libllama.so, libmtmd.so, etc.)
  # Missing any one of them causes "error while loading shared libraries" at runtime.
  local build_dir="$1"
  local found=0
  local bin_path=""

  # Search common output locations
  for candidate in     "${build_dir}/bin/llama-server"     "${build_dir}/llama-server"; do
    if [[ -x "$candidate" ]]; then
      bin_path="$candidate"; found=1; break
    fi
  done

  if [[ $found -eq 0 ]]; then
    bin_path=$(find "$build_dir" -name "llama-server" -type f -perm /111 2>/dev/null | head -1 || true)
    [[ -n "$bin_path" ]] && found=1
  fi

  [[ $found -eq 0 ]] && die "llama-server binary not found in: ${build_dir}"

  local bin_dir
  bin_dir=$(dirname "$bin_path")

  cp "$bin_path" "${PREFIX}/bin/llama-server"
  chmod +x "${PREFIX}/bin/llama-server"
  ok "Copied llama-server ← ${bin_path}"

  # ── Copy every shared library found in the build tree ──────────────────────
  # Covers: libggml.so, libggml-base.so, libggml-cpu.so, libggml-cuda.so,
  #         libllama.so, libmtmd.so, and any future splits
  local lib_count=0
  shopt -s nullglob

  # bin/ dir (most common location when built with cmake install)
  for lib in "${bin_dir}"/lib*.so "${bin_dir}"/lib*.so.*; do
    [[ -e "$lib" ]] || continue
    cp -P "$lib" "${PREFIX}/bin/"
    log "Copied lib: $(basename "$lib")"
    (( lib_count++ )) || true
  done

  # build/lib or build/lib64 dirs
  for lib_dir in "${build_dir}/lib" "${build_dir}/lib64" "${build_dir}/../lib"; do
    [[ -d "$lib_dir" ]] || continue
    for lib in "${lib_dir}"/lib*.so "${lib_dir}"/lib*.so.*; do
      [[ -e "$lib" ]] || continue
      cp -P "$lib" "${PREFIX}/bin/"
      log "Copied lib: $(basename "$lib")"
      (( lib_count++ )) || true
    done
  done
  shopt -u nullglob

  ok "Copied ${lib_count} shared libraries"

  # ── Register PREFIX/bin with the system dynamic linker (permanent fix) ──────
  # Writes /etc/ld.so.conf.d/llamastack.conf so libmtmd.so.0, libggml.so.0 etc
  # are found by any process without needing LD_LIBRARY_PATH
  if [[ $PLATFORM == linux ]]; then
    local ldconf="/etc/ld.so.conf.d/llamastack.conf"
    echo "${PREFIX}/bin" | ${SUDO_CMD} tee "$ldconf" > /dev/null
    ${SUDO_CMD} ldconfig
    ok "Registered ${PREFIX}/bin with ldconfig → ${ldconf}"
  fi
}


if [[ -n "${LLAMASTACK_PREBUILT:-}" ]]; then
  # ── Mode 1: user points at an existing build directory ──────────────────────
  # Usage: sudo LLAMASTACK_PREBUILT=/projects/llamacppstack/llama.cpp/build ./install.sh
  hdr "Using pre-built llama.cpp from: ${LLAMASTACK_PREBUILT}"
  [[ -d "${LLAMASTACK_PREBUILT}" ]] ||     die "LLAMASTACK_PREBUILT path not found: ${LLAMASTACK_PREBUILT}"
  _copy_prebuilt "${LLAMASTACK_PREBUILT}"

elif [[ $SKIP_BUILD -eq 0 ]]; then
  # ── Mode 2: full build from source (default) ─────────────────────────────────
  SRC="${PREFIX}/src/llama.cpp"

  # Git safe.directory: Git 2.35.2+ blocks cross-user operations
  git config --global --add safe.directory "$SRC" 2>/dev/null || true
  git config --system  --add safe.directory "$SRC" 2>/dev/null || true

  if [[ -d "$SRC/.git" ]]; then
    log "Source exists — pulling latest..."
    git -C "$SRC" pull --quiet
  else
    log "Cloning llama.cpp (depth=1)..."
    git clone --depth 1 https://github.com/ggml-org/llama.cpp "$SRC"
  fi

  # Normalise ownership: root builds, llamastack runs
  [[ $PLATFORM == linux ]] && chown -R root:root "$SRC" 2>/dev/null || true

  _cmake_build "$SRC"
  ok "llama-server installed → ${PREFIX}/bin/llama-server"

else
  # ── Mode 3: --skip-build: binary must already be at PREFIX/bin/llama-server ──
  warn "--skip-build: expecting llama-server already at ${PREFIX}/bin/llama-server"
  [[ -x "${PREFIX}/bin/llama-server" ]] ||     die "Binary not found at ${PREFIX}/bin/llama-server — remove --skip-build or use LLAMASTACK_PREBUILT="
fi

# Sanity-check: confirm the binary works
if [[ -x "${PREFIX}/bin/llama-server" ]]; then
  VER=$("${PREFIX}/bin/llama-server" --version 2>/dev/null | head -1 || echo "unknown")
  ok "llama-server ready — ${VER}"
else
  die "llama-server not found at ${PREFIX}/bin/llama-server after build/install step"
fi

# ── Compute sensible defaults ──────────────────────────────────────────────────
CPU_CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 8)
GEN_THREADS=$(( CPU_CORES / 2 ))
EMB_THREADS=$(( CPU_CORES / 3 + 1 ))

if [[ $GPU_BACKEND == cuda ]]; then
  VRAM=${GPU_VRAM:-8000}
  if   (( VRAM >= 20000 )); then GEN_LAYERS=999; CTX=16384
  elif (( VRAM >= 16000 )); then GEN_LAYERS=40;  CTX=8192
  elif (( VRAM >= 10000 )); then GEN_LAYERS=32;  CTX=4096
  else                           GEN_LAYERS=20;  CTX=2048
  fi
  EMB_LAYERS=99
elif [[ $GPU_BACKEND == metal ]]; then
  GEN_LAYERS=999; CTX=8192; EMB_LAYERS=999
else
  GEN_LAYERS=0; CTX=4096; EMB_LAYERS=0
fi

# ── Write config ──────────────────────────────────────────────────────────────
hdr "Writing configuration"
${SUDO_CMD} tee "${PREFIX}/config/llamastack.conf" > /dev/null <<CONF
# =============================================================================
#  llamastack.conf — edit and run: llamastack restart
# =============================================================================

# ── Runtime ───────────────────────────────────────────────────────────────────
PREFIX="${PREFIX}"
LLAMA_BIN="\${PREFIX}/bin/llama-server"
MODEL_DIR="${PREFIX}/models"
LOG_DIR="\${PREFIX}/logs"
RUN_DIR="\${PREFIX}/run"

# ── Network ───────────────────────────────────────────────────────────────────
BIND_HOST="127.0.0.1"       # Change to 0.0.0.0 to expose on LAN
GATEWAY_PORT=8080
GEN_PORT=8001
EMBED_PORT=8002

# ── Auth (GRC) ────────────────────────────────────────────────────────────────
# Leave empty to disable; set a string to require Bearer token
API_KEY=""

# ── Model paths ───────────────────────────────────────────────────────────────
# After: llamastack pull gen <alias>  these are set automatically.
# You can also point at any GGUF file on disk.
GEN_MODEL="${PREFIX}/models/gen-model.gguf"
EMBED_MODEL="${PREFIX}/models/embed-model.gguf"

# ── Generative server ─────────────────────────────────────────────────────────
GEN_GPU_LAYERS=${GEN_LAYERS}        # 0 = CPU only, 999 = all layers on GPU
GEN_CTX_SIZE=${CTX}
GEN_BATCH_SIZE=512
GEN_UBATCH_SIZE=512
GEN_THREADS=${GEN_THREADS}
GEN_PARALLEL=4                      # Concurrent request slots
GEN_CONT_BATCHING=true              # Ollama-style request batching
GEN_FLASH_ATTN=true                 # CUDA/Metal only — set false for CPU
GEN_CACHE_REUSE=256                 # KV prefix reuse tokens

# ── Embedding server ──────────────────────────────────────────────────────────
EMBED_GPU_LAYERS=${EMB_LAYERS}
EMBED_CTX_SIZE=2048
EMBED_BATCH_SIZE=512
EMBED_UBATCH_SIZE=512
EMBED_THREADS=${EMB_THREADS}
EMBED_PARALLEL=8
EMBED_POOLING="mean"                # mean | cls | last

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_FORMAT="json"                   # json | text
LOG_RETAIN_DAYS=90

# ── Platform (auto-detected at install, do not change) ───────────────────────
GPU_BACKEND="${GPU_BACKEND}"
PLATFORM="${PLATFORM}"
ARCH="${ARCH}"
CONF

ok "Config → ${PREFIX}/config/llamastack.conf"

# ── Model registry ────────────────────────────────────────────────────────────
${SUDO_CMD} tee "${PREFIX}/config/models.conf" > /dev/null <<'REGISTRY'
# =============================================================================
#  llamastack model registry
#  Format:  ALIAS|TYPE|HF_REPO|HF_FILE|DESCRIPTION
#  TYPE: gen | embed
#
#  llamastack pull gen   mistral-7b
#  llamastack pull embed nomic
#  llamastack use  gen   llama3.1-8b
# =============================================================================

# ── Generative models ─────────────────────────────────────────────────────────
mistral-7b|gen|bartowski/Mistral-7B-Instruct-v0.3-GGUF|Mistral-7B-Instruct-v0.3-Q4_K_M.gguf|Mistral 7B Instruct Q4_K_M — best general-purpose default
mistral-7b-q8|gen|bartowski/Mistral-7B-Instruct-v0.3-GGUF|Mistral-7B-Instruct-v0.3-Q8_0.gguf|Mistral 7B Q8 — maximum quality at ~7GB VRAM
llama3.1-8b|gen|bartowski/Meta-Llama-3.1-8B-Instruct-GGUF|Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf|Llama 3.1 8B Instruct Q4_K_M
llama3.1-8b-q8|gen|bartowski/Meta-Llama-3.1-8B-Instruct-GGUF|Meta-Llama-3.1-8B-Instruct-Q8_0.gguf|Llama 3.1 8B Q8
llama3.2-3b|gen|bartowski/Llama-3.2-3B-Instruct-GGUF|Llama-3.2-3B-Instruct-Q4_K_M.gguf|Llama 3.2 3B — lightweight fast model (~2GB)
phi3.5-mini|gen|bartowski/Phi-3.5-mini-instruct-GGUF|Phi-3.5-mini-instruct-Q4_K_M.gguf|Phi-3.5 Mini — 3.8B efficient reasoning
qwen2.5-7b|gen|bartowski/Qwen2.5-7B-Instruct-GGUF|Qwen2.5-7B-Instruct-Q4_K_M.gguf|Qwen 2.5 7B — strong at structured output
gemma2-9b|gen|bartowski/gemma-2-9b-it-GGUF|gemma-2-9b-it-Q4_K_M.gguf|Google Gemma 2 9B Instruct
deepseek-r1-7b|gen|bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF|DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf|DeepSeek R1 distill 7B — reasoning chains
llama3.1-70b-q2|gen|bartowski/Meta-Llama-3.1-70B-Instruct-GGUF|Meta-Llama-3.1-70B-Instruct-IQ2_M.gguf|Llama 3.1 70B IQ2 — large model CPU+GPU split
mistral-nemo|gen|bartowski/Mistral-Nemo-Instruct-2407-GGUF|Mistral-Nemo-Instruct-2407-Q4_K_M.gguf|Mistral Nemo 12B — long context 128k

# ── Embedding models ──────────────────────────────────────────────────────────
nomic|embed|nomic-ai/nomic-embed-text-v1.5-GGUF|nomic-embed-text-v1.5.f16.gguf|Nomic Embed Text v1.5 F16 — best general embedding (768-dim)
nomic-q8|embed|nomic-ai/nomic-embed-text-v1.5-GGUF|nomic-embed-text-v1.5.Q8_0.gguf|Nomic Embed Text v1.5 Q8 — smaller footprint
mxbai|embed|ChristianAzinn/mxbai-embed-large-v1-gguf|mxbai-embed-large-v1-f16.gguf|MixedBread mxbai-embed-large (1024-dim) — MTEB SOTA
bge-small|embed|ChristianAzinn/bge-small-en-v1.5-gguf|bge-small-en-v1.5-f16.gguf|BGE Small EN — ultra-fast minimal footprint (384-dim)
bge-large|embed|ChristianAzinn/bge-large-en-v1.5-gguf|bge-large-en-v1.5-f16.gguf|BGE Large EN — strong semantic similarity (1024-dim)
e5-large|embed|mjschock/e5-large-v2.gguf|e5-large-v2-q8_0.gguf|E5-large-v2 — multilingual capable (1024-dim)
REGISTRY

ok "Model registry → ${PREFIX}/config/models.conf"

# ── Nginx gateway config ──────────────────────────────────────────────────────
${SUDO_CMD} tee "${PREFIX}/config/nginx-gateway.conf" > /dev/null <<'NGINX'
# llamastack Nginx gateway — complete standalone config
# Start with: llamastack nginx-start
# Or include the server block in system nginx:
#   include /opt/llamastack/config/nginx-gateway.conf;

pid /opt/llamastack/run/nginx.pid;
error_log /opt/llamastack/logs/nginx-error.log warn;

events {
    worker_connections 1024;
}

http {
    access_log /opt/llamastack/logs/nginx-access.log;

    upstream llamastack_gen {
        server 127.0.0.1:8001;
        keepalive 32;
    }
    upstream llamastack_embed {
        server 127.0.0.1:8002;
        keepalive 32;
    }

    server {
        listen 8080;
        server_name _;

        client_max_body_size 64m;
        proxy_read_timeout   300s;
        proxy_send_timeout   300s;
        proxy_connect_timeout 10s;

        location /v1/embeddings {
            proxy_pass         http://llamastack_embed;
            proxy_http_version 1.1;
            proxy_set_header   Connection "";
            proxy_set_header   Host $host;
        }

        location ~ ^/v1/(chat/completions|completions) {
            proxy_pass         http://llamastack_gen;
            proxy_http_version 1.1;
            proxy_set_header   Connection "";
            proxy_set_header   Host $host;
            proxy_buffering    off;
            proxy_cache        off;
        }

        location /v1/models { proxy_pass http://llamastack_gen; proxy_http_version 1.1; }
        location /health    { proxy_pass http://llamastack_gen/health; }
        location /metrics   { proxy_pass http://llamastack_gen/metrics; allow 127.0.0.1; deny all; }
        location /          { return 404 '{"error":"endpoint not found"}'; add_header Content-Type application/json; }
    }
}
NGINX
ok "Nginx config → ${PREFIX}/config/nginx-gateway.conf"

# ── Install launch scripts (macOS) ────────────────────────────────────────────
${SUDO_CMD} tee "${PREFIX}/bin/_start-gen.sh" > /dev/null <<'SCRIPT'
#!/usr/bin/env bash
source "${LLAMASTACK_CONF:-/opt/llamastack/config/llamastack.conf}"

# ── Shared library resolution ──────────────────────────────────────────────
# llama.cpp builds multiple .so files (libmtmd.so, libggml.so, libllama.so…).
# Prepend the directory that contains llama-server so the dynamic linker
# finds them whether or not ldconfig has been updated.
BIN_DIR="$(dirname "$(readlink -f "${LLAMA_BIN}")")"
export LD_LIBRARY_PATH="${BIN_DIR}:${LD_LIBRARY_PATH:-}"
[[ -n "${CUDA_ROOT:-}" ]] && export LD_LIBRARY_PATH="${CUDA_ROOT}/lib64:${LD_LIBRARY_PATH}"

EXTRA=""
[[ "${GEN_FLASH_ATTN:-true}"      == "true" ]] && EXTRA="$EXTRA --flash-attn on"
[[ "${GEN_CONT_BATCHING:-true}"   == "true" ]] && EXTRA="$EXTRA --cont-batching"
[[ -n "${API_KEY:-}" ]]                        && EXTRA="$EXTRA --api-key ${API_KEY}"
exec "${LLAMA_BIN}" \
  --model          "${GEN_MODEL}" \
  --host           "${BIND_HOST:-127.0.0.1}" \
  --port           "${GEN_PORT:-8001}" \
  --n-gpu-layers   "${GEN_GPU_LAYERS:-40}" \
  --ctx-size       "${GEN_CTX_SIZE:-8192}" \
  --batch-size     "${GEN_BATCH_SIZE:-512}" \
  --ubatch-size    "${GEN_UBATCH_SIZE:-512}" \
  --threads        "${GEN_THREADS:-6}" \
  --parallel       "${GEN_PARALLEL:-4}" \
  --cache-reuse    "${GEN_CACHE_REUSE:-256}" \
  --metrics --no-webui \
  $EXTRA
SCRIPT

${SUDO_CMD} tee "${PREFIX}/bin/_start-embed.sh" > /dev/null <<'SCRIPT'
#!/usr/bin/env bash
source "${LLAMASTACK_CONF:-/opt/llamastack/config/llamastack.conf}"

# ── Shared library resolution ──────────────────────────────────────────────
BIN_DIR="$(dirname "$(readlink -f "${LLAMA_BIN}")")"
export LD_LIBRARY_PATH="${BIN_DIR}:${LD_LIBRARY_PATH:-}"
[[ -n "${CUDA_ROOT:-}" ]] && export LD_LIBRARY_PATH="${CUDA_ROOT}/lib64:${LD_LIBRARY_PATH}"

[[ -n "${API_KEY:-}" ]] && EXTRA="--api-key ${API_KEY}" || EXTRA=""
exec "${LLAMA_BIN}" \
  --model          "${EMBED_MODEL}" \
  --host           "${BIND_HOST:-127.0.0.1}" \
  --port           "${EMBED_PORT:-8002}" \
  --n-gpu-layers   "${EMBED_GPU_LAYERS:-99}" \
  --ctx-size       "${EMBED_CTX_SIZE:-2048}" \
  --batch-size     "${EMBED_BATCH_SIZE:-512}" \
  --ubatch-size    "${EMBED_UBATCH_SIZE:-512}" \
  --threads        "${EMBED_THREADS:-4}" \
  --parallel       "${EMBED_PARALLEL:-8}" \
  --embedding --pooling "${EMBED_POOLING:-mean}" \
  --metrics --no-webui \
  $EXTRA
SCRIPT

${SUDO_CMD} chmod +x "${PREFIX}/bin/_start-gen.sh" "${PREFIX}/bin/_start-embed.sh"

# ── systemd (Linux) ───────────────────────────────────────────────────────────
if [[ $PLATFORM == linux ]]; then
  hdr "Installing systemd services"

  CONF_FILE="${PREFIX}/config/llamastack.conf"

  for SVC in gen embed; do
    [[ $SVC == gen ]]   && DESC="generative" || DESC="embedding"
    cat > "/etc/systemd/system/llamastack-${SVC}.service" <<UNIT
[Unit]
Description=llamastack ${DESC} inference server
After=network.target
Documentation=file://${PREFIX}/docs/README.md

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
EnvironmentFile=${CONF_FILE}
ExecStartPre=/bin/bash -c 'source ${CONF_FILE}; MODEL=\${${SVC^^}_MODEL}; test -f "\$MODEL" || { echo "Model not found: \$MODEL — run: llamastack pull ${SVC} <alias>"; exit 1; }'
ExecStart=${PREFIX}/bin/_start-${SVC}.sh
Restart=always
RestartSec=5
TimeoutStartSec=120
StandardOutput=journal
StandardError=journal
SyslogIdentifier=llamastack-${SVC}

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${PREFIX}/logs ${PREFIX}/run
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=true

[Install]
WantedBy=multi-user.target
UNIT
  done

  systemctl daemon-reload
  systemctl enable llamastack-gen llamastack-embed
  ok "systemd units installed and enabled (not started — pull models first)"
fi

# ── launchd (macOS) ───────────────────────────────────────────────────────────
if [[ $PLATFORM == macos ]]; then
  hdr "Installing launchd agents"
  PLIST_DIR="/Library/LaunchDaemons"
  CONF_FILE="${PREFIX}/config/llamastack.conf"
  LOG_DIR="${PREFIX}/logs"

  for SVC in gen embed; do
    [[ $SVC == gen ]] && DESC="generative" || DESC="embedding"
    ${SUDO_CMD} tee "${PLIST_DIR}/com.llamastack.${SVC}.plist" > /dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>             <string>com.llamastack.${SVC}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${PREFIX}/bin/_start-${SVC}.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>LLAMASTACK_CONF</key><string>${CONF_FILE}</string>
  </dict>
  <key>RunAtLoad</key>         <false/>
  <key>KeepAlive</key>         <true/>
  <key>StandardOutPath</key>   <string>${LOG_DIR}/${SVC}.log</string>
  <key>StandardErrorPath</key> <string>${LOG_DIR}/${SVC}.error.log</string>
  <key>WorkingDirectory</key>  <string>${PREFIX}</string>
  <key>ProcessType</key>       <string>Background</string>
</dict>
</plist>
PLIST
  done
  ok "launchd plists installed (not loaded — pull models first)"
fi

# ── Install CLI (embedded — no external file dependency) ─────────────────────
hdr "Installing CLI"
${SUDO_CMD} tee "${PREFIX}/bin/llamastack" > /dev/null << 'ENDOFCLI'
#!/usr/bin/env bash
# =============================================================================
#  llamastack — management CLI
#  Commands: start, stop, restart, status, pull, use, models, chat, embed,
#            logs, update, uninstall, nginx-start, nginx-stop, config
# =============================================================================
set -euo pipefail

CONF="${LLAMASTACK_CONF:-/opt/llamastack/config/llamastack.conf}"
[[ -f "$CONF" ]] || { echo "Config not found: $CONF  (run installer first)"; exit 1; }
# shellcheck disable=SC1090
source "$CONF"

REGISTRY="${PREFIX}/config/models.conf"
VERSION="1.0.0"

# ── Colours ───────────────────────────────────────────────────────────────────
R='\033[0;31m' Y='\033[1;33m' G='\033[0;32m'
C='\033[0;36m' B='\033[1m' DM='\033[2m' NC='\033[0m'
ok()   { echo -e "${G}  ✓${NC}  $*"; }
fail() { echo -e "${R}  ✗${NC}  $*"; }
info() { echo -e "${C}  →${NC}  $*"; }
warn() { echo -e "${Y}  !${NC}  $*"; }
die()  { echo -e "${R}  ✗${NC}  $*" >&2; exit 1; }
hdr()  { echo -e "\n${B}$*${NC}"; }

# ── Platform helpers ──────────────────────────────────────────────────────────
_os() { uname -s; }

_sudo() {
  if [[ $(_os) == Linux ]]; then sudo "$@"
  elif [[ $EUID -ne 0 ]];   then sudo "$@"
  else "$@"
  fi
}

_svc_do() {
  local action="$1" svc="$2"
  case "$(_os)" in
    Linux)
      _sudo systemctl "$action" "llamastack-${svc}" 2>/dev/null ;;
    Darwin)
      local plist="/Library/LaunchDaemons/com.llamastack.${svc}.plist"
      case "$action" in
        start)   _sudo launchctl load -w "$plist" 2>/dev/null || _sudo launchctl start "com.llamastack.${svc}" ;;
        stop)    _sudo launchctl stop "com.llamastack.${svc}" 2>/dev/null || true ;;
        restart) _sudo launchctl stop "com.llamastack.${svc}" 2>/dev/null || true; sleep 1
                 _sudo launchctl load -w "$plist" 2>/dev/null || true ;;
      esac ;;
  esac
}

_svc_active() {
  local svc="$1"
  case "$(_os)" in
    Linux)  systemctl is-active "llamastack-${svc}" 2>/dev/null || echo "inactive" ;;
    Darwin)
      local pid
      pid=$(launchctl list "com.llamastack.${svc}" 2>/dev/null | awk 'NR>1{print $1}' | head -1 || echo "-")
      [[ "$pid" =~ ^[0-9]+$ ]] && echo "active" || echo "inactive"
      ;;
  esac
}

_health() {
  local port="$1"
  curl -sf "http://127.0.0.1:${port}/health" --max-time 3 &>/dev/null && echo "healthy" || echo "unreachable"
}

_await_health() {
  local port="$1" label="$2" tries=0
  echo -n "  Waiting for $label"
  while [[ $tries -lt 30 ]]; do
    if curl -sf "http://127.0.0.1:${port}/health" --max-time 2 &>/dev/null; then
      echo -e " ${G}ready${NC}"; return 0
    fi
    echo -n "."; sleep 2; (( tries++ ))
  done
  echo -e " ${Y}timeout (may still be loading model)${NC}"
}

_registry_lookup() {
  local alias="$1"
  grep -v '^#' "$REGISTRY" | grep -v '^$' | awk -F'|' -v a="$alias" '$1==a{print; exit}'
}

_registry_all() {
  grep -v '^#' "$REGISTRY" | grep -v '^$'
}

_hf_download() {
  local repo="$1" file="$2" dest="$3"
  local url="https://huggingface.co/${repo}/resolve/main/${file}"
  info "Source: $url"
  info "Dest  : $dest"
  echo ""
  if command -v wget &>/dev/null; then
    wget --show-progress -q -O "$dest" "$url"
  elif command -v curl &>/dev/null; then
    curl -L --progress-bar -o "$dest" "$url"
  else
    die "Neither wget nor curl found"
  fi
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_start() {
  local target="${1:-all}"
  hdr "Starting llamastack services"

  # Re-source config — paths may have been updated by pull/use since the CLI started
  # shellcheck disable=SC1090
  source "$CONF"

  # Resolve any unexpanded MODEL_DIR variable
  GEN_MODEL="${GEN_MODEL//\$\{PREFIX\}/${PREFIX}}"
  GEN_MODEL="${GEN_MODEL//\$PREFIX/${PREFIX}}"
  GEN_MODEL="${GEN_MODEL//\$\{MODEL_DIR\}/${PREFIX}/models}"
  EMBED_MODEL="${EMBED_MODEL//\$\{PREFIX\}/${PREFIX}}"
  EMBED_MODEL="${EMBED_MODEL//\$PREFIX/${PREFIX}}"
  EMBED_MODEL="${EMBED_MODEL//\$\{MODEL_DIR\}/${PREFIX}/models}"

  case "$target" in
    all|gen)
      if [[ ! -f "$GEN_MODEL" ]]; then
        fail "Gen model not found: ${GEN_MODEL}"
        echo "  Run: llamastack pull gen <alias>"
        echo "  Or:  llamastack use gen /path/to/model.gguf"
        return 1
      fi

      if ! _sudo systemctl start llamastack-gen 2>/tmp/llamastack-start-err; then
        fail "Failed to start llamastack-gen"
        echo ""
        echo "  systemctl error:"
        cat /tmp/llamastack-start-err 2>/dev/null | head -5
        echo ""
        echo "  Full service log:"
        sudo journalctl -u llamastack-gen -n 20 --no-pager 2>/dev/null || true
        echo ""
        echo "  Config values used:"
        grep -E "LLAMA_BIN|GEN_MODEL|GEN_GPU_LAYERS|GEN_CTX_SIZE" "$CONF" | head -8
        return 1
      fi
      ok "Gen server starting on :${GEN_PORT}"
      _await_health "$GEN_PORT" "gen server"
      ;;
  esac

  case "$target" in
    all|embed)
      if [[ ! -f "$EMBED_MODEL" ]]; then
        warn "No embed model — skipping. Run: llamastack pull embed <alias>"
      else
        if ! _sudo systemctl start llamastack-embed 2>/tmp/llamastack-start-err; then
          fail "Failed to start llamastack-embed"
          sudo journalctl -u llamastack-embed -n 15 --no-pager 2>/dev/null || true
        else
          ok "Embed server starting on :${EMBED_PORT}"
          _await_health "$EMBED_PORT" "embed server"
        fi
      fi
      ;;
  esac
}

cmd_stop() {
  local target="${1:-all}"
  hdr "Stopping llamastack services"
  [[ $target == all || $target == gen   ]] && { _sudo systemctl stop llamastack-gen   2>/dev/null || true; ok "Gen server stopped"; }
  [[ $target == all || $target == embed ]] && { _sudo systemctl stop llamastack-embed 2>/dev/null || true; ok "Embed server stopped"; }
}

cmd_restart() {
  local target="${1:-all}"
  hdr "Restarting llamastack services"

  # Re-source config so updated paths take effect
  # shellcheck disable=SC1090
  source "$CONF"

  case "$target" in
    all|gen)
      _sudo systemctl stop  llamastack-gen 2>/dev/null || true
      sleep 1
      cmd_start gen
      ;;
  esac
  case "$target" in
    all|embed)
      _sudo systemctl stop  llamastack-embed 2>/dev/null || true
      sleep 1
      cmd_start embed
      ;;
  esac
}

cmd_status() {
  hdr "llamastack status"
  echo ""

  # Re-source config for freshest values
  # shellcheck disable=SC1090
  source "$CONF"

  for SVC in gen embed; do
    [[ $SVC == gen ]] && PORT=$GEN_PORT MODEL_PATH="$GEN_MODEL" || PORT=$EMBED_PORT MODEL_PATH="$EMBED_MODEL"

    # Resolve unexpanded variables in path
    MODEL_PATH="${MODEL_PATH//\$\{PREFIX\}/${PREFIX}}"
    MODEL_PATH="${MODEL_PATH//\$PREFIX/${PREFIX}}"
    MODEL_PATH="${MODEL_PATH//\$\{MODEL_DIR\}/${PREFIX}/models}"

    local ACTIVE HEALTH MODEL_NAME
    ACTIVE=$(systemctl is-active "llamastack-${SVC}" 2>/dev/null || echo "inactive")
    HEALTH=$(_health "$PORT")
    MODEL_NAME=$(basename "$MODEL_PATH" 2>/dev/null || echo "not set")

    if [[ $ACTIVE == active ]]; then
      echo -e "  ${G}●${NC} llamastack-${SVC}"
    else
      echo -e "  ${R}●${NC} llamastack-${SVC}"
    fi
    echo -e "      state  : ${ACTIVE}"
    echo -e "      api    : ${HEALTH} (http://127.0.0.1:${PORT})"
    echo -e "      model  : ${MODEL_NAME}"

    # If inactive, show the last journal error to help diagnose
    if [[ $ACTIVE != active ]]; then
      local last_err
      last_err=$(sudo journalctl -u "llamastack-${SVC}" -n 3 --no-pager -o cat 2>/dev/null \
        | grep -i "error\|failed\|not found\|cannot\|no such" | tail -1 || true)
      [[ -n "$last_err" ]] && echo -e "      ${R}error${NC}  : ${last_err}"
      echo -e "      ${DM}hint   : llamastack start ${SVC}   |   llamastack logs ${SVC} 30${NC}"
    fi
    echo ""
  done

  # GPU — read live from nvidia-smi, don't trust stale config
  if command -v nvidia-smi &>/dev/null; then
    local GPU_NAME VRAM_USED VRAM_TOTAL
    GPU_NAME=$(nvidia-smi  --query-gpu=name          --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "?")
    VRAM_USED=$(nvidia-smi --query-gpu=memory.used   --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "?")
    VRAM_TOTAL=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "?")
    echo -e "  GPU      : ${GPU_NAME} — ${VRAM_USED} / ${VRAM_TOTAL} MB VRAM"
    # Warn if config says cpu but we have a real GPU
    [[ "${GPU_BACKEND:-cpu}" == "cpu" ]] && \
      echo -e "  ${Y}  ↳ GPU_BACKEND=cpu in config — run: llamastack fix-config${NC}"
  else
    echo -e "  GPU      : ${GPU_BACKEND} (nvidia-smi not found)"
  fi
  echo -e "  Endpoint : http://${BIND_HOST:-127.0.0.1}:${GATEWAY_PORT:-8080}/v1"
  echo ""
}

cmd_pull() {
  local type="${1:-}" alias="${2:-}"
  [[ -z "$type"  ]] && die "Usage: llamastack pull gen|embed <alias>\n  See: llamastack models list"
  [[ -z "$alias" ]] && die "Usage: llamastack pull gen|embed <alias>\n  See: llamastack models list"
  local row
  row=$(_registry_lookup "$alias") || die "Unknown alias '$alias'. See: llamastack models list"
  IFS='|' read -r REG_ALIAS REG_TYPE REG_REPO REG_FILE REG_DESC <<< "$row"
  [[ "$REG_TYPE" != "$type" ]] && \
    die "'$alias' is a ${REG_TYPE} model, not ${type}. Use: llamastack pull ${REG_TYPE} ${alias}"

  hdr "Downloading: $REG_DESC"
  echo ""

  # Resolve MODEL_DIR — guard against unexpanded variable in older configs
  local mdir="${MODEL_DIR:-/opt/llamastack/models}"
  mdir="${mdir//\$\{PREFIX\}/${PREFIX}}"
  mdir="${mdir//\$PREFIX/${PREFIX}}"

  # Check write access; fix automatically if we can sudo
  if [[ ! -w "$mdir" ]]; then
    warn "No write access to ${mdir} — fixing permissions (requires sudo)..."
    sudo chown "$(id -un):$(id -gn)" "$mdir" 2>/dev/null || \
      sudo chmod 777 "$mdir" 2>/dev/null || \
      die "Cannot write to ${mdir}.\n  Run manually: sudo chown \$(id -un):\$(id -gn) ${mdir} && sudo chmod 775 ${mdir}"
    ok "Permissions fixed: ${mdir}"
  fi

  local dest="${mdir}/${type}-model.gguf"
  local tmp="${dest}.tmp"

  # Remove stale tmp if exists
  [[ -f "$tmp" ]] && rm -f "$tmp"

  # Backup existing model
  [[ -f "$dest" ]] && { warn "Existing model backed up to ${dest}.bak"; mv "$dest" "${dest}.bak"; }

  # Download to a temp file in /tmp first (always writable), then move into place
  local tmptmp
  tmptmp=$(mktemp /tmp/llamastack-model-XXXXXX.gguf)
  trap "rm -f '$tmptmp'" EXIT

  _hf_download "$REG_REPO" "$REG_FILE" "$tmptmp"

  # Move to final location
  mv "$tmptmp" "$dest"
  trap - EXIT

  # Restore backup only on failure — clean it up on success
  [[ -f "${dest}.bak" ]] && rm -f "${dest}.bak"

  # Fix ownership so service user can read it
  sudo chown "llamastack:$(id -gn)" "$dest" 2>/dev/null || \
    chmod 644 "$dest" 2>/dev/null || true

  # Update alias tracking
  echo "$alias" | sudo tee "${mdir}/.${type}-alias" > /dev/null 2>/dev/null || \
    echo "$alias" > "${mdir}/.${type}-alias" 2>/dev/null || true

  # Update config to point at the actual resolved path
  _sudo sed -i.bak "s|^${type^^}_MODEL=.*|${type^^}_MODEL=\"${dest}\"|" "$CONF" 2>/dev/null || true

  ok "Downloaded: $(basename "$dest") ($(du -sh "$dest" | cut -f1))"
  echo ""
  info "Restart to load: llamastack restart ${type}"
}

cmd_use() {
  local type="${1:-}" path_or_alias="${2:-}"
  [[ -z "$type"          ]] && die "Usage: llamastack use gen|embed <path-to.gguf | alias>"
  [[ -z "$path_or_alias" ]] && die "Usage: llamastack use gen|embed <path-to.gguf | alias>"

  # Resolve MODEL_DIR — guard against unexpanded variable in older configs
  local mdir="${MODEL_DIR:-/opt/llamastack/models}"
  mdir="${mdir//\$\{PREFIX\}/${PREFIX}}"
  mdir="${mdir//\$PREFIX/${PREFIX}}"

  local target_path row
  row=$(_registry_lookup "$path_or_alias" 2>/dev/null) || true
  if [[ -n "$row" ]]; then
    target_path="${mdir}/${type}-model.gguf"
    if [[ ! -f "$target_path" ]]; then
      info "Model not yet downloaded — pulling now..."
      cmd_pull "$type" "$path_or_alias"
      return
    fi
  else
    target_path="$path_or_alias"
    [[ -f "$target_path" ]] || die "File not found: $target_path\n  Check path or run: llamastack pull ${type} <alias>"
  fi

  local conf_key abs_path
  [[ $type == gen ]] && conf_key="GEN_MODEL" || conf_key="EMBED_MODEL"
  abs_path=$(realpath "$target_path")
  _sudo sed -i.bak "s|^${conf_key}=.*|${conf_key}=\"${abs_path}\"|" "$CONF"
  ok "Configured: ${conf_key} → ${abs_path}"
  info "Restart to load: llamastack restart ${type}"
}

cmd_models() {
  local sub="${1:-list}"
  case "$sub" in
    list)
      hdr "Available models"
      echo ""
      printf "  ${B}%-20s %-6s %s${NC}\n" "ALIAS" "TYPE" "DESCRIPTION"
      printf "  %-20s %-6s %s\n" "$(printf '─%.0s' {1..20})" "──────" "$(printf '─%.0s' {1..36})"
      _registry_all | while IFS='|' read -r alias type _ _ desc; do
        local active_alias=""
        [[ -f "${MODEL_DIR}/.${type}-alias" ]] && active_alias=$(cat "${MODEL_DIR}/.${type}-alias")
        if [[ "$alias" == "$active_alias" ]]; then
          printf "  ${G}%-20s${NC} ${DM}%-6s${NC} %s ${G}← active${NC}\n" "$alias" "$type" "$desc"
        else
          printf "  %-20s ${DM}%-6s${NC} %s\n" "$alias" "$type" "$desc"
        fi
      done
      echo ""
      info "Pull : llamastack pull gen <alias>  |  llamastack pull embed <alias>"
      info "Add  : llamastack models add <alias> gen|embed <hf-repo> <hf-file> [desc]"
      ;;
    add)
      local alias="${2:-}" type="${3:-}" repo="${4:-}" file="${5:-}" desc="${6:-Custom model}"
      [[ -z "$alias" || -z "$type" || -z "$repo" || -z "$file" ]] && \
        die "Usage: llamastack models add <alias> gen|embed <hf-repo> <hf-file> [description]"
      echo "${alias}|${type}|${repo}|${file}|${desc}" >> "$REGISTRY"
      ok "Added '$alias' to registry"
      ;;
    remove)
      local alias="${2:-}"
      [[ -z "$alias" ]] && die "Usage: llamastack models remove <alias>"
      _sudo sed -i.bak "/^${alias}|/d" "$REGISTRY"
      ok "Removed '$alias' from registry"
      ;;
    *) die "Unknown models subcommand: $sub  (list | add | remove)" ;;
  esac
}

cmd_chat() {
  local prompt="${1:-}"
  [[ -z "$prompt" ]] && die "Usage: llamastack chat \"your prompt here\""
  [[ -z "${API_KEY:-}" ]] && AUTH="no-key" || AUTH="$API_KEY"

  # ── Step 1: confirm the server process is actually running ────────────────
  if ! systemctl is-active --quiet llamastack-gen 2>/dev/null && \
     ! launchctl list com.llamastack.gen 2>/dev/null | grep -q '[0-9]'; then
    # fallback: check if anything is listening on the port
    if ! curl -sf "http://127.0.0.1:${GEN_PORT}/health" --max-time 2 &>/dev/null; then
      echo ""
      fail "Gen server is not running on port ${GEN_PORT}"
      echo ""
      echo "  Diagnose with:"
      echo "    llamastack status"
      echo "    llamastack logs gen 30"
      echo ""
      echo "  Start with:"
      echo "    llamastack start gen"
      echo ""
      return 1
    fi
  fi

  # ── Step 2: get model name from /v1/models ────────────────────────────────
  local models_json model_name
  models_json=$(curl -sf "http://127.0.0.1:${GEN_PORT}/v1/models" \
    -H "Authorization: Bearer ${AUTH}" --max-time 5 2>/dev/null || true)

  if [[ -z "$models_json" ]]; then
    echo ""
    fail "Server is running but /v1/models returned nothing."
    echo ""
    echo "  The model may still be loading. Check:"
    echo "    llamastack logs gen 20"
    echo ""
    echo "  Confirm GEN_MODEL path in config:"
    echo "    llamastack config | grep GEN_MODEL"
    echo ""
    return 1
  fi

  model_name=$(echo "$models_json" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null \
    || true)

  if [[ -z "$model_name" ]]; then
    echo ""
    fail "Could not parse model name from /v1/models response:"
    echo "  $models_json"
    echo ""
    return 1
  fi

  # ── Step 3: stream the completion ─────────────────────────────────────────
  hdr "Chat → $model_name"
  echo ""

  local encoded_prompt
  encoded_prompt=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$prompt")

  local response
  response=$(curl -s --no-buffer \
    "http://127.0.0.1:${GEN_PORT}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AUTH}" \
    -d "{\"model\":\"${model_name}\",\"messages\":[{\"role\":\"user\",\"content\":${encoded_prompt}}],\"stream\":true}" \
    2>&1)

  if [[ -z "$response" ]]; then
    fail "Empty response from server. Check logs: llamastack logs gen 30"
    return 1
  fi

  # Check for an error JSON (non-streaming error response)
  if echo "$response" | python3 -c "
import sys,json
try:
  d=json.loads(sys.stdin.read().split('\n')[0])
  if 'error' in d:
    print('ERROR: ' + str(d['error']))
    sys.exit(1)
except: pass
" 2>/dev/null; then
    : # no error detected, fall through to stream parse
  fi

  echo "$response" | while IFS= read -r line; do
    data="${line#data: }"
    [[ "$data" == "[DONE]" ]] && break
    [[ -z "$data" ]] && continue
    python3 -c "
import sys,json
try:
  d=json.loads(sys.argv[1])
  t=d['choices'][0]['delta'].get('content','')
  if t: print(t,end='',flush=True)
except: pass
" "$data" 2>/dev/null || true
  done
  echo -e "\n"
}

cmd_embed() {
  local text="${1:-}"
  [[ -z "$text" ]] && die "Usage: llamastack embed \"text to embed\""
  [[ -z "${API_KEY:-}" ]] && AUTH="no-key" || AUTH="$API_KEY"
  hdr "Embedding"
  curl -s "http://127.0.0.1:${EMBED_PORT}/v1/embeddings" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AUTH}" \
    -d "{\"model\":\"embed\",\"input\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$text")}" \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
v=d['data'][0]['embedding']
print(f'  Dimensions    : {len(v)}')
print(f'  First 6 vals  : {[round(x,4) for x in v[:6]]}')
print(f'  Norm          : {round(sum(x*x for x in v)**0.5,4)}')
"
  echo ""
}

cmd_logs() {
  local svc="${1:-gen}" lines="${2:-50}"
  case "$(_os)" in
    Linux)  journalctl -u "llamastack-${svc}" -n "$lines" --no-pager ;;
    Darwin)
      local log="${LOG_DIR}/${svc}.log"
      [[ -f "$log" ]] && tail -n "$lines" "$log" || warn "Log not found: $log"
      ;;
  esac
}

cmd_update() {
  hdr "Updating llama.cpp"
  local src="${PREFIX}/src/llama.cpp"
  [[ -d "$src" ]] || die "Source not found: $src  (reinstall or use LLAMASTACK_PREBUILT)"
  info "Pulling latest source..."
  _sudo git -C "$src" pull
  JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
  _sudo cmake --build "${src}/build" --config Release -j"$JOBS"
  _sudo cmake --install "${src}/build"
  ok "llama.cpp updated — restart to apply: llamastack restart"
}

cmd_config() {
  local key="${1:-}" val="${2:-}"
  if [[ -z "$key" ]]; then
    hdr "Current config (${CONF})"
    grep -v '^#' "$CONF" | grep -v '^$'
    return
  fi
  [[ -z "$val" ]] && die "Usage: llamastack config KEY VALUE"
  _sudo sed -i.bak "s|^${key}=.*|${key}=\"${val}\"|" "$CONF"
  ok "Set ${key}=${val}"
  info "Restart to apply: llamastack restart"
}

cmd_uninstall() {
  hdr "Uninstalling llamastack"
  warn "This will remove all services, binaries, and configuration."
  echo ""
  read -rp "  Continue? [y/N] " ans
  [[ ${ans:-N} =~ ^[Yy] ]] || { echo "Aborted."; return; }
  for SVC in gen embed; do _svc_do stop "$SVC" 2>/dev/null || true; done
  case "$(_os)" in
    Linux)
      systemctl disable llamastack-gen llamastack-embed 2>/dev/null || true
      rm -f /etc/systemd/system/llamastack-{gen,embed}.service
      systemctl daemon-reload
      id "${SVC_USER:-llamastack}" &>/dev/null && userdel "${SVC_USER:-llamastack}" 2>/dev/null || true
      ;;
    Darwin)
      for SVC in gen embed; do
        local plist="/Library/LaunchDaemons/com.llamastack.${SVC}.plist"
        _sudo launchctl unload "$plist" 2>/dev/null || true
        _sudo rm -f "$plist"
      done
      ;;
  esac
  rm -f /usr/local/bin/llamastack
  read -rp "  Delete models too? [y/N] " del_models
  if [[ ${del_models:-N} =~ ^[Yy] ]]; then
    _sudo rm -rf "$PREFIX"
    ok "Removed $PREFIX (including models)"
  else
    _sudo rm -rf "${PREFIX}/bin" "${PREFIX}/config" "${PREFIX}/src" "${PREFIX}/logs" "${PREFIX}/run"
    ok "Removed binaries and config. Models preserved: ${MODEL_DIR}"
  fi
  ok "llamastack uninstalled"
}

cmd_nginx_start() {
  command -v nginx &>/dev/null || die "nginx not found — install: apt install nginx  or  brew install nginx"

  local conf="${PREFIX}/config/nginx-gateway.conf"
  local pid="${PREFIX}/run/nginx.pid"

  # Ensure log and run dirs are writable
  mkdir -p "${PREFIX}/logs" "${PREFIX}/run" 2>/dev/null || true

  # Stop any existing instance first
  [[ -f "$pid" ]] && _sudo nginx -s stop -c "$conf" 2>/dev/null || true
  sleep 1

  # Validate config before starting
  if ! _sudo nginx -t -c "$conf" 2>/tmp/nginx-test-err; then
    fail "Nginx config test failed:"
    cat /tmp/nginx-test-err
    return 1
  fi

  _sudo nginx -c "$conf"
  sleep 1

  if curl -sf http://127.0.0.1:${GATEWAY_PORT:-8080}/health --max-time 3 &>/dev/null; then
    ok "Nginx gateway running on :${GATEWAY_PORT:-8080}"
  else
    ok "Nginx started — gateway on :${GATEWAY_PORT:-8080}"
  fi
}

cmd_nginx_stop() {
  local conf="${PREFIX}/config/nginx-gateway.conf"
  local pid="${PREFIX}/run/nginx.pid"
  if [[ -f "$pid" ]]; then
    _sudo nginx -s stop -c "$conf" 2>/dev/null && ok "Nginx stopped" ||       { _sudo kill "$(cat "$pid")" 2>/dev/null && ok "Nginx killed"; }
  else
    warn "Nginx not running (no pid file)"
  fi
}

cmd_version() {
  echo "llamastack ${VERSION}"

  # Resolve LLAMA_BIN — config value may be wrong after prebuilt install;
  # search common locations if the configured path doesn't exist
  local bin="${LLAMA_BIN:-}"
  if [[ ! -x "$bin" ]]; then
    for candidate in \
      "${PREFIX}/bin/llama-server" \
      "/usr/local/bin/llama-server" \
      "$(command -v llama-server 2>/dev/null || true)"; do
      [[ -x "$candidate" ]] && { bin="$candidate"; break; }
    done
  fi

  if [[ -x "$bin" ]]; then
    local ver
    ver=$("$bin" --version 2>/dev/null | head -1 || echo "unknown")
    echo "llama.cpp : ${ver}"
    echo "binary    : ${bin}"
    # Auto-heal config if it was pointing at the wrong path
    if [[ "$bin" != "${LLAMA_BIN:-}" ]]; then
      warn "LLAMA_BIN in config was '${LLAMA_BIN}' — updating to '${bin}'"
      _sudo sed -i.bak "s|^LLAMA_BIN=.*|LLAMA_BIN=\"${bin}\"|" "$CONF"
    fi
  else
    echo "llama.cpp : not found"
    echo ""
    echo "  Fix: tell llamastack where llama-server is:"
    echo "    llamastack fix-bin /path/to/llama-server"
    echo ""
    echo "  Or find it:"
    echo "    find / -name 'llama-server' -type f 2>/dev/null"
  fi

  echo "platform  : $(_os) / $(uname -m)"

  # Detect actual GPU backend from running hardware, not just config
  local gpu_info="cpu (config)"
  if command -v nvidia-smi &>/dev/null; then
    local gpu_name vram_used vram_total
    gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
    vram_used=$(nvidia-smi --query-gpu=memory.used  --format=csv,noheader,nounits 2>/dev/null | head -1 || true)
    vram_total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || true)
    if [[ -n "$gpu_name" ]]; then
      gpu_info="cuda — ${gpu_name} (${vram_used}/${vram_total} MB VRAM)"
      # Auto-heal GPU_BACKEND in config if it says cpu but we have a real GPU
      if [[ "${GPU_BACKEND:-cpu}" == "cpu" ]]; then
        warn "GPU detected but config says GPU_BACKEND=cpu — run: llamastack fix-config"
      fi
    fi
  elif system_profiler SPDisplaysDataType 2>/dev/null | grep -qi metal; then
    gpu_info="metal (Apple)"
  fi
  echo "GPU       : ${gpu_info}"
  echo "config    : ${CONF}"
}

cmd_fix_bin() {
  # llamastack fix-bin /path/to/llama-server
  # Tells llamastack where the binary is and updates config + start scripts
  local bin="${1:-}"
  if [[ -z "$bin" ]]; then
    echo ""
    info "Searching for llama-server on this system..."
    find / -name "llama-server" -type f -perm /111 2>/dev/null | head -10
    echo ""
    echo "Usage: llamastack fix-bin /path/to/llama-server"
    return
  fi
  [[ -x "$bin" ]] || die "Not executable: $bin"
  local abs
  abs=$(realpath "$bin")
  _sudo sed -i.bak "s|^LLAMA_BIN=.*|LLAMA_BIN=\"${abs}\"|" "$CONF"
  ok "LLAMA_BIN → ${abs}"
  info "Restart to apply: llamastack restart"
}

cmd_fix_libs() {
  # Fix "error while loading shared libraries: libmtmd.so.0" and similar.
  # Finds all llama.cpp .so files from a build dir and registers them with ldconfig.
  # Usage: llamastack fix-libs [build-dir]
  # Example: llamastack fix-libs /projects/llamacppstack/llama.cpp/build
  hdr "Fixing shared library paths"
  echo ""

  local build_dir="${1:-}"

  # If no build dir given, search common locations
  if [[ -z "$build_dir" ]]; then
    for candidate in \
      /projects/llamacppstack/llama.cpp/build \
      /opt/llamastack/src/llama.cpp/build \
      "${PREFIX}/src/llama.cpp/build"; do
      if [[ -d "$candidate" ]]; then
        build_dir="$candidate"
        info "Auto-detected build dir: ${build_dir}"
        break
      fi
    done
  fi

  if [[ -z "$build_dir" ]]; then
    # Search the whole filesystem as last resort
    info "Searching for libmtmd.so..."
    local found_lib
    found_lib=$(find / -name "libmtmd.so*" -type f 2>/dev/null | head -1 || true)
    if [[ -n "$found_lib" ]]; then
      build_dir=$(dirname "$found_lib")
      info "Found at: ${found_lib}"
    else
      die "Cannot find libmtmd.so anywhere.\nProvide the build dir: llamastack fix-libs /path/to/llama.cpp/build"
    fi
  fi

  # Copy all .so files to PREFIX/bin
  local lib_count=0
  shopt -s nullglob
  for lib_dir in "$build_dir" "${build_dir}/bin" "${build_dir}/lib" "${build_dir}/lib64"; do
    [[ -d "$lib_dir" ]] || continue
    for lib in "${lib_dir}"/lib*.so "${lib_dir}"/lib*.so.*; do
      [[ -e "$lib" ]] || continue
      _sudo cp -P "$lib" "${PREFIX}/bin/"
      ok "Copied: $(basename "$lib")"
      (( lib_count++ )) || true
    done
  done
  shopt -u nullglob

  if (( lib_count == 0 )); then
    warn "No .so files found in ${build_dir}"
    warn "Try: llamastack fix-libs /path/to/llama.cpp/build/bin"
    return 1
  fi

  ok "Copied ${lib_count} libraries to ${PREFIX}/bin/"

  # Register with ldconfig
  local ldconf="/etc/ld.so.conf.d/llamastack.conf"
  echo "${PREFIX}/bin" | _sudo tee "$ldconf" > /dev/null
  _sudo ldconfig
  ok "ldconfig updated — ${ldconf}"

  echo ""
  info "Verify libraries are found:"
  echo "    ldconfig -p | grep -E 'libmtmd|libggml|libllama'"
  echo ""

  # Also patch the live start scripts to set LD_LIBRARY_PATH directly —
  # this is the belt-and-suspenders fix that works even if ldconfig is stale
  for script in "${PREFIX}/bin/_start-gen.sh" "${PREFIX}/bin/_start-embed.sh"; do
    [[ -f "$script" ]] || continue
    if ! grep -q "LD_LIBRARY_PATH" "$script"; then
      # Insert LD_LIBRARY_PATH lines after the source line
      _sudo sed -i '/^source.*llamastack.conf/a \nBIN_DIR="$(dirname "$(readlink -f "${LLAMA_BIN}")")"
export LD_LIBRARY_PATH="${BIN_DIR}:${LD_LIBRARY_PATH:-}"' "$script"
      ok "Patched LD_LIBRARY_PATH into $(basename $script)"
    else
      info "$(basename $script) already has LD_LIBRARY_PATH"
    fi
  done

  echo ""
  info "Restart services:"
  echo "    llamastack start gen"
}

cmd_fix_models_dir() {
  # Fix permissions on models/ so the current user can copy GGUFs into it.
  # Run once after a prebuilt/prepackaged install: sudo llamastack fix-models-dir
  hdr "Fixing models directory permissions"
  local mdir="${PREFIX}/models"

  _sudo chmod 775 "$mdir"
  # Give the calling user's group write access
  _sudo chown "llamastack:$(id -gn 2>/dev/null || echo root)" "$mdir" 2>/dev/null || \
    _sudo chmod 777 "$mdir"

  ok "Permissions fixed: ${mdir}"
  info "You can now copy GGUF files: cp /path/to/model.gguf ${mdir}/gen-model.gguf"
  echo ""

  # Also fix the unexpanded MODEL_DIR in config if present
  local cur
  cur=$(grep "^GEN_MODEL=" "$CONF" | cut -d= -f2- | tr -d '"')
  if echo "$cur" | grep -q '\${MODEL_DIR}\|\\$MODEL_DIR'; then
    local fixed="${mdir}/gen-model.gguf"
    _sudo sed -i.bak "s|^GEN_MODEL=.*|GEN_MODEL=\"${fixed}\"|" "$CONF"
    ok "Fixed GEN_MODEL path: ${fixed}"
  fi
  cur=$(grep "^EMBED_MODEL=" "$CONF" | cut -d= -f2- | tr -d '"')
  if echo "$cur" | grep -q '\${MODEL_DIR}\|\\$MODEL_DIR'; then
    local fixed="${mdir}/embed-model.gguf"
    _sudo sed -i.bak "s|^EMBED_MODEL=.*|EMBED_MODEL=\"${fixed}\"|" "$CONF"
    ok "Fixed EMBED_MODEL path: ${fixed}"
  fi
  cur=$(grep "^MODEL_DIR=" "$CONF" | cut -d= -f2- | tr -d '"')
  if echo "$cur" | grep -q '\${PREFIX}\|\\$PREFIX'; then
    _sudo sed -i.bak "s|^MODEL_DIR=.*|MODEL_DIR=\"${mdir}\"|" "$CONF"
    ok "Fixed MODEL_DIR path: ${mdir}"
  fi
}

cmd_fix_config() {
  # Detects actual hardware and heals GPU_BACKEND, CUDA_ROOT, LLAMA_BIN in config
  hdr "Fixing config from live hardware"
  echo ""

  # ── Find llama-server ──────────────────────────────────────────────────────
  local bin="${LLAMA_BIN:-}"
  if [[ ! -x "$bin" ]]; then
    for candidate in \
      "${PREFIX}/bin/llama-server" \
      "/usr/local/bin/llama-server" \
      "$(command -v llama-server 2>/dev/null || true)"; do
      [[ -x "$candidate" ]] && { bin="$candidate"; break; }
    done
  fi
  if [[ -x "$bin" ]]; then
    _sudo sed -i.bak "s|^LLAMA_BIN=.*|LLAMA_BIN=\"${bin}\"|" "$CONF"
    ok "LLAMA_BIN → ${bin}"
  else
    warn "llama-server binary not found — run: llamastack fix-bin /path/to/llama-server"
  fi

  # ── Detect GPU ─────────────────────────────────────────────────────────────
  if command -v nvidia-smi &>/dev/null; then
    local gpu_name compute vram
    gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
    compute=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d '.' || echo "86")
    vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")

    if [[ -n "$gpu_name" ]]; then
      # Find CUDA root
      local cuda_root=""
      for d in $(ls -d /usr/local/cuda-* 2>/dev/null | sort -V -r) /usr/local/cuda; do
        [[ -x "${d}/bin/nvcc" ]] && { cuda_root="$d"; break; }
      done
      [[ -z "$cuda_root" ]] && command -v nvcc &>/dev/null && \
        cuda_root=$(dirname "$(dirname "$(command -v nvcc)")")

      # Compute arch
      local arch
      case "$compute" in
        12*) arch=120 ;; 89*|90*) arch=89 ;; 86*|87*) arch=86 ;;
        80*) arch=80  ;; 75*)     arch=75 ;; *)        arch=86 ;;
      esac

      _sudo sed -i.bak "s|^GPU_BACKEND=.*|GPU_BACKEND=\"cuda\"|" "$CONF"
      ok "GPU_BACKEND → cuda (${gpu_name}, sm_${arch})"

      if [[ -n "$cuda_root" ]]; then
        # Patch GEN_GPU_LAYERS and EMBED_GPU_LAYERS based on VRAM
        if   (( vram >= 20000 )); then gen_layers=999; ctx=16384
        elif (( vram >= 16000 )); then gen_layers=40;  ctx=8192
        elif (( vram >= 10000 )); then gen_layers=32;  ctx=4096
        else                          gen_layers=20;  ctx=2048
        fi
        _sudo sed -i.bak \
          -e "s|^GEN_GPU_LAYERS=.*|GEN_GPU_LAYERS=${gen_layers}|" \
          -e "s|^GEN_CTX_SIZE=.*|GEN_CTX_SIZE=${ctx}|" \
          -e "s|^EMBED_GPU_LAYERS=.*|EMBED_GPU_LAYERS=99|" \
          "$CONF"
        ok "GEN_GPU_LAYERS → ${gen_layers}  (VRAM: ${vram} MB)"
        ok "GEN_CTX_SIZE   → ${ctx}"
        ok "EMBED_GPU_LAYERS → 99"
      else
        warn "CUDA toolkit (nvcc) not found — GPU_BACKEND set to cuda but layers will run on CPU"
        warn "Install CUDA toolkit: sudo apt install cuda-toolkit-13-2"
      fi

      # Update _start-gen.sh and _start-embed.sh to enable flash-attn
      _sudo sed -i.bak 's|GEN_FLASH_ATTN:-false|GEN_FLASH_ATTN:-true|g' \
        "${PREFIX}/bin/_start-gen.sh" 2>/dev/null || true

    fi
  elif system_profiler SPDisplaysDataType 2>/dev/null | grep -qi metal; then
    _sudo sed -i.bak "s|^GPU_BACKEND=.*|GPU_BACKEND=\"metal\"|" "$CONF"
    _sudo sed -i.bak -e "s|^GEN_GPU_LAYERS=.*|GEN_GPU_LAYERS=999|" \
                     -e "s|^EMBED_GPU_LAYERS=.*|EMBED_GPU_LAYERS=999|" "$CONF"
    ok "GPU_BACKEND → metal (Apple Silicon)"
  else
    warn "No GPU detected — staying at CPU mode"
  fi

  echo ""
  info "Config updated: ${CONF}"
  info "Restart services: llamastack restart"
  echo ""
}

cmd_help() {
  cat <<HELP

${B}llamastack ${VERSION}${NC} — offline OpenAI-compatible inference engine

${B}Service control${NC}
  llamastack start   [gen|embed]        Start service(s)
  llamastack stop    [gen|embed]        Stop service(s)
  llamastack restart [gen|embed]        Restart service(s)
  llamastack status                     Health, VRAM, active models

${B}Models${NC}
  llamastack models list                All available aliases
  llamastack models add  <alias> gen|embed <hf-repo> <hf-file> [desc]
  llamastack models remove <alias>
  llamastack pull gen   <alias>         Download generative model
  llamastack pull embed <alias>         Download embedding model
  llamastack use  gen   <alias|path>    Switch gen model (no download)
  llamastack use  embed <alias|path>    Switch embed model (no download)

${B}Quick test${NC}
  llamastack chat  "your prompt"        Streaming chat completion
  llamastack embed "text to embed"      Embedding dimensions + norm

${B}Config & logs${NC}
  llamastack config                     Show all config values
  llamastack config KEY VALUE           Update a config value
  llamastack logs [gen|embed] [N]       Tail logs (default: gen, 50 lines)

${B}Maintenance${NC}
  llamastack update                     Rebuild llama.cpp from source
  llamastack version                    Show versions
  llamastack diagnose                   Run full health check — start here if something is wrong
  llamastack fix-config                 Auto-detect GPU/binary and heal config (run after prebuilt install)
  llamastack fix-models-dir             Fix models/ permissions + unexpanded paths in config
  llamastack fix-libs [build-dir]       Fix missing .so libraries (libmtmd.so.0 etc)
  llamastack fix-bin [path]             Set or find the llama-server binary path
  llamastack uninstall                  Remove llamastack

${B}Gateway (Nginx)${NC}
  llamastack nginx-start                Start Nginx on :${GATEWAY_PORT:-8080}
  llamastack nginx-stop                 Stop Nginx

${B}Endpoint${NC}
  http://localhost:8080/v1/chat/completions
  http://localhost:8080/v1/embeddings
  http://localhost:8080/v1/models

${B}Examples${NC}
  llamastack pull gen  mistral-7b          # 4GB VRAM, Q4_K_M
  llamastack pull gen  llama3.1-8b         # 5GB VRAM
  llamastack pull gen  deepseek-r1-7b      # reasoning
  llamastack pull embed nomic              # 768-dim
  llamastack use  gen  /my/model.gguf      # any GGUF on disk

HELP
}

cmd_diagnose() {
  hdr "llamastack diagnostics"
  echo ""
  local ok=0 fail=0

  _chk() {
    local label="$1" result="$2" detail="${3:-}"
    if [[ "$result" == "ok" ]]; then
      echo -e "  ${G}✓${NC}  $label"
      (( ok++ )) || true
    else
      echo -e "  ${R}✗${NC}  $label"
      [[ -n "$detail" ]] && echo -e "       ${DM}$detail${NC}"
      (( fail++ )) || true
    fi
  }

  # 1. Config file
  [[ -f "$CONF" ]] && _chk "Config file: $CONF" ok || _chk "Config file: $CONF" fail "Not found — reinstall"

  # 2. llama-server binary
  [[ -x "${LLAMA_BIN}" ]] \
    && _chk "Binary: ${LLAMA_BIN}" ok \
    || _chk "Binary: ${LLAMA_BIN}" fail "Not found — run: sudo ./install.sh --skip-build"

  # 3. Gen model file
  if [[ -f "${GEN_MODEL}" ]]; then
    SIZE=$(du -sh "$GEN_MODEL" | cut -f1)
    _chk "Gen model: $(basename $GEN_MODEL) ($SIZE)" ok
  else
    _chk "Gen model: ${GEN_MODEL}" fail "File not found — run: llamastack pull gen <alias>"
  fi

  # 4. Embed model file
  if [[ -f "${EMBED_MODEL:-}" ]]; then
    SIZE=$(du -sh "$EMBED_MODEL" | cut -f1)
    _chk "Embed model: $(basename $EMBED_MODEL) ($SIZE)" ok
  else
    _chk "Embed model: ${EMBED_MODEL:-not set}" fail "Optional — run: llamastack pull embed <alias>"
  fi

  # 5. systemd service states
  if command -v systemctl &>/dev/null; then
    for SVC in gen embed; do
      STATE=$(systemctl is-active llamastack-${SVC} 2>/dev/null || echo "inactive")
      [[ "$STATE" == "active" ]] \
        && _chk "systemd llamastack-${SVC}: active" ok \
        || _chk "systemd llamastack-${SVC}: ${STATE}" fail "Run: llamastack start ${SVC}"
    done
  fi

  # 6. Port health
  for SVC in gen embed; do
    [[ $SVC == gen ]] && PORT=$GEN_PORT || PORT=$EMBED_PORT
    if curl -sf "http://127.0.0.1:${PORT}/health" --max-time 3 &>/dev/null; then
      _chk "HTTP health :${PORT} (/health)" ok
    else
      _chk "HTTP health :${PORT} (/health)" fail "Server not responding — check: llamastack logs ${SVC} 30"
    fi
  done

  # 7. /v1/models response
  MODELS=$(curl -sf "http://127.0.0.1:${GEN_PORT}/v1/models" --max-time 5 2>/dev/null || true)
  if [[ -n "$MODELS" ]]; then
    MODEL_ID=$(echo "$MODELS" | python3 -c "
import sys,json
try: print(json.load(sys.stdin)['data'][0]['id'])
except: print('parse error')
" 2>/dev/null || echo "parse error")
    _chk "/v1/models → ${MODEL_ID}" ok
  else
    _chk "/v1/models response" fail "Empty — model may still be loading or path is wrong"
  fi

  # 8. GPU visibility
  if command -v nvidia-smi &>/dev/null; then
    GPU=$(nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader 2>/dev/null | head -1 || true)
    [[ -n "$GPU" ]] && _chk "GPU: $GPU" ok || _chk "GPU: nvidia-smi failed" fail
  else
    _chk "GPU: nvidia-smi not found" fail "CPU-only mode or driver issue"
  fi

  # 9. GEN_MODEL path in config vs actual file on disk
  CONF_MODEL=$(grep "^GEN_MODEL=" "$CONF" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
  if [[ -n "$CONF_MODEL" && -f "$CONF_MODEL" ]]; then
    _chk "Config GEN_MODEL path resolves to file on disk" ok
  else
    _chk "Config GEN_MODEL path: ${CONF_MODEL}" fail \
      "File not at this path — run: llamastack use gen /actual/path/to/model.gguf"
  fi

  echo ""
  echo "  ─────────────────────────────────────────"
  echo -e "  ${G}${ok} passed${NC}  /  ${R}${fail} failed${NC}"
  echo ""

  if (( fail > 0 )); then
    echo "  Common fixes:"
    echo ""
    echo "  Model not found:"
    echo "    llamastack use gen /path/to/your/llama3.1-model.gguf"
    echo "    llamastack restart gen"
    echo ""
    echo "  Service not started:"
    echo "    llamastack start gen"
    echo "    llamastack logs gen 40"
    echo ""
    echo "  Confirm exact model path:"
    echo "    grep GEN_MODEL /opt/llamastack/config/llamastack.conf"
    echo "    ls -lh /opt/llamastack/models/"
    echo ""
  fi
}

CMD="${1:-help}"
shift || true
case "$CMD" in
  start)        cmd_start "$@" ;;
  stop)         cmd_stop "$@" ;;
  restart)      cmd_restart "$@" ;;
  status)       cmd_status ;;
  pull)         cmd_pull "$@" ;;
  use)          cmd_use "$@" ;;
  models)       cmd_models "$@" ;;
  chat)         cmd_chat "$@" ;;
  embed)        cmd_embed "$@" ;;
  logs)         cmd_logs "$@" ;;
  update)       cmd_update ;;
  config)       cmd_config "$@" ;;
  uninstall)    cmd_uninstall ;;
  nginx-start)  cmd_nginx_start ;;
  nginx-stop)   cmd_nginx_stop ;;
  version|-v|--version) cmd_version ;;
  diagnose)             cmd_diagnose ;;
  fix-bin)              cmd_fix_bin "$@" ;;
  fix-config)           cmd_fix_config ;;
  fix-models-dir)       cmd_fix_models_dir ;;
  fix-libs)             cmd_fix_libs "$@" ;;
  help|-h|--help)       cmd_help ;;
  *) echo "Unknown command: $CMD"; cmd_help; exit 1 ;;
esac
ENDOFCLI

${SUDO_CMD} chmod +x "${PREFIX}/bin/llamastack"
${SUDO_CMD} ln -sf "${PREFIX}/bin/llamastack" /usr/local/bin/llamastack
ok "CLI installed → /usr/local/bin/llamastack"

# ── Install docs (embedded) ───────────────────────────────────────────────────
${SUDO_CMD} mkdir -p "${PREFIX}/docs"

# ── Done ──────────────────────────────────────────────────────────────────────
hdr "Installation complete ✓"
echo ""
echo "  Prefix  : ${PREFIX}"
echo "  GPU     : ${GPU_LABEL}"
echo "  Config  : ${PREFIX}/config/llamastack.conf"
echo "  Models  : ${PREFIX}/models/"
echo ""
echo "  Next steps:"
echo ""
echo "    llamastack models list              # see all available models"
echo "    llamastack pull gen mistral-7b      # download generative model"
echo "    llamastack pull embed nomic         # download embedding model"
echo "    llamastack start                    # start both services"
echo "    llamastack status                   # check running state"
echo "    llamastack chat \"Hello world\"       # quick test"
echo ""
echo "  OpenAI-compatible endpoint: http://localhost:8080/v1"
echo ""
