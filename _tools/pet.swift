import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Claude Code 桌寵（原生版）：透明置頂窗口 + PNG幀動畫 + 狀態氣泡
// 狀態來自 ~/.claude/claude_pet_status.json（hooks 寫入）

let FRAME_MS = 83.0 / 1000.0    // ~12fps
let POLL_S = 0.25
let STALE_SEC = 600.0           // 單個專案超過這麼久沒動靜（10分鐘）→ 該專案視爲 idle
let LIST_STALE_SEC = 1800.0     // 超過這麼久沒動靜 → 該專案從清單消失（視爲已結束）
let MAX_ROWS = 6
let ROW_H: CGFloat = 15
let LIST_H = CGFloat(MAX_ROWS) * ROW_H + 8
let BUBBLE_H: CGFloat = 30
// 狀態優先級：多專案並存時，桌寵本人的動作/聲音跟這個順序裏最靠前的走
let PRIORITY: [String] = ["waiting", "working", "thinking", "error", "done", "idle"]

struct ProjectRow { let name: String; let status: String }

struct StateStyle { let badge: String; let text: String; let dot: NSColor }
let STATES: [String: StateStyle] = [
    "idle":     .init(badge: "😴", text: "Idle",     dot: NSColor(red: 0.54, green: 0.56, blue: 0.60, alpha: 1)),
    "thinking": .init(badge: "🤔", text: "Thinking", dot: NSColor(red: 0.36, green: 0.55, blue: 0.94, alpha: 1)),
    "working":  .init(badge: "🛠️", text: "Working",  dot: NSColor(red: 0.94, green: 0.63, blue: 0.13, alpha: 1)),
    "waiting":  .init(badge: "🙋", text: "Waiting for you!", dot: NSColor(red: 0.88, green: 0.27, blue: 0.48, alpha: 1)),
    "done":     .init(badge: "✨", text: "Done",      dot: NSColor(red: 0.18, green: 0.76, blue: 0.42, alpha: 1)),
    "error":    .init(badge: "😵", text: "Error",     dot: NSColor(red: 0.88, green: 0.27, blue: 0.48, alpha: 1)),
    "boot":     .init(badge: "🍵", text: "Ready",     dot: NSColor(red: 0.54, green: 0.56, blue: 0.60, alpha: 1)),
]

// ============ 語言 / 在地化 ============

enum Lang: String, CaseIterable, Identifiable, Hashable {
    case zh, en, th
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        case .th: return "ไทย"
        }
    }
}

// 狀態文字的三語版本；badge/dot 沿用 STATES，找不到就退回英文
let STATE_TEXT: [String: [Lang: String]] = [
    "idle":     [.zh: "空閒中",     .en: "Idle",              .th: "ว่าง"],
    "thinking": [.zh: "思考中",     .en: "Thinking",          .th: "กำลังคิด"],
    "working":  [.zh: "工作中",     .en: "Working",           .th: "กำลังทำงาน"],
    "waiting":  [.zh: "等你回話！", .en: "Waiting for you!",  .th: "รอคุณตอบ!"],
    "done":     [.zh: "搞定啦",     .en: "Done",              .th: "เสร็จแล้ว"],
    "error":    [.zh: "出錯了",     .en: "Error",             .th: "ผิดพลาด"],
    "boot":     [.zh: "待命中",     .en: "Ready",             .th: "พร้อม"],
]

func stateText(_ key: String, _ lang: Lang) -> String {
    STATE_TEXT[key]?[lang] ?? STATE_TEXT[key]?[.en] ?? STATES[key]?.text ?? key
}
func stateLabel(_ key: String, _ lang: Lang) -> String {
    "\(STATES[key]?.badge ?? "") \(stateText(key, lang))"
}

