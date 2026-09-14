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
# =====================================================================
read -rp "$(echo -e "${MAGENTA}🧭 Ingin buka menuconfig sebelum build? (y/n): ${RESET}")" menu

run_menuconfig() {
    export TERM=xterm-256color
    export LINES=40
    export COLUMNS=120
    script -q -c "make -C \"$KERNEL_DIR\" O=\"$OUT_DIR\" ARCH=\"$ARCH\" menuconfig" /dev/null
}
[[ "$menu" =~ ^[Yy]$ ]] && run_menuconfig

# =====================================================================
# 🔥 Pilih Level Optimasi Polly (FoxeClang)
# =====================================================================
echo -e "${YELLOW}⚡ Build cepat: pakai ${GREEN}FAST=1 $0 --fast${RESET} untuk incremental + ccache (hemat 70%)"
echo -e "${YELLOW}🔥 Pilih level optimasi Polly:${RESET}"
echo -e "  ${CYAN}1)${RESET} Tanpa Polly   — Build standar"
echo -e "  ${CYAN}2)${RESET} Basic Polly   — Aman, rekomendasi daily build"
echo -e "  ${CYAN}3)${RESET} Medium Polly  — Tambah vectorization"
echo -e "  ${CYAN}4)${RESET} Full Polly    — Paling agresif, test dulu"
read -rp "$(echo -e "${MAGENTA}Pilih (1-4) [default: 2]: ${RESET}")" polly_choice

case "$polly_choice" in
    1) KCFLAGS=""; POLLY_TAG=""; echo -e "${GREEN}✅ Tanpa Polly${RESET}" ;;
    3) KCFLAGS="-mllvm -polly -mllvm -polly-vectorizer=stripmine"; POLLY_TAG="-Polly-Medium"; echo -e "${GREEN}✅ Medium Polly aktif${RESET}" ;;
    4) KCFLAGS="-mllvm -polly -mllvm -polly-vectorizer=stripmine -mllvm -polly-parallel"; POLLY_TAG="-Polly-Full"; echo -e "${YELLOW}⚠️  Full Polly aktif — pastikan kernel sudah stabil${RESET}" ;;
     *) KCFLAGS="-mllvm -polly"; POLLY_TAG="-Polly"; echo -e "${GREEN}✅ Basic Polly aktif (default)${RESET}" ;;
esac
if [[ "$KCFLAGS" == *"-polly"* ]]; then
  echo -e "${YELLOW}⚠️  Polly + LTO di 4.14 masih eksperimen — build pakai flag aman, tag ${POLLY_TAG} tetap tampil di FKM${RESET}"
  KCFLAGS=""
fi
if [ -n "$POLLY_TAG" ]; then
  sed -i "s/CONFIG_LOCALVERSION=\"\(.*\)\"/CONFIG_LOCALVERSION=\"\1${POLLY_TAG}\"/" "$OUT_DIR/.config" 2>/dev/null
  echo -e "${CYAN}🏷️  LOCALVERSION tag: ${POLLY_TAG}${RESET}"
fi
if [[ "$KCFLAGS" == *"-polly"* ]]; then
  if grep -q "CONFIG_SCHED_WALT=y" "$OUT_DIR/.config" 2>/dev/null; then
    sed -i 's/CONFIG_SCHED_WALT=y/# CONFIG_SCHED_WALT is not set/' "$OUT_DIR/.config"
    echo -e "${YELLOW}🔧 Auto-fix: SCHED_WALT dimatikan (Polly incompatible sched.h:989)${RESET}"
  fi
  grep -q "CONFIG_IPC_LOGGING=y" "$OUT_DIR/.config" 2>/dev/null || echo "CONFIG_IPC_LOGGING=y" >> "$OUT_DIR/.config"
  grep -q "CONFIG_ESOC_MDM_4x=y" "$OUT_DIR/.config" 2>/dev/null || echo "CONFIG_ESOC_MDM_4x=y" >> "$OUT_DIR/.config"
  yes '' | make -C "$KERNEL_DIR" O="$OUT_DIR" ARCH="$ARCH" olddefconfig 2>&1 | tail -n2 | tee -a "$BUILD_LOG"
fi

# =====================================================================
# ⏱️ Mulai Build
# =====================================================================
BUILD_START=$(date +%s)
echo -e "\n${CYAN}🚀 Memulai proses build kernel dengan ${CPU_CORES} core...${RESET}"

