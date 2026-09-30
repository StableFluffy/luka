<p align="center">
  <img src="assets/icon.png" width="128" alt="Luka">
</p>

<h1 align="center">Luka</h1>

<p align="center">
  <strong>为 Mac 听到的一切配上实时字幕。</strong><br>
  通话、视频、会议，边听边转写、边翻译，并标出是谁在说话。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-black?style=flat-square" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-6.2-F05138?style=flat-square" alt="Swift 6.2">
  <img src="https://img.shields.io/badge/speech-Soniox%20stt--rt--v5-FF6A3D?style=flat-square" alt="Soniox">
  <a href="../LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT"></a>
</p>

<p align="center">
  <a href="../README.md">English</a> | <a href="README.ko.md">한국어</a> | <b>中文</b>
</p>

<p align="center">
  <img src="assets/hero.png" width="820" alt="Luka 记录窗口与字幕">
</p>

---

## 安装

1. 从 [Releases](../../../releases) 下载 `Luka-<版本>.dmg`，把 **Luka** 拖到 **应用程序**。
2. 打开 Luka。当前版本尚未公证，首次打开会被 macOS 拦下：
   **系统设置 › 隐私与安全性** → 向下滚动 → **仍要打开**。
   或在终端执行一次：`xattr -dr com.apple.quarantine /Applications/Luka.app`
3. 在首个窗口粘贴 [Soniox API 密钥](https://console.soniox.com)。
4. 按 <kbd>⌃</kbd><kbd>⌥</kbd><kbd>N</kbd>，并允许 **系统音频录制**。

需要 macOS 15 或更高版本；在 macOS 26 上使用 Liquid Glass。Soniox 按音频时长计费（[价格](https://soniox.com/pricing)）。

## 字幕

<p align="center">
  <img src="assets/captions.png" width="720" alt="字幕条">
</p>

悬浮在任何应用之上的玻璃字幕，全屏视频也不例外，且从不抢占焦点。
开始收听时出现，结束后淡出；随时可按 <kbd>⌃</kbd><kbd>⌥</kbd><kbd>C</kbd> 隐藏。

| 操作 | 效果 |
| --- | --- |
| 拖动上下边缘 | 调整行数（1–6） |
| 拖动两侧 | 调整宽度 |
| 放到屏幕中央附近 | 自动居中 |
| 鼠标悬停 | 语言、音源、大小、锁定控件 |
| 点击说话人名字 | 重命名，全局即时生效 |
| 锁定 <kbd>⌃</kbd><kbd>⌥</kbd><kbd>L</kbd> | 点击穿透；悬停出现 **解锁** |

## 会话

每次转写都会作为会话出现在侧栏，并自动保存。
点击标题即可改名。用 <kbd>⌘</kbd><kbd>.</kbd> 结束后可 **继续收听**、编辑、或用 <kbd>⇧</kbd><kbd>⌘</kbd><kbd>C</kbd> 复制全部。

同一个人被分成两位说话人？点开名字选择 **与…是同一人**。

## 快捷键

在任意应用中可用：

| 按键 | 操作 |
| --- | --- |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>N</kbd> | 新建转写 |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>R</kbd> | 开始 / 暂停 |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>C</kbd> | 显示 / 隐藏字幕 |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>T</kbd> | 显示 / 隐藏记录 |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>L</kbd> | 锁定 / 解锁字幕 |

在 Luka 中：<kbd>⌘</kbd><kbd>E</kbd> 为正在说话的人命名，<kbd>⌘</kbd><kbd>1</kbd> / <kbd>⌘</kbd><kbd>2</kbd> 切换窗口，<kbd>⌘</kbd><kbd>+</kbd> <kbd>⌘</kbd><kbd>−</kbd> 文字大小，<kbd>⌘</kbd><kbd>↑</kbd> <kbd>⌘</kbd><kbd>↓</kbd> 字幕行数。

## 模式

| 模式 | 用途 |
| --- | --- |
| 翻译 | 任何语言 → 一种语言 |
| 双向 | 对话：双方互译 |
| 转写 | 只记录，不翻译 |

可收听 Mac 音频、麦克风或两者。界面支持 English、한국어、中文。

## 隐私

音频通过 WebSocket 直接从 Mac 发送到 Soniox，没有 Luka 服务器。
API 密钥以 AES-GCM 加密保存在 `~/Library/Application Support/Luka/`，会话以 JSON 文件保存在旁边。

## 从源码构建

```sh
./scripts/build-app.sh --install   # ~/Applications/Luka.app
./scripts/build-app.sh --dmg       # build/Luka-<版本>.dmg
swift test                         # 回放录制的 Soniox 流
```

使用 Xcode 26 / Swift 6.2 构建，可在 macOS 15 及以上运行。

## 许可证

MIT
