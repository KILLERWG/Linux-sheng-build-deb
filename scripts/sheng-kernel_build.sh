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
    echo "  KERNEL_ONLY=1       仅编译内核+模块+boot.img+linux-xiaomi-sheng.deb，跳过其余所有 deb 打包"
    echo "  ENABLE_BUILD_LOG=1  将所有构建步骤输出记录到日志文件"
    exit 1
}

if [ $# -lt 1 ]; then
    echo "❌ 缺少内核版本号参数"
    usage
fi

KERNEL_VERSION="$1"
echo "🔧 内核版本: ${KERNEL_VERSION}"
echo "   Git 分支: sheng-${KERNEL_VERSION}"
echo "   配置标签: ${KERNEL_VERSION}"

# ==========================================
# 2. 日志文件 & 构建模式
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"
LOG_FILE="${SCRIPT_DIR}/build-$(date +%Y%m%d-%H%M%S).log"

is_kernel_only() {
    [ "${KERNEL_ONLY:-0}" = "1" ] || [ "${KERNEL_ONLY:-0}" = "true" ]
}

log_exec() {
    if [ "${ENABLE_BUILD_LOG:-0}" = "1" ] || [ "${ENABLE_BUILD_LOG:-0}" = "true" ]; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
    else
        "$@"
    fi
}

build_deb() {
    local pkg="$1"
    if is_kernel_only && [ "$pkg" != "packages/linux-xiaomi-sheng" ]; then
        echo "⏭️ KERNEL_ONLY=1，跳过 $pkg 打包"
    else
        log_exec dpkg-deb --build --root-owner-group -Zzstd -z10 "$pkg"
    fi
}

if is_kernel_only; then
    echo "⚡ KERNEL_ONLY=1，仅编译内核+模块+boot.img，仅打包 linux-xiaomi-sheng.deb"
fi

if [ "${ENABLE_BUILD_LOG:-0}" = "1" ] || [ "${ENABLE_BUILD_LOG:-0}" = "true" ]; then
    echo "📝 构建日志: $LOG_FILE"
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
# 🛠️ 自动配置 (跳过所有交互式菜单)
# ==========================================
echo "⚙️ 正在应用并强行补全配置..."
log_exec wget -O .config https://github.com/ianchb/sm8550-mainline/releases/download/${KERNEL_VERSION}/sm8550.config

# 🔥 启用 Clang ThinLTO 优化 (编译加速 + 运行时性能提升)
./scripts/config --disable LTO_NONE --enable LTO_CLANG_THIN

log_exec make ARCH=arm64 CC="ccache clang" LLVM=1 olddefconfig
# ==========================================

# ==========================================
# 5. 执行多线程编译
# ==========================================
echo "🔨 开始极速编译..."
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

# 编译内核模块
log_exec make -j$(nproc) ARCH=arm64 CC="ccache clang" LLVM=1 INSTALL_MOD_PATH=../packages/linux-xiaomi-sheng modules_install

# 清理冗余链接
rm -rf ../packages/linux-xiaomi-sheng/lib/modules/*/build
rm -rf ../packages/linux-xiaomi-sheng/lib/modules/*/source

cd ..

# ==========================================
# 7. 外围组件构建
# ==========================================
IS_ARM64=0
if [ "$(uname -m)" = "aarch64" ]; then
    IS_ARM64=1
fi

if is_kernel_only; then
    echo "⏭️ KERNEL_ONLY=1，跳过外围组件构建 (fastrpc, libssc, iio-sensor-proxy, mipps-auth)"
else

# ==========================================
# 7.1 构建 fastrpc
# ==========================================
echo "📦 构建 fastrpc..."
log_exec wget -q https://github.com/qualcomm/fastrpc/archive/refs/tags/v1.0.6.zip
log_exec unzip -qo v1.0.6.zip
cd fastrpc-1.0.6
log_exec autoreconf -is
log_exec ./configure --prefix=/usr --host=aarch64-linux-gnu
log_exec make -j$(nproc)
log_exec make DESTDIR=$PWD/stage install
cd ..
mkdir -p packages/fastrpc/usr
cp -r fastrpc-1.0.6/stage/usr/* packages/fastrpc/usr/
find packages/fastrpc/usr/bin -type f -exec chmod +x {} \;
find packages/fastrpc/usr/lib -name "*.so*" -exec chmod +x {} \;

# ==========================================
# 7.2 传感器组件 (仅 arm64 原生编译)
# ==========================================

if [ "$IS_ARM64" -eq 0 ]; then
    echo "⏭️ 非 arm64 deb系环境，跳过 libssc 和 iio-sensor-proxy 构建"
else

# --- libssc ---
echo "📦 构建 libssc (Qualcomm Sensor Core)..."
git clone https://codeberg.org/DylanVanAssche/libssc.git --depth 1 libssc-src
cd libssc-src
# 打补丁：等待 QMI 服务就绪
cp ../tools/wait_for_qmi_service.patch .
patch -Np1 < wait_for_qmi_service.patch
log_exec meson setup build --prefix=/usr
log_exec meson compile -C build
DESTDIR=$PWD/../packages/libssc log_exec meson install -C build
cd ..
find packages/libssc/usr/bin -type f -exec chmod +x {} \;
find packages/libssc/usr/lib -name "*.so*" -exec chmod +x {} \;
# 打包并安装到系统，供 iio-sensor-proxy 编译链接
log_exec dpkg-deb --build --root-owner-group -Zzstd -z10 packages/libssc
if [ -n "${SUDO_PASS:-}" ]; then
    echo "$SUDO_PASS" | sudo -S dpkg -i packages/libssc.deb
else
    sudo dpkg -i packages/libssc.deb
fi
sudo ldconfig

# --- iio-sensor-proxy ---
echo "📦 构建 iio-sensor-proxy (SSC 支持)..."
if ! pkg-config --exists udev && pkg-config --exists libudev; then
    PC_DIR=$(pkg-config --variable=pc_path pkg-config 2>/dev/null | cut -d: -f1)
    if [ -f "$PC_DIR/libudev.pc" ] && [ ! -f "$PC_DIR/udev.pc" ]; then
        sudo ln -sf "$PC_DIR/libudev.pc" "$PC_DIR/udev.pc"
    fi
fi
log_exec wget -q https://gitlab.freedesktop.org/hadess/iio-sensor-proxy/-/archive/3.9/iio-sensor-proxy-3.9.tar.gz
log_exec tar -xf iio-sensor-proxy-3.9.tar.gz
cd iio-sensor-proxy-3.9
log_exec meson setup output \
  --prefix=/usr \
  -Db_lto=true \
  -Dssc-support=enabled \
  -Dsystemdsystemunitdir=/usr/lib/systemd/system
log_exec meson compile -C output
DESTDIR=$PWD/../packages/iio-sensor-proxy log_exec meson install --no-rebuild -C output
cd ..
if [ -d packages/iio-sensor-proxy/lib ]; then
    mkdir -p packages/iio-sensor-proxy/usr/lib
    cp -r packages/iio-sensor-proxy/lib/* packages/iio-sensor-proxy/usr/lib/
    rm -rf packages/iio-sensor-proxy/lib
fi
if [ -d packages/iio-sensor-proxy/rules.d ]; then
    mkdir -p packages/iio-sensor-proxy/usr/lib/udev/rules.d
    cp -r packages/iio-sensor-proxy/rules.d/* packages/iio-sensor-proxy/usr/lib/udev/rules.d/
    rm -rf packages/iio-sensor-proxy/rules.d
fi
find packages/iio-sensor-proxy/usr/bin -type f -exec chmod +x {} \;
find packages/iio-sensor-proxy/usr/libexec -type f -exec chmod +x {} \;
RULES_FILE="packages/iio-sensor-proxy/usr/lib/udev/rules.d/80-iio-sensor-proxy.rules"
if [ -f "$RULES_FILE" ]; then
    sed -i 's/ssc-light ssc-compass/ssc-light ssc-compass ssc-accel ssc-proximity/' "$RULES_FILE"
fi

fi  # IS_ARM64

# ==========================================
# 7.3 获取 xiaomi-mipps-auth
# ==========================================
echo "📥 正在下载 xiaomi-mipps-auth 最新版本..."
MIPPS_URL=$(wget -qO- https://api.github.com/repos/ianchb/xiaomi-mipps-auth/releases/latest | grep -o '"browser_download_url": "[^"]*\.deb"' | head -1 | cut -d'"' -f4)
if [ -n "$MIPPS_URL" ]; then
    wget -q "$MIPPS_URL"
    echo "✅ xiaomi-mipps-auth 下载完成"
else
    echo "⚠️ 未找到 xiaomi-mipps-auth .deb，跳过"
fi

fi  # ! is_kernel_only

echo "🔧 正在进行 UsrMerge 路径手术"

# 对所有可能包含 /lib 目录的包进行自动化修正
for pkg in packages/firmware-xiaomi-sheng packages/alsa-xiaomi-sheng packages/linux-xiaomi-sheng packages/fastrpc packages/ppd-arm-sync; do
    if [ -d "$pkg/lib" ]; then
        echo "✅ 正在将 $pkg 中的 /lib 迁移至 /usr/lib"
        mkdir -p "$pkg/usr"
        mv "$pkg/lib" "$pkg/usr/"
    fi
done
# ==========================================
# 8. 打包组件
# ==========================================
build_deb packages/linux-xiaomi-sheng
build_deb packages/firmware-xiaomi-sheng
build_deb packages/alsa-xiaomi-sheng
build_deb packages/sheng-devauth
build_deb packages/fastrpc
build_deb packages/ppd-arm-sync
if [ "${IS_ARM64:-0}" -eq 1 ]; then
    build_deb packages/iio-sensor-proxy
fi
build_deb packages/sheng-sensors

echo "🎉 所有任务圆满完成！"
