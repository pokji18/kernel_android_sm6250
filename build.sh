#!/bin/bash
# =====================================================================
# 💫 MICHIKO Build Script — CLOUD & LOCAL HYBRID MODE
# 🔧 Dibuat oleh: pokji18
# 🧰 Toolchain: NezukoClang 23.1.1 (otomatis didetect/didownload)
#         Bekerja di: Serverhive (local)ATAU GitHub Codespaces
# =====================================================================

# ============================================================
# � ENVIRONMENT DETECTION & TOOLCHAIN AUTO-SETUP
# ============================================================

# Warna
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; CYAN='\033[1;36m'; MAGENTA='\033[1;35m'
RESET='\033[0m'; BOLD='\033[1m'

# === DETEKSI LOKASI ============================================================
# Cek apakah kita di GitHub Codespace atau Serverhive/local

CURRENT_DIR=$(pwd)
IS_CODESPACES=false
IS_SERVERHIVE=false

# Cek environment variable codespace
if [ -n "$CODESPACES" ] || [ -f "/workspaces/.codespace" ] || grep -q "codespace" /etc/hostname 2>/dev/null; then
    IS_CODESPACES=true
fi

# Cek serverhive path
if [ -d "/serverhive1" ] || [ -d "/serverhive" ]; then
    IS_SERVERHIVE=true
fi

echo -e "${CYAN}🌍 Environment: ${RESET}"
[ "$IS_CODESPACES" = true ] && echo -e "  ${YELLOW}GitHub Codespaces${RESET}" || echo -e "  ${GREEN}Local/Serverhive${RESET}"
[ "$IS_SERVERHIVE" = true ] && echo -e "  ${GREEN}Terdeteksi Serverhive${RESET}" || echo -e "  ${RED}Tidak ada Serverhive${RESET}"

# === TOOLCHAIN AUTODETECT & DOWNLOAD ============================================

# Path default NezukoClang di serverhive
SERVERHIVE_CLANG="/serverhive1/nezuko330/clang/NezukoClang"

# Cari atau unduh NezukoClang
find_nezuko_clang() {
    local result=1

    # 1. Cek Serverhive first
    if [ "$IS_SERVERHIVE" = true ] && [ -f "$SERVERHIVE_CLANG/bin/clang" ]; then
        echo -e "${GREEN}✅ NezukoClang Serverhive ditemukan${RESET}"
        echo "CLANG_DIR=$SERVERHIVE_CLANG" > /tmp/nezuko_clang_path.txt
        return 0
    fi

    # 2. Cek jika sudah ada di PATH atau direktori kerja
    if command -v clang &>/dev/null && clang --version 2>/dev/null | grep -q "NezukoClang\|version 23"; then
        CLANG_PATH=$(which clang)
        echo -e "${GREEN}✅ NezukoClang ditemukan via PATH${RESET}"
        echo "CLANG_DIR=$(dirname $CLANG_PATH)" > /tmp/nezuko_clang_path.txt
        return 0
    fi

    # 3. Cek di direktori umum Codespace
    if [ "$IS_CODESPACES" = true ]; then
        for path in "/workspaces/NezukoClang" "$HOME/NezukoClang" "/home/user/NezukoClang"; do
            if [ -f "$path/bin/clang" ]; then
                echo -e "${GREEN}✅ NezukoClang ditemukan di Codespace: $path${RESET}"
                echo "CLANG_DIR=$path" > /tmp/nezuko_clang_path.txt
                return 0
            fi
        done
    fi

    # 4. Auto-download dari repo GitHub
    echo -e "${YELLOW}⚠️ Sedang mengunduh NezukoClang 23.1.1...${RESET}"
    mkdir -p /tmp/nezuko-clang-download
    git clone --depth 1 -b 23.1.1-r3 https://github.com/pokji18/NezukoClang.git /tmp/nezuko-clang-download/nezuko 2>/dev/null

    if [ -f "/tmp/nezuko-clang-download/nezuko/bin/clang" ]; then
        CLANG_DIR="/tmp/nezuko-clang-download/nezuko"
        echo -e "${GREEN}✅ NezukoClang berhasil diunduh${RESET}"
        echo "CLANG_DIR=$CLANG_DIR" > /tmp/nezuko_clang_path.txt
        return 0
    else
        echo -e "${RED}❌ Gagal mengunduh NezukoClang${RESET}"
        return 1
    fi

    return $result
}