enum L {
    static let table: [String: [Lang: String]] = [
        "menu.settings": [.zh: "DIY 設定…", .en: "DIY Settings…", .th: "ตั้งค่า DIY…"],
        "menu.quit": [.zh: "退出桌寵", .en: "Quit Pet", .th: "ออกจากโปรแกรม"],

        "settings.title": [.zh: "桌寵 DIY 設定", .en: "Pet DIY Settings", .th: "ตั้งค่า DIY สัตว์เลี้ยง"],
        "settings.tab.actions": [.zh: "動作", .en: "Actions", .th: "ท่าทาง"],
        "settings.tab.general": [.zh: "一般設定", .en: "General", .th: "ทั่วไป"],
        "settings.tab.about": [.zh: "關於", .en: "About", .th: "เกี่ยวกับ"],

        "actions.subtitle": [
            .zh: "為每個狀態上傳一段影片，點選背景色後會自動去背、抓出動作，馬上套用到桌寵身上。",
            .en: "Upload a video for each state. Pick the background color and it'll auto key it out and apply right away.",
            .th: "อัปโหลดวิดีโอให้แต่ละสถานะ เลือกสีพื้นหลังแล้วระบบจะลบพื้นหลังและนำไปใช้ทันที",
        ],
        "actions.hideWindow": [.zh: "隱藏視窗", .en: "Hide Window", .th: "ซ่อนหน้าต่าง"],
        "row.noAsset": [.zh: "尚未設定，套用預設站姿", .en: "Not set yet, using default pose", .th: "ยังไม่ได้ตั้งค่า ใช้ท่ายืนพื้นฐาน"],
        "row.frames": [.zh: "幀", .en: "frames", .th: "เฟรม"],
        "row.hasSound": [.zh: "有聲音", .en: "has sound", .th: "มีเสียง"],
        "row.keepSound": [.zh: "保留聲音", .en: "Keep sound", .th: "เก็บเสียง"],
        "row.removeBackground": [.zh: "去背景", .en: "Remove background", .th: "ลบพื้นหลัง"],
        "row.upload": [.zh: "上傳影片…", .en: "Upload video…", .th: "อัปโหลดวิดีโอ…"],
        "row.noThumb": [.zh: "無", .en: "None", .th: "ไม่มี"],

        "upload.reading": [.zh: "讀取畫面中…", .en: "Reading video…", .th: "กำลังอ่านวิดีโอ…"],
        "upload.readFail": [.zh: "讀取影片失敗", .en: "Failed to read video", .th: "อ่านวิดีโอไม่สำเร็จ"],
        "upload.pickColor": [.zh: "請點選背景色", .en: "Please pick the background color", .th: "กรุณาเลือกสีพื้นหลัง"],
        "upload.titleZh": [.zh: "選擇「%@」要用的影片", .en: "選擇「%@」要用的影片", .th: "選擇「%@」要用的影片"],

        "process.processing": [.zh: "摳圖處理中…", .en: "Removing background…", .th: "กำลังลบพื้นหลัง…"],
        "process.fail": [.zh: "摳圖失敗", .en: "Background removal failed", .th: "ลบพื้นหลังไม่สำเร็จ"],
        "process.noContent": [.zh: "沒摳到內容，換張影片試試", .en: "Nothing extracted, try another video", .th: "ไม่พบเนื้อหา ลองวิดีโออื่น"],
        "process.done": [.zh: "已更新 ✓ 桌寵已即時套用", .en: "Updated ✓ applied instantly", .th: "อัปเดตแล้ว ✓ นำไปใช้ทันที"],

        "colorpick.title": [.zh: "點選背景色", .en: "Pick Background Color", .th: "เลือกสีพื้นหลัง"],
        "colorpick.instructions": [
            .zh: "點下方按鈕，再點畫面裡的背景（建議綠幕/藍幕等純色背景效果最好）",
            .en: "Click the button below, then click the background in the image (a solid green/blue screen works best)",
            .th: "กดปุ่มด้านล่าง แล้วคลิกพื้นหลังในภาพ (พื้นหลังสีเขียว/น้ำเงินล้วนจะได้ผลดีที่สุด)",
        ],
        "colorpick.button": [.zh: "🎨 選取背景色", .en: "🎨 Pick Color", .th: "🎨 เลือกสี"],
        "colorpick.cancelled": [.zh: "已取消", .en: "Cancelled", .th: "ยกเลิกแล้ว"],

        "settings.name.label": [.zh: "桌寵名字", .en: "Pet Name", .th: "ชื่อสัตว์เลี้ยง"],
        "settings.name.placeholder": [.zh: "輸入名字…", .en: "Enter a name…", .th: "ใส่ชื่อ…"],
        "settings.lang.label": [.zh: "語言", .en: "Language", .th: "ภาษา"],
        "settings.save": [.zh: "保存", .en: "Save", .th: "บันทึก"],
        "settings.saved": [.zh: "✓ 已儲存", .en: "✓ Saved", .th: "✓ บันทึกแล้ว"],

        "settings.about.designer": [.zh: "設計者", .en: "Designer", .th: "ผู้ออกแบบ"],
        "settings.about.designer.placeholder": [.zh: "輸入設計者資訊…", .en: "Enter designer info…", .th: "ใส่ข้อมูลผู้ออกแบบ…"],
        "settings.about.intro": [.zh: "產品介紹", .en: "About This App", .th: "เกี่ยวกับแอปนี้"],
        "settings.about.intro.placeholder": [.zh: "輸入產品介紹…", .en: "Enter app introduction…", .th: "ใส่คำแนะนำแอป…"],
    ]
    static func t(_ key: String, _ lang: Lang) -> String {
        table[key]?[lang] ?? table[key]?[.en] ?? key
    }
    static func uploadTitle(_ label: String, _ lang: Lang) -> String {
        switch lang {
        case .zh: return "選擇「\(label)」要用的影片"
        case .en: return "Choose a video for \(label)"
        case .th: return "เลือกวิดีโอสำหรับ \(label)"
        }
    }
}

