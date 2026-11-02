# mi-remote

用小米蓝牙遥控器控制 Mac 上的 **Cursor Agent** 与 **Codex 桌面 App**：
方向选、确认发、按住说话（豆包输入法听写）、一键切换应用与会话。

灵感来自 [fanxeon/mi-ao](https://github.com/fanxeon/mi-ao)。不同点：mi-ao 走遥控器自带麦克风的
BLE ATVV 协议 + 本地 Whisper，本项目走「遥控器本来就是一台 BLE HID 键盘」这条更轻的路，
语音借用豆包输入法（Mac 麦克风拾音）。

## 真机验证结论（2026-11-02）

作者手里的「小米遥控器 2」在 macOS 下报告的身份与 mi-ao 已验证的 2 Pro 完全一致 —
名称 `小米蓝牙语音遥控器`、Vendor `0x2717` / Product `0x32B8`、固件 `2671`，
实测 13 个按键的 HID Usage 与 2 Pro 固件 2671 档案逐一吻合，因此这类遥控器可直接当 HID 设备用。

## 按键表

| 遥控器键 | 动作 | 实现层 |
| --- | --- | --- |
| 方向 上/下/左/右 | 方向键（原生） | HID 原生 |
| 确认 | Return（原生） | HID 原生 |
| 返回 | Delete（⌫，删前一个字） | 守护进程 HID 层合成（该键 Usage `0xF1` 非标准、系统直接丢弃，hidutil 无效） |
| HOME | 跳到 Cursor 并聚焦对话输入框（激活 Cursor + `⌘;`） | hidutil → F20 + 守护进程 |
| 语音（按住） | 豆包听写：按住说话、松手上屏 | hidutil 映射为右 Option（系统实收 `Option+F5`），在豆包里把该组合录为自定义语音快捷键 |
| TV | 在 Cursor ↔ Codex 间切换聚焦（缺失则启动） | hidutil → F16 + 守护进程 |
| 电源 | 跳到 Codex 并聚焦主聊天输入框（激活 Codex + `⌘;`，需在 Codex 设置中把聚焦输入框快捷键设为 `⌘;`） | hidutil → F17 + 守护进程 |
| 音量 + / − | 下一个 / 上一个会话（Cursor：模拟「按住 `⌘⌥`+方向、松开提交」的切换器手势；Codex：`⌘⌥←/→`，均已真机验证） | hidutil → F18/F19 + 守护进程 |
| 菜单 | 系统原生（应用菜单键） | HID 原生 |

> 用哪个 App 就切到哪个 App 操作：所有动作都发给当前聚焦的应用，两边都适用。

## 工作原理

```text
小米遥控器 ──BLE HID──► macOS
  ├─ Layer 1: hidutil 按设备 (VID/PID) 重映射（只影响遥控器，不动 Mac 键盘）
  └─ Layer 2: MiRemote 守护进程 (CGEventTap) 拦截 F16–F19 标记键，执行切应用/切会话
语音键 ─► 右 Option（实测系统收到 Option+F5）─► 豆包输入法全局语音快捷键 ─► Mac 麦克风听写上屏
```

关键实测坑（都有日志证据）：

- `hidutil` 把普通键映射到修饰键时是**叠加**不是替换：映射为右 Command 后系统收到 `Cmd+F5`，会弹出旁白（VoiceOver）确认框。所以语音键改走 `Option+F5` 组合、由豆包录制该组合。
- 标记键不能用 `F14/F15`（macOS 原生亮度键，会话层事件拦截挡不住）；用无系统功能的 `F16–F19`。
- HID 层事件拦截（`cghidEventTap`）有额外权限要求；会话层拦截足够。
- 自签名（未受信任）证书签出的 App 进不了辅助功能授权名单；本项目用 ad-hoc 签名。
  **代价：每次重新编译后，需要在「辅助功能」里删掉旧 MiRemote 再重新添加一次。**
- F 键事件 flags 带 `Fn/nonCoalesced` 位，判断「无修饰键」时只能看 Command/Shift/Option/Control/CapsLock。
- Cursor 的会话列表是 `⌘Tab` 式切换器：`⌘⌥+方向`只移动高亮，**松开修饰键才提交切换**，补回车无效；必须完整合成修饰键的按下/松开（flagsChanged）事件。

## 安装

```bash
./install.sh   # 构建 -> ~/Applications/MiRemote.app + LaunchAgent 登录自启
```

然后手动两步（只需一次）：

1. 系统设置 → 隐私与安全性 → **辅助功能** → 添加 `~/Applications/MiRemote.app` 并开启
   （守护进程拦截 TV/电源/音量标记键并合成快捷键需要它；日志在 `~/Library/Logs/mi-remote.log`，
   出现 `event tap ready` 即 OK）。
2. 豆包输入法设置 → 语音快捷键 → 自定义 → 点录制后**按一下遥控器语音键**
   （录到的应是 `Option+F5`）→ 如有模式选「长按」→ 保存。

input 监控不需要为守护进程单独授权；但如果从终端跑探测工具，需要给终端/Cursor 开输入监控。

## 自定义会话快捷键

编辑 `~/.config/mi-remote/config.json` 后 `launchctl kickstart -k gui/$(id -u)/com.miremote.daemon` 生效，
格式见仓库内示例（keycode 为 macOS 虚拟键码）。

## 卸载

```bash
./uninstall.sh
```

## 已知限制 / TODO

- 语音用的是 Mac 麦克风，不是遥控器自带麦克风（遥控器麦克风需 BLE ATVV + Whisper，即 mi-ao 路线，
  本机硬件身份相同，理论上可再叠加）。
- TV/电源/音量标记键（F16–F19）若从 Mac 键盘按下也会触发相同动作（这几个键日常几乎不用）。
- 方向键目前是方向键模式；原版 mi-ao 的「方向键移动鼠标」模式未实现。
- 每次重新编译需重做一次辅助功能授权（ad-hoc 签名限制）；有 Apple Developer ID 后可消除。