# Jalankan autodetect
if ! find_nezuko_clang; then
    echo -e "${RED}❌ Tidak dapat menemukan/mendownload NezukoClang. Exit.${RESET}"
    exit 1
fi

# Load path yang dideteksi
source /tmp/nezuko_clang_path.txt
CLANG_DIR="${CLANG_DIR:-$SERVERHIVE_CLANG}"

# Pastikan path benar
if [ ! -f "$CLANG_DIR/bin/clang" ]; then
    # Coba cari lagi di PATH
    CLANG_DIR=$(dirname $(which clang 2>/dev/null))
fi

CLANG_VERSION=$($CLANG_DIR/bin/clang --version | head -n 1)

# Setup GCC32 (arm-linux-androideabi-4.9)
# Cari di beberapa kemungkinan lokasi
GCC32_DIR=""

# Urutan prioritas GCC32
if [ "$IS_SERVERHIVE" = true ]; then
    if [ -d "$SERVERHIVE_CLANG/arm-linux-androideabi-4.9" ]; then
        GCC32_DIR="$SERVERHIVE_CLANG/arm-linux-androideabi-4.9"
    elif [ -d "$KERNEL_DIR/../arm-linux-androideabi-4.9" ]; then
        GCC32_DIR="$KERNEL_DIR/../arm-linux-androideabi-4.9"
    fi
fi

if [ "$IS_CODESPACES" = true ] && [ -z "$GCC32_DIR" ]; then
    if [ -d "$HOME/arm-linux-androideabi-4.9" ]; then
        GCC32_DIR="$HOME/arm-linux-androideabi-4.9"
    fi
fi

# Jika GCC32 masih kosong, cari otomatis
if [ -z "$GCC32_DIR" ] || [ ! -d "$GCC32_DIR/bin" ]; then
    echo -e "${YELLOW}⚠️ Mencari GCC32 otomatis...${RESET}"
    # Cari di beberapa kemungkinan
    for search_path in "/serverhive1/nezuko330/clang/NezukoClang/arm-linux-androideabi-4.9" \
                       "$HOME/arm-linux-androideabi-4.9" \
                       "/tmp/nezuko-clang-download/nezuko/arm-linux-androideabi-4.9" \
                       "/usr/local/arm-linux-androideabi-4.9"; do
        if [ -d "$search_path/bin" ]; then
            GCC32_DIR="$search_path"
            break
        fi
    done

    # Kalau masih kosong, buat symlink ke clang dir
    if [ -z "$GCC32_DIR" ]; then
        GCC32_DIR="$CLANG_DIR/arm-linux-androideabi-4.9"
        if [ ! -d "$GCC32_DIR" ]; then
            mkdir -p "$GCC32_DIR"
            # Buat symlink ke biner yang ada
            ln -sf "$CLANG_DIR/bin/arm-linux-androideabi-gcc" "$GCC32_DIR/bin/arm-linux-androideabi-gcc" 2>/dev/null
            ln -sf "$CLANG_DIR/bin/arm-linux-androideabi-gcc-4.9" "$GCC32_DIR/bin/arm-linux-androideabi-gcc-4.9" 2>/dev/null
        fi
    fi
fi

# Export PATH
export PATH="$CLANG_DIR/bin:$GCC32_DIR/bin:$PATH"

# ============================================================
# � KERNEL BUILD SETUP
# ============================================================

