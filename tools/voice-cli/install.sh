#!/usr/bin/env bash
# install.sh — single-command Linux setup for Voice
#
# Usage:
#   bash tools/voice-cli/install.sh                       # first install
#   bash tools/voice-cli/install.sh --update              # pull latest whisper.cpp + rebuild
#   bash tools/voice-cli/install.sh --gpu cpu            # force CPU + OpenBLAS
#   bash tools/voice-cli/install.sh --gpu vulkan         # force Vulkan
#   bash tools/voice-cli/install.sh --gpu cuda           # force CUDA
#   bash tools/voice-cli/install.sh --help

set -euo pipefail

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
WHISPER_BUILD_FLAGS_FILE="${WHISPER_BUILD_DIR}/.voice-cmake-flags"
WHISPER_CMAKE_CACHE_FILE="${WHISPER_BUILD_DIR}/CMakeCache.txt"
LOCAL_BIN="${HOME}/.local/bin"
VOICE_WRAPPER="${REPO_ROOT}/tools/voice-cli/voice"
WHISPER_REPO="https://github.com/ggerganov/whisper.cpp.git"

PACKAGE_MANAGER=""
DISTRO_LABEL=""

APT_CORE_PACKAGES=(
  git build-essential cmake ninja-build pkg-config ccache curl wget
  ffmpeg sox wl-clipboard xclip xdotool python3 python3-gi
  libopenblas-dev pciutils
)
APT_OPTIONAL_PACKAGES=(
  wtype
  vulkan-tools
  libvulkan-dev
  glslc
)

DNF_CORE_PACKAGES=(
  git gcc gcc-c++ make cmake ninja-build pkgconf-pkg-config ccache curl wget
  ffmpeg-free sox wl-clipboard xclip xdotool python3 python3-gobject
  openblas-devel pipewire-utils alsa-utils pciutils
)
DNF_OPTIONAL_PACKAGES=(
  wtype
  vulkan-tools
  vulkan-loader-devel
  shaderc
  glslc
)

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
UPDATE=0
GPU_MODE="auto"
UNINSTALL=0
UNINSTALL_KEEP_MODELS=0
UNINSTALL_YES=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --update)
      UPDATE=1
      shift
      ;;
    --uninstall)
      UNINSTALL=1
      shift
      ;;
    --keep-models)
      UNINSTALL_KEEP_MODELS=1
      shift
      ;;
    --yes|-y)
      UNINSTALL_YES=1
      shift
      ;;
    --gpu)
      if [[ "$#" -lt 2 ]]; then
        echo "Missing value for --gpu. Expected one of: auto, cpu, vulkan, cuda" >&2
        exit 1
      fi
      GPU_MODE="${2,,}"
      shift 2
      ;;
    --gpu=*)
      GPU_MODE="${1#--gpu=}"
      GPU_MODE="${GPU_MODE,,}"
      shift
      ;;
    --help|-h)
      echo "Usage: bash tools/voice-cli/install.sh [--update] [--gpu auto|cpu|vulkan|cuda]"
      echo "       bash tools/voice-cli/install.sh --uninstall [--keep-models] [--yes]"
      echo ""
      echo "  (no flags)     Install system packages, build whisper.cpp, wire voice command."
      echo "                 Skips whisper.cpp build if the binary already exists."
      echo "  --update       Pull the latest whisper.cpp and rebuild before installing."
      echo "  --gpu MODE     Select backend: auto, cpu, vulkan, or cuda."
      echo "                 auto inspects hardware, installs Vulkan packages when useful,"
      echo "                 and falls back to CPU if no validated accelerator is usable."
      echo "  --uninstall    Remove Voice config, data, whisper.cpp build, and symlinks."
      echo "  --keep-models  (with --uninstall) Preserve downloaded model files."
      echo "  --yes, -y      (with --uninstall) Skip confirmation prompt."
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Run with --help for usage." >&2
      exit 1
      ;;
  esac
done

case "${GPU_MODE}" in
  auto|cpu|vulkan|cuda) ;;
  *)
    echo "Unknown GPU mode: ${GPU_MODE}" >&2
    echo "Expected one of: auto, cpu, vulkan, cuda" >&2
    exit 1
    ;;
esac

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
    DISTRO_LABEL="dnf-based distro"
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
# install system packages
# ---------------------------------------------------------------------------
install_optional_apt_packages() {
  local package=""
  local available=()
  for package in "$@"; do
    if apt-cache show "${package}" >/dev/null 2>&1; then
      available+=("${package}")
    else
      warn "Optional package unavailable on this apt repo set: ${package}"
    fi
  done

  if [[ "${#available[@]}" -gt 0 ]]; then
    sudo apt-get install -y --no-upgrade "${available[@]}"
  fi
}

