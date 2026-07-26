# Thaistars Desktop

一只跟着 [Claude Code](https://claude.com/claude-code) 工作状态实时变化表情的 macOS 桌面宠物。你打字、Claude 思考、跑工具、等你确认权限、答完一轮……它都会跟着换动作和气泡文字。

动作素材来自你自己上传的影片：选一段影片、点一下背景色，AI 自动去背抠图、生成动作帧序列，马上套用到桌宠身上——不用任何设计软件。

> 素材/影片版权说明见 [NOTICE.md](NOTICE.md)。

## 功能

- **六种状态**：思考中 / 工作中 / 等你回话 / 搞定啦 / 出错了 / 空闲中，各自可配一段专属动作影片
- **DIY 设定面板**：右键桌宠 →「DIY 設定…」
  - 上传影片 → 滴管点选背景色 → 自动去背抠图 → 即时热更新，不用重启
  - 也可以选择「不去背景」，直接用原始画面
  - 保留/去除影片原始音效
- **多专案追踪**：同时开好几个 Claude Code 对话，底部会列出正在等你回话的专案
- **三语界面**：中文 / English / ไทย，跟着设定即时切换
- **可自订桌宠名字**，会显示在气泡文字前面
- **关于页面**：展示作者资讯与产品介绍

## 安装 / 运行

需要 macOS + Xcode Command Line Tools（提供 `swiftc`）。

```bash
git clone <this-repo-url>
cd thaistars-desktop

# 编译主程式
swiftc -O _tools/pet.swift -o 宠物本体

# 编译抠图工具
swiftc -O _tools/greenframes.swift -o _tools/greenframes
swiftc -O _tools/extract_audio.swift -o _tools/extract_audio

# 启动
./启动桌宠.command
```

`frames/` 里附带了作者自己用的动作素材（影片来源与版权说明见 [NOTICE.md](NOTICE.md)）。想换成自己的素材，右键桌宠打开「DIY 設定」重新上传影片即可，会直接覆盖对应状态的素材。

## 接上 Claude Code 状态

在 `~/.claude/settings.json` 里为以下 hook 事件加上调用 `pet_status.py <event>` 的命令：

| Hook 事件 | 桌宠状态 |
|---|---|
| `UserPromptSubmit` | thinking |
| `PreToolUse` | working |
| `PostToolUse` | thinking |
| `Notification` / `PermissionRequest` | waiting |
| `Stop` / `SubagentStop` | done |
| （超过 10 分钟无事件） | idle |

`pet_status.py` 会把状态写进 `~/.claude/claude_pet_status.json`，`宠物本体` 每 250ms 轮询这个档案。

## 项目结构

```
_tools/pet.swift        主程式（AppKit + SwiftUI 设定面板）
_tools/greenframes.swift 色度键去背抠图工具
_tools/extract_audio.swift 提取影片音轨
pet_status.py            Claude Code hook → 状态档案 的转接脚本
frames/<状态名>/          每个状态的动作帧序列（PNG + 可选 sound.m4a）
启动桌宠.command          启动脚本
```

## License

程式码使用 [MIT License](LICENSE)。`frames/` 等资料夹里的影片衍生素材另见 [NOTICE.md](NOTICE.md)，不受此授权约束。

## 作者

**Peethew** — Vibe coder and photographer based in Thailand.

Threads: [@goodplaylo](https://threads.net/@goodplaylo) · IG: [@pppeethew](https://instagram.com/pppeethew) · Email: pppeethew@gmail.com
