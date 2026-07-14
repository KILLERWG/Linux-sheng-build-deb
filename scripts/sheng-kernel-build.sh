#!/bin/bash
set -e
set -o pipefail

# ==========================================
# 1. 版本参数解析
# ==========================================
usage() {
    echo "用法: $0 <kernel_version>"
    echo "示例: $0 7.1.0"
    echo ""
    echo "  内核版本号将用于:"
    echo "    - git clone 分支: sheng-<version>"
    echo "    - 内核配置下载: <version>/sm8550.config"
    echo ""
    echo "可选环境变量:"
    echo "  ENABLE_BUILD_LOG=1  将所有构建步骤输出记录到日志文件"
    exit 1
}

if [ $# -lt 1 ]; then
    echo " 缺少内核版本号参数"
    usage
fi

KERNEL_VERSION="$1"
echo " 内核版本: ${KERNEL_VERSION}"
echo "   Git 分支: sheng-${KERNEL_VERSION}"
echo "   配置标签: ${KERNEL_VERSION}"

# ==========================================
# 2. 日志文件
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"
LOG_FILE="${SCRIPT_DIR}/build-$(date +%Y%m%d-%H%M%S).log"

log_exec() {
    if [ "${ENABLE_BUILD_LOG:-0}" = "1" ] || [ "${ENABLE_BUILD_LOG:-0}" = "true" ]; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
    else
        "$@"
    fi
}

if [ "${ENABLE_BUILD_LOG:-0}" = "1" ] || [ "${ENABLE_BUILD_LOG:-0}" = "true" ]; then
    echo " 构建日志: $LOG_FILE"
fi

# ==========================================
# 3. 编译环境与工具链配置
# ==========================================
export CCACHE_DIR="$HOME/.ccache"
export CCACHE_MAXSIZE="10G"
export CCACHE_SLOPPINESS="file_macro,locale,time_macros"
export CCACHE_NOHASHDIR="true"
mkdir -p "$CCACHE_DIR"

export CC="ccache clang"
export CXX="ccache clang++"
export AR="llvm-ar"
export NM="llvm-nm"
export OBJCOPY="llvm-objcopy"
export OBJDUMP="llvm-objdump"
export READELF="llvm-readelf"
export STRIP="llvm-strip"

# ==========================================
# 4. 拉取内核源码
# ==========================================
git clone https://github.com/ianchb/sm8550-mainline.git --branch sheng-${KERNEL_VERSION} --depth 1 linux
cd linux

# ==========================================
#  自动配置 (跳过所有交互式菜单)
# ==========================================
echo " 正在应用并强行补全配置..."
log_exec wget -O .config https://github.com/ianchb/sm8550-mainline/releases/download/${KERNEL_VERSION}/sm8550.config

#  启用 Clang ThinLTO 优化 (编译加速 + 运行时性能提升)
./scripts/config --disable LTO_NONE --enable LTO_CLANG_THIN

log_exec make ARCH=arm64 CC="ccache clang" LLVM=1 olddefconfig
# ==========================================

# ==========================================
# 5. 执行多线程编译
# ==========================================
echo " 开始极速编译..."
log_exec make -j$(nproc) ARCH=arm64 CC="ccache clang" LLVM=1
_kernel_version="$(make kernelrelease -s)"

# 更新 DEBIAN 版本
sed -i "s/Version:.*/Version: ${_kernel_version}/" ../packages/linux-xiaomi-sheng/DEBIAN/control

# ==========================================
# 6. 提取产物与打包
# ==========================================
PKGDIR=../packages/linux-xiaomi-sheng
mkdir -p $PKGDIR/boot

install -Dm644 arch/arm64/boot/Image.gz $PKGDIR/boot/Image.gz
install -Dm644 arch/arm64/boot/Image $PKGDIR/boot/Image
install -Dm644 arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb $PKGDIR/boot/sm8550-xiaomi-sheng.dtb
install -Dm644 .config $PKGDIR/boot/config-${_kernel_version}
install -Dm644 System.map $PKGDIR/boot/System.map-${_kernel_version}

chmod +x ../tools/mkbootimg

# 打包 boot.img
cat arch/arm64/boot/Image.gz arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb > Image.gz-dtb_sheng
install -Dm644 Image.gz-dtb_sheng $PKGDIR/boot/Image.gz-dtb_sheng
mv Image.gz-dtb_sheng zImage_sheng

../tools/mkbootimg --kernel zImage_sheng --cmdline "root=PARTLABEL=linux rootwait rw" --base 0x00000000 --kernel_offset 0x00008000 --tags_offset 0x01e00000 --pagesize 4096 --id -o ../boot_sheng_dualboot.img
../tools/mkbootimg --kernel zImage_sheng --cmdline "root=PARTLABEL=userdata rootwait rw" --base 0x00000000 --kernel_offset 0x00008000 --tags_offset 0x01e00000 --pagesize 4096 --id -o ../boot_sheng_singleboot.img

# 生成 UKI (Unified Kernel Image) EFI
ukify build \
  --linux=arch/arm64/boot/Image \
  --devicetree=arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb \
  --cmdline="console=tty0 root=PARTLABEL=linux rootwait rw" \
  --output=../bootaa64.efi

# 编译内核模块
log_exec make -j$(nproc) ARCH=arm64 CC="ccache clang" LLVM=1 INSTALL_MOD_PATH=../packages/linux-xiaomi-sheng modules_install

# 清理冗余链接
rm -rf ../packages/linux-xiaomi-sheng/lib/modules/*/build
rm -rf ../packages/linux-xiaomi-sheng/lib/modules/*/source

cd ..

echo " 正在进行 UsrMerge 路径手术"
if [ -d "packages/linux-xiaomi-sheng/lib" ]; then
    echo " 正在将 packages/linux-xiaomi-sheng 中的 /lib 迁移至 /usr/lib"
    mkdir -p "packages/linux-xiaomi-sheng/usr"
    mv "packages/linux-xiaomi-sheng/lib" "packages/linux-xiaomi-sheng/usr/"
fi

# ==========================================
# 6. 打包
# ==========================================
echo " 打包 linux-xiaomi-sheng.deb..."
log_exec dpkg-deb --build --root-owner-group -Zzstd -z10 packages/linux-xiaomi-sheng

echo " 内核构建完成！"