install_apt_packages() {
  step "Installing system packages..."

  local packages=("${APT_CORE_PACKAGES[@]}")

  # Audio: if PipeWire/PulseAudio is already running keep it; otherwise add ALSA
  if pactl info &>/dev/null 2>&1; then
    ok "Audio server already running — skipping audio package installation"
  else
    packages+=(alsa-utils)
  fi

  sudo apt-get update
  sudo apt-get install -y --no-upgrade "${packages[@]}"

  step "Installing optional packages when available..."
  install_optional_apt_packages "${APT_OPTIONAL_PACKAGES[@]}"

  ok "System packages installed"
}

install_dnf_packages() {
  step "Installing system packages..."

  sudo dnf makecache -y -q
  sudo dnf install -y -q "${DNF_CORE_PACKAGES[@]}"

  step "Installing optional packages when available..."
  sudo dnf install -y -q --skip-unavailable "${DNF_OPTIONAL_PACKAGES[@]}" || true

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
# select_gpu_backend — sets CMAKE_GPU_FLAGS and GPU_LABEL
# ---------------------------------------------------------------------------
CMAKE_GPU_FLAGS=""
GPU_LABEL=""
GPU_KIND="unknown"
GPU_SUMMARY="unknown"

set_cpu_backend() {
  CMAKE_GPU_FLAGS="-DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS"
  GPU_LABEL="CPU + OpenBLAS"
}

set_vulkan_backend() {
  CMAKE_GPU_FLAGS="-DGGML_VULKAN=1"
  GPU_LABEL="Vulkan"
}

set_cuda_backend() {
  CMAKE_GPU_FLAGS="-DGGML_CUDA=ON"
  GPU_LABEL="NVIDIA CUDA"
}

vulkan_build_ready() {
  command -v glslc &>/dev/null && pkg-config --exists vulkan
}

cuda_build_ready() {
  command -v nvcc &>/dev/null
}

vulkan_runtime_ready() {
  command -v vulkaninfo &>/dev/null && vulkaninfo &>/dev/null 2>&1
}

detect_graphics_hardware() {
  local summary="unknown"
  local kind="unknown"
  local inventory=""

  if command -v lspci &>/dev/null; then
    inventory="$(lspci -nn | grep -Ei 'vga|3d|display' || true)"
  fi

  if [[ -n "${inventory}" ]]; then
    summary="$(printf '%s' "${inventory}" | paste -sd '; ' -)"
    local inventory_lc
    inventory_lc="$(printf '%s' "${inventory}" | tr '[:upper:]' '[:lower:]')"

    if [[ "${inventory_lc}" == *nvidia* ]]; then
      kind="nvidia"
    elif [[ "${inventory_lc}" == *amd* ]] || [[ "${inventory_lc}" == *advanced\ micro\ devices* ]] || [[ "${inventory_lc}" == *radeon* ]]; then
      kind="amd"
    elif [[ "${inventory_lc}" == *intel* ]]; then
      if [[ "${inventory_lc}" == *arc* ]] || [[ "${inventory_lc}" == *dg2* ]] || [[ "${inventory_lc}" == *bmg* ]]; then
        kind="intel-arc"
      else
        kind="intel-integrated"
      fi
    fi
  elif command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
    summary="NVIDIA GPU detected via nvidia-smi"
    kind="nvidia"
  fi

  GPU_KIND="${kind}"
  GPU_SUMMARY="${summary}"
}

ensure_vulkan_packages() {
  case "${PACKAGE_MANAGER}" in
    apt)
      local packages=(libvulkan-dev vulkan-tools glslc)
      if [[ "${GPU_KIND}" == "amd" ]] || [[ "${GPU_KIND}" == "intel-arc" ]] || [[ "${GPU_KIND}" == "intel-integrated" ]]; then
        packages+=(mesa-vulkan-drivers)
      fi
      install_optional_apt_packages "${packages[@]}"
      ;;
    dnf)
      sudo dnf install -y -q --skip-unavailable vulkan-tools vulkan-loader-devel shaderc glslc || true
      ;;
    *)
      die "Unsupported package manager: ${PACKAGE_MANAGER}"
      ;;
  esac
}

