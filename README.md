# Thaistars Desktop

一隻跟着 [Claude Code](https://claude.com/claude-code) 工作狀態實時變化表情的 macOS 桌面寵物。你打字、Claude 思考、跑工具、等你確認權限、答完一輪……它都會跟着換動作和氣泡文字。

**核心特色是「上傳影片 → AI 自動摳圖」這個素材製作流程**：選一段你喜歡的影片、點一下背景色，AI 自動去背、生成動作幀序列，馬上套用到桌寵身上——不用任何設計軟件、不用剪輯經驗。特別適合**追星用戶**：把愛豆的影片素材摳出來，做成桌寵天天陪你。

> 上傳素材建議：**盡量用綠幕（或藍幕等純色背景）拍攝/尋找的影片**，去背效果最乾淨；一般背景的影片也能用，但摳圖邊緣可能會有雜色殘留，效果因片而異。
>
> 素材/影片版權說明見 [NOTICE.md](NOTICE.md)——用他人拍攝或出鏡的影片前，請自行確認版權/肖像權。

## 功能

- **八種狀態**：思考中 / 工作中 / 等你回話 / 搞定啦 / 空閒中 / 開機畫面 / 關機畫面 / 生日快樂，各自可配一段專屬動作影片
- **DIY 設定面板**：右鍵桌寵 →「DIY 設定…」
  - 上傳影片 → 滴管點選背景色 → 自動去背摳圖 → 即時熱更新，不用重啓
  - 也可以選擇「不去背景」，直接用原始畫面
  - 保留/去除影片原始音效
- **多專案追蹤**：同時開好幾個 Claude Code 對話，底部會列出正在等你回話的專案
- **三語界面**：中文 / English / ไทย，跟着設定即時切換
- **可自訂桌寵名字**，會顯示在氣泡文字前面
- **生日模式**：設定生日月/日後，當天第一次觸發時完整播一輪專屬生日影片，播完自動切回跟隨 Claude Code 狀態的正常動作（同一天不會重播，除非重啓桌寵）
- **靜音切換**：角色圖右下角有個 🔊/🔇 按鈕，點一下切換有沒有聲音，設定會記住
- **關於頁面**：展示作者資訊與產品介紹

## 安裝 / 運行

需要 macOS + Xcode Command Line Tools（提供 `swiftc`）。

```bash
git clone <this-repo-url>
cd thaistars-desktop

# 編譯主程式
swiftc -O _tools/pet.swift -o 寵物本體

# 編譯摳圖工具
swiftc -O _tools/greenframes.swift -o _tools/greenframes
swiftc -O _tools/extract_audio.swift -o _tools/extract_audio

# 啓動
./啓動桌寵.command
```

`frames/` 裏附帶了作者自己用的動作素材（影片來源與版權說明見 [NOTICE.md](NOTICE.md)）。想換成自己的素材，右鍵桌寵打開「DIY 設定」重新上傳影片即可，會直接覆蓋對應狀態的素材。

## 接上 Claude Code 狀態

在 `~/.claude/settings.json` 裏爲以下 hook 事件加上調用 `pet_status.py <event>` 的命令：

| Hook 事件 | 桌寵狀態 |
|---|---|
| `UserPromptSubmit` | thinking |
| `PreToolUse` | working |
| `PostToolUse` | thinking |
| `Notification` / `PermissionRequest` | waiting |
| `Stop` / `SubagentStop` | done |
| （超過 10 分鐘無事件） | idle |

`pet_status.py` 會把狀態寫進 `~/.claude/claude_pet_status.json`，`寵物本體` 每 250ms 輪詢這個檔案。

## 項目結構

```
_tools/pet.swift        主程式（AppKit + SwiftUI 設定面板）
_tools/greenframes.swift 色度鍵去背摳圖工具
_tools/extract_audio.swift 提取影片音軌
pet_status.py            Claude Code hook → 狀態檔案 的轉接腳本
frames/<狀態名>/          每個狀態的動作幀序列（PNG + 可選 sound.m4a）
啓動桌寵.command          啓動腳本
```

## License

程式碼使用 [MIT License](LICENSE)。`frames/` 等資料夾裏的影片衍生素材另見 [NOTICE.md](NOTICE.md)，不受此授權約束。

## 作者

**Peethew** — Vibe coder and photographer based in Thailand.

Threads: [@goodplaylo](https://threads.net/@goodplaylo) · IG: [@pppeethew](https://instagram.com/pppeethew) · Email: pppeethew@gmail.com
