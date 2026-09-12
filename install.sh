#!/usr/bin/env bash
# =============================================================================
#  samp-wine-launcher — install.sh
#  把 README「前置条件」自动化：裸 Debian 12 → 可直接运行 start_samp.sh
#
#  做什么（幂等，可重复执行）：
#    1. i386 多架构 + 全部 apt 依赖（wine32 / Xorg / VNC / Vulkan i386 / CJK 字体）
#    2. 当前用户加入 video,render 组（访问 /dev/dri/renderD128）
#    3. 创建 32 位 Wine 前缀
#    4. 下载 DXVK 并装入前缀（DLL overrides + dxvk.conf）
#    5. Wine 音频驱动 = alsa（避免引擎弹"未找到声卡"错误框）
#    6. /etc/asound.conf dmix 软件混音（多程序共享声卡，防 CLEO/mod 音频崩溃）
#    7. sudoers NOPASSWD（Xorg 提权 + 字体安装；--skip-sudoers 可跳过）
#    8. 创建默认游戏目录
#
#  不做什么（版权/硬件，结束时提醒）：
#    - 游戏本体（gta_sa.exe + samp.exe 需自备放入游戏目录）
#    - HDMI 欺骗器（无显示器时必需的硬件）
#
#  用法：
#    ./install.sh                    # 全部步骤
#    ./install.sh --skip-sudoers     # 跳过 sudoers 写入
#    ./install.sh --skip-dxvk        # 跳过 DXVK 下载（离线环境）
#    ./install.sh --dxvk 2.4         # 指定 DXVK 版本（默认 2.4，README 验证版）
#    ./install.sh --prefix DIR --game-dir DIR
#
#  提权方式与 start_samp.sh 一致：优先 sudoers NOPASSWD，或用
#  SAMP_SUDO_PASS 环境变量传密码（不推荐硬编码）。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${SAMP_WINEPREFIX:-$HOME/.samp-prefix}"
GAME_DIR="${SAMP_GAME_DIR:-$HOME/GTA San Andreas}"
DXVK_VER="2.4"
DO_SUDOERS=1
DO_DXVK=1

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-sudoers) DO_SUDOERS=0 ;;
    --skip-dxvk)    DO_DXVK=0 ;;
    --dxvk)         DXVK_VER="${2:?--dxvk 需要版本号}"; shift ;;
    --prefix)       PREFIX="${2:?--prefix 需要路径}"; shift ;;
    --game-dir)     GAME_DIR="${2:?--game-dir 需要路径}"; shift ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
  shift
done