try_enable_vulkan_backend() {
  ensure_vulkan_packages

  if ! vulkan_runtime_ready; then
    return 1
  fi
  if ! vulkan_build_ready; then
    return 1
  fi

  set_vulkan_backend
  return 0
}

select_gpu_backend() {
  detect_graphics_hardware

  if [[ "${GPU_MODE}" == "auto" ]]; then
    step "Detecting GPU..."
    ok "Graphics: ${GPU_SUMMARY}"

    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1 && cuda_build_ready; then
      set_cuda_backend
      ok "GPU: ${GPU_LABEL}"
    elif [[ "${GPU_KIND}" == "amd" ]] || [[ "${GPU_KIND}" == "intel-arc" ]]; then
      if try_enable_vulkan_backend; then
        ok "GPU: ${GPU_LABEL}"
      else
        set_cpu_backend
        warn "Vulkan was preferred for ${GPU_SUMMARY}, but the runtime or build dependencies are not usable."
        ok "Falling back to ${GPU_LABEL}"
      fi
    elif [[ "${GPU_KIND}" == "nvidia" ]]; then
      if try_enable_vulkan_backend; then
        warn "NVIDIA GPU detected without a usable CUDA toolkit; using Vulkan instead."
        ok "GPU: ${GPU_LABEL}"
      else
        set_cpu_backend
        warn "NVIDIA GPU detected, but CUDA is not build-ready and Vulkan is not usable."
        warn "Install the CUDA toolkit for the fastest NVIDIA path, or force --gpu vulkan if your driver stack supports it."
        ok "Falling back to ${GPU_LABEL}"
      fi
    elif [[ "${GPU_KIND}" == "intel-integrated" ]]; then
      set_cpu_backend
      warn "Intel integrated graphics detected; auto mode prefers ${GPU_LABEL} for stability."
      warn "If you want to experiment with GPU inference, rerun with --gpu vulkan."
      ok "GPU: ${GPU_LABEL}"
    else
      set_cpu_backend
      ok "GPU: no supported accelerator detected — using ${GPU_LABEL}"
    fi

    return 0
  fi

  step "Using requested GPU mode: ${GPU_MODE}"

  case "${GPU_MODE}" in
    cpu)
      set_cpu_backend
      ok "GPU: forced ${GPU_LABEL}"
      ;;
    vulkan)
      ensure_vulkan_packages
      if ! vulkan_runtime_ready; then
        die "Requested --gpu vulkan, but the Vulkan runtime is unavailable or failed validation."
      fi
      if ! vulkan_build_ready; then
        die "Requested --gpu vulkan, but Vulkan build dependencies are missing after installation."
      fi
      set_vulkan_backend
      ok "GPU: forced ${GPU_LABEL}"
      ;;
    cuda)
      if ! cuda_build_ready; then
        die "Requested --gpu cuda, but nvcc was not found. Install the CUDA toolkit first."
      fi
      set_cuda_backend
      ok "GPU: forced ${GPU_LABEL}"
      if ! command -v nvidia-smi &>/dev/null || ! nvidia-smi &>/dev/null 2>&1; then
        warn "nvidia-smi is unavailable or failed; the NVIDIA runtime was not validated."
      fi
      ;;
  esac
}

configure_whisper_cpp() {
  local gpu_flags="$1"
  local gpu_label="$2"

  rm -rf "${WHISPER_BUILD_DIR}"

  step "Configuring whisper.cpp (${gpu_label})..."
  # shellcheck disable=SC2086
  if ! cmake -B "${WHISPER_BUILD_DIR}" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        ${gpu_flags} \
        -S "${WHISPER_SRC_DIR}"; then
    return 1
  fi

  printf '%s' "${gpu_flags}" > "${WHISPER_BUILD_FLAGS_FILE}"
}

