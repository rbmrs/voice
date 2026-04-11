#!/usr/bin/env bash
# install.sh — single-command Linux setup for Voice
#
# Usage:
#   bash tools/voice-cli/install.sh           # first install
#   bash tools/voice-cli/install.sh --update  # pull latest whisper.cpp + rebuild
#   bash tools/voice-cli/install.sh --help

set -u

# ---------------------------------------------------------------------------
# Resolve script and repo root (symlink-safe, same pattern as voice wrapper)
# ---------------------------------------------------------------------------
SOURCE="${BASH_SOURCE[0]}"
while [ -L "${SOURCE}" ]; do
  SCRIPT_DIR="$(cd -- "$(dirname -- "${SOURCE}")" && pwd)"
  TARGET="$(readlink -- "${SOURCE}")"
  if [[ "${TARGET}" == /* ]]; then
    SOURCE="${TARGET}"
  else
    SOURCE="${SCRIPT_DIR}/${TARGET}"
  fi
done
SCRIPT_DIR="$(cd -- "$(dirname -- "${SOURCE}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

# ---------------------------------------------------------------------------
# Path constants
# ---------------------------------------------------------------------------
VOICE_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/voice"
WHISPER_SRC_DIR="${VOICE_DATA_DIR}/src/whisper.cpp"
WHISPER_BUILD_DIR="${WHISPER_SRC_DIR}/build"
WHISPER_BIN="${WHISPER_BUILD_DIR}/bin/whisper-cli"
LOCAL_BIN="${HOME}/.local/bin"
VOICE_WRAPPER="${REPO_ROOT}/tools/voice-cli/voice"
WHISPER_REPO="https://github.com/ggerganov/whisper.cpp.git"
PACKAGE_MANAGER=""
DISTRO_LABEL=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
UPDATE=0
for arg in "$@"; do
  case "${arg}" in
    --update)   UPDATE=1 ;;
    --help|-h)
      echo "Usage: bash tools/voice-cli/install.sh [--update]"
      echo ""
      echo "  (no flags)  Install system packages, build whisper.cpp, wire voice command."
      echo "              Skips whisper.cpp build if the binary already exists."
      echo "  --update    Pull the latest whisper.cpp and rebuild before installing."
      exit 0
      ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      echo "Run with --help for usage." >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Print helpers
# ---------------------------------------------------------------------------
_tty_bold=""
_tty_reset=""
_tty_green=""
_tty_yellow=""
_tty_cyan=""
if [[ -t 1 ]]; then
  _tty_bold="\033[1m"
  _tty_reset="\033[0m"
  _tty_green="\033[32m"
  _tty_yellow="\033[33m"
  _tty_cyan="\033[36m"
fi

step()  { printf "${_tty_bold}${_tty_cyan}[voice]${_tty_reset} %s\n" "$*"; }
ok()    { printf "${_tty_bold}${_tty_green}[voice]${_tty_reset} %s\n" "$*"; }
warn()  { printf "${_tty_bold}${_tty_yellow}[voice] warning:${_tty_reset} %s\n" "$*" >&2; }
die()   { printf "${_tty_bold}\033[31m[voice] error:${_tty_reset} %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# check_prerequisites
# ---------------------------------------------------------------------------
detect_package_manager() {
  if command -v apt-get &>/dev/null; then
    PACKAGE_MANAGER="apt"
    DISTRO_LABEL="apt-based distro"
    return 0
  fi

  if command -v dnf &>/dev/null; then
    PACKAGE_MANAGER="dnf"
    DISTRO_LABEL="Fedora-like distro"
    return 0
  fi

  die "Unsupported Linux package manager. Expected apt-get or dnf."
}

check_prerequisites() {
  step "Checking prerequisites..."

  detect_package_manager

  if ! command -v python3 &>/dev/null; then
    die "python3 is required but not found. Install it with your system package manager first."
  fi

  if ! command -v git &>/dev/null; then
    die "git is required but not found. Install it with your system package manager first."
  fi

  ok "Prerequisites OK (${DISTRO_LABEL})"
}

# ---------------------------------------------------------------------------
# install_apt_packages
# ---------------------------------------------------------------------------
install_apt_packages() {
  step "Installing system packages..."

  local packages=(
    git build-essential cmake ninja-build pkg-config ccache curl wget
    ffmpeg sox xclip xdotool python3
    libopenblas-dev
  )

  # Audio: if PipeWire/PulseAudio is already running keep it; otherwise add ALSA
  if pactl info &>/dev/null 2>&1; then
    ok "Audio server already running — skipping audio package installation"
  else
    packages+=(alsa-utils)
  fi

  sudo apt-get install -y --no-upgrade "${packages[@]}"

  ok "System packages installed"
}

install_dnf_packages() {
  step "Installing system packages..."

  local packages=(
    git gcc gcc-c++ make cmake ninja-build pkgconf-pkg-config ccache curl wget
    ffmpeg-free sox wl-clipboard xclip xdotool wtype python3
    openblas-devel pipewire-utils alsa-utils
  )

  sudo dnf install -y "${packages[@]}"

  ok "System packages installed"
}

install_system_packages() {
  case "${PACKAGE_MANAGER}" in
    apt) install_apt_packages ;;
    dnf) install_dnf_packages ;;
    *) die "Unsupported package manager: ${PACKAGE_MANAGER}" ;;
  esac
}

# ---------------------------------------------------------------------------
# detect_gpu — sets CMAKE_GPU_FLAGS and GPU_LABEL
# ---------------------------------------------------------------------------
CMAKE_GPU_FLAGS=""
GPU_LABEL=""

detect_gpu() {
  step "Detecting GPU..."

  if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
    CMAKE_GPU_FLAGS="-DGGML_CUDA=ON"
    GPU_LABEL="NVIDIA CUDA"
    ok "GPU: ${GPU_LABEL}"
    warn "Ensure the CUDA toolkit is installed before building."
    warn "See docs/linux-mvp.md for CUDA setup instructions."
  elif command -v vulkaninfo &>/dev/null && vulkaninfo &>/dev/null 2>&1; then
    CMAKE_GPU_FLAGS="-DGGML_VULKAN=1"
    GPU_LABEL="Vulkan"
    ok "GPU: ${GPU_LABEL}"
  else
    CMAKE_GPU_FLAGS="-DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS"
    GPU_LABEL="CPU + OpenBLAS"
    ok "GPU: none detected — using ${GPU_LABEL}"
  fi
}

# ---------------------------------------------------------------------------
# build_whisper_cpp
# ---------------------------------------------------------------------------
build_whisper_cpp() {
  # Skip if binary already exists and --update was not requested
  if [[ -x "${WHISPER_BIN}" ]] && [[ "${UPDATE}" -eq 0 ]]; then
    ok "whisper-cli already built — skipping (pass --update to rebuild)"
    return 0
  fi

  # Clone if source directory is absent
  if [[ ! -d "${WHISPER_SRC_DIR}/.git" ]]; then
    step "Cloning whisper.cpp..."
    mkdir -p "$(dirname "${WHISPER_SRC_DIR}")"
    git clone --depth=1 "${WHISPER_REPO}" "${WHISPER_SRC_DIR}"
  fi

  # Pull latest if --update requested
  if [[ "${UPDATE}" -eq 1 ]]; then
    step "Updating whisper.cpp..."
    git -C "${WHISPER_SRC_DIR}" pull --ff-only
  fi

  # Configure
  step "Configuring whisper.cpp (${GPU_LABEL})..."
  # shellcheck disable=SC2086
  cmake -B "${WHISPER_BUILD_DIR}" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        ${CMAKE_GPU_FLAGS} \
        -S "${WHISPER_SRC_DIR}"

  # Build only the whisper-cli target to avoid building tests and extras
  step "Building whisper-cli (this takes a few minutes)..."
  cmake --build "${WHISPER_BUILD_DIR}" \
        --target whisper-cli \
        -j "$(nproc)"

  if [[ ! -x "${WHISPER_BIN}" ]]; then
    die "Build succeeded but whisper-cli binary not found at ${WHISPER_BIN}"
  fi

  ok "whisper-cli built at ${WHISPER_BIN}"
}

# ---------------------------------------------------------------------------
# install_symlinks
# ---------------------------------------------------------------------------
install_symlinks() {
  step "Installing symlinks to ~/.local/bin..."

  mkdir -p "${LOCAL_BIN}"

  # whisper-cli
  _install_symlink "${WHISPER_BIN}" "${LOCAL_BIN}/whisper-cli" "whisper-cli"

  # voice wrapper
  _install_symlink "${VOICE_WRAPPER}" "${LOCAL_BIN}/voice" "voice"

  ok "Symlinks installed"
}

_install_symlink() {
  local target="$1"
  local link="$2"
  local label="$3"

  # Refuse to overwrite a regular file
  if [[ -e "${link}" && ! -L "${link}" ]]; then
    warn "${link} exists as a regular file — not overwriting. Remove it manually if you want the symlink."
    return 0
  fi

  # Already correct
  if [[ -L "${link}" ]] && [[ "$(readlink "${link}")" == "${target}" ]]; then
    ok "${label}: symlink already up to date"
    return 0
  fi

  ln -sf "${target}" "${link}"
  ok "${label}: ${link} -> ${target}"
}

# ---------------------------------------------------------------------------
# ensure_path
# ---------------------------------------------------------------------------
ensure_path() {
  if [[ ":${PATH}:" == *":${LOCAL_BIN}:"* ]]; then
    ok "~/.local/bin already in PATH"
    return 0
  fi

  step "Adding ~/.local/bin to PATH..."

  local path_line='export PATH="$HOME/.local/bin:$PATH"'
  local added=0

  for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
    if [[ -f "${rc}" ]]; then
      if ! grep -qF '.local/bin' "${rc}"; then
        printf '\n# Added by voice install\n%s\n' "${path_line}" >> "${rc}"
        ok "Added to ${rc}"
        added=1
      else
        ok "${rc} already references .local/bin"
      fi
    fi
  done

  if [[ "${added}" -eq 1 ]]; then
    warn "PATH updated in shell config but not active in this session."
    warn "To activate now:  export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
}

# ---------------------------------------------------------------------------
# run_doctor — fall back if PATH not yet active
# ---------------------------------------------------------------------------
run_doctor() {
  step "Running voice doctor..."

  if command -v voice &>/dev/null; then
    voice doctor
  elif [[ -x "${LOCAL_BIN}/voice" ]]; then
    "${LOCAL_BIN}/voice" doctor
  else
    python3 "${REPO_ROOT}/tools/voice-cli/voice.py" doctor
  fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  echo ""
  step "Voice Linux setup"
  echo ""

  check_prerequisites
  install_system_packages
  detect_gpu
  build_whisper_cpp
  install_symlinks
  ensure_path
  run_doctor

  echo ""
  ok "Setup complete."
  echo ""
  echo "  Launch the TUI:   voice"
  echo "  Download a model: press M inside the TUI"
  echo "  Start recording:  press R"
  echo ""
}

main
