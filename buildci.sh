#!/bin/bash
# =====================================================================
# 💫 Build Script — HYBRID MODE (CI/GitHub Actions)
# 🔧 Created by Michikoextv2
# =====================================================================

# ──────────────────────────────────────────
# 🎨 Warna (dinonaktifkan di CI jika perlu)
# ──────────────────────────────────────────
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; CYAN='\033[1;36m'; MAGENTA='\033[1;35m'
RESET='\033[0m'; BOLD='\033[1m'

# ──────────────────────────────────────────
# 📂 Variabel utama — path disesuaikan CI
# ──────────────────────────────────────────
KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${KERNEL_DIR}/out"
WORKSPACE="${KERNEL_DIR}/.."
CLANG_DIR="${CLANG_DIR:-${WORKSPACE}/clang}"
# Auto-detect: NezukoClang may live inside clang/ or next to the kernel dir
if [ ! -f "${CLANG_DIR}/bin/clang" ] && [ -f "${CLANG_DIR}/NezukoClang/bin/clang" ]; then
    CLANG_DIR="${CLANG_DIR}/NezukoClang"
fi
if [ ! -f "${CLANG_DIR}/bin/clang" ] && [ -f "${WORKSPACE}/NezukoClang/bin/clang" ]; then
    CLANG_DIR="${WORKSPACE}/NezukoClang"
fi
GCC64_DIR="${WORKSPACE}/aarch64-linux-android-4.9"
GCC32_DIR="${WORKSPACE}/arm-linux-androideabi-4.9"
ARCH="arm64"
DEFCONFIG="miatoll_defconfig"
BUILD_LOG="${KERNEL_DIR}/build.log"
DATE=$(TZ=Asia/Jakarta date +"%Y-%m-%d_%H-%M")

# ──────────────────────────────────────────
# 📥 Ambil variabel dari environment (set oleh workflow)
# ──────────────────────────────────────────
KERNEL_NAME="${KERNEL_NAME:-SuperPotato}"
ENABLE_LTO="${ENABLE_LTO:-false}"
ENABLE_CAMERA_BOOTCLOCK="${ENABLE_CAMERA_BOOTCLOCK:-false}"
CI_BUILD="${CI_BUILD:-false}"

# ──────────────────────────────────────────
# 🧠 Info sistem
# ──────────────────────────────────────────
CPU_CORES=$(nproc)
CLANG_VERSION=$("${CLANG_DIR}/bin/clang" --version 2>/dev/null | head -n 1 || echo "Clang tidak ditemukan")
HOST_OS=$(uname -o 2>/dev/null || uname -s)
HOST_KERNEL=$(uname -r)
HOST_CPU=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ //' || echo "N/A")

echo -e "${MAGENTA}${BOLD}=============================================================="
echo -e " 💫 MICHIKO Build Script — FINAL HYBRID MODE (CI)"
echo -e "==============================================================${RESET}"
echo -e "${CYAN}👤 Dibuat oleh   :${RESET} ${GREEN}Michikoextv2${RESET}"
echo -e "${CYAN}🏷️  Nama Kernel   :${RESET} ${GREEN}${KERNEL_NAME}${RESET}"
echo -e "${YELLOW}🧰 Toolchain     :${RESET} ${GREEN}${CLANG_VERSION}${RESET}"
echo -e "${YELLOW}🧠 CPU           :${RESET} ${GREEN}${HOST_CPU}${RESET}"
echo -e "${YELLOW}💻 Host          :${RESET} ${GREEN}${HOST_OS} (${HOST_KERNEL})${RESET}"
echo -e "${YELLOW}📋 Defconfig     :${RESET} ${GREEN}${DEFCONFIG}${RESET}"
echo -e "${YELLOW}⚡ LTO           :${RESET} ${GREEN}${ENABLE_LTO}${RESET}"
echo -e "${YELLOW}📷 Camera Clock  :${RESET} ${GREEN}${ENABLE_CAMERA_BOOTCLOCK}${RESET}"
echo -e "${YELLOW}🔢 CPU Cores     :${RESET} ${GREEN}${CPU_CORES}${RESET}"
echo -e "${YELLOW}📄 Build Log     :${RESET} ${GREEN}${BUILD_LOG}${RESET}"
echo -e "${MAGENTA}==============================================================${RESET}"
echo ""

# ──────────────────────────────────────────
# 🔍 Cek toolchain
# ──────────────────────────────────────────
if [ ! -f "${CLANG_DIR}/bin/clang" ]; then
    echo -e "${RED}❌ Clang tidak ditemukan di: ${CLANG_DIR}${RESET}"
    exit 1