# ---------------------------------------------------------------------------
# build_whisper_cpp
# ---------------------------------------------------------------------------
build_whisper_cpp() {
  # Skip if binary already exists and --update was not requested
  if [[ -x "${WHISPER_BIN}" ]] && [[ "${UPDATE}" -eq 0 ]]; then
    local previous_flags=""

    if [[ -f "${WHISPER_BUILD_FLAGS_FILE}" ]]; then
      previous_flags="$(<"${WHISPER_BUILD_FLAGS_FILE}")"
      if [[ "${previous_flags}" != "${CMAKE_GPU_FLAGS}" ]]; then
        warn "Build backend changed since last install. Rebuilding whisper.cpp."
      else
        ok "whisper-cli already built — skipping (pass --update to rebuild)"
        return 0
      fi
    elif [[ -f "${WHISPER_CMAKE_CACHE_FILE}" ]] && [[ "${CMAKE_GPU_FLAGS}" != *"GGML_CUDA=ON"* ]]; then
      if grep -q "GGML_CUDA:.*=ON" "${WHISPER_CMAKE_CACHE_FILE}"; then
        warn "Found stale CUDA config in cached CMake state. Rebuilding whisper.cpp."
      else
        ok "whisper-cli already built — skipping (pass --update to rebuild)"
        return 0
      fi
    else
      ok "whisper-cli already built — skipping (pass --update to rebuild)"
      return 0
    fi
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

  if ! configure_whisper_cpp "${CMAKE_GPU_FLAGS}" "${GPU_LABEL}"; then
    if [[ "${GPU_MODE}" != "auto" ]] || [[ "${GPU_LABEL}" == "CPU + OpenBLAS" ]]; then
      die "whisper.cpp configuration failed for ${GPU_LABEL}."
    fi

    warn "whisper.cpp configuration failed with ${GPU_LABEL}; retrying with CPU + OpenBLAS."
    set_cpu_backend
    configure_whisper_cpp "${CMAKE_GPU_FLAGS}" "${GPU_LABEL}"
  fi

  # Build only the whisper-cli target to avoid building tests and extras
  step "Building whisper-cli (this takes a few minutes)..."
  cmake --build "${WHISPER_BUILD_DIR}" \
        --target whisper-cli \
        -j "$(nproc)"

  if [[ ! -x "${WHISPER_BIN}" ]]; then
    die "Build finished but whisper-cli binary was not found at ${WHISPER_BIN}"
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

  # If a regular file exists, replace it only if it looks like a Voice-managed
  # wrapper script (exec line points to a whisper.cpp or voice path). Stale
  # wrappers from old installs would otherwise silently shadow the new symlink.
  if [[ -e "${link}" && ! -L "${link}" ]]; then
    if grep -q "exec.*\(whisper\.cpp\|voice\)" "${link}" 2>/dev/null; then
      warn "${label}: replacing stale Voice-managed script at ${link}"
      rm "${link}"
    else
      warn "${link} exists as a regular file — not overwriting. Remove it manually if you want the symlink."
      return 0
    fi
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
# do_uninstall
# ---------------------------------------------------------------------------
do_uninstall() {
  local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/voice"
  local voice_data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/voice"
  local model_dir="${voice_data_dir}/models"
  local src_dir="${voice_data_dir}/src"

  local targets=()

  [[ -d "${config_dir}" ]] && targets+=("${config_dir}")

  if [[ "${UNINSTALL_KEEP_MODELS}" -eq 1 ]]; then
    [[ -d "${src_dir}" ]] && targets+=("${src_dir}")
  else
    [[ -d "${voice_data_dir}" ]] && targets+=("${voice_data_dir}")
  fi

  [[ -L "${LOCAL_BIN}/voice" ]] && targets+=("${LOCAL_BIN}/voice")
  [[ -L "${LOCAL_BIN}/whisper-cli" ]] && targets+=("${LOCAL_BIN}/whisper-cli")

  if [[ "${#targets[@]}" -eq 0 ]]; then
    ok "Nothing to remove."
    return 0
  fi

  step "Voice will remove:"
  for t in "${targets[@]}"; do
    echo "  ${t}"
  done
  if [[ "${UNINSTALL_KEEP_MODELS}" -eq 1 ]] && [[ -d "${model_dir}" ]]; then
    echo "  (keeping models at ${model_dir})"
  fi

  if [[ "${UNINSTALL_YES}" -eq 0 ]]; then
    printf "Proceed? [y/N] "
    read -r answer
    if [[ "${answer,,}" != "y" && "${answer,,}" != "yes" ]]; then
      warn "Uninstall cancelled."
      exit 0
    fi
  fi

  for t in "${targets[@]}"; do
    rm -rf "${t}"
    ok "Removed: ${t}"
  done

  ok "Uninstall complete."
  echo ""
  echo "  System packages installed by install.sh were not removed."
  echo "  To reinstall: bash tools/voice-cli/install.sh"
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
  if [[ "${UNINSTALL}" -eq 1 ]]; then
    echo ""
    step "Voice uninstall"
    echo ""
    do_uninstall
    echo ""
    exit 0
  fi

  echo ""
  step "Voice Linux setup"
  echo ""

  check_prerequisites
  install_system_packages
  select_gpu_backend
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
