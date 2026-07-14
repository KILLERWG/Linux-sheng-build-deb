#!/usr/bin/env bash
set -euo pipefail

# =============================================
#  sheng Debian rootfs 配置文件写入
#  通过环境变量控制:
#   ROOTFS_DIR      : rootfs 挂载目录 (必需)
#   FLAVOUR         : gnome | kde | server
#   DISTRO_VERSION  : trixie | forky
#   USERNAME        : 普通用户名
# =============================================

ROOTFS_DIR="${ROOTFS_DIR:-}"
FLAVOUR="${FLAVOUR:-kde}"
DISTRO_VERSION="${DISTRO_VERSION:-forky}"
USERNAME="${USERNAME:-xiaomi}"

if [ -z "$ROOTFS_DIR" ] || [ ! -d "$ROOTFS_DIR" ]; then
    echo "错误: ROOTFS_DIR 未设置或不存在: $ROOTFS_DIR"
    exit 1
fi

RD="$ROOTFS_DIR"

write()   { cat > "$RD/$1"; }
writedir() { mkdir -p "$(dirname "$RD/$1")"; }

# ============================================================
#  /etc/environment  — 输入法环境变量
# ============================================================
if [ "$FLAVOUR" = "gnome" ]; then
    write etc/environment <<'EOF'
GTK_IM_MODULE=ibus
QT_IM_MODULE=ibus
XMODIFIERS=@im=ibus
EOF
elif [ "$FLAVOUR" = "kde" ]; then
    write etc/environment <<'EOF'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
INPUT_METHOD=fcitx
EOF
fi

# ============================================================
#  GNOME: GDM 自动登录
# ============================================================
if [ "$FLAVOUR" = "gnome" ]; then
    writedir etc/gdm3/daemon.conf
    write etc/gdm3/daemon.conf <<GDMCFG
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=${USERNAME}
GDMCFG
fi

# ============================================================
#  KDE: SDDM 自动登录
# ============================================================
if [ "$FLAVOUR" = "kde" ]; then
    writedir etc/sddm.conf.d/autologin.conf
    write etc/sddm.conf.d/autologin.conf <<SDDMCFG
[Autologin]
User=${USERNAME}
Session=plasma
SDDMCFG
fi

# ============================================================
#  forky: Plasma Keyboard + Fcitx5 分层共存
# ============================================================
if [ "$FLAVOUR" = "kde" ] && [ "$DISTRO_VERSION" = "forky" ]; then

    # /etc/environment.d/ 兜底
    writedir etc/environment.d/90-fcitx5.conf
    write etc/environment.d/90-fcitx5.conf <<'EOF'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
INPUT_METHOD=fcitx
EOF

    # /etc/xdg/kwinrc — KWin 全局默认
    writedir etc/xdg/kwinrc
    write etc/xdg/kwinrc <<'EOF'
[Wayland]
InputMethod[$e]=/usr/share/applications/org.kde.plasma.keyboard.desktop
VirtualKeyboardEnabled=true
EOF

    # /etc/skel/ 新用户默认配置
    writedir etc/skel/.config/autostart/org.fcitx.Fcitx5.desktop
    write etc/skel/.config/autostart/org.fcitx.Fcitx5.desktop <<'EOF'
[Desktop Entry]
Name=Fcitx 5
GenericName=Input Method
Comment=Start Fcitx 5 input method
Exec=fcitx5 -d --replace
Icon=org.fcitx.Fcitx5
Terminal=false
Type=Application
Categories=System;Utility;
X-GNOME-Autostart-enabled=true
X-KDE-autostart-after=panel
EOF

    writedir etc/skel/.config/plasma-workspace/env/fcitx5.sh
    write etc/skel/.config/plasma-workspace/env/fcitx5.sh <<'EOF'
#!/bin/sh
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export SDL_IM_MODULE=fcitx
export INPUT_METHOD=fcitx
EOF
    chmod 0755 "$RD/etc/skel/.config/plasma-workspace/env/fcitx5.sh"

    writedir etc/skel/.config/environment.d/90-fcitx5.conf
    write etc/skel/.config/environment.d/90-fcitx5.conf <<'EOF'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
INPUT_METHOD=fcitx
EOF

    writedir etc/skel/.config/kwinrc
    write etc/skel/.config/kwinrc <<'EOF'
[Wayland]
InputMethod[$e]=/usr/share/applications/org.kde.plasma.keyboard.desktop
VirtualKeyboardEnabled=true
EOF

    # fcitx5 默认 profile — 预设拼音输入法
    writedir etc/skel/.config/fcitx5/profile
    write etc/skel/.config/fcitx5/profile <<'EOF'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=pinyin

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=pinyin
Layout=

[GroupOrder]
0=Default
EOF

    # plasmakeyboardrc — 虚拟键盘震动/声音
    writedir etc/skel/.config/plasmakeyboardrc
    write etc/skel/.config/plasmakeyboardrc <<'EOF'
[General]
enabledLocales=en_US
soundEnabled=true
vibrationEnabled=true
vibrationMs=20
EOF
fi