// ============ 桌寵全局設定：名字 / 語言 / 關於（持久化到 UserDefaults） ============

final class AppSettings: ObservableObject {
    @Published var lang: Lang { didSet { UserDefaults.standard.set(lang.rawValue, forKey: "petLang") } }
    @Published var petName: String { didSet { UserDefaults.standard.set(petName, forKey: "petName") } }
    @Published var aboutDesignerName: String { didSet { UserDefaults.standard.set(aboutDesignerName, forKey: "petAboutDesignerName") } }
    // 設計者簡介／產品介紹按語言分開存，跟着 lang 切換顯示
    @Published var aboutDesignerZh: String { didSet { UserDefaults.standard.set(aboutDesignerZh, forKey: "petAboutDesignerZh") } }
    @Published var aboutDesignerEn: String { didSet { UserDefaults.standard.set(aboutDesignerEn, forKey: "petAboutDesignerEn") } }
    @Published var aboutDesignerTh: String { didSet { UserDefaults.standard.set(aboutDesignerTh, forKey: "petAboutDesignerTh") } }
    @Published var aboutIntroZh: String { didSet { UserDefaults.standard.set(aboutIntroZh, forKey: "petAboutIntroZh") } }
    @Published var aboutIntroEn: String { didSet { UserDefaults.standard.set(aboutIntroEn, forKey: "petAboutIntroEn") } }
    @Published var aboutIntroTh: String { didSet { UserDefaults.standard.set(aboutIntroTh, forKey: "petAboutIntroTh") } }

    func aboutDesigner(_ lang: Lang) -> String {
        switch lang { case .zh: return aboutDesignerZh; case .en: return aboutDesignerEn; case .th: return aboutDesignerTh }
    }
    func aboutIntro(_ lang: Lang) -> String {
        switch lang { case .zh: return aboutIntroZh; case .en: return aboutIntroEn; case .th: return aboutIntroTh }
    }

    init() {
        let d = UserDefaults.standard
        lang = Lang(rawValue: d.string(forKey: "petLang") ?? "") ?? .zh
        petName = d.string(forKey: "petName") ?? ""
        aboutDesignerName = d.string(forKey: "petAboutDesignerName") ?? ""
        aboutDesignerZh = d.string(forKey: "petAboutDesignerZh") ?? ""
        aboutDesignerEn = d.string(forKey: "petAboutDesignerEn") ?? ""
        aboutDesignerTh = d.string(forKey: "petAboutDesignerTh") ?? ""
        aboutIntroZh = d.string(forKey: "petAboutIntroZh") ?? ""
        aboutIntroEn = d.string(forKey: "petAboutIntroEn") ?? ""
        aboutIntroTh = d.string(forKey: "petAboutIntroTh") ?? ""
    }
}

final class PetView: NSView {
    var frames: [NSImage] = []      // 當前狀態的動作幀組
    var fi = 0
    var animate = true              // 該組是否循環播放（靜止姿勢=false）
    var badge = "🍵", label = "Ready"
    var name = ""                   // 桌寵名字，氣泡文字前面
    var dot = STATES["boot"]!.dot
    var rows: [ProjectRow] = []     // 專案清單（最多 MAX_ROWS 條）
    var onOpenSettings: (() -> Void)?
    var settings: AppSettings!

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // 先清成全透明，避免上一幀的像素殘留造成殘影
        NSGraphicsContext.current?.cgContext.clear(bounds)