KERNEL_DIR=$(pwd)
OUT_DIR="$KERNEL_DIR/out"
ARCH="arm64"

# Cek defconfig
CONFIG_PATH="$KERNEL_DIR/arch/arm64/configs/vendor/xiaomi"
DEFCONFIGS=($(ls "$CONFIG_PATH" | grep -E "defconfig$" 2>/dev/null))

if [ ${#DEFCONFIGS[@]} -eq 0 ]; then
    echo -e "${RED}❌ Tidak ada defconfig di $CONFIG_PATH${RESET}"
    exit 1
elif [ ${#DEFCONFIGS[@]} -eq 1 ]; then
    DEFCONFIG="${DEFCONFIGS[0]}"
    echo -e "${GREEN}✅ Ditemukan satu defconfig: ${DEFCONFIG}${RESET}"
else
    echo -e "${YELLOW}Pilih defconfig:${RESET}"
    select DEFCONFIG in "${DEFCONFIGS[@]}"; do
        [ -n "$DEFCONFIG" ] && break
        echo -e "${RED}Pilihan tidak valid.${RESET}"
    done
fi

# ============================================================
# � BUILD PROCESS
# ============================================================

# Membersihkan build lama tapi jaga .config
echo -e "${CYAN}🧹 Membersihkan build (tetap simpan .config)...${RESET}"
make mrproper 2>&1 | grep -v "CLEAN" | tail -n 3
make clean 2>&1 | grep -v "CLEAN" | tail -n 3

# Generate ulang defconfig dari file asli
echo -e "${YELLOW}⚙️ Menghasilkan defconfig (${DEFCONFIG})...${RESET}"
make O="$OUT_DIR" ARCH="$ARCH" "$DEFCONFIG" 2>&1 | tee -a "$KERNEL_DIR/build.log"
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Gagal generate defconfig.${RESET}"
    exit 1
fi

# Olddefconfig untuk men-set nilai yang kosong berdasarkan defconfig
echo -e "${CYAN}🔧 Olddefconfig...${RESET}"
make O="$OUT_DIR" ARCH="$ARCH" olddefconfig 2>&1 | tee -a "$KERNEL_DIR/build.log"

# Verifikasi config krusial
echo -e "${CYAN}ℹ️ Verifikasi config krusial...${RESET}"
for cfg in CONFIG_CFI_CLANG CONFIG_CFI_PERMISSIVE CONFIG_LTO_CLANG CONFIG_COMPAT CONFIG_HIDRAW CONFIG_HID_PLAYSTATION; do
    val=$(grep -E "^${cfg}=" "$OUT_DIR/.config" 2>/dev/null | head -n 1 | sed "s/^${cfg}=//")
    if [ -n "$val" ]; then
        echo -e "  ${GREEN}$cfg: $val${RESET}"
    else
        echo -e "  ${YELLOW}$cfg: not set (akan di-set otomatis)${RESET}"
        # Set auto berdasarkan environment
        if [ "$IS_CODESPACES" = true ]; then
            # di Codespace: minimal standar
            :
        else
            # di Serverhive: pakai yang sudah ada
            :
        fi
    fi
done

# Menuconfig opsional (skip di Codespace untuk kecepatan)
if [ "$IS_CODESPACES" = false ]; then
    read -p "$(echo -e ${MAGENTA}'🧭 Ingin buka menuconfig sebelum build? (y/n): '${RESET})" menu
    [[ "$menu" =~ ^[Yy]$ ]] && make O="$OUT_DIR" ARCH="$ARCH" menuconfig | tee -a "$KERNEL_DIR/build.log"
fi

# Timer mulai
BUILD_START=$(date +%s)

# Setup variabel kernel
export USE_CCACHE=1
export KBUILD_BUILD_HOST=pokji18
export KBUILD_BUILD_USER=androidbuilder

# ============================================================
# � BUILD KERNEL
# ============================================================

echo -e "${CYAN}🚀 Memulai build kernel (${CPU_CORES:-$(nproc)} cores)...${RESET}\n"

make -j"${CPU_CORES:-$(nproc)}" O="$OUT_DIR" ARCH="$ARCH" \
    CC=clang \
    LD=ld.lld \
    AR=llvm-ar \
    NM=llvm-nm \
    STRIP=llvm-strip \
    OBJCOPY=llvm-objcopy \
    OBJDUMP=llvm-objdump \
    READELF=llvm-readelf \
    LLVM=1 LLVM_IAS=1 \
    CROSS_COMPILE="$CLANG_DIR/bin/aarch64-linux-gnu-" \
    CROSS_COMPILE_ARM32="$GCC32_DIR/bin/arm-linux-androideabi-" \
    2>&1 | tee -a "$KERNEL_DIR/build.log"

BUILD_END=$(date +%s)
BUILD_TIME=$((BUILD_END - BUILD_START))

# ============================================================
# � HASIL BUILD & OUTPUT
# ============================================================

echo -e "\n${CYAN}==============================================================${RESET}"
IMAGE="$OUT_DIR/arch/arm64/boot/Image.gz"

if [ -f "$IMAGE" ]; then
    echo -e "${GREEN}✅ Build kernel SUCCESS!${RESET}"
    echo -e "${YELLOW}📦 Output:${RESET} ${BLUE}${IMAGE}${RESET}"

    KERNEL_RELEASE=$(make -s O="$OUT_DIR" ARCH="$ARCH" kernelrelease 2>/dev/null || true)
    if [ -n "$KERNEL_RELEASE" ]; then
        echo -e "${YELLOW}🔖 Kernel release:${RESET} ${GREEN}${KERNEL_RELEASE}${RESET}"
    fi

    # Rename otomatis
    DATE="$(TZ=Asia/Jakarta date +%Y%m%d%H%M)"
    FINAL_IMAGE="$KERNEL_DIR/Millenia-Kernel-${DATE}.img"
    cp "$IMAGE" "$FINAL_IMAGE"
    echo -e "${GREEN}💾 Disalin ke:${RESET} ${FINAL_IMAGE}"

    echo -e "\n${CYAN}🎯 Instruksi flash:${RESET}"
    echo -e "${YELLOW}File kernel:${RESET} ${BLUE}${FINAL_IMAGE}${RESET}"
    echo -e "${YELLOW}Kernel release:${RESET} ${GREEN}${KERNEL_RELEASE}${RESET}"
    echo -e "${MAGENTA}Pastikan file ini yang di-flash ke HP!${RESET}"

    # Ringkas status config
    echo -e "\n${CYAN}✅ Config terverifikasi:${RESET}"
    for cfg in CONFIG_CFI_CLANG CONFIG_CFI_PERMISSIVE CONFIG_LTO_CLANG CONFIG_COMPAT; do
        val=$(grep -E "^${cfg}=" "$OUT_DIR/.config" 2>/dev/null | head -n 1 | sed "s/^${cfg}=//")
        [ -n "$val" ] && echo -e "  ${GREEN}$cfg: $val${RESET}"
    done

else
    echo -e "${RED}❌ Build kernel GAGAL. Lihat ${KERNEL_DIR}/build.log untuk detail.${RESET}"
    echo -e "${YELLOW}⚠️ Tips utama: Pastikan Clang 23.1.1 tersedia dan PATH sudah benar.${RESET}"
    echo -e "${YELLOW}Error terakhir:${RESET}"
    tail -n 30 "$KERNEL_DIR/build.log" | grep -E "error|Error|FAILED" | head -n 5
fi

echo -e "\n${YELLOW}⏱️ Durasi build:${RESET} ${GREEN}${BUILD_TIME}s${RESET}"
echo -e "${CYAN}==============================================================${RESET}"
echo -e "${MAGENTA}${BOLD}🎉 Selamat — build selesai oleh pokji18!${RESET}\n"