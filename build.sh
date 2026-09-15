#!/bin/bash
# =====================================================================
# 💫 Build Script — HYBRID MODE (Portable: ServerHive, Codespace, Local, CI)
# 🔧 Created by Michikoextv2
# =====================================================================

# 🎨 Warna
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
MAGENTA='\033[1;35m'
RESET='\033[0m'
BOLD='\033[1m'

# =====================================================================
# 📂 Auto-detect paths (portable: ServerHive, Codespace, Local, CI)
# =====================================================================
# Kernel dir = direktori script
KERNEL_DIR="${KERNEL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
OUT_DIR="${OUT_DIR:-$KERNEL_DIR/out}"
ARCH="${ARCH:-arm64}"
BUILD_LOG="${BUILD_LOG:-$KERNEL_DIR/build.log}"
DATE=$(date +"%Y%m%d-%H%M%S")
CPU_CORES=$(nproc --all)

# =====================================================================
# 🔧 Auto-detect clang (absolute path: portable ServerHive, Codespace, Local, CI)
# =====================================================================
if [ -z "$CLANG_DIR" ] || [ ! -f "$CLANG_DIR/bin/clang" ]; then
    for cand in \
        "$(realpath "$KERNEL_DIR/../clang/NezukoClang" 2>/dev/null)" \
        "$(realpath "$KERNEL_DIR/../NezukoClang" 2>/dev/null)" \
        "$(realpath "$HOME/clang/NezukoClang" 2>/dev/null)" \
        "/opt/clang/NezukoClang" \
        "/usr/local/clang/NezukoClang" \
        "$(realpath "$(dirname "$(command -v clang 2>/dev/null)" 2>/dev/null | xargs dirname 2>/dev/null)" 2>/dev/null)"; do
        [ -f "$cand/bin/clang" ] && CLANG_DIR="$cand" && break
    done
fi

# Fallback: clang dari PATH (absolute)
if [ -z "$CLANG_DIR" ] || [ ! -f "$CLANG_DIR/bin/clang" ]; then
    CLANG_DIR="$(realpath "$(dirname "$(command -v clang 2>/dev/null)" 2>/dev/null | xargs dirname 2>/dev/null)" 2>/dev/null)"
fi

# Validasi
if [ ! -f "$CLANG_DIR/bin/clang" ]; then
    echo -e "${RED}❌ Clang tidak ditemukan! Set CLANG_DIR atau install clang.${RESET}"
    exit 1
fi

# =====================================================================
# 🌐 AnyKernel3 config
# =====================================================================
AK3_REPO="https://github.com/Michikoextv2/AnyKernel3-miatoll.git"
AK3_BRANCH="miatoll"
AK3_DIR="$KERNEL_DIR/AnyKernel3"

# =====================================================================
# 📂 Defconfig detection
# =====================================================================
CONFIG_VENDOR_PATH="$KERNEL_DIR/arch/arm64/configs/vendor/xiaomi"
if [ ! -d "$CONFIG_VENDOR_PATH" ]; then
    echo -e "${RED}❌ Folder vendor defconfig tidak ditemukan: $CONFIG_VENDOR_PATH${RESET}"
    exit 1
fi

mapfile -t DEFCONFIGS < <(ls "$CONFIG_VENDOR_PATH" | grep -E "defconfig$")
if [ ${#DEFCONFIGS[@]} -eq 0 ]; then
    echo -e "${RED}❌ Tidak ada defconfig ditemukan di $CONFIG_VENDOR_PATH${RESET}"
    exit 1
elif [ ${#DEFCONFIGS[@]} -eq 1 ]; then
    DEFCONFIG="${DEFCONFIGS[0]}"
    echo -e "${GREEN}✅ Ditemukan satu defconfig: ${DEFCONFIG}${RESET}"
else
    echo -e "${YELLOW}📋 Pilih defconfig yang ingin digunakan:${RESET}"
    select opt in "${DEFCONFIGS[@]}"; do
        if [ -n "$opt" ]; then
            DEFCONFIG="$opt"
            break
        else
            echo -e "${RED}❌ Pilihan tidak valid${RESET}"
        fi
    done
fi
echo -e "${GREEN}✅ Menggunakan defconfig: $DEFCONFIG${RESET}"

# =====================================================================
# 🗑️ Hapus AnyKernel3 Lama (jika ada)
# =====================================================================
if [ -d "$AK3_DIR" ]; then
    echo -e "\n${YELLOW}🗑️  Menghapus AnyKernel3 lama...${RESET}"
    rm -rf "$AK3_DIR"
fi

# =====================================================================
# 🧹 Bersihkan Build Lama (FAST mode: skip jika FAST=1)
# =====================================================================
if [ "${FAST:-0}" = "1" ] || [ "$1" = "--fast" ]; then
  echo -e "${CYAN}⚡ FAST mode: skip clean, pakai ccache + incremental${RESET}"
  mkdir -p "$OUT_DIR"
  export USE_CCACHE=1
  export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
  export CCACHE_EXEC="$(command -v ccache 2>/dev/null || echo ccache)"
  ccache -M 10G 2>/dev/null; ccache -z 2>/dev/null
else
  echo -e "${CYAN}🧹 Membersihkan build lama...${RESET}"
  make -C "$KERNEL_DIR" O="$OUT_DIR" clean &>/dev/null
  rm -rf "$OUT_DIR"
  mkdir -p "$OUT_DIR"
  rm -f "$BUILD_LOG"
fi

# Fast flags
if command -v ccache >/dev/null 2>&1; then export CC="ccache clang"; export USE_CCACHE=1; fi
export KBUILD_BUILD_TIMESTAMP="$(date)"

# =====================================================================
# ⚙️ Generate Defconfig (DULU)
# =====================================================================
echo -e "${YELLOW}⚙️  Menghasilkan defconfig (${DEFCONFIG})...${RESET}"
make -C "$KERNEL_DIR" O="$OUT_DIR" ARCH="$ARCH" "$DEFCONFIG" 2>&1 | tee -a "$BUILD_LOG"
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo -e "${RED}❌ Gagal generate defconfig. Pastikan file '${DEFCONFIG}' ada.${RESET}"
    exit 1
fi

# =====================================================================
# 🧭 Menuconfig Opsional (SETELAH defconfig)
read -rp "$(echo -e "${MAGENTA}🧭 Ingin buka menuconfig sebelum build? (y/n): ${RESET}")" menu
run_menuconfig() {
    export TERM=xterm-256color
    export LINES=40
    export COLUMNS=120
    # Jalankan menuconfig di foreground, tunggu selesai
    make -C "$KERNEL_DIR" O="$OUT_DIR" ARCH="$ARCH" menuconfig
}
[[ "$menu" =~ ^[Yy]$ ]] && run_menuconfig
# =====================================================================