# ---------------------------- helpers ---------------------------------------
sdo(){ if [ -n "${SAMP_SUDO_PASS:-}" ]; then printf '%s\n' "$SAMP_SUDO_PASS" | sudo -S "$@"; else sudo "$@"; fi; }
log(){ printf '\033[1;32m[install]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[install]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[install]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------- 0. preflight ----------------------------------
[ "$(id -u)" -eq 0 ] && die "请用普通用户运行（脚本内部用 sudo 提权）；用 root 跑会导致 Wine 前缀属主错误"
command -v sudo >/dev/null 2>&1 || die "缺少 sudo"
# shellcheck disable=SC1091
. /etc/os-release 2>/dev/null || true
if [ "${ID:-}" = "debian" ]; then
  log "检测到 ${PRETTY_NAME:-Debian}"
else
  warn "仅在 Debian 12 (bookworm) 验证过；当前 ${PRETTY_NAME:-未知系统}，继续但包名/路径可能需调整"
fi

# ---------------------------- 1. apt 依赖 ------------------------------------
if ! dpkg --print-foreign-architectures 2>/dev/null | grep -qx i386; then
  log "添加 i386 多架构"
  sdo dpkg --add-architecture i386
fi
log "安装 apt 依赖（几分钟，取决于网速）"
sdo apt-get update -y
sdo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  wine wine32 winetricks \
  xserver-xorg xserver-xorg-video-intel xinit \
  openbox picom x11vnc novnc websockify \
  mesa-utils x11-xserver-utils \
  libgl1:i386 libglx0:i386 libgl1-mesa-dri:i386 \
  mesa-vulkan-drivers:i386 libvulkan1:i386 \
  fonts-noto-cjk curl ca-certificates

# ---------------------------- 2. 用户组（GPU 访问） --------------------------
# DXVK 需要访问 /dev/dri/renderD128；组变更要重新登录才生效
id -nG "$USER" | grep -qw video  || { log "加入 video 组";  sdo usermod -aG video "$USER"; }
id -nG "$USER" | grep -qw render || { log "加入 render 组"; sdo usermod -aG render "$USER"; }

# ---------------------------- 3. Wine 前缀（32 位） --------------------------
if [ ! -f "$PREFIX/system.reg" ]; then
  log "创建 32 位 Wine 前缀: $PREFIX（首次约 1-2 分钟）"
  WINEPREFIX="$PREFIX" WINEARCH=win32 wineboot -i >/tmp/wineboot_install.log 2>&1 \
    || die "wineboot 失败，详见 /tmp/wineboot_install.log"
else
  log "Wine 前缀已存在: $PREFIX"
fi
# GTA SA 是 32 位程序，64 位前缀没法用 wine32 跑
if [ -d "$PREFIX/drive_c/windows/syswow64" ]; then
  die "前缀 $PREFIX 是 64 位（存在 syswow64），删除后重跑，或用 --prefix 换新路径"
fi

# ---------------------------- 4. DXVK ----------------------------------------
SYS32="$PREFIX/drive_c/windows/system32"
mkdir -p "$SYS32"
if [ "$DO_DXVK" = 1 ]; then
  if [ -f "$SYS32/d3d9.dll" ] && grep -aq DXVK "$SYS32/d3d9.dll" 2>/dev/null; then
    log "DXVK d3d9.dll 已存在，跳过下载"
  else
    log "下载并安装 DXVK v$DXVK_VER（32 位 DLL）"
    TMP="$(mktemp -d)"
    curl -fL --retry 3 -o "$TMP/dxvk.tar.gz" \
      "https://github.com/doitsujin/dxvk/releases/download/v${DXVK_VER}/dxvk-${DXVK_VER}.tar.gz" \
      || { rm -rf "$TMP"; die "DXVK 下载失败（离线机器可用 --skip-dxvk，之后手动拷 DLL）"; }
    tar -xzf "$TMP/dxvk.tar.gz" -C "$TMP"
    cp -f "$TMP/dxvk-${DXVK_VER}/x32/d3d9.dll"      "$SYS32/"
    cp -f "$TMP/dxvk-${DXVK_VER}/x32/dxgi.dll"      "$SYS32/"
    cp -f "$TMP/dxvk-${DXVK_VER}/x32/d3d10core.dll" "$SYS32/"
    cp -f "$TMP/dxvk-${DXVK_VER}/x32/d3d11.dll"     "$SYS32/"
    rm -rf "$TMP"
  fi
  # dxvk.conf 含关键的 presentInterval=0（无头 Xorg 下不开它游戏会卡死在加载画面）
  if [ -f "$SCRIPT_DIR/dxvk.conf" ]; then
    cp -f "$SCRIPT_DIR/dxvk.conf" "$SYS32/dxvk.conf"
    log "dxvk.conf -> $SYS32/dxvk.conf"
  else
    warn "仓库里没找到 dxvk.conf，游戏可能卡在 1 fps（见 README 踩坑 #1）"
  fi
  # DLL overrides：让 Wine 优先加载 DXVK 的 native 版本（与 DXVK 官方 setup 脚本一致）
  for dll in d3d9 dxgi d3d10core d3d11; do
    WINEPREFIX="$PREFIX" wine reg add "HKCU\\Software\\Wine\\DllOverrides" \
      /v "$dll" /t REG_SZ /d "native,builtin" /f >/dev/null 2>&1
  done
  log "DXVK DLL overrides 已写入注册表"
else
  warn "已跳过 DXVK；游戏将走 Wine 内置 D3D9（无头环境下大概率卡死，见 README 踩坑 #1）"
fi

# ---------------------------- 5. Wine 音频驱动 -------------------------------
# Audio=none 会让引擎弹俄语"未找到声卡"错误框（README 踩坑 #8）
WINEPREFIX="$PREFIX" wine reg add "HKCU\\Software\\Wine\\Drivers" \
  /v Audio /t REG_SZ /d alsa /f >/dev/null 2>&1
log "Wine 音频驱动 = alsa"

# ---------------------------- 6. ALSA dmix 软件混音 --------------------------
# hw:0,0 是独占设备；CLEO/mod 的 bass.dll 会独占它导致游戏崩溃（README 踩坑 #9）
if sdo test -f /etc/asound.conf && sdo grep -q dmixer /etc/asound.conf; then
  log "/etc/asound.conf 已配置 dmix"
else
  log "写入 /etc/asound.conf（dmix，默认 hw:0,0；多声卡机器请核对 aplay -l）"
  sdo tee /etc/asound.conf >/dev/null <<'EOF'
pcm.!default {
    type plug
    slave.pcm "dmixer"
}
pcm.dmixer {
    type dmix
    ipc_key 1024
    slave {
        pcm "hw:0,0"
        period_time 0
        period_size 1024
        buffer_size 4096
        rate 44100
    }
    bindings { 0 0  1 1 }
}
ctl.!default { type hw card 0 }
EOF
fi

# ---------------------------- 7. sudoers NOPASSWD ----------------------------
# start_samp.sh 以 root 启动 Xorg；NOPASSWD 比每次传密码安全
if [ "$DO_SUDOERS" = 1 ]; then
  if sdo test -f /etc/sudoers.d/samp && sdo grep -q "/usr/lib/xorg/Xorg" /etc/sudoers.d/samp; then
    log "sudoers 已配置（/etc/sudoers.d/samp）"
  else
    log "写入 /etc/sudoers.d/samp（NOPASSWD: Xorg + 字体安装）"
    T="$(mktemp)"
    printf '%s ALL=(root) NOPASSWD: /usr/lib/xorg/Xorg\n' "$USER" > "$T"
    printf '%s ALL=(root) NOPASSWD: /usr/bin/apt-get install -y fonts-noto-cjk\n' "$USER" >> "$T"
    sdo visudo -cf "$T" >/dev/null || { rm -f "$T"; die "sudoers 校验失败，未写入"; }
    sdo install -m 0440 "$T" /etc/sudoers.d/samp
    rm -f "$T"
  fi
else
  log "已跳过 sudoers；start_samp.sh 启动 Xorg 时会要密码，或需手动配 NOPASSWD"
fi

# ---------------------------- 8. 游戏目录 ------------------------------------
mkdir -p "$GAME_DIR"
if [ ! -f "$GAME_DIR/gta_sa.exe" ] || [ ! -f "$GAME_DIR/samp.exe" ]; then
  warn "游戏目录缺文件：$GAME_DIR 需放入 gta_sa.exe + samp.exe（含 samp.dll、eax.dll、models/）"
else
  log "游戏目录就绪: $GAME_DIR"
fi

# ---------------------------- done ------------------------------------------
log "==================================================================="
log " 安装完成。剩余一次性手工事项："
log "   1. 重新登录（或重启）使 video/render 组生效"
log "   2. 插上 HDMI 欺骗器（无显示器必需）"
log "   3. 确认游戏文件在: $GAME_DIR"
log "   4. 启动: $SCRIPT_DIR/start_samp.sh <昵称> <服务器IP> <端口>"
log "   5. 浏览器打开: http://<本机IP>:6080/vnc.html"
log "==================================================================="
