#!/bin/bash
# =====================================================================
# 💫 Build Script — PORTABLE HYBRID MODE
# 🔧 Created by Michikoextv2
# Works on: ServerHive, Codespace, Local, CI, Docker
# =====================================================================

# 🎨 Warna
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; CYAN='\033[1;36m'; MAGENTA='\033[1;35m'
RESET='\033[0m'; BOLD='\033[1m'

# =====================================================================
# 📂 AUTO-DETECT PATHS (Portable: ServerHive, Codespace, Local, CI, Docker)
# =====================================================================
# Kernel dir = direktori script (bukan pwd)
KERNEL_DIR="${KERNEL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
OUT_DIR="${OUT_DIR:-$KERNEL_DIR/out}"
ARCH="${ARCH:-arm64}"
BUILD_LOG="${BUILD_LOG:-$KERNEL_DIR/build.log}"
DATE=$(date +"%Y%m%d-%H%M%S")
CPU_CORES=$(nproc --all)

# =====================================================================
# 🔧 AUTO-DETECT CLANG (Portable: ServerHive, Codespace, Local, CI, Docker)
# =====================================================================
# Prioritas: ENV > kernel/../clang > kernel/../NezukoClang > $HOME/clang > /opt/clang > /usr/local/clang > PATH
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

# Fallback: clang dari PATH (absolute path)
if [ -z "$CLANG_DIR" ] || [ ! -f "$CLANG_DIR/bin/clang" ]; then
    CLANG_DIR="$(realpath "$(dirname "$(command -v clang 2>/dev/null)" 2>/dev/null | xargs dirname 2>/dev/null)" 2>/dev/null)"
fi

# Validasi clang
if [ ! -f "$CLANG_DIR/bin/clang" ]; then
    echo -e "${RED}❌ Clang tidak ditemukan! Set CLANG_DIR atau install clang.${RESET}"
    exit 1
fi

# =====================================================================
# 🧠 Toolchain Info
# =====================================================================
CLANG_VERSION=$("$CLANG_DIR/bin/clang" --version | head -n 1)
HOST_OS=$(uname -o)
HOST_KERNEL=$(uname -r)
HOST_CPU=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')

clear
echo -e "${MAGENTA}${BOLD}=============================================================="
echo -e " 💫 Build Script — PORTABLE HYBRID MODE"
echo -e "==============================================================${RESET}"
echo -e "${CYAN}👤 Dibuat oleh:${RESET} ${GREEN}Michikoextv2${RESET}"
echo -e "${YELLOW}🧰 Toolchain:${RESET} ${GREEN}${CLANG_VERSION}${RESET}"
echo -e "${YELLOW}🧠 CPU:${RESET} ${GREEN}${HOST_CPU}${RESET}"
echo -e "${YELLOW}💻 Host:${RESET} ${GREEN}${HOST_OS} (${HOST_KERNEL})${RESET}"
echo -e "${MAGENTA}==============================================================${RESET}
"

# =====================================================================
# 🔧 AUTO-DETECT GCC32 (Portable)
# =====================================================================
if [ -z "$GCC32_DIR" ] || [ ! -d "$GCC32_DIR/bin" ]; then
    for cand in \
        "$(realpath "$KERNEL_DIR/../clang/NezukoClang/arm-linux-androideabi-4.9" 2>/dev/null)" \
        "$(realpath "$KERNEL_DIR/../arm-linux-androideabi-4.9" 2>/dev/null)" \
        "$(realpath "$HOME/clang/NezukoClang/arm-linux-androideabi-4.9" 2>/dev/null)" \
        "$(find /home -maxdepth 3 -name "arm-linux-androideabi-4.9" -type d 2>/dev/null | head -1)" \
        "$(realpath "$(dirname "$(command -v arm-linux-androideabi-gcc 2>/dev/null)" 2>/dev/null | xargs dirname 2>/dev/null)" 2>/dev/null)"; do
        [ -d "$cand/bin" ] && [ -x "$cand/bin/arm-linux-androideabi-gcc" ] && GCC32_DIR="$cand" && break
    done
fi

# Validasi GCC32
if [ ! -d "$GCC32_DIR/bin" ] || [ ! -x "$GCC32_DIR/bin/arm-linux-androideabi-gcc" ]; then
    echo -e "${YELLOW}⚠️  GCC32 tidak ditemukan! CONFIG_COMPAT_VDSO akan dimatikan.${RESET}"
    GCC32_DIR=""
fi

# =====================================================================
# 🎨 Warna
# =====================================================================
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; CYAN='\033[1;36m'; MAGENTA='\033[1;35m'
RESET='\033[0m'; BOLD='\033[1m'

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
            echo -e "${GREEN}✅ Menggunakan defconfig: $DEFCONFIG${RESET}"
            break
        else
            echo -e "${RED}❌ Pilihan tidak valid${RESET}"
        fi
    done
fi
echo -e "${GREEN}✅ Menggunakan defconfig: $DEFCONFIG${RESET}"

# =====================================================================
# 🧭 Menuconfig Opsional (SETELAH defconfig)
# =====================================================================
read -rp "$(echo -e "${MAGENTA}🧭 Ingin buka menuconfig sebelum build? (y/n): ${RESET}")" menu

run_menuconfig() {
    export TERM=xterm-256color
    export LINES=40
    export COLUMNS=120
    script -q -c "stty rows 40 cols 120; make -C \"$KERNEL_DIR\" O=\"$OUT_DIR\" ARCH=\"$ARCH\" menuconfig" /dev/null
}
[[ "$menu" =~ ^[Yy]$ ]] && run_menuconfig

# =====================================================================
# 🔥 Pilih Level Optimasi Polly
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
  sed -i 's/CONFIG_LOCALVERSION="\(.*\)"/CONFIG_LOCALVERSION="\1${POLLY_TAG}"/' "$OUT_DIR/.config" 2>/dev/null
  echo -e "${CYAN}🏷️  LOCALVERSION tag: ${POLLY_TAG}${RESET}"
fi

# =====================================================================
# ⏱️ Mulai Build
# =====================================================================
BUILD_START=$(date +%s)
# Set build identity
export KBUILD_BUILD_HOST=Kimochh
export KBUILD_BUILD_USER=Nezuko

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

# Buat flashable ZIP
ZIP_NAME="Millenia-Kernel-${DATE}.zip"
cd "$AK3_DIR" || exit 1
zip -r9 "$KERNEL_DIR/$ZIP_NAME" . -x "*.git*" 2>&1 | tee -a "$BUILD_LOG"
cd "$KERNEL_DIR" || exit 1

echo -e "\n${CYAN}==============================================================${RESET}"
echo -e "${GREEN}💾 Flashable ZIP : ${BLUE}${KERNEL_DIR}/${ZIP_NAME}${RESET}"
echo -e "${CYAN}==============================================================${RESET}"
echo -e "${MAGENTA}${BOLD}🎉 Congratulations by Michikoextv2 — Build Selesai!${RESET}\n"