        // 專案清單（窗口最底部，固定預留區域，不足則留白）
        let bw = bounds.width - 24
        if !rows.isEmpty {
            // 深色底板：不管桌面背景是黑是白，文字對比度都固定，不用偵測桌面顏色
            let panelH = CGFloat(min(rows.count, MAX_ROWS)) * ROW_H + 6
            let panel = NSBezierPath(roundedRect: NSRect(x: 12, y: LIST_H - panelH, width: bw, height: panelH),
                                     xRadius: 8, yRadius: 8)
            NSColor(red: 0.125, green: 0.137, blue: 0.165, alpha: 0.85).setFill()
            panel.fill()
        }
        for (i, row) in rows.prefix(MAX_ROWS).enumerated() {
            let st = STATES[row.status] ?? STATES["idle"]!
            let y = LIST_H - CGFloat(i + 1) * ROW_H
            let isWaiting = row.status == "waiting"
            let dotPath = NSBezierPath(ovalIn: NSRect(x: 14, y: y + 4, width: 7, height: 7))
            st.dot.setFill(); dotPath.fill()
            let text = "\(row.name)  \(st.badge)" as NSString
            let color = isWaiting
                ? NSColor(red: 1.0, green: 0.55, blue: 0.70, alpha: 1)
                : NSColor(white: 1, alpha: 0.62)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5, weight: isWaiting ? .bold : .regular),
                .foregroundColor: color,
            ]
            text.draw(at: NSPoint(x: 26, y: y + 2), withAttributes: attrs)
        }

        guard !frames.isEmpty else { return }
        let img = frames[fi]
        let iw = img.size.width, ih = img.size.height
        // 人物（頂部對齊居中，位於清單+氣泡之上）
        let x = (bounds.width - iw) / 2
        img.draw(in: NSRect(x: x, y: LIST_H + BUBBLE_H, width: iw, height: ih))
        // 氣泡（清單正上方）
        let bubble = NSBezierPath(roundedRect: NSRect(x: 12, y: LIST_H + 2, width: bw, height: 24), xRadius: 12, yRadius: 12)
        NSColor(red: 0.125, green: 0.137, blue: 0.165, alpha: 0.95).setFill()
        bubble.fill()
        // 圓點
        let dotPath = NSBezierPath(ovalIn: NSRect(x: 22, y: LIST_H + 9, width: 10, height: 10))
        dot.setFill(); dotPath.fill()
        // 文字：名字（若有）+ badge + 狀態文字
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let namePrefix = name.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "\(name) · "
        let str = "\(namePrefix)\(badge) \(label)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor(red: 0.94, green: 0.95, blue: 0.96, alpha: 1),
            .paragraphStyle: para,
        ]
        str.draw(in: NSRect(x: 34, y: LIST_H + 5, width: bw - 44, height: 18), withAttributes: attrs)
    }

    // 右鍵菜單：DIY 設定 / 退出
    override func rightMouseDown(with event: NSEvent) {
        let lang = settings?.lang ?? .zh
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: L.t("menu.settings", lang), action: #selector(openSettingsClicked), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: L.t("menu.quit", lang), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc func openSettingsClicked() { onOpenSettings?() }
    // 雙擊 → 切回 Claude App
    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            NSWorkspace.shared.launchApplication(
                withBundleIdentifier: "com.anthropic.claudefordesktop",
                options: [.default], additionalEventParamDescriptor: nil, launchIdentifier: nil)
        }
        super.mouseUp(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { NSApp.terminate(nil) }  // Esc
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: PetView!
    let statusPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/claude_pet_status.json")

    var projectBase: URL!    // 項目根目錄（frames/、_tools/ 所在處）
    var framesDir: URL { projectBase.appendingPathComponent("frames") }
    var groups: [String: [NSImage]] = [:]   // 狀態名 → 動作幀組
    var sounds: [String: AVAudioPlayer] = [:]  // 狀態名 → 音效
    var curGroup = ""
    var settingsWC: SettingsWindowController?
    let settings = AppSettings()
    var cancellables = Set<AnyCancellable>()

    func loadFrames(_ dir: URL) -> [NSImage] {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".png") }.sorted()
        return files.compactMap { NSImage(contentsOfFile: dir.appendingPathComponent($0).path) }
    }

    func loadSound(_ dir: URL) -> AVAudioPlayer? {
        for ext in ["m4a", "wav", "mp3", "aiff"] {
            let f = dir.appendingPathComponent("sound.\(ext)")
            if FileManager.default.fileExists(atPath: f.path),
               let p = try? AVAudioPlayer(contentsOf: f) { p.prepareToPlay(); return p }
        }
        return nil
    }

    // 掃描 frames/ 目錄重建 groups/sounds，可在 DIY 上傳新素材後熱重載，不用重啓整個程序
    @discardableResult
    func reloadFrames() -> Bool {
        var newGroups: [String: [NSImage]] = [:]
        var newSounds: [String: AVAudioPlayer] = [:]
        let fm = FileManager.default
        for entry in ((try? fm.contentsOfDirectory(atPath: framesDir.path)) ?? []) {
            var isDir: ObjCBool = false
            let sub = framesDir.appendingPathComponent(entry)
            if fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue {
                let f = loadFrames(sub)
                if !f.isEmpty { newGroups[entry] = f }
                if let s = loadSound(sub) { newSounds[entry] = s }
            }
        }
        let loose = loadFrames(framesDir)
        if !loose.isEmpty { newGroups["default"] = loose }
        guard (newGroups["working"] ?? newGroups["default"] ?? newGroups.values.first)?.first != nil else {
            return false
        }
        groups = newGroups
        sounds = newSounds
        FileHandle.standardError.write("Action groups / 動作組: \(groups.keys.sorted())  Sounds / 音效: \(sounds.keys.sorted())\n".data(using: .utf8)!)
        curGroup = ""   // 強制下一次 pollStatus 重新套用當前狀態的（可能是新的）素材
        if view != nil { pollStatus() }   // 首次啓動時 view 還沒建立，跳過；DIY 熱重載時才需要立刻套用
        return true
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        projectBase = URL(fileURLWithPath: CommandLine.arguments.count > 1
                          ? CommandLine.arguments[1]
                          : FileManager.default.currentDirectoryPath)
        guard reloadFrames() else {
            FileHandle.standardError.write("No usable PNG found in frames/ / frames/ 裡沒有可用的 PNG\n".data(using: .utf8)!)
            NSApp.terminate(nil); return
        }
        // 窗口取所有動作組的最大尺寸，保證每個動作都放得下
        var maxW: CGFloat = 150, maxH: CGFloat = 0
        for f in groups.values { for img in f {
            maxW = max(maxW, img.size.width); maxH = max(maxH, img.size.height)
        }}
        let W = maxW, H = maxH + BUBBLE_H + LIST_H

        // 屏幕右上角
        let screen = NSScreen.main!.visibleFrame
        let origin = NSPoint(x: screen.maxX - W - 40, y: screen.maxY - H - 60)

        window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: W, height: H)),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating                       // 永遠置頂
        window.hasShadow = false
        window.isMovableByWindowBackground = true       // 按住即拖
        window.collectionBehavior = [.canJoinAllSpaces] // 所有桌面空間可見

        view = PetView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        view.onOpenSettings = { [weak self] in self?.openSettings() }
        view.settings = settings
        view.name = settings.petName
        applyGroup(for: "boot")
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 語言／名字變動 → 立刻刷新氣泡與視窗標題
        settings.$lang.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            self.settingsWC?.window?.title = L.t("settings.title", self.settings.lang)
            self.pollStatus()
            self.view.needsDisplay = true
        }.store(in: &cancellables)
        settings.$petName.sink { [weak self] name in
            self?.view.name = name
            self?.view.needsDisplay = true
        }.store(in: &cancellables)

        // 幀動畫（靜止組不推進）
        Timer.scheduledTimer(withTimeInterval: FRAME_MS, repeats: true) { [weak self] _ in
            guard let self, self.view.animate, self.view.frames.count > 1 else { return }
            self.view.fi = (self.view.fi + 1) % self.view.frames.count
            self.view.needsDisplay = true
        }
        // 狀態輪詢
        Timer.scheduledTimer(withTimeInterval: POLL_S, repeats: true) { [weak self] _ in
            self?.pollStatus()
        }
        pollStatus()
    }

    func openSettings() {
        if settingsWC == nil {
            settingsWC = SettingsWindowController(appDelegate: self)
        }
        settingsWC?.show()
    }

    // 狀態 → 動作組：有專屬組就循環播放；沒有就用兜底組第一幀靜止站着
    func applyGroup(for status: String) {
        guard curGroup != status else { return }
        curGroup = status
        if let f = groups[status] {
            view.frames = f; view.animate = true
        } else if let fallback = groups["default"] ?? groups["working"] ?? groups.values.first {
            view.frames = [fallback[0]]; view.animate = false   // 靜止姿勢
        }
        view.fi = 0
        view.needsDisplay = true
        // 進入帶音效的狀態 → 播一聲呼叫
        if let snd = sounds[status] { snd.currentTime = 0; snd.play() }
    }

    func pollStatus() {
        var live: [ProjectRow] = []
        let now = Date().timeIntervalSince1970

        if let data = FileManager.default.contents(atPath: statusPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projects = obj["projects"] as? [String: Any] {
            for (name, v) in projects {
                guard let entry = v as? [String: Any] else { continue }
                let ts = (entry["ts"] as? Double) ?? 0
                if now - ts > LIST_STALE_SEC { continue }   // 太久沒動靜 → 視爲已結束，從清單移除
                var s = (entry["status"] as? String) ?? "idle"
                if s != "waiting", now - ts > STALE_SEC { s = "idle" }
                if STATES[s] == nil { s = "idle" }
                live.append(ProjectRow(name: name, status: s))
            }
        }

        // 排序：等你回話優先，其餘按狀態優先級，再按名稱穩定排序
        live.sort { a, b in
            let ra = PRIORITY.firstIndex(of: a.status) ?? 99
            let rb = PRIORITY.firstIndex(of: b.status) ?? 99
            if ra != rb { return ra < rb }
            return a.name < b.name
        }
        // 底部清單隻留「等你回話」的專案，其餘在跑的任務不列出來
        view.rows = live.filter { $0.status == "waiting" }
        view.needsDisplay = true

        // 桌寵本人跟隨全體專案裏優先級最高的狀態走（waiting 優先）
        let key = PRIORITY.first { p in live.contains { $0.status == p } } ?? "boot"
        let st = STATES[key]!
        let text = stateText(key, settings.lang)
        if view.badge != st.badge || view.label != text {
            view.badge = st.badge; view.label = text; view.dot = st.dot
        }
        applyGroup(for: key)
    }
}

