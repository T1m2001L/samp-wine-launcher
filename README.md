# samp-wine-launcher

> Run **GTA: San Andreas + SA-MP** on a **headless Linux** server via Wine, and play it
> from any browser through noVNC — with one command.

在**无头 Linux 主机**上用 Wine 跑 GTA: SA + SA-MP，并通过**浏览器（noVNC）**游玩。
专为没有显示器、只有核显 + HDMI 欺骗器的家用 NAS / 小主机设计。

---

## 它解决什么问题

想在 Linux 服务器上玩 SA-MP，通常要自己拼一整套：

```
Wine(32位) + Xorg(无显示器) + 显卡加速 + 音频 + VNC + 中文字体 ...
```

这个项目把这些**封成一个脚本**，并解决了几个非常容易踩的坑（见下方「踩坑记录」）。

**最终效果**：一条命令启动，浏览器打开 `http://<主机>:6080/vnc.html` 就能玩，左下角出现连接进度条 → 进入 3D 世界。

---

## 架构

```
浏览器 ──HTTP──> noVNC (:6080) ──> x11vnc (:5900) ──> Xorg :0
                                                        │
                                          (HDMI 欺骗器 / 核显 → 硬件 GL)
                                                        │
                                          Wine (win32 前缀) ──> gta_sa.exe
                                                        │
                                              DXVK ──> Vulkan (ANV/i915)
```

| 组件 | 作用 |
|---|---|
| `Xorg :0` | 无显示器时的显示服务器（配合 HDMI 欺骗器激活核显） |
| `x11vnc` + `websockify` + `noVNC` | 把 X 桌面变成网页 |
| `picom` | 合成器，避免 VNC 看到黑屏（DRI3 零拷贝 Present 问题） |
| `DXVK` | D3D9 → Vulkan，让游戏走硬件渲染 |
| `Wine` (win32) | 运行 Windows 版 `samp.exe` / `gta_sa.exe` |

---

## 前置条件

### 硬件
- x86_64 主机（**核显** 可用，如 Intel HD/UHD；需要 Vulkan 支持）
- **HDMI 欺骗器**（dummy plug）—— 没有显示器时用它让 Xorg/核显正常工作
- 建议 ≥ 4 GB 内存

### 系统（Debian 12 上验证，其它发行版需自行调整包名）
```bash
# 32 位架构 + Wine
sudo dpkg --add-architecture i386
sudo apt update
sudo apt install -y wine wine32 winetricks \
    xserver-xorg xserver-xorg-video-intel xinit openbox picom \
    x11vnc novnc websockify \
    mesa-utils x11-xserver-utils \
    libgl1:i386 libglx0:i386 libgl1-mesa-dri:i386 mesa-vulkan-drivers:i386 \
    fonts-noto-cjk
```

### Wine 前缀（32 位）
```bash
export WINEARCH=win32
export WINEPREFIX=$HOME/.samp-prefix
winecfg          # 首次会创建前缀
```

### DXVK（硬件渲染，可选但强烈建议）
把 DXVK 的 32 位 DLL 放进前缀：
```bash
cp x32/d3d9.dll x32/dxgi.dll x32/d3d10core.dll x32/d3d11.dll \
   "$WINEPREFIX/drive_c/windows/system32/"
# 并把本仓库的 dxvk.conf 放到同一目录
cp dxvk.conf "$WINEPREFIX/drive_c/windows/system32/dxvk.conf"
```
> ⚠️ 若显卡驱动是 Mesa，请确保 **32 位 Vulkan 驱动** 已装，且用户有
> `/dev/dri/renderD128` 访问权限（加入 `video`、`render` 组）：
> `sudo usermod -aG video,render $USER`

### 游戏文件
把你自己的 GTA: SA（v1.0 US/EU）和 SA-MP 客户端放进一个目录，例如
`~/GTA San Andreas/`，其中应包含 `gta_sa.exe`、`samp.exe`、`samp.dll`。

---

## 用法

```bash
# 直接进游戏（默认 CLI 直连）
./start_samp.sh <昵称> <服务器IP或域名> <端口>

# 例：
./start_samp.sh Player_One 1.2.3.4 7777
./start_samp.sh Player_One play.example.com 7777

# 打开 SA-MP 自带的连接窗口（手动选服）
./start_samp.sh gui
```

启动后浏览器访问：
```
http://<主机IP>:6080/vnc.html        # 无密码
```

### 全部可通过环境变量覆盖

| 变量 | 默认值 | 说明 |
|---|---|---|
| `SAMP_NICK` / `SAMP_HOST` / `SAMP_PORT` | `Player` / `127.0.0.1` / `7777` | 也可用位置参数 |
| `SAMP_MODE` | `cli` | `cli` 或 `gui` |
| `SAMP_WINEPREFIX` | `$HOME/.samp-prefix` | Wine 前缀路径 |
| `SAMP_GAME_DIR` | `$HOME/GTA San Andreas` | 游戏目录 |
| `SAMP_RESOLUTION` | `800x600` | 虚拟桌面分辨率 |
| `SAMP_VNC_PORT` / `SAMP_NOVNC_PORT` | `5900` / `6080` | VNC / 网页端口 |
| `SAMP_SUDO_PASS` | (空) | 非交互 sudo 用；**推荐改用 sudoers NOPASSWD** |

### 关于 sudo