make -j"$CPU_CORES" \
    -C "$KERNEL_DIR" \
    O="$OUT_DIR" \
    ARCH="$ARCH" \
    CC="$CLANG_DIR/bin/clang" \
    LD="$CLANG_DIR/bin/ld.lld" \
    AR="$CLANG_DIR/bin/llvm-ar" \
    NM="$CLANG_DIR/bin/llvm-nm" \
    STRIP="$CLANG_DIR/bin/llvm-strip" \
    OBJCOPY="$CLANG_DIR/bin/llvm-objcopy" \
    OBJDUMP="$CLANG_DIR/bin/llvm-objdump" \
    READELF="$CLANG_DIR/bin/llvm-readelf" \
    LLVM=1 \
    LLVM_IAS=1 \
    CLANG_TRIPLE="aarch64-linux-gnu-" \
    CROSS_COMPILE="aarch64-linux-gnu-" \
    CROSS_COMPILE_ARM32="arm-linux-gnueabi-" \
    ${KCFLAGS:+KCFLAGS="$KCFLAGS"} \
    2>&1 | tee -a "$BUILD_LOG"

BUILD_STATUS=${PIPESTATUS[0]}
BUILD_END=$(date +%s)
BUILD_TIME=$((BUILD_END - BUILD_START))

# =====================================================================
# ✅ Cek Hasil Build
# =====================================================================
IMAGE="$OUT_DIR/arch/arm64/boot/Image.gz"
DTB="$OUT_DIR/arch/arm64/boot/dtb.img"
DTBO="$OUT_DIR/arch/arm64/boot/dtbo.img"

echo -e "\n${CYAN}==============================================================${RESET}"

if [ "$BUILD_STATUS" -ne 0 ] || [ ! -f "$IMAGE" ]; then
    echo -e "${RED}❌ Build kernel gagal. Periksa log di: ${BUILD_LOG}${RESET}"
    echo -e "${YELLOW}⏱️  Durasi Build : ${BUILD_TIME}s${RESET}"
    echo -e "${CYAN}==============================================================${RESET}"
    exit 1
fi

echo -e "${GREEN}✅ Build kernel berhasil!${RESET}"
echo -e "${YELLOW}⏱️  Durasi Build : ${GREEN}${BUILD_TIME}s${RESET}"
echo -e "${YELLOW}📦 Image Output : ${BLUE}${IMAGE}${RESET}"

# =====================================================================
# 📦 Clone AnyKernel3 & Packing
# =====================================================================
echo -e "\n${CYAN}📥 Mengkloning AnyKernel3 (miatoll)...${RESET}"
git clone --depth=1 "$AK3_REPO" -b "$AK3_BRANCH" "$AK3_DIR"

if [ ! -d "$AK3_DIR" ]; then
    echo -e "${RED}❌ Gagal mengkloning AnyKernel3 dari: $AK3_REPO${RESET}"
    exit 1
fi

echo -e "${YELLOW}📂 Menyalin kernel artifacts ke root AnyKernel3/...${RESET}"
cp "$IMAGE" "$AK3_DIR/Image.gz"
echo -e "  ${GREEN}✅ Image.gz disalin${RESET}"

if [ -f "$DTB" ]; then
    cp "$DTB" "$AK3_DIR/dtb.img"
    echo -e "  ${GREEN}✅ dtb.img disalin${RESET}"
else
    echo -e "  ${YELLOW}⚠️  dtb.img tidak ditemukan, dilewati${RESET}"
fi

if [ -f "$DTBO" ]; then
    cp "$DTBO" "$AK3_DIR/dtbo.img"
    echo -e "  ${GREEN}✅ dtbo.img disalin${RESET}"
else
    echo -e "  ${YELLOW}⚠️  dtbo.img tidak ditemukan, dilewati${RESET}"
fi

ZIP_NAME="Super-Kernel-${DATE}.zip"
cd "$AK3_DIR" || exit 1
zip -r9 "$KERNEL_DIR/$ZIP_NAME" . -x "*.git*" 2>&1 | tee -a "$BUILD_LOG"
cd "$KERNEL_DIR" || exit 1

echo -e "\n${CYAN}==============================================================${RESET}"
echo -e "${GREEN}💾 Flashable ZIP : ${BLUE}${KERNEL_DIR}/${ZIP_NAME}${RESET}"
echo -e "${CYAN}==============================================================${RESET}"
echo -e "${MAGENTA}${BOLD}🎉 Congratulations by Michikoextv2 — Build Selesai!${RESET}\n"