// ============ DIY 設定：上傳影片 → 點選背景色 → 自動摳圖 → 熱更新 ============

let DIY_STATE_KEYS = ["thinking", "working", "waiting", "idle", "done", "error"]

final class StateAssetModel: ObservableObject, Identifiable {
    let key: String
    @Published var thumbnail: NSImage?
    @Published var frameCount: Int = 0
    @Published var hasSound: Bool = false
    @Published var statusText: String = ""
    @Published var isProcessing: Bool = false
    @Published var keepSound: Bool = false
    @Published var removeBackground: Bool = true
    var id: String { key }
    init(key: String) { self.key = key }
}

final class SettingsModel: ObservableObject {
    @Published var rows: [StateAssetModel]
    let settings: AppSettings
    weak var appDelegate: AppDelegate?
    weak var windowController: SettingsWindowController?
    private var settingsBridge: AnyCancellable?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        self.settings = appDelegate.settings
        self.rows = DIY_STATE_KEYS.map { StateAssetModel(key: $0) }
        refreshAll()
        // AppSettings（語言/名字/關於）變動時轉發成自己的變動，讓觀察 model 的畫面（分頁標題、動作列表等）也跟著重繪
        settingsBridge = settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func refreshAll() {
        guard let ad = appDelegate else { return }
        for row in rows {
            let dir = ad.framesDir.appendingPathComponent(row.key)
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.lowercased().hasSuffix(".png") }.sorted()
            row.frameCount = files.count
            row.thumbnail = files.first.flatMap { NSImage(contentsOfFile: dir.appendingPathComponent($0).path) }
            row.hasSound = ["m4a", "wav", "mp3", "aiff"].contains {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent("sound.\($0)").path)
            }
            row.keepSound = row.hasSound
        }
    }

    func hideWindow() { windowController?.hide() }

    func upload(for row: StateAssetModel) {
        let lang = settings.lang
        let panel = NSOpenPanel()
        panel.title = L.uploadTitle(stateLabel(row.key, lang), lang)
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        row.isProcessing = true
        row.statusText = L.t("upload.reading", lang)
        if !row.removeBackground {
            // 不去背景：跳過選色步驟，直接抽幀
            process(row: row, videoURL: url, color: nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            guard let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil) else {
                DispatchQueue.main.async { row.isProcessing = false; row.statusText = L.t("upload.readFail", lang) }
                return
            }
            let preview = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            DispatchQueue.main.async {
                row.isProcessing = false
                row.statusText = L.t("upload.pickColor", lang)
                self?.windowController?.startColorPick(row: row, videoURL: url, previewImage: preview)
            }
        }
    }

    // color 爲 nil 表示不去背景，直接抽幀存原畫面
    func process(row: StateAssetModel, videoURL: URL, color: NSColor?) {
        guard let ad = appDelegate else { return }
        let lang = settings.lang
        row.isProcessing = true
        row.statusText = L.t("process.processing", lang)
        let outDir = ad.framesDir.appendingPathComponent(row.key)
        let keepSound = row.keepSound
        let toolsDir = ad.projectBase.appendingPathComponent("_tools")
        let greenframesBin = toolsDir.appendingPathComponent("greenframes").path
        let extractAudioBin = toolsDir.appendingPathComponent("extract_audio").path

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? FileManager.default.removeItem(at: outDir)
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

            let p = Process()
            p.executableURL = URL(fileURLWithPath: greenframesBin)
            if let color {
                let rgb = color.usingColorSpace(.deviceRGB) ?? color
                let hue = Double(rgb.hueComponent)
                let tol = 0.06
                let hMin = max(0, hue - tol), hMax = min(1, hue + tol)
                p.arguments = [videoURL.path, outDir.path, "15", "300",
                               String(format: "%.4f", hMin), String(format: "%.4f", hMax)]
            } else {
                p.arguments = [videoURL.path, outDir.path, "15", "300", "--nokey"]
            }
            let pipe = Pipe(); p.standardError = pipe; p.standardOutput = pipe
            do { try p.run(); p.waitUntilExit() } catch {
                DispatchQueue.main.async { row.isProcessing = false; row.statusText = L.t("process.fail", lang) }
                return
            }
            guard p.terminationStatus == 0,
                  !((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []).isEmpty else {
                DispatchQueue.main.async { row.isProcessing = false; row.statusText = L.t("process.noContent", lang) }
                return
            }

            if keepSound {
                let a = Process()
                a.executableURL = URL(fileURLWithPath: extractAudioBin)
                a.arguments = [videoURL.path, outDir.appendingPathComponent("sound.m4a").path]
                let pipe2 = Pipe(); a.standardError = pipe2; a.standardOutput = pipe2
                try? a.run(); a.waitUntilExit()
            } else {
                for ext in ["m4a", "wav", "mp3", "aiff"] {
                    try? FileManager.default.removeItem(at: outDir.appendingPathComponent("sound.\(ext)"))
                }
            }

            DispatchQueue.main.async {
                _ = ad.reloadFrames()
                self?.refreshAll()
                row.isProcessing = false
                row.statusText = L.t("process.done", lang)
            }
        }
    }
}

