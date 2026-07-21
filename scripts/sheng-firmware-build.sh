#!/bin/bash
set -e
set -o pipefail

# ==========================================
#  sheng 设备固件/传感器组件构建脚本
#  编译 fastrpc、libssc、iio-sensor-proxy
#  下载 mipps-auth、sheng-thp、pen-status，打包所有非内核 .deb
#
#  注意: 需在项目根目录运行
#        libssc/iio-sensor-proxy 仅在 aarch64 环境编译
# ==========================================

usage() {
    echo "用法: $0"
    echo ""
    echo "  编译 sheng 设备的所有固件/传感器组件并打包为 .deb"
    echo ""
    echo "可选环境变量:"
    echo "  ENABLE_BUILD_LOG=1  将所有构建步骤输出记录到日志文件"
    exit 1
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"
LOG_FILE="${SCRIPT_DIR}/firmware-build-$(date +%Y%m%d-%H%M%S).log"

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

IS_ARM64=0
if [ "$(uname -m)" = "aarch64" ]; then
    IS_ARM64=1
fi

# ==========================================
# 1. fastrpc
# ==========================================
echo " 构建 fastrpc..."
log_exec wget -q https://github.com/qualcomm/fastrpc/archive/refs/tags/v1.0.2.zip
log_exec unzip -qo v1.0.2.zip
cd fastrpc-1.0.2
log_exec autoreconf -is
log_exec ./configure --prefix=/usr --host=aarch64-linux-gnu \
    CC="clang --target=aarch64-linux-gnu" \
    CXX="clang++ --target=aarch64-linux-gnu" \
    LD=ld.lld
log_exec make -j$(nproc)
log_exec make DESTDIR=$PWD/stage install
cd ..
mkdir -p packages/fastrpc/usr
cp -r fastrpc-1.0.2/stage/usr/* packages/fastrpc/usr/
find packages/fastrpc/usr/bin -type f -exec chmod +x {} \;
find packages/fastrpc/usr/lib -name "*.so*" -exec chmod +x {} \;

# ==========================================
# 2. 传感器组件 (仅 arm64 原生编译)
# ==========================================
if [ "$IS_ARM64" -eq 0 ]; then
    echo " 非 arm64 环境，跳过 libssc 和 iio-sensor-proxy 构建"
else

    # --- libssc ---
    echo " 构建 libssc (Qualcomm Sensor Core)..."
    git clone https://codeberg.org/DylanVanAssche/libssc.git --depth 1 libssc-src
    cd libssc-src
    cp ../tools/wait_for_qmi_service.patch .
    patch -Np1 < wait_for_qmi_service.patch
    log_exec meson setup build --prefix=/usr
    log_exec meson compile -C build
    DESTDIR=$PWD/../packages/libssc log_exec meson install -C build
    cd ..
    find packages/libssc/usr/bin -type f -exec chmod +x {} \;
    find packages/libssc/usr/lib -name "*.so*" -exec chmod +x {} \;

    # 安装 libssc 到系统，供 iio-sensor-proxy 编译链接
    log_exec dpkg-deb --build --root-owner-group -Zzstd -z10 packages/libssc
    if [ -n "${SUDO_PASS:-}" ]; then
        echo "$SUDO_PASS" | sudo -S dpkg -i packages/libssc.deb
    else
        sudo dpkg -i packages/libssc.deb
    fi
    sudo ldconfig

    # --- iio-sensor-proxy ---
    echo " 构建 iio-sensor-proxy (SSC 支持)..."
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

    # 修正路径
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
fi

# ==========================================
# 3. 下载预构建 .deb 包
# ==========================================

# --- xiaomi-mipps-auth (充电认证) ---
echo " 正在下载 xiaomi-mipps-auth 最新版本..."
MIPPS_URL=$(wget -qO- https://api.github.com/repos/ianchb/xiaomi-mipps-auth/releases/latest | grep -o '"browser_download_url": "[^"]*\.deb"' | head -1 | cut -d'"' -f4)
if [ -n "$MIPPS_URL" ]; then
    wget -q "$MIPPS_URL" -P packages/
    echo " xiaomi-mipps-auth 下载完成"
else
    echo " 未找到 xiaomi-mipps-auth .deb，跳过"
fi

# --- xiaomi-sheng-thp (触摸屏 THP 用户态守护进程) ---
echo " 正在下载 xiaomi-sheng-thp 最新版本..."
THP_URL=$(wget -qO- https://api.github.com/repos/ianchb/xiaomi-sheng-thp/releases/latest | grep -o '"browser_download_url": "[^"]*\.deb"' | head -1 | cut -d'"' -f4)
if [ -n "$THP_URL" ]; then
    wget -q "$THP_URL" -P packages/
    echo " xiaomi-sheng-thp 下载完成"
else
    echo " 未找到 xiaomi-sheng-thp .deb，跳过"
fi

# --- xiaomi-sheng-fingerprint (指纹传感器固件/驱动) ---
echo " 正在下载 xiaomi-sheng-fingerprint 最新版本..."
FINGERPRINT_URL=$(wget -qO- https://api.github.com/repos/ianchb/xiaomi-sheng-fingerprint/releases/latest | grep -o '"browser_download_url": "[^"]*\.deb"' | head -1 | cut -d'"' -f4)
if [ -n "$FINGERPRINT_URL" ]; then
    wget -q "$FINGERPRINT_URL" -P packages/
    echo " xiaomi-sheng-fingerprint 下载完成"
else
    echo " 未找到 xiaomi-sheng-fingerprint .deb，跳过"
fi

# --- xiaomi-pen-status (触控笔状态/蓝牙连接工具) ---
echo " 正在下载 xiaomi-pen-status 最新版本..."
PEN_URL=$(wget -qO- https://api.github.com/repos/ianchb/xiaomi-pen-status/releases/latest | grep -o '"browser_download_url": "[^"]*\.deb"' | head -1 | cut -d'"' -f4)
if [ -n "$PEN_URL" ]; then
    wget -q "$PEN_URL" -P packages/
    echo " xiaomi-pen-status 下载完成"
else
    echo " 未找到 xiaomi-pen-status .deb，跳过"
fi

# ==========================================
# 4. 编译 sheng-devauth (键盘认证服务)
# ==========================================
echo " 编译 sheng-devauth..."
DEVUAUTH_SRC="/tmp/sheng_devauth"
rm -rf "$DEVUAUTH_SRC"
git clone https://github.com/ianchb/sheng_devauth.git --depth 1 "$DEVUAUTH_SRC"
make -C "$DEVUAUTH_SRC" \
    CC="clang --target=aarch64-linux-gnu" \
    LDFLAGS="-fuse-ld=lld" \
    -j$(nproc)
mkdir -p packages/sheng-devauth/usr/bin
install -Dm755 "$DEVUAUTH_SRC/xiaomi_devauth" packages/sheng-devauth/usr/bin/xiaomi_devauth
rm -rf "$DEVUAUTH_SRC"
echo " sheng-devauth 编译完成"

# ==========================================
# 5. UsrMerge 路径迁移
# ==========================================
echo " 正在进行 UsrMerge 路径手术"
for pkg in packages/firmware-xiaomi-sheng packages/alsa-xiaomi-sheng packages/fastrpc packages/ppd-arm-sync; do
    if [ -d "$pkg/lib" ]; then
        echo " 正在将 $pkg 中的 /lib 迁移至 /usr/lib"
        mkdir -p "$pkg/usr"
        mv "$pkg/lib" "$pkg/usr/"
    fi
done

# ==========================================
# 6. 打包所有组件
# ==========================================
echo " 打包 .deb..."
log_exec dpkg-deb --build --root-owner-group -Zzstd -z10 packages/firmware-xiaomi-sheng
log_exec dpkg-deb --build --root-owner-group -Zzstd -z10 packages/alsa-xiaomi-sheng
log_exec dpkg-deb --build --root-owner-group -Zzstd -z10 packages/sheng-devauth
log_exec dpkg-deb --build --root-owner-group -Zzstd -z10 packages/fastrpc
log_exec dpkg-deb --build --root-owner-group -Zzstd -z10 packages/ppd-arm-sync
if [ "${IS_ARM64:-0}" -eq 1 ]; then
    log_exec dpkg-deb --build --root-owner-group -Zzstd -z10 packages/iio-sensor-proxy
fi
log_exec dpkg-deb --build --root-owner-group -Zzstd -z10 packages/sheng-sensors

echo " 固件/传感器组件构建完成！"
