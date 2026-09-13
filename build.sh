#!/bin/bash
# =====================================================================
# 💫 MICHIKO Build Script — ULTIMATE HYBRID MODE FOR MIATOLL
# 🔧 Dibuat oleh: Michikoextv2
# 🧰 Toolchain: NezukoClang 23.1.1 + GCC ARM 32-bit
# 📱 Device: Xiaomi Miatoll
# 🎯 Output: Kernel Image + AnyKernel3 Zip Package (branch: staging)
# =====================================================================

# =====================================================================
# 🎨 WARNA & TAMPILAN
# =====================================================================
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; CYAN='\033[1;36m'; MAGENTA='\033[1;35m'
RESET='\033[0m'; BOLD='\033[1m'

# =====================================================================
# 📂 DIREKTORI & VARIABEL UTAMA
# =====================================================================
KERNEL_DIR="$(pwd)"
OUT_DIR="$KERNEL_DIR/out"
ARCH="arm64"
BUILD_LOG="$KERNEL_DIR/build.log"
DATE="$(date +"%Y-%m-%d_%H-%M")"

# 📦 AnyKernel3 Setup untuk miatoll
AK3_REPO="https://github.com/Michikoextv2/AnyKernel3-miatoll.git"
AK3_BRANCH="staging"  # <<< BRANCH YANG DIMINTA USER
AK3_DIR="$KERNEL_DIR/AnyKernel3"

# 🧰 Toolchain Detection (Auto-detect NezukoClang)
# Auto-detect clang kamu (NezukoClang) - prioritas: env CLANG_DIR > ../clang > ../NezukoClang > /serverhive1
if [ -z "$CLANG_DIR" ] || [ ! -f "$CLANG_DIR/bin/clang" ]; then
  for cand in "$KERNEL_DIR/../clang" "$KERNEL_DIR/../clang/NezukoClang" "$KERNEL_DIR/../NezukoClang" "/serverhive1/nezuko330/clang/NezukoClang" "/tmp/nezuko-pubtest/NezukoClang"; do
    if [ -f "$cand/bin/clang" ]; then CLANG_DIR="$cand"; break; fi
  done
fi
# fallback dari PATH jika masih kosong
if [ ! -f "$CLANG_DIR/bin/clang" ] && command -v clang >/dev/null 2>&1; then CLANG_DIR="$(dirname $(dirname $(command -v clang)) 2>/dev/null)"; fi
if [ ! -f "$CLANG_DIR/bin/clang" ] && [ -f "$CLANG_DIR/NezukoClang/bin/clang" ]; then CLANG_DIR="$CLANG_DIR/NezukoClang"; fi

# FIX: Buat symlink ld.gold jika belum ada (crash saat build VDSO)
if [ ! -f "$CLANG_DIR/bin/aarch64-linux-gnu-ld.gold" ]; then
    ln -sf "$CLANG_DIR/bin/ld.lld" "$CLANG_DIR/bin/aarch64-linux-gnu-ld.gold"
    echo -e "${YELLOW}⚠️  Symlink ld.gold dibuat otomatis${RESET}"
fi

GCC32_DIR="$KERNEL_DIR/../arm-linux-androideabi-4.9"

# Pastikan GCC32 tersedia
if [ ! -d "$GCC32_DIR/bin" ]; then
    for sp in "$CLANG_DIR/arm-linux-androideabi-4.9" \
              "/serverhive1/nezuko330/clang/NezukoClang/arm-linux-androideabi-4.9" \
              "/tmp/nezuko-pubtest/NezukoClang/arm-linux-androideabi-4.9" \
              "$KERNEL_DIR/../arm-linux-androideabi-4.9"; do
        if [ -d "$sp/bin" ] && [ -x "$sp/bin/arm-linux-androideabi-gcc" ]; then
            GCC32_DIR="$sp"
            echo -e "${GREEN}✅ GCC32 ditemukan: $GCC32_DIR${RESET}"
            break
        fi
    done
    if [ -z "$GCC32_DIR" ]; then
        echo -e "${RED}❌ GCC32 tidak ditemukan. Konfig COMPAT akan dimatikan.${RESET}"
        GCC32_DIR=""
    fi
fi

# Export PATH — CLANG DIR PAKAI PERTAMA
export PATH="$CLANG_DIR/bin:$GCC32_DIR/bin:$PATH"