fi
echo -e "${GREEN}✅ Clang ditemukan${RESET}"

if [ ! -f "${CLANG_DIR}/bin/ld.lld" ]; then
    echo -e "${YELLOW}⚠️  ld.lld tidak ditemukan, menggunakan system lld${RESET}"
    sudo apt install -y lld &>/dev/null
fi

if [ ! -d "${GCC32_DIR}/bin" ]; then
    echo -e "${YELLOW}⚠️  GCC32 tidak ditemukan! CROSS_COMPILE_ARM32 akan dikosongkan.${RESET}"
    GCC32_DIR=""
fi

if [ ! -d "${GCC64_DIR}/bin" ]; then
    echo -e "${YELLOW}⚠️  GCC64 tidak ditemukan!${RESET}"
    GCC64_DIR=""
fi

# ──────────────────────────────────────────
# 🌐 Set PATH
# ──────────────────────────────────────────
if [ -n "${GCC32_DIR}" ] && [ -n "${GCC64_DIR}" ]; then
    export PATH="${CLANG_DIR}/bin:${GCC64_DIR}/bin:${GCC32_DIR}/bin:${PATH}"
elif [ -n "${GCC64_DIR}" ]; then
    export PATH="${CLANG_DIR}/bin:${GCC64_DIR}/bin:${PATH}"
else
    export PATH="${CLANG_DIR}/bin:${PATH}"
fi

# ──────────────────────────────────────────
# 🔧 Environment variables
# ──────────────────────────────────────────
export USE_CCACHE=1
export KBUILD_BUILD_HOST="xyz"
export KBUILD_BUILD_USER="pokji18"

# ──────────────────────────────────────────
# 🧹 Bersihkan build lama
# ──────────────────────────────────────────
echo -e "${CYAN}🧹 Membersihkan build lama...${RESET}"
make -C "${KERNEL_DIR}" clean O="${OUT_DIR}" &>/dev/null || true
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"
rm -f "${BUILD_LOG}"

# ──────────────────────────────────────────
# ⚙️ Generate defconfig
# ──────────────────────────────────────────
echo -e "${YELLOW}⚙️  Menghasilkan defconfig (${DEFCONFIG})...${RESET}"
make -C "${KERNEL_DIR}" \
    O="${OUT_DIR}" \
    ARCH="${ARCH}" \
    "${DEFCONFIG}" 2>&1 | tee -a "${BUILD_LOG}"

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo -e "${RED}❌ Gagal generate defconfig. Pastikan file '${DEFCONFIG}' ada di arch/arm64/configs/.${RESET}"
    exit 1
fi
echo -e "${GREEN}✅ Defconfig berhasil digenerate${RESET}"

# ──────────────────────────────────────────
# 🔀 Terapkan opsi kconfig dari workflow input
# ──────────────────────────────────────────
DOTCONFIG="${OUT_DIR}/.config"

apply_config() {
    local key="$1"
    local val="$2"
    if grep -q "^${key}=" "${DOTCONFIG}" 2>/dev/null; then
        sed -i "s/^${key}=.*/${key}=${val}/" "${DOTCONFIG}"
    elif grep -q "^# ${key} is not set" "${DOTCONFIG}" 2>/dev/null; then
        sed -i "s/^# ${key} is not set/${key}=${val}/" "${DOTCONFIG}"
    else
        echo "${key}=${val}" >> "${DOTCONFIG}"
    fi
}

# CONFIG_LTO
if [ "${ENABLE_LTO}" = "true" ]; then
    echo -e "${CYAN}⚡ Mengaktifkan CONFIG_LTO...${RESET}"
    apply_config "CONFIG_LTO_NONE" "n"
    apply_config "CONFIG_LTO" "y"
    apply_config "CONFIG_LTO_CLANG" "y"
    apply_config "CONFIG_THINLTO" "y"
else
    echo -e "${YELLOW}⚡ CONFIG_LTO dinonaktifkan${RESET}"
    apply_config "CONFIG_LTO" "n"
    apply_config "CONFIG_LTO_CLANG" "n"
    apply_config "CONFIG_THINLTO" "n"
    apply_config "CONFIG_LTO_NONE" "y"
fi