脚本需要 root 权限启动 Xorg。推荐配置 **NOPASSWD**（比传密码安全）：
```
# /etc/sudoers.d/samp  (用 visudo -f 编辑)
youruser ALL=(root) NOPASSWD: /usr/lib/xorg/Xorg
youruser ALL=(root) NOPASSWD: /usr/bin/apt-get install -y fonts-noto-cjk
```

---

## SA-MP 命令行规则（反直觉，实测确认）

SA-MP 的 CLI 参数**不是** `-h/-p/-n` 那种常规风格：

| 规则 | 说明 |
|---|---|
| ① **第一个参数必须是 `IP:PORT`** | `samp.exe 1.2.3.4:7777`。写成 `-h 1.2.3.4` 会解析失败，游戏只连 `:7777`（无效地址） |
| ② **昵称不能走命令行** | `-n` 无效。昵称从注册表读：`HKCU\Software\SAMP\PlayerName` |
| ③ **`-c` 必需** | 表示"空 RCON 密码"，漏了不工作 |
| ④ **只认 IPv4** | 域名要先解析成 IP（脚本已自动处理） |

等价命令：
```bash
wine reg add "HKCU\\Software\\SAMP" /v PlayerName /t REG_SZ /d "MyNick" /f
wine explorer /desktop=gtasa,800x600 samp.exe 1.2.3.4:7777 -c
```

---

## 踩坑记录（Troubleshooting）

这些是实际调试中踩到的，供参考：

**1. 画面定格在 1 fps / 一直卡在启动画面，进度条永不出现**
→ DXVK 默认用 `VK_PRESENT_MODE_FIFO_KHR`（垂直同步），在无头 Xorg 下 Present 会**永久阻塞**在主线程。
解决：`dxvk.conf` 里 `d3d9.presentInterval = 0`（仓库已附带）。

**2. VNC 里看到黑屏，但游戏其实在渲染**
→ DRI3 零拷贝 Present。解决：装一个合成器（`picom --backend glx`）。

**3. 一改分辨率就崩 (`NtUserChangeDisplaySettings` → `free(): invalid pointer`)**
→ 用 **Wine 虚拟桌面** 绕开：`wine explorer /desktop=gtasa,800x600 ...`。

**4. 游戏数值/文字全是乱码**
→ SA-MP 服务器文本是 **GBK**。需要：装 CJK 字体 + 字体替换 + 用
`LANG=zh_CN.GBK` 启动 Wine（ANSI 代码页 936）。

**5. `DxvkMemoryAllocator: Memory allocation failed`**
→ 32 位 Mesa 的 ANV 缺陷。升级 Mesa（Debian 12 用 backports 的 25.x），
并确认用户可以访问 `/dev/dri/renderD128`（`video`/`render` 组）。

**6. 报 `Unacceptable NickName`（但昵称明明合法）**
→ **很可能是同一账号已在别处登录**（SA-MP 会踢掉重复登录），
不一定是字符问题。先在其它设备退出，再试。

**7. 基础游戏直接崩溃**
→ 某些 SA-MP 整合包自带一个 ~2.8 MB 的 `version.dll` 代理/加载器会崩基础游戏。
重命名掉即可（脚本已自动处理）。

**8. 启动即弹 "Grand Theft Auto SA" 错误框（俄语乱码），游戏卡住不进主界面**
→ 引擎检测不到声卡。原文是 CP1251 俄语"未找到已安装的声卡"，因 Wine 的 ANSI
代码页不是 1251 而显示成乱码（可从进程内存还原确认）。最常见原因：
音频驱动被设成 `none`（见第 9 条的踩坑来历）。修复：
```bash
wine reg add "HKCU\\Software\\Wine\\Drivers" /v Audio /t REG_SZ /d alsa /f
```

**9. 装了 CLEO4 / SAMPFUNCS / MoonLoader 的客户端进服后 SA-MP 崩溃
`Exception At Address: 0x004DD5A3`（干净客户端正常）**
→ ALSA 的 `hw:0,0` 是**独占设备**：mod 的音频库（CLEO 的 bass.dll/SoundSystem）
先初始化并占住声卡，游戏引擎随后创建 DirectSound 失败，
`AUDIO\CONFIG\EVENTVOL.DAT` 的音量表指针保持 NULL，播放音效即崩。
Windows 没有这个问题（系统层共享混音）。
解决：`/etc/asound.conf` 用 **dmix** 软件混音让多方共享声卡：
```
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
```
注意别把音频设成 `none` 来绕：会换成第 8 条的声卡错误框。
另：整合包里的 `eax.dll` 是 gta_sa.exe 按序号**静态导入**的必需依赖，
删掉/改名会导致 `err:module:import_dll ... c0000135`，游戏根本起不来。

---

## 已知限制

- 仅在 **Debian 12 + Wine 8.0(win32) + Intel 核显 + Mesa 25 + DXVK 2.4** 上验证过。
  其它发行版/显卡（AMD、NVIDIA）理论可行，但需自行调整。
- **open.mp 客户端不推荐**：其 launcher 的 CLI 模式会让 `omp-client` 反复重连
  Tauri IPC（`reconnect to Tauri... connect() failed`），本项目因此专注原生 SA-MP。
- 需要 **HDMI 欺骗器**（或接一台真显示器），否则核显/Xorg 可能起不来。
- 游戏文件、SA-MP 客户端、GTA: SA 版权均**不包含**在本仓库内，请自备。
- VNC **默认无密码**，请只在可信局域网内使用；公网请自行加认证（如反向代理 + Basic Auth / TLS）。

---

## 许可

[MIT](LICENSE) —— 仅供参考学习，请遵守游戏及 SA-MP 的授权条款。