// 讓用戶在影片首幀畫面上用系統滴管點選背景色
final class ColorPickWindowController: NSWindowController {
    var onColorPicked: ((NSColor) -> Void)?
    var onCancel: (() -> Void)?

    init(previewImage: NSImage, lang: Lang) {
        let w: CGFloat = 380
        let ratio = previewImage.size.height / max(1, previewImage.size.width)
        let h = w * ratio
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h + 96),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = L.t("colorpick.title", lang)
        win.center()
        super.init(window: win)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h + 96))
        let imageView = NSImageView(frame: NSRect(x: 0, y: 96, width: w, height: h))
        imageView.image = previewImage
        imageView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(imageView)
        let label = NSTextField(wrappingLabelWithString: L.t("colorpick.instructions", lang))
        label.frame = NSRect(x: 16, y: 46, width: w - 32, height: 40)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        container.addSubview(label)
        let button = NSButton(title: L.t("colorpick.button", lang), target: self, action: #selector(pickColor))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 16, y: 12, width: w - 32, height: 28)
        container.addSubview(button)
        win.contentView = container
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func pickColor() {
        NSColorSampler().show { [weak self] color in
            guard let self else { return }
            if let color {
                self.onColorPicked?(color)
                self.close()
            } else {
                self.onCancel?()
            }
        }
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct StateRowView: View {
    @ObservedObject var row: StateAssetModel
    @ObservedObject var model: SettingsModel
    var body: some View {
        let lang = model.settings.lang
        HStack(spacing: 12) {
            Group {
                if let thumb = row.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.15))
                        .overlay(Text(L.t("row.noThumb", lang)).font(.caption2).foregroundColor(.secondary))
                }
            }
            .frame(width: 46, height: 62)
            .cornerRadius(6)

            VStack(alignment: .leading, spacing: 3) {
                Text(stateLabel(row.key, lang)).font(.system(size: 13, weight: .semibold))
                Text(row.frameCount > 0
                     ? "\(row.frameCount) \(L.t("row.frames", lang))" + (row.hasSound ? " · \(L.t("row.hasSound", lang))" : "")
                     : L.t("row.noAsset", lang))
                    .font(.caption).foregroundColor(.secondary)
                if !row.statusText.isEmpty {
                    Text(row.statusText).font(.caption2).foregroundColor(.accentColor)
                }
                HStack(spacing: 12) {
                    Toggle(L.t("row.removeBackground", lang), isOn: $row.removeBackground).toggleStyle(.checkbox).font(.caption)
                    Toggle(L.t("row.keepSound", lang), isOn: $row.keepSound).toggleStyle(.checkbox).font(.caption)
                }
            }
            Spacer()
            if row.isProcessing {
                ProgressView().scaleEffect(0.7).frame(width: 70)
            } else {
                Button(L.t("row.upload", lang)) { model.upload(for: row) }.font(.caption)
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
    }
}

struct ActionsSettingsView: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        let lang = model.settings.lang
        VStack(alignment: .leading, spacing: 10) {
            Text(L.t("actions.subtitle", lang))
                .font(.caption).foregroundColor(.secondary)
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.rows) { row in
                        StateRowView(row: row, model: model)
                    }
                }
            }
        }
        .padding(16)
        .contextMenu { Button(L.t("actions.hideWindow", lang)) { model.hideWindow() } }
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var draftName: String = ""
    @State private var draftLang: Lang = .zh
    @State private var justSaved = false

    var body: some View {
        let lang = settings.lang
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L.t("settings.name.label", lang)).font(.headline)
                TextField(L.t("settings.name.placeholder", lang), text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L.t("settings.lang.label", lang)).font(.headline)
                Picker("", selection: $draftLang) {
                    ForEach(Lang.allCases) { l in Text(l.displayName).tag(l) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
            Spacer()
            HStack(spacing: 8) {
                Button(L.t("settings.save", lang)) {
                    settings.petName = draftName
                    settings.lang = draftLang
                    justSaved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { justSaved = false }
                }
                .keyboardShortcut(.defaultAction)
                if justSaved {
                    Text(L.t("settings.saved", draftLang)).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .onAppear { draftName = settings.petName; draftLang = settings.lang }
    }
}

struct AboutSettingsView: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        let lang = settings.lang
        let designerText = settings.aboutDesigner(lang)
        let introText = settings.aboutIntro(lang)
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text(L.t("settings.about.designer", lang)).font(.headline)
                        if !settings.aboutDesignerName.isEmpty {
                            Text(settings.aboutDesignerName).font(.headline)
                        }
                    }
                    Text(designerText.isEmpty ? L.t("settings.about.designer.placeholder", lang) : designerText)
                        .font(.system(size: 12))
                        .foregroundColor(designerText.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.t("settings.about.intro", lang)).font(.headline)
                    Text(introText.isEmpty ? L.t("settings.about.intro.placeholder", lang) : introText)
                        .font(.system(size: 12))
                        .foregroundColor(introText.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DIYSettingsView: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        let lang = model.settings.lang
        TabView {
            ActionsSettingsView(model: model)
                .tabItem { Text(L.t("settings.tab.actions", lang)) }
            GeneralSettingsView(settings: model.settings)
                .tabItem { Text(L.t("settings.tab.general", lang)) }
            AboutSettingsView(settings: model.settings)
                .tabItem { Text(L.t("settings.tab.about", lang)) }
        }
        .frame(width: 440, height: 560)
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel
    var colorPickWC: ColorPickWindowController?

    init(appDelegate: AppDelegate) {
        let m = SettingsModel(appDelegate: appDelegate)
        model = m
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        win.title = L.t("settings.title", m.settings.lang)
        win.isReleasedWhenClosed = false
        win.center()
        super.init(window: win)
        m.windowController = self
        win.delegate = self
        win.contentView = NSHostingView(rootView: DIYSettingsView(model: m))
    }
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        model.refreshAll()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func hide() { window?.orderOut(nil) }

    // 點標題欄紅色關閉鈕 = 隱藏，不是真正結束（桌寵本體持續在背景跑）
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func startColorPick(row: StateAssetModel, videoURL: URL, previewImage: NSImage) {
        let wc = ColorPickWindowController(previewImage: previewImage, lang: model.settings.lang)
        colorPickWC = wc
        wc.onColorPicked = { [weak self] color in
            self?.model.process(row: row, videoURL: videoURL, color: color)
        }
        wc.onCancel = { [weak self] in
            row.statusText = L.t("colorpick.cancelled", self?.model.settings.lang ?? .zh)
        }
        wc.show()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 不佔 Dock
let delegate = AppDelegate()
app.delegate = delegate
app.run()