# CONFIG_CAMERA_BOOTCLOCK_TIMESTAMP
if [ "${ENABLE_CAMERA_BOOTCLOCK}" = "true" ]; then
    echo -e "${CYAN}📷 Mengaktifkan CONFIG_CAMERA_BOOTCLOCK_TIMESTAMP...${RESET}"
    apply_config "CONFIG_CAMERA_BOOTCLOCK_TIMESTAMP" "y"
else
    echo -e "${YELLOW}📷 CONFIG_CAMERA_BOOTCLOCK_TIMESTAMP dinonaktifkan${RESET}"
    apply_config "CONFIG_CAMERA_BOOTCLOCK_TIMESTAMP" "n"
fi

# Sync kconfig agar tidak ada inkonsistensi
make -C "${KERNEL_DIR}" \
    O="${OUT_DIR}" \
    ARCH="${ARCH}" \
    olddefconfig 2>&1 | tee -a "${BUILD_LOG}"

echo -e "${GREEN}✅ Konfigurasi selesai diterapkan${RESET}"

# ──────────────────────────────────────────
# ⏱️ Timer mulai
# ──────────────────────────────────────────
BUILD_START=$(date +%s)

# ──────────────────────────────────────────
# 🚀 Build kernel
# ──────────────────────────────────────────
echo ""
echo -e "${CYAN}🚀 Memulai proses build kernel dengan ${CPU_CORES} core...${RESET}"
echo ""

# Tentukan CROSS_COMPILE_ARM32 hanya jika GCC32 tersedia
if [ -n "${GCC32_DIR}" ]; then
    CROSS_COMPILE_ARM32_FLAG="CROSS_COMPILE_ARM32=${GCC32_DIR}/bin/arm-linux-androideabi-"
else
    CROSS_COMPILE_ARM32_FLAG=""
fi

make -j"${CPU_CORES}" \
    -C "${KERNEL_DIR}" \
    O="${OUT_DIR}" \
    ARCH="${ARCH}" \
    CC=clang \
    LD=ld.lld \
    AR=llvm-ar \
    NM=llvm-nm \
    STRIP=llvm-strip \
    OBJCOPY=llvm-objcopy \
    OBJDUMP=llvm-objdump \
    READELF=llvm-readelf \
    LLVM=1 \
    LLVM_IAS=1 \
    CROSS_COMPILE="${CLANG_DIR}/bin/aarch64-linux-gnu-" \
    ${CROSS_COMPILE_ARM32_FLAG} \
    2>&1 | tee -a "${BUILD_LOG}"

BUILD_EXIT=${PIPESTATUS[0]}

# ──────────────────────────────────────────
# 🕒 Timer selesai
# ──────────────────────────────────────────
BUILD_END=$(date +%s)
BUILD_TIME=$((BUILD_END - BUILD_START))
BUILD_MIN=$((BUILD_TIME / 60))
BUILD_SEC=$((BUILD_TIME % 60))

# ──────────────────────────────────────────
# ✅ Cek dan simpan hasil build
# ──────────────────────────────────────────
IMAGE="${OUT_DIR}/arch/arm64/boot/Image.gz"
DTB="${OUT_DIR}/arch/arm64/boot/dtb.img"
DTBO="${OUT_DIR}/arch/arm64/boot/dtbo.img"

echo ""
echo -e "${CYAN}==============================================================${RESET}"

if [ -f "${IMAGE}" ] && [ "${BUILD_EXIT}" -eq 0 ]; then
    echo -e "${GREEN}✅ Build kernel berhasil!${RESET}"
    echo -e "${YELLOW}📦 Image.gz :${RESET} ${BLUE}${IMAGE}${RESET}"
    [ -f "${DTB}" ]  && echo -e "${YELLOW}📦 dtb.img  :${RESET} ${BLUE}${DTB}${RESET}"
    [ -f "${DTBO}" ] && echo -e "${YELLOW}📦 dtbo.img :${RESET} ${BLUE}${DTBO}${RESET}"
    echo -e "${YELLOW}⏱️  Durasi   :${RESET} ${GREEN}${BUILD_MIN}m ${BUILD_SEC}s${RESET}"
else
    echo -e "${RED}❌ Build kernel gagal (exit code: ${BUILD_EXIT}). Periksa ${BUILD_LOG}.${RESET}"
    echo -e "${YELLOW}⏱️  Durasi   :${RESET} ${GREEN}${BUILD_MIN}m ${BUILD_SEC}s${RESET}"
    exit 1
fi

echo -e "${CYAN}==============================================================${RESET}"
echo -e "${MAGENTA}${BOLD}🎉 Congratulations by Michikoextv2 — Build Selesai!${RESET}"
echo ""