# 🧠 Info Sistem
CPU_CORES=$(nproc --all)
HOST_OS=$(uname -o)
HOST_KERNEL=$(uname -r)
HOST_CPU=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')
TOOLCHAIN_VERSION=$("$CLANG_DIR/bin/clang" --version | head -n 1)
# Deteksi LLVM Polly (akan diaktifkan jika tersedia di toolchain)
if ls "$CLANG_DIR"/lib/*Polly* 1>/dev/null 2>&1 || "$CLANG_DIR/bin/clang" -mllvm --help 2>&1 | grep -qi polly; then HAS_POLLY=1; POLLY_INFO="✅ LLVM Polly tersedia"; else HAS_POLLY=0; POLLY_INFO="❌ Polly tidak ada (build tetap jalan)"; fi
[ "$HAS_POLLY" = 1 ] && echo -e "${GREEN}${POLLY_INFO}: $CLANG_DIR${RESET}" || echo -e "${YELLOW}${POLLY_INFO}${RESET}"

# =====================================================================
# 🖨️ TAMPILAN KELAS INTERNASAL
# =====================================================================
clear
echo -e "${MAGENTA}${BOLD}================================================================${RESET}"
echo -e " 💫 MICHIKO Build Script — ULTIMATE HYBRID MODE FOR MIATOLL"
echo -e "================================================================${RESET}"
echo -e "${CYAN}👤 Dibuat oleh   :${RESET} ${GREEN}Michikoextv2${RESET}"
echo -e "${YELLOW}🧠 CPU           :${RESET} ${GREEN}${HOST_CPU}${RESET}"
echo -e "${YELLOW}💻 Host          :${RESET} ${GREEN}${HOST_OS} (${HOST_KERNEL})${RESET}"
echo -e "${YELLOW}🧵 CPU Cores     :${RESET} ${GREEN}${CPU_CORES}${RESET}"
echo -e "${YELLOW}🧰 Toolchain     :${RESET} ${GREEN}${TOOLCHAIN_VERSION}${RESET}"
echo -e "${YELLOW}   └─ Polly       :${RESET} ${GREEN}${POLLY_INFO}${RESET}"
echo -e "${YELLOW}📱 Device       :${RESET} ${GREEN}miatoll${RESET}"
echo -e "${YELLOW}🌍 AK3 Branch   :${RESET} ${GREEN}${AK3_BRANCH}${RESET}"
echo -e "${MAGENTA}================================================================${RESET}"
echo -e ""
echo -e "${CYAN}📦 Proses: Generate Defconfig → Build Kernel → Buat Zip (AnyKernel3)${RESET}"
echo -e ""

# =====================================================================
# 🔍 CEK TOOLCHAIN
# =====================================================================
if [ ! -f "$CLANG_DIR/bin/clang" ]; then
    echo -e "${RED}❌ Clang tidak ditemukan di: $CLANG_DIR${RESET}"
    echo -e "${YELLOW}   Pastikan NezukoClang 23.1.1 sudah diekstrak di sini.${RESET}"
    exit 1
fi

if [ ! -f "$CLANG_DIR/bin/ld.lld" ]; then
    echo -e "${YELLOW}⚠️  ld.lld tidak ditemukan, menggunakan system lld.${RESET}"
    sudo apt install -y lld &>/dev/null
fi

if [ ! -d "$GCC32_DIR/bin" ]; then
    echo -e "${RED}❌ GCC32 (arm-linux-androideabi-4.9) tidak ditemukan${RESET}"
    echo -e "${YELLOW}   Pastikan ada di $KERNEL_DIR/../arm-linux-androideabi-4.9${RESET}"
    exit 1
fi

echo -e "${GREEN}✅ Toolchain Aktif:${RESET} $TOOLCHAIN_VERSION + GCC32 cross-compile\n"

# =====================================================================
# 🌿 GENERATE DEFCONFIG
# =====================================================================
echo -e "${CYAN}⚙️  Menghasilkan defconfig miatoll...${RESET}"
make O="$OUT_DIR" ARCH="$ARCH" miatoll_defconfig 2>&1 | tee -a "$BUILD_LOG"
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Gagal generate defconfig!${RESET}"
    exit 1
fi

# 🔧 Aktifkan fitur krusial SETELA defconfig
echo -e "${CYAN}🔧 Memasang konfigurasi krusial...${RESET}"
# CFI Clang
echo "CONFIG_CFI_CLANG=y" >> "$OUT_DIR/.config"
echo "CONFIG_CFI_PERMISSIVE=y" >> "$OUT_DIR/.config"
echo "CONFIG_CFI_CLANG_SHADOW=y" >> "$OUT_DIR/.config"
# LTO + Polly (auto enable jika toolchain support)
echo "CONFIG_LTO_CLANG=y" >> "$OUT_DIR/.config"
if [ "$HAS_POLLY" = 1 ]; then echo "CONFIG_LLVM_POLLY=y" >> "$OUT_DIR/.config"; echo -e "${GREEN}✅ LLVM_POLLY diaktifkan${RESET}"; else echo "# CONFIG_LLVM_POLLY is not set" >> "$OUT_DIR/.config"; fi
# GCC32/COMPAT
echo "CONFIG_COMPAT=y" >> "$OUT_DIR/.config"
# HID & BPF untuk matrix level 7
echo "CONFIG_HIDRAW=y" >> "$OUT_DIR/.config"
echo "CONFIG_HID_PLAYSTATION=y" >> "$OUT_DIR/.config"
echo "CONFIG_NET_ACT_BPF=y" >> "$OUT_DIR/.config"
echo "CONFIG_NET_ACT_POLICE=y" >> "$OUT_DIR/.config"
echo "CONFIG_NET_CLS_MATCHALL=y" >> "$OUT_DIR/.config"
echo "CONFIG_NET_SCH_TBF=y" >> "$OUT_DIR/.config"
echo "CONFIG_RD_LZ4=y" >> "$OUT_DIR/.config"
echo "CONFIG_PLAYSTATION_FF=y" >> "$OUT_DIR/.config"
#LLVM & Clang flags
echo "CONFIG_AS_IS_LLVM=y" >> "$OUT_DIR/.config"
echo "CONFIG_CC_IS_CLANG=y" >> "$OUT_DIR/.config"

# ✅ Jalankan olddefconfig SETELA menambah config (bukan sebelum)
echo -e "${CYAN}✅ Menjalankan olddefconfig...${RESET}"
yes '' | make O="$OUT_DIR" ARCH="$ARCH" olddefconfig 2>&1 | tee -a "$BUILD_LOG"

# Lancar langsung ke build - jangan jalankan silentoldconfig lagi
# karena sudah dijalankan olddefconfig di atas dan config sudah tepat

# =====================================================================
# ⏱️ TIMER MULAI
# =====================================================================
BUILD_START=$(date +%s)

# =====================================================================
# 🚀 BUILD KERNEL
# =====================================================================
echo -e "${CYAN}🚀 Memulai build kernel (${CPU_CORES} cores)...${RESET}\n"
make -j"$CPU_CORES" O="$OUT_DIR" ARCH="$ARCH" \
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
    2>&1 | tee -a "$BUILD_LOG"

BUILD_END=$(date +%s)
BUILD_TIME=$((BUILD_END - BUILD_START))

# =====================================================================
# 📦 CEK HASIL BUILD
# =====================================================================
IMAGE="$OUT_DIR/arch/arm64/boot/Image.gz"

if [ ! -f "$IMAGE" ]; then
    echo -e "${RED}❌ Build kernel GAGAL! Cek ${BUILD_LOG}.${RESET}"
    exit 1
fi

echo -e "${GREEN}✅ Build kernel SUCCESS!${RESET}"
echo -e "${YELLOW}📦 Output Image:${RESET} ${BLUE}${IMAGE}${RESET}"

KERNEL_RELEASE=$(make -s O="$OUT_DIR" ARCH="$ARCH" kernelrelease 2>/dev/null || true)
if [ -n "$KERNEL_RELEASE" ]; then
    echo -e "${YELLOW}🔖 Kernel release:${RESET} ${GREEN}${KERNEL_RELEASE}${RESET}"
fi

# =====================================================================
# 📦 BUAT ANYKERNEL3 ZIP UNTUK MIATOLL (branch staging)
# =====================================================================
echo -e "${CYAN}📦 Menyiapkan AnyKernel3 untuk miatoll (branch: ${AK3_BRANCH})...${RESET}"

# Clone atau update AnyKernel3
if [ ! -d "$AK3_DIR" ]; then
    echo -e "${YELLOW}📥 Mengclone AnyKernel3-miatoll (branch: ${AK3_BRANCH})...${RESET}"
    git clone --depth 1 -b "$AK3_BRANCH" "$AK3_REPO" "$AK3_DIR" 2>&1 | tee -a "$BUILD_LOG"
fi

# Update AnyKernel3
git -C "$AK3_DIR" fetch --depth 1 origin "$AK3_BRANCH" 2>&1 | tee -a "$BUILD_LOG"
git -C "$AK3_DIR" checkout "$AK3_BRANCH" 2>&1 | tee -a "$BUILD_LOG"

# Salin Image ke AnyKernel3
cp "$IMAGE" "$AK3_DIR/${DATE}-img.gz-dtbo.img" 2>&1 | tee -a "$BUILD_LOG"

# Salin .config untuk debugging di recovery
cp "$OUT_DIR/.config" "$AK3_DIR/.config" 2>&1 | tee -a "$BUILD_LOG"

# Salin vmlinux jika ada
if [ -f "$OUT_DIR/vmlinux" ]; then
    cp "$OUT_DIR/vmlinux" "$AK3_DIR/vmlinux" 2>&1 | tee -a "$BUILD_LOG"
fi

# Salin dtbo jika ada
if [ -f "$OUT_DIR/arch/arm64/boot/dtbo.img" ]; then
    cp "$OUT_DIR/arch/arm64/boot/dtbo.img" "$AK3_DIR/dtbo.img" 2>&1 | tee -a "$BUILD_LOG"
fi

# Buat zip menggunakan AnyKernel3 script
echo -e "${CYAN}📦 Membuat zip package...${RESET}"
cd "$AK3_DIR"
ZIP_NAME="Millenia-Kernel-MIATOLL-${DATE}.zip"

# Cek ada script zip di AnyKernel3
if [ -f "$AK3_DIR/zip.sh" ]; then
    bash "$AK3_DIR/zip.sh" "$ZIP_NAME" 2>&1 | tee -a "$BUILD_LOG"
else
    # Fallback: buat zip sederhana
    cd "$AK3_DIR"
    zip -r "$ZIP_NAME" .
    echo -e "${YELLOW}⚠️  Gunakan zip.sh dari AnyKernel3 untuk hasil terbaik.${RESET}"
fi

ZIP_PATH="$AK3_DIR/$ZIP_NAME"

echo -e "${GREEN}✅ Zip Package Selesai:${RESET} ${BLUE}${ZIP_PATH}${RESET}"
echo -e "${YELLOW}📏 Ukuran Zip:${RESET} $(du -h "$ZIP_PATH" | cut -f1)"

# =====================================================================
# 📊 AKHIR BUILD & INSTRUKSI
# =====================================================================
echo -e ""
echo -e "${MAGENTA}${BOLD}================================================================${RESET}"
echo -e " ${GREEN}✅ BUILD SELESAI UNTUK MIATOLL!${RESET}"
echo -e ""
echo -e "${CYAN}📁 File Output:${RESET}"
echo -e "   ${BLUE}${IMAGE}${RESET}    —  Kernel Image (${KERNEL_RELEASE})"
echo -e "   ${BLUE}${ZIP_PATH}${RESET}   —  Zip Package untuk di-flash (branch: ${AK3_BRANCH})"
echo -e ""
echo -e "${YELLOW}📋 Instruksi Flash:${RESET}"
echo -e "   1. Copy zip ke SD card/internal storage HP miatoll"
echo -e "   2. Boot ke TWRP/Custom Recovery"
echo -e "   3. Pilih 'Install' → Pilih zip file"
echo -e "   4. Swipe to confirm flash"
echo -e "   5. Reboot dan nikmati ROM baru!${RESET}"
echo -e ""
echo -e "${CYAN}📊 Detail Build:${RESET}"
echo -e "   ⏱️  Durasi: ${BUILD_TIME}s"
echo -e "   🧰  Toolchain: $TOOLCHAIN_VERSION"
echo -e "   🛡️  Fitur: CFI-Clang + LTO + GCC32 + 12 Config Matrix"
echo -e ""
echo -e "${MAGENTA}${BOLD}🎉 Selamat — Kernel Miatoll siap di-flash oleh Michikoextv2!${RESET}"
echo -e "${MAGENTA}${BOLD}================================================================${RESET}"
echo -e ""

# Simpan informasi build untuk user
echo "KERNEL_ZIP=$ZIP_PATH" >> "$KERNEL_DIR/build.log"
echo "KERNEL_IMAGE=$IMAGE" >> "$KERNEL_DIR/build.log"
echo "BUILD_TIME=$BUILD_TIME" >> "$KERNEL_DIR/build.log"