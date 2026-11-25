import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 2D Dense Bento Grid Packer (4-Column Auto-Flow Dense Layout)

struct BentoVariantSpec: Identifiable, Codable, Equatable {
    var id: String { key }
    let key: String
    let w: Int
    let h: Int
    let title: String
}

struct BentoCanvasEntry: Identifiable, Codable, Equatable {
    var id: String { widgetID.rawValue }
    let widgetID: BentoWidgetID
    var variantKey: String
}

enum BentoCategory: String, CaseIterable, Identifiable {
    case all, hardware, control, toolkit, aiDev, productivity
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部"
        case .hardware: "算力·外设"
        case .control: "声画·开关"
        case .toolkit: "分屏·工具"
        case .aiDev: "AI·端口"
        case .productivity: "日程·媒体"
        }
    }
}

enum BentoWidgetID: String, Codable, CaseIterable, Identifiable {
    case realMac = "w_real_mac"
    case cpuGpu = "w_cpu_gpu"
    case batteryCare = "w_battery_care"
    case bluetooth = "w_bluetooth"
    case network = "w_network"
    case brightVol = "w_bright_vol"
    case appMixer = "w_app_mixer"
    case hideDock = "w_hide_dock"
    case micMute = "w_mic_mute"
    case caffeinate = "w_caffeinate"
    case cleanKeyboard = "w_clean_kb"
    case hideDesktop = "w_hide_desktop"
    case winSnap = "w_win_snap"
    case colorPick = "w_color_pick"
    case pasteClean = "w_paste_clean"
    case trash = "w_trash"
    case aiQuota = "w_ai_quota"
    case devPorts = "w_ports"
    case meeting = "w_meeting"
    case todo = "w_todo"
    case focus = "w_focus"
    case music = "w_music"
    case shelf = "w_shelf"

    var id: String { rawValue }

    var category: BentoCategory {
        switch self {
        case .realMac, .cpuGpu, .batteryCare, .bluetooth, .network: .hardware
        case .brightVol, .appMixer, .hideDock, .micMute, .caffeinate, .cleanKeyboard, .hideDesktop: .control
        case .winSnap, .colorPick, .pasteClean, .trash: .toolkit
        case .aiQuota, .devPorts: .aiDev
        case .meeting, .todo, .focus, .music, .shelf: .productivity
        }
    }

    var title: String {
        switch self {
        case .realMac: "真实本机 · 内存与储存"
        case .cpuGpu: "CPU & GPU 对等双子星"
        case .batteryCare: "电池健康与功率透视"
        case .bluetooth: "蓝牙与外设电量"
        case .network: "实时上下行网速"
        case .brightVol: "屏幕亮度 & 系统音量"
        case .appMixer: "应用独立音量混音台"
        case .hideDock: "自动隐藏 Dock 栏"
        case .micMute: "全局闭麦开关"
        case .caffeinate: "防休眠常亮"
        case .cleanKeyboard: "锁键盘清洁防误触"
        case .hideDesktop: "隐藏桌面图标"
        case .winSnap: "窗口分屏磁贴"
        case .colorPick: "屏幕放大取色器"
        case .pasteClean: "纯文本去追踪净化"
        case .trash: "废纸篓容量透视"
        case .aiQuota: "主流 AI 余量监控"
        case .devPorts: "活跃开发端口释放"
        case .meeting: "合并日程与一键入会"
        case .todo: "随手待办清单"
        case .focus: "番茄专注计时"
        case .music: "音乐播放速控"
        case .shelf: "文件暂存速览"
        }
    }

    var subtitle: String {
        switch self {
        case .realMac: "sysctl + host_statistics64 真实读取"
        case .cpuGpu: "50/50 无主次同图双曲线与双圆环"
        case .batteryCare: "AppleSmartBattery 循环与健康度"
        case .bluetooth: "本机与蓝牙键盘/鼠标/耳机电量"
        case .network: "网卡实时 MB/s 吞吐"
        case .brightVol: "支持水平双滑杆与垂直控制柱"
        case .appMixer: "运行中媒体与会议应用分轨调节"
        case .hideDock: "CoreDock 收起 Dock · 底边悬停弹出"
        case .micMute: "CoreAudio 默认输入一键静音"
        case .caffeinate: "IOPMAssertion 保持屏幕唤醒"
        case .cleanKeyboard: "擦拭键盘时临时屏蔽按键误触"
        case .hideDesktop: "录屏演示一键净空桌面图标"
        case .winSnap: "AXUIElement 左半/右半/居中/铺满"
        case .colorPick: "NSColorSampler 像素取色写入剪贴板"
        case .pasteClean: "剥离富文本样式与链接追踪参数"
        case .trash: "实时统计废纸篓体积与一键查看"
        case .aiQuota: "Cursor / Claude / Codex / DeepSeek"
        case .devPorts: "自动扫描本机监听端口并一键 SIGTERM"
        case .meeting: "本地日历 + Google + 岛内合并排期"
        case .todo: "支持仅岛内或合并本地提醒事项"
        case .focus: "单调时钟防休眠漂移番茄钟"
        case .music: "Apple Music 曲目与播放控制"
        case .shelf: "暂存架文件数量与快捷打开"
        }
    }

    static let switchVariants: [BentoVariantSpec] = [
        BentoVariantSpec(key: "tile_1x1", w: 1, h: 1, title: "方形磁贴 · 1×1"),
        BentoVariantSpec(key: "orb_1x1", w: 1, h: 1, title: "圆钮图标 · 1×1"),
        BentoVariantSpec(key: "pill_2x1", w: 2, h: 1, title: "控制宽胶囊 · 2×1")
    ]

    var variants: [BentoVariantSpec] {
        switch self {
        case .realMac:
            return [
                BentoVariantSpec(key: "banner_4x1", w: 4, h: 1, title: "精雕铭牌通栏 · 4×1"),
                BentoVariantSpec(key: "square_2x2", w: 2, h: 2, title: "工作站大方砖 · 2×2"),
                BentoVariantSpec(key: "bars_2x1", w: 2, h: 1, title: "紧凑双进度条 · 2×1"),
                BentoVariantSpec(key: "rings_2x1", w: 2, h: 1, title: "内存储存双环 · 2×1"),
                BentoVariantSpec(key: "mini_1x1", w: 1, h: 1, title: "芯片微铭牌 · 1×1")
            ]
        case .cpuGpu:
            return [
                BentoVariantSpec(key: "wave_2x1", w: 2, h: 1, title: "同图对等双曲线 · 2×1"),
                BentoVariantSpec(key: "rings_2x1", w: 2, h: 1, title: "双核圆环仪表 · 2×1"),
                BentoVariantSpec(key: "wide_4x1", w: 4, h: 1, title: "全宽双核监测仪 · 4×1")
            ]
        case .batteryCare:
            return [
                BentoVariantSpec(key: "card_2x1", w: 2, h: 1, title: "健康与功率横卡 · 2×1"),
                BentoVariantSpec(key: "ring_1x1", w: 1, h: 1, title: "电量圆环 · 1×1"),
                BentoVariantSpec(key: "square_2x2", w: 2, h: 2, title: "电池透视方砖 · 2×2")
            ]
        case .bluetooth:
            return [
                BentoVariantSpec(key: "rings_2x1", w: 2, h: 1, title: "多设备电量环 · 2×1"),
                BentoVariantSpec(key: "ring_1x1", w: 1, h: 1, title: "单环点按轮换 · 1×1"),
                BentoVariantSpec(key: "bars_2x1", w: 2, h: 1, title: "双列电量条 · 2×1"),
                BentoVariantSpec(key: "square_2x2", w: 2, h: 2, title: "外设详情方砖 · 2×2")
            ]
        case .network:
            return [
                BentoVariantSpec(key: "pill_2x1", w: 2, h: 1, title: "上下行吞吐卡 · 2×1"),
                BentoVariantSpec(key: "mini_1x1", w: 1, h: 1, title: "极简速率 · 1×1")
            ]
        case .brightVol:
            return [
                BentoVariantSpec(key: "capsule_2x1", w: 2, h: 1, title: "水平控制双滑杆 · 2×1"),
                BentoVariantSpec(key: "pillars_1x2", w: 1, h: 2, title: "垂直双控制柱 · 1×2"),
                BentoVariantSpec(key: "wide_4x1", w: 4, h: 1, title: "并排宽幅双推子 · 4×1")
            ]
        case .appMixer:
            return [
                BentoVariantSpec(key: "horiz_2x1", w: 2, h: 1, title: "双应用混音卡 · 2×1"),
                BentoVariantSpec(key: "square_2x2", w: 2, h: 2, title: "多轨混音方砖 · 2×2")
            ]
        case .hideDock, .micMute, .caffeinate, .cleanKeyboard, .hideDesktop, .colorPick, .pasteClean:
            return Self.switchVariants
        case .trash:
            return [
                BentoVariantSpec(key: "tile_1x1", w: 1, h: 1, title: "容量方砖 · 1×1"),
                BentoVariantSpec(key: "pill_2x1", w: 2, h: 1, title: "详情横卡 · 2×1")
            ]
        case .winSnap:
            return [
                BentoVariantSpec(key: "grid_2x1", w: 2, h: 1, title: "四向分屏面板 · 2×1"),
                BentoVariantSpec(key: "mini_1x1", w: 1, h: 1, title: "左右快切 · 1×1"),
                BentoVariantSpec(key: "wide_4x1", w: 4, h: 1, title: "通栏窗口布局器 · 4×1")
            ]
        case .aiQuota:
            return [
                BentoVariantSpec(key: "bars_2x1", w: 2, h: 1, title: "四家余量全显 · 2×1"),
                BentoVariantSpec(key: "ring_1x1", w: 1, h: 1, title: "首选 AI 圆环 · 1×1"),
                BentoVariantSpec(key: "square_2x2", w: 2, h: 2, title: "配额驾驶舱 · 2×2")
            ]
        case .devPorts:
            return [
                BentoVariantSpec(key: "chips_2x1", w: 2, h: 1, title: "端口速杀胶囊 · 2×1"),
                BentoVariantSpec(key: "mini_1x1", w: 1, h: 1, title: "端口计数 · 1×1"),
                BentoVariantSpec(key: "square_2x2", w: 2, h: 2, title: "进程端口列表 · 2×2")
            ]
        case .meeting:
            return [
                BentoVariantSpec(key: "card_2x1", w: 2, h: 1, title: "下场日程入会卡 · 2×1"),
                BentoVariantSpec(key: "mini_1x1", w: 1, h: 1, title: "极简日程 · 1×1"),
                BentoVariantSpec(key: "square_2x2", w: 2, h: 2, title: "全天合并日程 · 2×2")
            ]
        case .todo:
            return [
                BentoVariantSpec(key: "list_2x1", w: 2, h: 1, title: "双条速勾待办 · 2×1"),
                BentoVariantSpec(key: "ring_1x1", w: 1, h: 1, title: "完成度圆环 · 1×1"),
                BentoVariantSpec(key: "square_2x2", w: 2, h: 2, title: "完整清单方砖 · 2×2")
            ]
        case .focus:
            return [
                BentoVariantSpec(key: "card_2x1", w: 2, h: 1, title: "番茄倒计时卡 · 2×1"),
                BentoVariantSpec(key: "mini_1x1", w: 1, h: 1, title: "极简计时 · 1×1")
            ]
        case .music:
            return [
                BentoVariantSpec(key: "card_2x1", w: 2, h: 1, title: "黑胶唱机横卡 · 2×1"),
                BentoVariantSpec(key: "vinyl_1x1", w: 1, h: 1, title: "迷你黑胶 · 1×1")
            ]
        case .shelf:
            return [
                BentoVariantSpec(key: "card_2x1", w: 2, h: 1, title: "暂存文件横卡 · 2×1"),
                BentoVariantSpec(key: "mini_1x1", w: 1, h: 1, title: "暂存计数 · 1×1")
            ]
        }
    }

    func resolveVariant(_ key: String?) -> BentoVariantSpec {
        if let key, let found = variants.first(where: { $0.key == key }) { return found }
        return variants[0]
    }
}

struct PackedBentoPlacement: Identifiable, Equatable {
    let id: String
    let entryIndex: Int
    let entry: BentoCanvasEntry
    let variant: BentoVariantSpec
    let col: Int
    let row: Int
}

struct EmptySlotCoordinate: Identifiable, Equatable {
    var id: String { "\(col)_\(row)" }
    let col: Int
    let row: Int
}

enum BentoGridPacker {
    static func pack(entries: [BentoCanvasEntry], maxCells: Int, columns: Int = 4) -> (placements: [PackedBentoPlacement], empties: [EmptySlotCoordinate], totalRows: Int) {
        let targetRows = max(2, maxCells / max(1, columns))
        var occupied: Set<String> = []
        func key(_ c: Int, _ r: Int) -> String { "\(c)_\(r)" }
        func fits(_ c: Int, _ r: Int, _ w: Int, _ h: Int) -> Bool {
            guard c + w <= columns else { return false }
            for dy in 0..<h {
                for dx in 0..<w {
                    if occupied.contains(key(c + dx, r + dy)) { return false }
                }
            }
            return true
        }

        var placements: [PackedBentoPlacement] = []
        var maxRowUsed = targetRows - 1

        for (idx, entry) in entries.enumerated() {
            let v = entry.widgetID.resolveVariant(entry.variantKey)
            let w = min(columns, max(1, v.w))
            let h = max(1, v.h)
            var placed = false
            var r = 0
            while !placed && r < 24 {
                for c in 0...(columns - w) {
                    if fits(c, r, w, h) {
                        for dy in 0..<h {
                            for dx in 0..<w {
                                occupied.insert(key(c + dx, r + dy))
                            }
                        }
                        maxRowUsed = max(maxRowUsed, r + h - 1)
                        placements.append(PackedBentoPlacement(
                            id: entry.id,
                            entryIndex: idx,
                            entry: entry,
                            variant: BentoVariantSpec(key: v.key, w: w, h: h, title: v.title),
                            col: c,
                            row: r
                        ))
                        placed = true
                        break
                    }
                }
                r += 1
            }
        }

        let totalRows = max(targetRows, maxRowUsed + 1)
        var empties: [EmptySlotCoordinate] = []
        for r in 0..<totalRows {
            for c in 0..<columns {
                if !occupied.contains(key(c, r)) {
                    empties.append(EmptySlotCoordinate(col: c, row: r))
                }
            }
        }
        return (placements, empties, totalRows)
    }
}

// MARK: - Persistent Bento Layout Store

enum CompactShellStyle: String, Codable, CaseIterable, Identifiable {
    case glassPill = "glass_pill"
    case obsidianNotch = "obsidian_notch"
    case hairline = "hairline"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glassPill: "液态玻璃悬浮胶囊"
        case .obsidianNotch: "曜石刘海融合舱"
        case .hairline: "极简静默呼吸线"
        }
    }
    var subtitle: String {
        switch self {
        case .glassPill: "通透折射壁纸高光边"
        case .obsidianNotch: "深邃黑玻与屏幕顶边一体"
        case .hairline: "平时隐形，专注时浮现"
        }
    }
}

enum CompactCapsuleSlot: String, Codable, CaseIterable, Identifiable {
    case cpu, gpu, ram, net, battery, aiQuota, meeting, focus, music
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU 负载"
        case .gpu: "GPU 负载"
        case .ram: "统一内存"
        case .net: "实时网速"
        case .battery: "电量功率"
        case .aiQuota: "首选 AI 余量"
        case .meeting: "下场日程"
        case .focus: "番茄倒计时"
        case .music: "音乐律动"
        }
    }
}

enum IslandTabLabelMode: String, CaseIterable, Identifiable {
    case activeOnly = "active_only"
    case iconsOnly = "icons_only"
    case allLabels = "all_labels"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .activeOnly: "仅当前选中项展开文字"
        case .iconsOnly: "极简纯图标"
        case .allLabels: "全部显示图标+文字"
        }
    }
}

@MainActor final class IslandBentoStore: ObservableObject {
    static let shared = IslandBentoStore()

    @Published var gridMaxCells: Int {
        didSet { defaults.set(gridMaxCells, forKey: Keys.maxCells) }
    }
    @Published var activeCanvas: [BentoCanvasEntry] {
        didSet { persistCanvas() }
    }
    @Published var compactShell: CompactShellStyle {
        didSet { defaults.set(compactShell.rawValue, forKey: Keys.compactShell) }
    }
    @Published var compactSlots: [CompactCapsuleSlot] {
        didSet {
            if let data = try? JSONEncoder().encode(compactSlots) {
                defaults.set(data, forKey: Keys.compactSlots)
            }
        }
    }
    @Published var tabLabelMode: IslandTabLabelMode {
        didSet { defaults.set(tabLabelMode.rawValue, forKey: Keys.tabLabelMode) }
    }
    @Published var selectedCategory: BentoCategory = .all
    @Published var spotlightWidget: BentoWidgetID? = nil

    var onNavigateModule: ((IslandModule) -> Void)?
    var onOpenDIYSettings: (() -> Void)?
    var shelfItemCountProvider: (() -> Int)?
    weak var notesCoordinator: StickyNotesCoordinator?

    private let defaults: UserDefaults
    private enum Keys {
        static let maxCells = "moriq.bento.maxCells.v1"
        static let canvas = "moriq.bento.canvas.v1"
        static let compactShell = "moriq.bento.compactShell.v1"
        static let compactSlots = "moriq.bento.compactSlots.v1"
        static let tabLabelMode = "moriq.bento.tabLabelMode.v1"
    }

    init(defaults: UserDefaults = .standard) {
        let isProductBundle = (try? RuntimeEnvironment.resolve(
            bundleID: Bundle.main.bundleIdentifier ?? "",
            flavor: Bundle.main.object(forInfoDictionaryKey: "MORIQBuildFlavor") as? String
        ))?.mode == .product
        let resolvedDefaults: UserDefaults = (defaults === UserDefaults.standard && !isProductBundle)
            ? (UserDefaults(suiteName: "local.moriq.bento.ephemeral.\(UUID().uuidString)") ?? defaults)
            : defaults
        self.defaults = resolvedDefaults
        let savedMax = resolvedDefaults.integer(forKey: Keys.maxCells)
        self.gridMaxCells = [8, 12, 16].contains(savedMax) ? savedMax : 12
        self.compactShell = CompactShellStyle(rawValue: resolvedDefaults.string(forKey: Keys.compactShell) ?? "") ?? .glassPill
        if let slotData = resolvedDefaults.data(forKey: Keys.compactSlots),
           let decodedSlots = try? JSONDecoder().decode([CompactCapsuleSlot].self, from: slotData), !decodedSlots.isEmpty {
            self.compactSlots = Array(decodedSlots.prefix(3))
        } else {
            self.compactSlots = [.cpu, .gpu]
        }
        self.tabLabelMode = IslandTabLabelMode(rawValue: resolvedDefaults.string(forKey: Keys.tabLabelMode) ?? "") ?? .activeOnly

        if let data = resolvedDefaults.data(forKey: Keys.canvas),
           let decoded = try? JSONDecoder().decode([BentoCanvasEntry].self, from: data), !decoded.isEmpty {
            self.activeCanvas = decoded
        } else {
            self.activeCanvas = [
                BentoCanvasEntry(widgetID: .realMac, variantKey: "banner_4x1"),
                BentoCanvasEntry(widgetID: .cpuGpu, variantKey: "wave_2x1"),
                BentoCanvasEntry(widgetID: .bluetooth, variantKey: "rings_2x1"),
                BentoCanvasEntry(widgetID: .brightVol, variantKey: "capsule_2x1"),
                BentoCanvasEntry(widgetID: .hideDock, variantKey: "tile_1x1"),
                BentoCanvasEntry(widgetID: .micMute, variantKey: "tile_1x1")
            ]
        }
    }

    var usedCells: Int {
        activeCanvas.reduce(0) { sum, item in
            let v = item.widgetID.resolveVariant(item.variantKey)
            return sum + v.w * v.h
        }
    }

    @discardableResult
    func selectOrInsert(widget: BentoWidgetID, variantKey: String, at targetIndex: Int? = nil) -> Bool {
        let variant = widget.resolveVariant(variantKey)
        let needed = variant.w * variant.h
        if let existingIdx = activeCanvas.firstIndex(where: { $0.widgetID == widget }) {
            let currentV = widget.resolveVariant(activeCanvas[existingIdx].variantKey)
            let delta = needed - (currentV.w * currentV.h)
            if usedCells + delta > gridMaxCells {
                SystemTelemetryStore.shared.showToast("画布剩余空间不足，请先切换为 16 格或移除组件")
                return false
            }
            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                activeCanvas[existingIdx].variantKey = variant.key
                if let targetIndex, targetIndex >= 0, targetIndex < activeCanvas.count, targetIndex != existingIdx {
                    let moved = activeCanvas.remove(at: existingIdx)
                    activeCanvas.insert(moved, at: min(targetIndex, activeCanvas.count))
                }
            }
            return true
        } else {
            if usedCells + needed > gridMaxCells {
                SystemTelemetryStore.shared.showToast("画布已满（\(usedCells)/\(gridMaxCells)格），可切换 16 格画布")
                return false
            }
            let entry = BentoCanvasEntry(widgetID: widget, variantKey: variant.key)
            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                if let targetIndex, targetIndex >= 0, targetIndex <= activeCanvas.count {
                    activeCanvas.insert(entry, at: targetIndex)
                } else {
                    activeCanvas.append(entry)
                }
            }
            return true
        }
    }

    func remove(widget: BentoWidgetID) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            activeCanvas.removeAll { $0.widgetID == widget }
            if spotlightWidget == widget { spotlightWidget = nil }
        }
    }

    func move(widget: BentoWidgetID, before target: BentoWidgetID) {
        guard widget != target,
              let from = activeCanvas.firstIndex(where: { $0.widgetID == widget }),
              let to = activeCanvas.firstIndex(where: { $0.widgetID == target }) else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            let item = activeCanvas.remove(at: from)
            activeCanvas.insert(item, at: to)
        }
    }

    func setCapacity(_ cells: Int) {
        guard [8, 12, 16].contains(cells) else { return }
        withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
            gridMaxCells = cells
            while usedCells > gridMaxCells && !activeCanvas.isEmpty {
                activeCanvas.removeLast()
            }
        }
    }

    func toggleCompactSlot(_ slot: CompactCapsuleSlot) {
        if let idx = compactSlots.firstIndex(of: slot) {
            guard compactSlots.count > 1 else {
                SystemTelemetryStore.shared.showToast("至少保留 1 个数据槽（或切换为极简静默呼吸线）")
                return
            }
            compactSlots.remove(at: idx)
        } else {
            guard compactSlots.count < 3 else {
                SystemTelemetryStore.shared.showToast("收起态胶囊最多拼装 3 项，请先点 ✕ 移除一项")
                return
            }
            compactSlots.append(slot)
        }
    }

    func moveCompactSlot(at index: Int, delta: Int) {
        let next = index + delta
        guard compactSlots.indices.contains(index), compactSlots.indices.contains(next) else { return }
        let moved = compactSlots.remove(at: index)
        compactSlots.insert(moved, at: next)
    }

    private func persistCanvas() {
        if let data = try? JSONEncoder().encode(activeCanvas) {
            defaults.set(data, forKey: Keys.canvas)
        }
    }
}

// MARK: - Live Overlapping Dual-Curve CPU & GPU Chart

struct DualPeerWaveformChart: View {
    let cpuHistory: [Double]
    let gpuHistory: [Double]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cpuStroke = LiquidGlassPalette.cpuStroke(scheme)

            ZStack {
                // GPU Area + Curve (Sapphire)
                curvePath(values: gpuHistory, width: w, height: h, closedArea: true)
                    .fill(
                        LinearGradient(
                            colors: [LiquidGlassPalette.sapphire.opacity(0.26), LiquidGlassPalette.sapphire.opacity(0.01)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                curvePath(values: gpuHistory, width: w, height: h, closedArea: false)
                    .stroke(LiquidGlassPalette.sapphire, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

                // CPU Area + Curve (Obsidian / Silver)
                curvePath(values: cpuHistory, width: w, height: h, closedArea: true)
                    .fill(
                        LinearGradient(
                            colors: [cpuStroke.opacity(0.16), cpuStroke.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                curvePath(values: cpuHistory, width: w, height: h, closedArea: false)
                    .stroke(cpuStroke, style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func curvePath(values: [Double], width: CGFloat, height: CGFloat, closedArea: Bool) -> Path {
        var path = Path()
        guard values.count >= 2, width > 2, height > 2 else { return path }
        let pts: [CGPoint] = values.enumerated().map { idx, val in
            let x = CGFloat(idx) / CGFloat(values.count - 1) * width
            let clamped = min(96, max(4, val))
            let y = height - CGFloat(clamped / 100.0) * (height - 4) - 2
            return CGPoint(x: x, y: y)
        }
        path.move(to: pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = pts[i]
            let p1 = pts[i + 1]
            let midX = (p0.x + p1.x) * 0.5
            path.addCurve(to: p1, control1: CGPoint(x: midX, y: p0.y), control2: CGPoint(x: midX, y: p1.y))
        }
        if closedArea {
            path.addLine(to: CGPoint(x: width, y: height))
            path.addLine(to: CGPoint(x: 0, y: height))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Multi-Style Bento Tile View Renderer

struct BentoWidgetTileView: View {
    let entry: BentoCanvasEntry
    var previewOnly: Bool = false
    @ObservedObject private var telemetry = SystemTelemetryStore.shared
    @ObservedObject private var syncHub = MoriqSyncHub.shared
    @ObservedObject private var focusStore = FocusTimerStore.shared
    @ObservedObject private var bentoStore = IslandBentoStore.shared
    @Environment(\.colorScheme) private var scheme

    private var variant: BentoVariantSpec {
        entry.widgetID.resolveVariant(entry.variantKey)
    }

    var body: some View {
        Group {
            switch entry.widgetID {
            case .realMac: realMacView
            case .cpuGpu: cpuGpuView
            case .batteryCare: batteryCareView
            case .bluetooth: bluetoothView
            case .network: networkView
            case .brightVol: brightVolView
            case .appMixer: appMixerView
            case .hideDock:
                switchTile(
                    on: telemetry.dockAutoHidden,
                    symbol: "dock.rectangle",
                    title: "自动藏 Dock",
                    subtitle: telemetry.dockAutoHidden ? "移至底边弹出" : "点击自动收起",
                    badge: telemetry.dockAutoHidden ? "已收起" : "常驻"
                ) { if !previewOnly { telemetry.toggleDockAutoHide() } }
            case .micMute:
                switchTile(
                    on: telemetry.micMuted,
                    symbol: telemetry.micMuted ? "mic.slash.fill" : "mic.fill",
                    title: "全局闭麦",
                    subtitle: telemetry.micMuted ? "麦克风已静音" : "点击一键静音",
                    badge: telemetry.micMuted ? "静音中" : "拾音"
                ) { if !previewOnly { telemetry.toggleMicMute() } }
            case .caffeinate:
                switchTile(
                    on: telemetry.caffeinateActive,
                    symbol: "cup.and.saucer.fill",
                    title: "防休眠常亮",
                    subtitle: telemetry.caffeinateActive ? telemetry.awakeRemainingLabel(active: true, expiresAt: telemetry.displayAwakeExpiresAt, preset: telemetry.displayAwakeDuration) : "点击开启常亮",
                    badge: telemetry.caffeinateActive ? telemetry.displayAwakeDuration.shortTitle : "默认"
                ) { if !previewOnly { telemetry.toggleCaffeinate() } }
            case .cleanKeyboard:
                switchTile(
                    on: false,
                    symbol: "keyboard.badge.ellipsis",
                    title: "锁键盘清洁",
                    subtitle: "擦键盘防乱按",
                    badge: "防误触"
                ) { if !previewOnly { telemetry.setKeyboardCleanLock(true) } }
            case .hideDesktop:
                switchTile(
                    on: telemetry.desktopIconsHidden,
                    symbol: "menubar.dock.rectangle",
                    title: "净空桌面",
                    subtitle: telemetry.desktopIconsHidden ? "图标已隐藏" : "演示隐藏图标",
                    badge: telemetry.desktopIconsHidden ? "已净空" : "正常"
                ) { if !previewOnly { telemetry.toggleDesktopIcons() } }
            case .colorPick:
                switchTile(
                    on: false,
                    symbol: "eyedropper.halffull",
                    title: "屏幕取色",
                    subtitle: telemetry.lastPickedHex,
                    badge: "HEX",
                    swatchHex: telemetry.lastPickedHex
                ) { if !previewOnly { telemetry.pickScreenColor() } }
            case .pasteClean:
                switchTile(
                    on: false,
                    symbol: "sparkles.rectangle.stack",
                    title: "纯文本净化",
                    subtitle: "去样式与追踪码",
                    badge: "净化"
                ) { if !previewOnly { telemetry.scrubClipboardPlainText() } }
            case .trash: trashView
            case .winSnap: winSnapView
            case .aiQuota: aiQuotaView
            case .devPorts: devPortsView
            case .meeting: meetingView
            case .todo: todoView
            case .focus: focusView
            case .music: musicView
            case .shelf: shelfView
            }
        }
        .allowsHitTesting(!previewOnly)
    }

    // MARK: 1. Real Mac Hardware (Machined Die + Dual Recessed Telemetry Pods)

    @ViewBuilder private var realMacView: some View {
        let hw = telemetry.hardware
        let appFrac = max(0.08, (hw.ramUsedGB - hw.ramWiredGB) / max(1, hw.ramTotalGB))
        let wiredFrac = max(0.04, hw.ramWiredGB / max(1, hw.ramTotalGB))
        let usedDiskFrac = max(0.08, (hw.ssdTotalGB - hw.ssdAvailableGB) / max(1, hw.ssdTotalGB))

        switch variant.key {
        case "mini_1x1":
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 2) {
                        Image(systemName: "apple.logo").font(.system(size: 10, weight: .semibold))
                        Text(hw.chipShort).font(.system(size: 10.5, weight: .bold))
                    }
                    Spacer(minLength: 2)
                    Text("\(telemetry.thermalCelsius)°C")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LiquidGlassPalette.sapphire)
                }
                Spacer(minLength: 2)
                VStack(spacing: 3) {
                    HStack {
                        Text("内存").foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                        Spacer()
                        Text("\(Int(hw.ramPercent.rounded()))%").fontWeight(.bold)
                    }
                    HStack {
                        Text("储存").foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                        Spacer()
                        Text("余\(Int(hw.ssdAvailableGB))G").fontWeight(.bold)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
            }
            .padding(11)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile()
            .onTapGesture { bentoStore.onNavigateModule?(.system) }

        case "rings_2x1":
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    AppleRingGauge(percent: hw.ramPercent, size: 36, lineWidth: 3.6, tint: LiquidGlassPalette.sapphire) {
                        Text("\(Int(hw.ramPercent.rounded()))%")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("统一内存").font(.system(size: 9.5)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme)).lineLimit(1)
                        Text(String(format: "%.1f/%.0fG", hw.ramUsedGB, hw.ramTotalGB))
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    AppleRingGauge(percent: hw.ssdUsedPercent, size: 36, lineWidth: 3.6, tint: LiquidGlassPalette.cpuStroke(scheme)) {
                        Text("\(Int(hw.ssdUsedPercent.rounded()))%")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("闪存空间").font(.system(size: 9.5)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme)).lineLimit(1)
                        Text("余\(Int(hw.ssdAvailableGB))G")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile()
            .onTapGesture { bentoStore.onNavigateModule?(.system) }

        case "bars_2x1":
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "apple.logo").font(.system(size: 10.5))
                        Text("\(hw.chipShort) · \(telemetry.displayHostTitle)")
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(String(format: "%.1fW · %d°C", telemetry.powerWatts, telemetry.thermalCelsius))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LiquidGlassPalette.sapphire)
                }
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("内存").foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                            Spacer()
                            Text(String(format: "%.1f/%.0fG", hw.ramUsedGB, hw.ramTotalGB)).fontWeight(.semibold)
                        }.font(.system(size: 10, design: .monospaced)).lineLimit(1)
                        MultiSegmentTelemetryBar(primaryFraction: appFrac, secondaryFraction: wiredFrac)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("储存").foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                            Spacer()
                            Text("余 \(Int(hw.ssdAvailableGB))G").fontWeight(.semibold)
                        }.font(.system(size: 10, design: .monospaced)).lineLimit(1)
                        MultiSegmentTelemetryBar(primaryFraction: usedDiskFrac * 0.65, secondaryFraction: usedDiskFrac * 0.35, primaryColor: LiquidGlassPalette.cpuStroke(scheme), secondaryColor: LiquidGlassPalette.sapphire)
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile()
            .onTapGesture { bentoStore.onNavigateModule?(.system) }

        case "square_2x2":
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    MachinedAppleDieBadge(chipShort: hw.chipShort, coreShort: "\(hw.coreCount)C", size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(telemetry.displayHostTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text("\(hw.modelIdentifier) · macOS \(hw.osVersion)")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                VStack(spacing: 5) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("统一内存").foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                            Spacer()
                            Text(String(format: "%.1f / %.0f GB", hw.ramUsedGB, hw.ramTotalGB)).fontWeight(.bold)
                        }.font(.system(size: 10, design: .monospaced)).lineLimit(1)
                        MultiSegmentTelemetryBar(primaryFraction: appFrac, secondaryFraction: wiredFrac)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6).liquidGlassWell(cornerRadius: 11)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("内置闪存").foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                            Spacer()
                            Text("可用 \(Int(hw.ssdAvailableGB))G / \(hw.ssdTotalDisplay)").fontWeight(.bold)
                        }.font(.system(size: 10, design: .monospaced)).lineLimit(1)
                        MultiSegmentTelemetryBar(primaryFraction: usedDiskFrac * 0.65, secondaryFraction: usedDiskFrac * 0.35, primaryColor: LiquidGlassPalette.cpuStroke(scheme), secondaryColor: LiquidGlassPalette.sapphire)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6).liquidGlassWell(cornerRadius: 11)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile(cornerRadius: 20)
            .onTapGesture { bentoStore.onNavigateModule?(.system) }

        default: // banner_4x1
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    MachinedAppleDieBadge(chipShort: hw.chipShort, coreShort: "\(hw.coreCount)C", size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(telemetry.displayHostTitle)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text("\(hw.modelIdentifier) · \(hw.osVersion)")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .liquidGlassPill()
                                .lineLimit(1)
                        }
                        HStack(spacing: 4) {
                            Circle().fill(LiquidGlassPalette.sapphire).frame(width: 5, height: 5)
                            Text(String(format: "%.1fW · %d°C · 电量 %d%%", telemetry.powerWatts, telemetry.thermalCelsius, telemetry.batteryPercent))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("内存").font(.system(size: 9.5, weight: .medium)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                            Spacer(minLength: 2)
                            Text(String(format: "%.1f/%.0fG", hw.ramUsedGB, hw.ramTotalGB))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .lineLimit(1)
                        }
                        MultiSegmentTelemetryBar(primaryFraction: appFrac, secondaryFraction: wiredFrac)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(width: 108)
                    .liquidGlassWell(cornerRadius: 11)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("储存").font(.system(size: 9.5, weight: .medium)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                            Spacer(minLength: 2)
                            Text("余\(Int(hw.ssdAvailableGB))G/\(hw.ssdTotalDisplay)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .lineLimit(1)
                        }
                        MultiSegmentTelemetryBar(primaryFraction: usedDiskFrac * 0.65, secondaryFraction: usedDiskFrac * 0.35, primaryColor: LiquidGlassPalette.cpuStroke(scheme), secondaryColor: LiquidGlassPalette.sapphire)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(width: 112)
                    .liquidGlassWell(cornerRadius: 11)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile()
            .onTapGesture { bentoStore.onNavigateModule?(.system) }
        }
    }

    // MARK: 2. 50/50 Peer-Equal CPU & GPU

    @ViewBuilder private var cpuGpuView: some View {
        let cpuInt = Int(telemetry.cpuPercent.rounded())
        let gpuInt = Int(telemetry.gpuPercent.rounded())
        switch variant.key {
        case "rings_2x1":
            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    AppleRingGauge(percent: telemetry.cpuPercent, size: 44, lineWidth: 4.2, tint: LiquidGlassPalette.cpuStroke(scheme)) {
                        Text("\(cpuInt)%").font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("CPU").font(.system(size: 10, weight: .semibold)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                        Text("\(telemetry.hardware.coreCount) 核").font(.system(size: 10.5, weight: .medium))
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    AppleRingGauge(percent: telemetry.gpuPercent, size: 44, lineWidth: 4.2, tint: LiquidGlassPalette.sapphire) {
                        Text("\(gpuInt)%").font(.system(size: 9.5, weight: .bold, design: .monospaced)).foregroundStyle(LiquidGlassPalette.sapphire)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("GPU").font(.system(size: 10, weight: .semibold)).foregroundStyle(LiquidGlassPalette.sapphire)
                        Text("图形核心").font(.system(size: 10.5, weight: .medium))
                    }
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile()

        default: // wave_2x1 & wide_4x1
            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 5) {
                        Circle().fill(LiquidGlassPalette.cpuStroke(scheme)).frame(width: 6, height: 6)
                        Text("CPU").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                        Text("\(cpuInt)%").font(.system(size: 14, weight: .bold, design: .monospaced))
                    }
                    Spacer()
                    if variant.w == 4 {
                        Text(String(format: "%.1fW · %d°C", telemetry.powerWatts, telemetry.thermalCelsius))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(LiquidGlassPalette.inkTertiary(scheme))
                        Spacer()
                    }
                    HStack(spacing: 5) {
                        Circle().fill(LiquidGlassPalette.sapphire).frame(width: 6, height: 6)
                        Text("GPU").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                        Text("\(gpuInt)%").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(LiquidGlassPalette.sapphire)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.top, 9)

                Spacer(minLength: 2)
                DualPeerWaveformChart(cpuHistory: telemetry.cpuHistory, gpuHistory: telemetry.gpuHistory)
                    .frame(height: 34)
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile()
        }
    }

    // MARK: 3. Battery Care & Peripherals & Network

    @ViewBuilder private var batteryCareView: some View {
        let remainText = telemetry.remainingMinutes.map { "\($0 / 60)h \($0 % 60)m" } ?? (telemetry.isCharging ? "充电中" : "电源供电")
        if variant.w == 1 {
            VStack(spacing: 3) {
                AppleRingGauge(percent: Double(telemetry.batteryPercent), size: 36, lineWidth: 3.6) {
                    Text("\(telemetry.batteryPercent)%").font(.system(size: 9, weight: .bold, design: .monospaced))
                }
                Text("健康 \(telemetry.batteryHealthPercent)%").font(.system(size: 9, weight: .medium)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("电池健康 · \(telemetry.batteryHealthPercent)%")
                        .font(.system(size: 10.5, weight: .semibold))
                    Spacer()
                    Text(telemetry.isCharging ? "快充中" : "循环 \(telemetry.batteryCycles) 次")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LiquidGlassPalette.sapphire)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .liquidGlassPill()
                }
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline) {
                    Text("\(telemetry.batteryPercent)%")
                        .font(.system(size: variant.h == 2 ? 24 : 17, weight: .bold, design: .monospaced))
                    Text(remainText)
                        .font(.system(size: 10))
                        .foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                        .lineLimit(1)
                    Spacer()
                    Text(String(format: "%.1fW · %d°C", telemetry.powerWatts, telemetry.thermalCelsius))
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(LiquidGlassPalette.sapphire)
                }
                if variant.h == 2 {
                    MultiSegmentTelemetryBar(primaryFraction: Double(telemetry.batteryPercent) / 100.0, secondaryFraction: 0)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile(cornerRadius: variant.h == 2 ? 20 : 18)
            .onTapGesture {
                telemetry.activeSystemDetailTab = .power
                bentoStore.onNavigateModule?(.system)
            }
        }
    }

    @ViewBuilder private var bluetoothView: some View {
        let items = telemetry.peripherals
        if variant.key == "ring_1x1", !items.isEmpty {
            let cur = items[telemetry.btSpotlightIndex % items.count]
            Button {
                telemetry.cycleBluetoothSpotlight()
            } label: {
                VStack(spacing: 3) {
                    AppleRingGauge(percent: Double(cur.percent), size: 36, lineWidth: 3.6) {
                        Image(systemName: cur.symbol).font(.system(size: 11.5, weight: .medium))
                    }
                    HStack(spacing: 2) {
                        Text(cur.shortName).font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
                        Text("\(cur.percent)%").font(.system(size: 9.5, weight: .bold, design: .monospaced)).foregroundStyle(LiquidGlassPalette.sapphire)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .liquidGlassTile()
        } else if variant.key == "square_2x2" {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("蓝牙与本机外设").font(.system(size: 11.5, weight: .semibold))
                    Spacer()
                    Text("\(items.count) 台在线")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LiquidGlassPalette.sapphire)
                        .padding(.horizontal, 7).padding(.vertical, 2).liquidGlassPill()
                }
                VStack(spacing: 8) {
                    ForEach(items) { dev in
                        VStack(spacing: 4) {
                            HStack {
                                Label(dev.name, systemImage: dev.symbol).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                                Spacer()
                                Text("\(dev.percent)%").font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            }
                            MultiSegmentTelemetryBar(primaryFraction: Double(dev.percent) / 100.0, secondaryFraction: 0)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(13)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile(cornerRadius: 20)
        } else {
            HStack(spacing: 6) {
                ForEach(items) { dev in
                    VStack(spacing: 4) {
                        AppleRingGauge(percent: Double(dev.percent), size: 38, lineWidth: 3.6) {
                            Image(systemName: dev.symbol).font(.system(size: 11.5, weight: .medium))
                        }
                        Text("\(dev.percent)%").font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile()
        }
    }

    @ViewBuilder private var networkView: some View {
        let downTxt = telemetry.netDownMBps >= 1.0 ? String(format: "%.1f MB/s", telemetry.netDownMBps) : String(format: "%.0f KB/s", telemetry.netDownMBps * 1024)
        let upTxt = telemetry.netUpMBps >= 1.0 ? String(format: "%.1f MB/s", telemetry.netUpMBps) : String(format: "%.0f KB/s", telemetry.netUpMBps * 1024)
        if variant.w == 1 {
            VStack(alignment: .leading, spacing: 4) {
                Text("实时网速").font(.system(size: 10, weight: .semibold)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                Spacer(minLength: 0)
                Text("↓ \(downTxt)").font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(LiquidGlassPalette.sapphire).lineLimit(1)
                Text("↑ \(upTxt)").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme)).lineLimit(1)
            }
            .padding(11)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile()
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("实时下行吞吐").font(.system(size: 10)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                    Text("↓ \(downTxt)").font(.system(size: 13.5, weight: .bold, design: .monospaced)).foregroundStyle(LiquidGlassPalette.sapphire)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("上行速率").font(.system(size: 10)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                    Text("↑ \(upTxt)").font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile()
            .onTapGesture {
                telemetry.activeSystemDetailTab = .network
                bentoStore.onNavigateModule?(.system)
            }
        }
    }

    // MARK: 4. Brightness, Volume & App Mixer

    @ViewBuilder private var brightVolView: some View {
        if variant.key == "pillars_1x2" {
            HStack(spacing: 7) {
                ControlCenterSliderCapsule(symbol: "sun.max.fill", value: telemetry.brightness, minimum: 0.10, vertical: true) { val, commit in
                    telemetry.setDisplayBrightness(val, commit: commit)
                }
                ControlCenterSliderCapsule(symbol: "speaker.wave.2.fill", value: telemetry.outputVolume, minimum: 0.0, vertical: true) { val, commit in
                    telemetry.setSystemVolume(val, commit: commit)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile(cornerRadius: 20)
        } else if variant.key == "wide_4x1" {
            HStack(spacing: 10) {
                ControlCenterSliderCapsule(symbol: "sun.max.fill", value: telemetry.brightness, minimum: 0.10, label: "屏幕亮度") { val, commit in
                    telemetry.setDisplayBrightness(val, commit: commit)
                }
                .frame(height: 36)
                ControlCenterSliderCapsule(symbol: "speaker.wave.2.fill", value: telemetry.outputVolume, minimum: 0.0, label: "系统音量") { val, commit in
                    telemetry.setSystemVolume(val, commit: commit)
                }
                .frame(height: 36)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile()
        } else {
            VStack(spacing: 7) {
                ControlCenterSliderCapsule(symbol: "sun.max.fill", value: telemetry.brightness, minimum: 0.10) { val, commit in
                    telemetry.setDisplayBrightness(val, commit: commit)
                }
                ControlCenterSliderCapsule(symbol: "speaker.wave.2.fill", value: telemetry.outputVolume, minimum: 0.0) { val, commit in
                    telemetry.setSystemVolume(val, commit: commit)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile()
        }
    }

    @ViewBuilder private var appMixerView: some View {
        let channels = telemetry.appMixer
        VStack(alignment: .leading, spacing: 5) {
            if variant.h == 2 {
                HStack {
                    Text("应用独立混音台").font(.system(size: 11.5, weight: .semibold))
                    Spacer()
                    Text("CoreAudio").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(LiquidGlassPalette.sapphire)
                }
            }
            ForEach(channels.prefix(variant.h == 2 ? 3 : 2)) { ch in
                ControlCenterSliderCapsule(symbol: "waveform", value: ch.volume, label: ch.name) { val, _ in
                    telemetry.setAppChannelVolume(id: ch.id, value: val)
                }
                .frame(height: variant.h == 2 ? 30 : 23)
            }
            if channels.isEmpty {
                Text("暂无活跃媒体应用").font(.system(size: 11)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidGlassTile(cornerRadius: variant.h == 2 ? 20 : 18)
    }

    // MARK: 5. Unified Switch / Quick Action Tile (tile_1x1 / orb_1x1 / pill_2x1)

    @ViewBuilder private func switchTile(on: Bool, symbol: String, title: String, subtitle: String, badge: String, swatchHex: String? = nil, action: @escaping () -> Void) -> some View {
        switch variant.key {
        case "orb_1x1":
            Button(action: action) {
                VStack(spacing: 6) {
                    Circle()
                        .fill(on ? LiquidGlassPalette.sapphire : LiquidGlassPalette.sapphireSoft(scheme))
                        .frame(width: 36, height: 36)
                        .overlay {
                            Image(systemName: symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(on ? .white : LiquidGlassPalette.sapphire)
                        }
                    Text(title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .liquidGlassTile()

        case "pill_2x1":
            Button(action: action) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(on ? LiquidGlassPalette.sapphire : LiquidGlassPalette.sapphireSoft(scheme))
                        .frame(width: 34, height: 34)
                        .overlay {
                            Image(systemName: symbol)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(on ? .white : LiquidGlassPalette.sapphire)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                        Text(subtitle).font(.system(size: 10)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme)).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(badge)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(on ? .white : LiquidGlassPalette.sapphire)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(on ? LiquidGlassPalette.sapphire : LiquidGlassPalette.sapphireSoft(scheme), in: Capsule())
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .liquidGlassTile()

        default: // tile_1x1
            Button(action: action) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: symbol)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(on ? .white : LiquidGlassPalette.sapphire)
                        Spacer(minLength: 2)
                        if let hex = swatchHex, let col = Color(hexString: hex) {
                            Circle().fill(col).frame(width: 13, height: 13).overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                        } else {
                            Text(badge)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(on ? .white.opacity(0.9) : LiquidGlassPalette.inkSecondary(scheme))
                        }
                    }
                    Spacer(minLength: 4)
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(on ? .white : LiquidGlassPalette.inkPrimary(scheme))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(on ? .white.opacity(0.82) : LiquidGlassPalette.inkSecondary(scheme))
                        .lineLimit(1)
                }
                .padding(11)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .liquidGlassTile(active: on)
        }
    }

    // MARK: 6. Toolkit, AI/Dev & Productivity Tiles

    @ViewBuilder private var trashView: some View {
        switchTile(
            on: false,
            symbol: "trash",
            title: "废纸篓",
            subtitle: "\(telemetry.trashCount) 项 · \(telemetry.trashSizeLabel)",
            badge: telemetry.trashSizeLabel
        ) { if !previewOnly { telemetry.openSystemTrash() } }
    }

    @ViewBuilder private var winSnapView: some View {
        if variant.w == 1 {
            HStack(spacing: 4) {
                ForEach([WindowSnapAction.leftHalf, .rightHalf], id: \.rawValue) { act in
                    Button { telemetry.snapActiveWindow(act) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: act.symbol).font(.system(size: 13))
                            Text(act == .leftHalf ? "左" : "右").font(.system(size: 9.5, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .liquidGlassWell(cornerRadius: 11)
                    }.buttonStyle(.plain)
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("窗口分屏磁贴").font(.system(size: 10, weight: .semibold)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                HStack(spacing: 6) {
                    ForEach(WindowSnapAction.allCases, id: \.rawValue) { act in
                        Button { telemetry.snapActiveWindow(act) } label: {
                            VStack(spacing: 3) {
                                Image(systemName: act.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(LiquidGlassPalette.sapphire)
                                Text(act.title).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .liquidGlassWell(cornerRadius: 10)
                        }.buttonStyle(.plain)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile()
        }
    }

    @ViewBuilder private var aiQuotaView: some View {
        let active = telemetry.aiProviders.filter(\.enabled)
        if variant.w == 1, let first = active.first {
            VStack(spacing: 3) {
                AppleRingGauge(percent: Double(first.percent), size: 36, lineWidth: 3.6) {
                    Text("\(first.percent)%").font(.system(size: 9, weight: .bold, design: .monospaced))
                }
                Text(first.name).font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile()
            .onTapGesture { bentoStore.onNavigateModule?(.aiDev) }
        } else {
            let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
            VStack(alignment: .leading, spacing: 7) {
                if variant.h == 2 {
                    HStack {
                        Text("AI 编码与模型余量").font(.system(size: 11.5, weight: .semibold))
                        Spacer()
                        Text("实时窗口").font(.system(size: 9.5)).foregroundStyle(LiquidGlassPalette.sapphire)
                    }
                }
                LazyVGrid(columns: cols, spacing: variant.h == 2 ? 10 : 6) {
                    ForEach(active.prefix(4)) { p in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(p.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                                Spacer(minLength: 2)
                                Text("\(p.percent)%").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(LiquidGlassPalette.sapphire)
                            }
                            MultiSegmentTelemetryBar(primaryFraction: Double(p.percent) / 100.0, secondaryFraction: 0)
                        }
                    }
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile(cornerRadius: variant.h == 2 ? 20 : 18)
            .onTapGesture { bentoStore.onNavigateModule?(.aiDev) }
        }
    }

    @ViewBuilder private var devPortsView: some View {
        let ports = telemetry.devPorts
        if variant.w == 1 {
            VStack(alignment: .leading, spacing: 2) {
                Text("监听端口").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                Spacer(minLength: 0)
                Text("\(ports.count)").font(.system(size: 17, weight: .bold, design: .monospaced)).foregroundStyle(LiquidGlassPalette.sapphire)
                Text("活跃 TCP").font(.system(size: 9)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
            }
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .liquidGlassTile()
            .onTapGesture { bentoStore.onNavigateModule?(.aiDev) }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("活跃开发端口（点击释放）").font(.system(size: 10, weight: .semibold)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                    Spacer()
                    Button { telemetry.refreshSlowMetricsAsync() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9.5))
                    }.buttonStyle(.plain)
                }
                if ports.isEmpty {
                    Text("当前无本机开发监听端口").font(.system(size: 10.5)).foregroundStyle(LiquidGlassPalette.inkTertiary(scheme))
                } else if variant.h == 2 {
                    VStack(spacing: 5) {
                        ForEach(ports.prefix(4)) { p in
                            HStack {
                                Text(":\(p.port)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(LiquidGlassPalette.sapphire)
                                Text(p.processName).font(.system(size: 10)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme)).lineLimit(1)
                                Spacer()
                                Button("释放") { telemetry.terminateDevPort(p) }
                                    .buttonStyle(.plain).font(.system(size: 9.5, weight: .semibold))
                                    .padding(.horizontal, 7).padding(.vertical, 2).liquidGlassPill()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5).liquidGlassWell(cornerRadius: 9)
                        }
                    }
                } else {
                    HStack(spacing: 5) {
                        ForEach(ports.prefix(3)) { p in
                            Button { telemetry.terminateDevPort(p) } label: {
                                Text(":\(p.port) ✕")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(LiquidGlassPalette.sapphire)
                                    .padding(.horizontal, 7).padding(.vertical, 4)
                                    .liquidGlassWell(cornerRadius: 8)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .liquidGlassTile(cornerRadius: variant.h == 2 ? 20 : 18)
        }
    }

    @ViewBuilder private var meetingView: some View {
        let todayKey = MoriqSyncHub.dateKey(from: Date())
        let events = syncHub.mergedEvents(for: todayKey)
        let nextEv = events.first
        if variant.w == 1 {
            VStack(alignment: .leading, spacing: 2) {
                Text(nextEv?.origin.badgeText ?? "今日日程")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LiquidGlassPalette.sapphire)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(nextEv?.title ?? "暂无排期").font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                Text(nextEv?.sortKey ?? "空闲").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
            }
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .liquidGlassTile()
            .onTapGesture { bentoStore.onNavigateModule?(.calendar) }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(variant.h == 2 ? "今日合并日程 (\(events.count))" : "下场日程 · \(nextEv?.origin.badgeText ?? "空闲")")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                        .lineLimit(1)
                    Spacer()
                    if let url = nextEv?.joinURL {
                        Button("入会") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.plain)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 2.5)
                            .background(LiquidGlassPalette.sapphire, in: Capsule())
                    }
                }
                if variant.h == 2 {
                    if events.isEmpty {
                        Text("当日暂无排期，点击新建或连接日历").font(.system(size: 11)).foregroundStyle(LiquidGlassPalette.inkTertiary(scheme))
                    } else {
                        ForEach(events.prefix(3)) { ev in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(ev.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                    Spacer()
                                    Text(ev.origin.badgeText).font(.system(size: 9)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                                }
                                Text("\(ev.timeDisplay) · \(ev.location)").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme)).lineLimit(1)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5).liquidGlassWell(cornerRadius: 10)
                        }
                    }
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    Text(nextEv?.title ?? "点击打开日程连接或新建排期")
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let ev = nextEv {
                        Text("\(ev.timeDisplay) · \(ev.location)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(LiquidGlassPalette.inkSecondary(scheme)).lineLimit(1)
                    }
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .liquidGlassTile(cornerRadius: variant.h == 2 ? 20 : 18)
            .onTapGesture { bentoStore.onNavigateModule?(.calendar) }
        }
    }

    @ViewBuilder private var todoView: some View {
        let items = syncHub.mergedTodos
        let doneCount = items.filter(\.done).count
        let pct = items.isEmpty ? 0.0 : (Double(doneCount) / Double(items.count) * 100.0)
        if variant.w == 1 {
            VStack(spacing: 3) {
                AppleRingGauge(percent: pct, size: 36, lineWidth: 3.6) {
                    Text("\(doneCount)/\(items.count)").font(.system(size: 9, weight: .bold, design: .monospaced))
                }
                Text("待办清单").font(.system(size: 9.5, weight: .semibold))
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile()
            .onTapGesture { bentoStore.onNavigateModule?(.calendar) }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("随手待办 \(syncHub.appleRemindersEnabled ? "· 含提醒事项" : "· 仅岛内")")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                    Spacer()
                    Text("\(doneCount)/\(items.count)").font(.system(size: 9.5, weight: .bold, design: .monospaced)).foregroundStyle(LiquidGlassPalette.sapphire)
                }
                if items.isEmpty {
                    Spacer(minLength: 0)
                    Text("点击进入日程页新建待办").font(.system(size: 10.5)).foregroundStyle(LiquidGlassPalette.inkTertiary(scheme))
                    Spacer(minLength: 0)
                } else {
                    ForEach(items.prefix(variant.h == 2 ? 4 : 2)) { item in
                        Button { syncHub.toggleTodo(item) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(item.done ? LiquidGlassPalette.sapphire : LiquidGlassPalette.inkTertiary(scheme))
                                Text(item.text)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .strikethrough(item.done)
                                    .opacity(item.done ? 0.55 : 1)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }.buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .liquidGlassTile(cornerRadius: variant.h == 2 ? 20 : 18)
        }
    }

    @ViewBuilder private var focusView: some View {
        let running = focusStore.snapshot.status == .running
        if variant.w == 1 {
            Button {
                if running { focusStore.pause() } else { focusStore.start(.focus) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Image(systemName: "timer").font(.system(size: 12, weight: .semibold)).foregroundStyle(running ? .white : LiquidGlassPalette.sapphire)
                    Spacer(minLength: 0)
                    Text(focusStore.displayTime).font(.system(size: 12.5, weight: .bold, design: .monospaced)).foregroundStyle(running ? .white : LiquidGlassPalette.inkPrimary(scheme))
                    Text(running ? "专注中" : "点按开始").font(.system(size: 9)).foregroundStyle(running ? .white.opacity(0.82) : LiquidGlassPalette.inkSecondary(scheme))
                }
                .padding(9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .liquidGlassTile(active: running)
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(focusStore.snapshot.phase == .focus ? "番茄专注" : "小憩休息")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                    Text(focusStore.displayTime)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                }
                Spacer()
                Button(running ? "暂停" : "开始") {
                    if running { focusStore.pause() } else { focusStore.start(.focus) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(running ? LiquidGlassPalette.inkPrimary(scheme) : .white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(running ? Color.clear : LiquidGlassPalette.sapphire, in: Capsule())
                .overlay { if running { Capsule().strokeBorder(LiquidGlassPalette.divider(scheme)) } }
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile()
        }
    }

    @ViewBuilder private var musicView: some View {
        Button { bentoStore.onNavigateModule?(.music) } label: {
            if variant.w == 1 {
                VStack(spacing: 3) {
                    Circle().fill(Color(red: 0.08, green: 0.09, blue: 0.13)).frame(width: 34, height: 34)
                        .overlay { Circle().fill(LiquidGlassPalette.sapphire).frame(width: 10, height: 10) }
                    Text("音乐").font(.system(size: 9.5, weight: .semibold))
                }
                .padding(6).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 10) {
                    Circle().fill(Color(red: 0.08, green: 0.09, blue: 0.13)).frame(width: 38, height: 38)
                        .overlay { Circle().fill(LiquidGlassPalette.sapphire).frame(width: 10, height: 10) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Music 速控").font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                        Text("点击展开曲目与播放控制").font(.system(size: 10)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme)).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "playpause.fill").font(.system(size: 12)).foregroundStyle(LiquidGlassPalette.sapphire)
                }
                .padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .buttonStyle(.plain)
        .liquidGlassTile()
    }

    @ViewBuilder private var shelfView: some View {
        let count = bentoStore.shelfItemCountProvider?() ?? 0
        Button { bentoStore.onNavigateModule?(.shelf) } label: {
            if variant.w == 1 {
                VStack(alignment: .leading, spacing: 2) {
                    Image(systemName: "tray.full.fill").font(.system(size: 12)).foregroundStyle(LiquidGlassPalette.sapphire)
                    Spacer(minLength: 0)
                    Text("\(count)").font(.system(size: 16, weight: .bold, design: .monospaced))
                    Text("暂存文件").font(.system(size: 9)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                }
                .padding(9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("文件暂存架").font(.system(size: 11.5, weight: .semibold))
                        Text(count == 0 ? "拖入文件随时取用" : "当前已暂存 \(count) 个文件").font(.system(size: 10)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                    }
                    Spacer()
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 14)).foregroundStyle(LiquidGlassPalette.sapphire)
                }
                .padding(.horizontal, 13).padding(.vertical, 10).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .buttonStyle(.plain)
        .liquidGlassTile()
    }
}

private extension Color {
    init?(hexString: String) {
        let clean = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard clean.count == 6, let val = UInt64(clean, radix: 16) else { return nil }
        self.init(
            red: Double((val >> 16) & 0xFF) / 255.0,
            green: Double((val >> 8) & 0xFF) / 255.0,
            blue: Double(val & 0xFF) / 255.0
        )
    }
}

// MARK: - Live 4-Column Dense Bento Canvas View (Used Inside Dynamic Island & DIY Studio!)

struct BentoDenseCanvasGridView: View {
    @ObservedObject var bentoStore: IslandBentoStore
    var editable: Bool = false
    var rowHeight: CGFloat = 78
    var spacing: CGFloat = 8

    @State private var hoveredWidget: BentoWidgetID? = nil
    @State private var dropTargetWidget: BentoWidgetID? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let packed = BentoGridPacker.pack(entries: bentoStore.activeCanvas, maxCells: bentoStore.gridMaxCells, columns: 4)
        let totalHeight = CGFloat(packed.totalRows) * rowHeight + CGFloat(max(0, packed.totalRows - 1)) * spacing

        GeometryReader { geo in
            let colWidth = max(40, (geo.size.width - spacing * 3) / 4.0)
            ZStack(alignment: .topLeading) {
                // 1. Recessed Frosted Liquid Glass Empty Sockets
                ForEach(packed.empties) { slot in
                    let x = CGFloat(slot.col) * (colWidth + spacing)
                    let y = CGFloat(slot.row) * (rowHeight + spacing)
                    RecessedGlassEmptySlot(highlighted: false) {
                        if editable {
                            bentoStore.spotlightWidget = nil
                        } else {
                            bentoStore.onOpenDIYSettings?()
                        }
                    }
                    .frame(width: colWidth, height: rowHeight)
                    .offset(x: x, y: y)
                    .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                        handleDropProviders(providers, targetIndex: nil)
                    }
                }

                // 2. Multi-Style & Multi-Size Bento Cards
                ForEach(packed.placements) { p in
                    let w = CGFloat(p.variant.w) * colWidth + CGFloat(p.variant.w - 1) * spacing
                    let h = CGFloat(p.variant.h) * rowHeight + CGFloat(p.variant.h - 1) * spacing
                    let x = CGFloat(p.col) * (colWidth + spacing)
                    let y = CGFloat(p.row) * (rowHeight + spacing)
                    let isSpotlit = editable && bentoStore.spotlightWidget == p.entry.widgetID
                    let isHovered = hoveredWidget == p.entry.widgetID

                    ZStack(alignment: .topTrailing) {
                        BentoWidgetTileView(entry: p.entry, previewOnly: editable)
                            .frame(width: w, height: h)
                            .overlay {
                                if isSpotlit || dropTargetWidget == p.entry.widgetID {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .strokeBorder(LiquidGlassPalette.sapphire, lineWidth: 2)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard editable else { return }
                                bentoStore.spotlightWidget = (bentoStore.spotlightWidget == p.entry.widgetID) ? nil : p.entry.widgetID
                            }

                        if editable && isHovered {
                            HStack(spacing: 4) {
                                Button {
                                    bentoStore.spotlightWidget = p.entry.widgetID
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "square.grid.2x2")
                                        Text("样式")
                                    }
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(LiquidGlassPalette.sapphire)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .liquidGlassPill(selected: true)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    bentoStore.remove(widget: p.entry.widgetID)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8.5, weight: .bold))
                                        .foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                                        .frame(width: 20, height: 20)
                                        .liquidGlassPill(selected: true)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(6)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        }
                    }
                    .frame(width: w, height: h)
                    .onHover { inside in
                        withAnimation(.easeOut(duration: 0.14)) {
                            if inside { hoveredWidget = p.entry.widgetID }
                            else if hoveredWidget == p.entry.widgetID { hoveredWidget = nil }
                        }
                    }
                    .contextMenu {
                        Menu("切换组件样式与占格") {
                            ForEach(p.entry.widgetID.variants) { vr in
                                Button {
                                    bentoStore.selectOrInsert(widget: p.entry.widgetID, variantKey: vr.key)
                                } label: {
                                    HStack {
                                        Text(vr.title)
                                        if vr.key == p.variant.key { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("从画布移除", role: .destructive) {
                            bentoStore.remove(widget: p.entry.widgetID)
                        }
                    }
                    .onDrag {
                        NSItemProvider(object: "moriq_bento:\(p.entry.widgetID.rawValue):\(p.variant.key)" as NSString)
                    }
                    .onDrop(
                        of: [UTType.plainText.identifier],
                        isTargeted: Binding(
                            get: { dropTargetWidget == p.entry.widgetID },
                            set: { targeted in dropTargetWidget = targeted ? p.entry.widgetID : nil }
                        )
                    ) { providers in
                        handleDropProviders(providers, targetWidget: p.entry.widgetID, targetIndex: p.entryIndex)
                    }
                    .offset(x: x, y: y)
                }
            }
        }
        .frame(height: totalHeight)
    }

    private func handleDropProviders(_ providers: [NSItemProvider], targetWidget: BentoWidgetID? = nil, targetIndex: Int?) -> Bool {
        guard let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let raw = obj as? String, raw.hasPrefix("moriq_bento:") else { return }
            let parts = raw.split(separator: ":").map(String.init)
            guard parts.count == 3, let wid = BentoWidgetID(rawValue: parts[1]) else { return }
            let vKey = parts[2]
            Task { @MainActor in
                if let targetWidget, bentoStore.activeCanvas.contains(where: { $0.widgetID == wid }) {
                    bentoStore.move(widget: wid, before: targetWidget)
                    if bentoStore.activeCanvas.first(where: { $0.widgetID == wid })?.variantKey != vKey {
                        bentoStore.selectOrInsert(widget: wid, variantKey: vKey)
                    }
                } else {
                    bentoStore.selectOrInsert(widget: wid, variantKey: vKey, at: targetIndex)
                }
            }
        }
        return true
    }
}

// MARK: - Unified Island Planner View (Day/Week/Month Calendar + Non-Destructive Notes & To-Do)

struct IslandPlannerUnifiedView: View {
    @ObservedObject var syncHub = MoriqSyncHub.shared
    @ObservedObject var noteStore: StickyNoteStore
    var togglePinDesktopNote: ((UUID) -> Void)? = nil
    var createDesktopBackedNote: (() -> UUID?)? = nil
    var onEditingChange: (Bool) -> Void = { _ in }

    @State private var span: CalendarDisplaySpan = .day
    @State private var selectedDateKey: String = MoriqSyncHub.dateKey(from: Date())
    @State private var addingEvent = false
    @State private var newEventTime = "15:00"
    @State private var newEventTitle = ""

    @State private var lowerMode: String = "todo" // "todo" or "note"
    @State private var addingTodo = false
    @State private var newTodoText = ""
    @State private var selectedNoteID: String = ""
    @FocusState private var fieldFocused: Bool
    @Environment(\.colorScheme) private var scheme

    private let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            upperCalendarSection
            Divider().overlay(LiquidGlassPalette.divider(scheme))
            lowerNotesAndTodoSection
        }
        .onChange(of: fieldFocused) { _, focused in onEditingChange(focused) }
        .task { await syncHub.refreshEnabledSources(interactiveRequest: false) }
        .sheet(isPresented: $syncHub.showingGoogleConnectSheet) {
            GoogleCalendarConnectSheet(syncHub: syncHub)
        }
    }

    // MARK: Upper Calendar (Day / Week / Month + Multi-Source Non-Destructive Pills)

    private var upperCalendarSection: some View {
        let selDate = MoriqSyncHub.date(fromKey: selectedDateKey)
        let comps = Calendar.current.dateComponents([.year, .month, .day, .weekday], from: selDate)
        let weekdayIdx = ((comps.weekday ?? 2) + 5) % 7
        let events = syncHub.mergedEvents(for: selectedDateKey)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("\(comps.month ?? 1)月\(comps.day ?? 1)日 周\(weekdayLabels[weekdayIdx])")
                    .font(.system(size: 12, weight: .semibold))
                Button(addingEvent ? "收起" : "+ 新建") {
                    withAnimation(.easeOut(duration: 0.16)) { addingEvent.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LiquidGlassPalette.sapphire)
                .padding(.horizontal, 7).padding(.vertical, 2.5)
                .liquidGlassWell(cornerRadius: 10)

                Spacer(minLength: 4)

                // Source Connection Pills
                Button {
                    syncHub.toggleAppleCalendar()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "apple.logo").font(.system(size: 9))
                        Text(syncHub.appleCalEnabled ? "本地日历 ✓" : "本地日历")
                    }
                    .font(.system(size: 10, weight: syncHub.appleCalEnabled ? .semibold : .medium))
                    .foregroundStyle(syncHub.appleCalEnabled ? LiquidGlassPalette.sapphire : LiquidGlassPalette.inkSecondary(scheme))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .liquidGlassPill(selected: syncHub.appleCalEnabled)
                }
                .buttonStyle(.plain)
                .help("连接或断开 macOS 本地日历（不会覆盖岛内已有日程）")

                Button {
                    syncHub.toggleGoogleCalendar()
                } label: {
                    HStack(spacing: 3) {
                        Text("G").font(.system(size: 10, weight: .bold, design: .rounded))
                        Text(syncHub.googleCalEnabled ? "Google ✓" : "Google")
                    }
                    .font(.system(size: 10, weight: syncHub.googleCalEnabled ? .semibold : .medium))
                    .foregroundStyle(syncHub.googleCalEnabled ? LiquidGlassPalette.sapphire : LiquidGlassPalette.inkSecondary(scheme))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .liquidGlassPill(selected: syncHub.googleCalEnabled)
                }
                .buttonStyle(.plain)
                .help("连接或暂停 Google 日历（并存展示，绝不覆盖已有排期）")

                // Day / Week / Month Switcher
                HStack(spacing: 2) {
                    ForEach(CalendarDisplaySpan.allCases) { item in
                        Button(item.title) { span = item }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: span == item ? .semibold : .regular))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(span == item ? Color.white.opacity(scheme == .dark ? 0.16 : 0.9) : .clear, in: Capsule())
                    }
                }
                .padding(2)
                .liquidGlassWell(cornerRadius: 12)

                HStack(spacing: 2) {
                    Button { stepDate(-1) } label: { Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18) }.buttonStyle(.plain)
                    Button { stepDate(1) } label: { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18) }.buttonStyle(.plain)
                }
            }

            if addingEvent {
                HStack(spacing: 6) {
                    TextField("15:00", text: $newEventTime)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .frame(width: 48)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .liquidGlassPill(selected: true)
                        .focused($fieldFocused)

                    TextField("输入岛内日程，回车保存（连接外部日历后不覆盖）…", text: $newEventTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .focused($fieldFocused)
                        .onSubmit { commitNewEvent() }

                    Button("保存") { commitNewEvent() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(LiquidGlassPalette.sapphire, in: Capsule())
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .liquidGlassWell(cornerRadius: 12)
            }

            if span == .week {
                weekStrip(around: selDate)
            } else if span == .month {
                monthCompactGrid(for: selDate)
            }

            if events.isEmpty {
                HStack {
                    Text("当日暂无排期（可点 + 新建岛内日程，或开启本地 / Google 日历）")
                        .font(.system(size: 11))
                        .foregroundStyle(LiquidGlassPalette.inkTertiary(scheme))
                    Spacer()
                    if syncHub.calendarPermissionDenied {
                        Button("系统日历权限") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                                NSWorkspace.shared.open(url)
                            }
                        }.buttonStyle(.link).font(.system(size: 10.5))
                    }
                }
                .padding(.horizontal, 11).padding(.vertical, 8)
                .liquidGlassWell(cornerRadius: 12)
            } else {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(events) { ev in
                            HStack(spacing: 9) {
                                Capsule()
                                    .fill(ev.origin == .moriq ? LiquidGlassPalette.inkSecondary(scheme) : LiquidGlassPalette.sapphire)
                                    .frame(width: 3, height: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text(ev.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                                        Text(ev.origin.badgeText)
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(ev.origin == .googleCalendar ? LiquidGlassPalette.sapphire : LiquidGlassPalette.inkSecondary(scheme))
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .liquidGlassPill()
                                    }
                                    Text("\(ev.timeDisplay) · \(ev.location)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                if let uuid = ev.localUUID {
                                    Button { syncHub.deleteLocalEvent(id: uuid) } label: {
                                        Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(LiquidGlassPalette.inkTertiary(scheme))
                                    }.buttonStyle(.plain).help("删除此条岛内日程")
                                }
                                if let joinURL = ev.joinURL {
                                    Button("入会") { NSWorkspace.shared.open(joinURL) }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 9).padding(.vertical, 3.5)
                                        .background(LiquidGlassPalette.sapphire, in: Capsule())
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .liquidGlassWell(cornerRadius: 12)
                        }
                    }
                }
                .frame(maxHeight: span == .month ? 76 : 102)
            }
        }
    }

    private func weekStrip(around date: Date) -> some View {
        let cal = Calendar.current
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        let startOfWeek = cal.date(from: comps) ?? date
        let todayKey = MoriqSyncHub.dateKey(from: Date())
        return HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { idx in
                let d = cal.date(byAdding: .day, value: idx, to: startOfWeek) ?? date
                let k = MoriqSyncHub.dateKey(from: d)
                let dayNum = cal.component(.day, from: d)
                let wIdx = ((cal.component(.weekday, from: d) + 5) % 7)
                let hasEv = !syncHub.mergedEvents(for: k).isEmpty
                Button { selectedDateKey = k } label: {
                    VStack(spacing: 2) {
                        Text(weekdayLabels[wIdx]).font(.system(size: 9)).foregroundStyle(LiquidGlassPalette.inkTertiary(scheme))
                        Text("\(dayNum)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(k == todayKey ? LiquidGlassPalette.sapphire : LiquidGlassPalette.inkPrimary(scheme))
                        Circle().fill(hasEv ? LiquidGlassPalette.sapphire : .clear).frame(width: 4, height: 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(k == selectedDateKey ? Color.white.opacity(scheme == .dark ? 0.14 : 0.85) : .clear, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain)
            }
        }
        .padding(4)
        .liquidGlassWell(cornerRadius: 12)
    }

    private func monthCompactGrid(for date: Date) -> some View {
        let cal = Calendar.current
        let y = cal.component(.year, from: date)
        let m = cal.component(.month, from: date)
        let first = cal.date(from: DateComponents(year: y, month: m, day: 1)) ?? date
        let offset = (cal.component(.weekday, from: first) + 5) % 7
        let count = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        return LazyVGrid(columns: cols, spacing: 3) {
            ForEach(0..<(offset + count), id: \.self) { i in
                if i < offset {
                    Color.clear.frame(height: 18)
                } else {
                    let day = i - offset + 1
                    let k = String(format: "%04d-%02d-%02d", y, m, day)
                    Button { selectedDateKey = k } label: {
                        Text("\(day)")
                            .font(.system(size: 10, weight: k == selectedDateKey ? .bold : .regular, design: .monospaced))
                            .foregroundStyle(k == selectedDateKey ? .white : LiquidGlassPalette.inkPrimary(scheme))
                            .frame(width: 22, height: 18)
                            .background(k == selectedDateKey ? LiquidGlassPalette.sapphire : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(6)
        .liquidGlassWell(cornerRadius: 12)
    }

    // MARK: Lower Notes & To-Do (Optional Local Reminders / Notes Connection, Non-Destructive!)

    private var lowerNotesAndTodoSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    Button("随手便签") { lowerMode = "note" }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: lowerMode == "note" ? .semibold : .regular))
                        .padding(.horizontal, 8).padding(.vertical, 2.5)
                        .background(lowerMode == "note" ? Color.white.opacity(scheme == .dark ? 0.16 : 0.92) : .clear, in: Capsule())
                    Button("待办清单") { lowerMode = "todo" }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: lowerMode == "todo" ? .semibold : .regular))
                        .padding(.horizontal, 8).padding(.vertical, 2.5)
                        .background(lowerMode == "todo" ? Color.white.opacity(scheme == .dark ? 0.16 : 0.92) : .clear, in: Capsule())
                }
                .padding(2)
                .liquidGlassWell(cornerRadius: 12)

                Spacer(minLength: 4)

                if lowerMode == "todo" {
                    Button {
                        syncHub.toggleAppleReminders()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "apple.logo").font(.system(size: 9))
                            Text(syncHub.appleRemindersEnabled ? "提醒事项已合并 ✓" : "仅岛内 · 连提醒事项")
                        }
                        .font(.system(size: 10, weight: syncHub.appleRemindersEnabled ? .semibold : .medium))
                        .foregroundStyle(syncHub.appleRemindersEnabled ? LiquidGlassPalette.sapphire : LiquidGlassPalette.inkSecondary(scheme))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .liquidGlassPill(selected: syncHub.appleRemindersEnabled)
                    }
                    .buttonStyle(.plain)

                    Button(addingTodo ? "收起" : "+ 待办") {
                        withAnimation(.easeOut(duration: 0.15)) { addingTodo.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LiquidGlassPalette.sapphire)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .liquidGlassWell(cornerRadius: 10)
                } else {
                    Button {
                        syncHub.toggleAppleNotes()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "apple.logo").font(.system(size: 9))
                            Text(syncHub.appleNotesEnabled ? "备忘录已并存 ✓" : "仅岛内 · 连备忘录")
                        }
                        .font(.system(size: 10, weight: syncHub.appleNotesEnabled ? .semibold : .medium))
                        .foregroundStyle(syncHub.appleNotesEnabled ? LiquidGlassPalette.sapphire : LiquidGlassPalette.inkSecondary(scheme))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .liquidGlassPill(selected: syncHub.appleNotesEnabled)
                    }
                    .buttonStyle(.plain)

                    Button("+ 便签") {
                        if let created = createDesktopBackedNote?() ?? noteStore.create(openOnDesktop: false) {
                            selectedNoteID = "local_\(created.uuidString)"
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LiquidGlassPalette.sapphire)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .liquidGlassWell(cornerRadius: 10)

                    if let activeLocal = activeLocalStickyNote {
                        Button {
                            togglePinDesktopNote?(activeLocal.id)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: activeLocal.isOpen ? "pin.fill" : "pin").font(.system(size: 9.5))
                                Text(activeLocal.isOpen ? "已钉桌面" : "钉桌面")
                            }
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .liquidGlassWell(cornerRadius: 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if lowerMode == "todo" {
                todoListSection
            } else {
                notesEditorSection
            }
        }
    }

    private var todoListSection: some View {
        let items = syncHub.mergedTodos
        return VStack(alignment: .leading, spacing: 6) {
            if addingTodo {
                HStack(spacing: 6) {
                    TextField("输入新待办回车保存（开启提醒事项后并存不覆盖）…", text: $newTodoText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .focused($fieldFocused)
                        .onSubmit {
                            syncHub.addLocalTodo(text: newTodoText)
                            newTodoText = ""
                            addingTodo = false
                        }
                    Button("添加") {
                        syncHub.addLocalTodo(text: newTodoText)
                        newTodoText = ""
                        addingTodo = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(LiquidGlassPalette.sapphire, in: Capsule())
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .liquidGlassWell(cornerRadius: 10)
            }

            if items.isEmpty {
                Text("暂无待办事项，点击右上角 + 待办添加，或可选连接提醒事项。")
                    .font(.system(size: 11))
                    .foregroundStyle(LiquidGlassPalette.inkTertiary(scheme))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .liquidGlassWell(cornerRadius: 12)
            } else {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(items) { item in
                            HStack(spacing: 8) {
                                Button { syncHub.toggleTodo(item) } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: item.done ? "checkmark.square.fill" : "square")
                                            .font(.system(size: 12))
                                            .foregroundStyle(item.done ? LiquidGlassPalette.sapphire : LiquidGlassPalette.inkTertiary(scheme))
                                        Text(item.text)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .strikethrough(item.done)
                                            .opacity(item.done ? 0.55 : 1)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Text(item.origin.badgeText)
                                    .font(.system(size: 9))
                                    .foregroundStyle(item.origin == .appleReminders ? LiquidGlassPalette.sapphire : LiquidGlassPalette.inkTertiary(scheme))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .liquidGlassPill()

                                if let uuid = item.localUUID {
                                    Button { syncHub.deleteLocalTodo(id: uuid) } label: {
                                        Image(systemName: "xmark").font(.system(size: 8.5)).foregroundStyle(LiquidGlassPalette.inkTertiary(scheme))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                }
                .frame(maxHeight: 84)
                .liquidGlassWell(cornerRadius: 12)
            }
        }
    }

    private var activeLocalStickyNote: StickyNote? {
        if selectedNoteID.hasPrefix("local_"),
           let uuid = UUID(uuidString: String(selectedNoteID.dropFirst(6))),
           let found = noteStore.notes.first(where: { $0.id == uuid }) {
            return found
        }
        if selectedNoteID.hasPrefix("apple_") { return nil }
        return noteStore.notes.first
    }

    private var notesEditorSection: some View {
        let localNotes = noteStore.notes
        let extNotes = syncHub.appleNotesEnabled ? syncHub.externalAppleNotes : []
        return VStack(alignment: .leading, spacing: 5) {
            if localNotes.count + extNotes.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(localNotes) { n in
                            let tag = "local_\(n.id.uuidString)"
                            let active = activeLocalStickyNote?.id == n.id
                            Button { selectedNoteID = tag } label: {
                                Text("岛内 · \(noteHeading(n.text))")
                                    .font(.system(size: 10, weight: active ? .semibold : .regular))
                                    .foregroundStyle(active ? LiquidGlassPalette.sapphire : LiquidGlassPalette.inkSecondary(scheme))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .liquidGlassPill(selected: active)
                            }.buttonStyle(.plain)
                        }
                        ForEach(extNotes) { an in
                            let tag = "apple_\(an.id)"
                            let active = selectedNoteID == tag
                            Button { selectedNoteID = tag } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: "apple.logo").font(.system(size: 8.5))
                                    Text(an.title)
                                }
                                .font(.system(size: 10, weight: active ? .semibold : .regular))
                                .foregroundStyle(active ? LiquidGlassPalette.sapphire : LiquidGlassPalette.inkSecondary(scheme))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .liquidGlassPill(selected: active)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }

            if selectedNoteID.hasPrefix("apple_"),
               let ext = extNotes.first(where: { "apple_\($0.id)" == selectedNoteID }) {
                VStack(alignment: .leading, spacing: 4) {
                    ScrollView {
                        Text(ext.plainBody.isEmpty ? "（空备忘录）" : ext.plainBody)
                            .font(.system(size: 11.5))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 58)
                    HStack {
                        Text("来自本地「备忘录」只读并存视图").font(.system(size: 9.5)).foregroundStyle(LiquidGlassPalette.inkTertiary(scheme))
                        Spacer()
                        Button("复制为岛内独立便签") {
                            if let id = noteStore.create(openOnDesktop: false) {
                                noteStore.updateText("\(ext.title)\n\(ext.plainBody)", id: id)
                                selectedNoteID = "local_\(id.uuidString)"
                                syncHub.postNotice("已派生为独立岛内便签，可自由编辑与钉在桌面")
                            }
                        }
                        .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(LiquidGlassPalette.sapphire)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .liquidGlassWell(cornerRadius: 12)
            } else if let note = activeLocalStickyNote {
                TextEditor(text: Binding(
                    get: { noteStore.text(for: note.id) },
                    set: { noteStore.updateText($0, id: note.id) }
                ))
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .focused($fieldFocused)
                .frame(height: 62)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .liquidGlassWell(cornerRadius: 12)
            } else {
                Button {
                    if let id = noteStore.create(openOnDesktop: false) {
                        selectedNoteID = "local_\(id.uuidString)"
                        fieldFocused = true
                    }
                } label: {
                    HStack {
                        Image(systemName: "square.and.pencil")
                        Text("点击创建第一条随手便签（后续连接本地备忘录时独立保留，绝不覆盖）")
                        Spacer()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                    .padding(10)
                    .liquidGlassWell(cornerRadius: 12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func commitNewEvent() {
        guard !newEventTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        syncHub.addLocalEvent(dateKey: selectedDateKey, timeText: newEventTime, title: newEventTitle)
        newEventTitle = ""
        addingEvent = false
    }

    private func stepDate(_ delta: Int) {
        let cal = Calendar.current
        let cur = MoriqSyncHub.date(fromKey: selectedDateKey)
        let next: Date
        switch span {
        case .day: next = cal.date(byAdding: .day, value: delta, to: cur) ?? cur
        case .week: next = cal.date(byAdding: .day, value: delta * 7, to: cur) ?? cur
        case .month: next = cal.date(byAdding: .month, value: delta, to: cur) ?? cur
        }
        selectedDateKey = MoriqSyncHub.dateKey(from: next)
    }

    private func noteHeading(_ raw: String) -> String {
        let first = raw.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return first.isEmpty ? "新速记" : String(first.prefix(10))
    }
}

struct GoogleCalendarConnectSheet: View {
    @ObservedObject var syncHub: MoriqSyncHub
    @Environment(\.dismiss) private var dismiss
    @State private var feedInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("连接 Google 日历（非破坏并存合并）").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            Text("无论选择哪种连接方式，MORIQ 均将 Google 日程与您已在灵动岛建立的排期及本地日历并列合并，绝不清空或覆盖已有内容。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("方式一：系统互联网账户直连（推荐 · 支持双向与自动续期）").font(.system(size: 12.5, weight: .semibold))
                Text("在 macOS「系统设置 → 互联网账户」登录 Google 后，MORIQ 自动识别 Google 日历与 Google Meet 一键入会链接。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("打开系统互联网账户并启用合并") {
                    syncHub.openSystemInternetAccountsForGoogle()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(12)
            .liquidGlassWell(cornerRadius: 12)

            VStack(alignment: .leading, spacing: 8) {
                Text("方式二：粘贴 Google Calendar 私密 iCal 地址（免系统挂载）").font(.system(size: 12.5, weight: .semibold))
                TextField("https://calendar.google.com/calendar/ical/.../basic.ics", text: $feedInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("保存并合并拉取") {
                        syncHub.saveGoogleFeedAndConnect(feedInput)
                        dismiss()
                    }
                    .disabled(feedInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(12)
            .liquidGlassWell(cornerRadius: 12)
        }
        .padding(20)
        .frame(width: 470)
        .onAppear { feedInput = syncHub.googleFeedURLString }
    }
}

// MARK: - Pinned Top DIY Canvas + Scrollable Multi-Style Showcase Studio (Settings View)

struct IslandStudioSettingsView: View {
    @ObservedObject var tabModel: IslandPreviewContent
    @ObservedObject var bentoStore = IslandBentoStore.shared
    @ObservedObject var syncHub = MoriqSyncHub.shared
    @ObservedObject var telemetry = SystemTelemetryStore.shared

    @State private var subTab: String = "canvas" // "canvas", "tabs", "sync", "hardware"
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top Studio Mode Bar
            HStack(spacing: 4) {
                studioTabButton("canvas", "置顶画布与样式库")
                studioTabButton("tabs", "顶栏 Tab 自定义")
                studioTabButton("sync", "日历·待办同步")
                studioTabButton("ai_quota", "AI 余量连接")
                studioTabButton("hardware", "本机硬件与胶囊")
            }
            .padding(3)
            .liquidGlassWell(cornerRadius: 12)

            if subTab == "canvas" {
                pinnedCanvasAndDrawerView
            } else if subTab == "tabs" {
                topTabsCustomizationView
            } else if subTab == "sync" {
                syncHubSettingsView
            } else if subTab == "ai_quota" {
                aiQuotaSettingsView
            } else {
                hardwareAndCompactSettingsView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $syncHub.showingGoogleConnectSheet) {
            GoogleCalendarConnectSheet(syncHub: syncHub)
        }
        .onAppear { telemetry.retainSampling() }
        .onDisappear { telemetry.releaseSampling() }
    }

    private func studioTabButton(_ id: String, _ label: String) -> some View {
        Button {
            subTab = id
        } label: {
            Text(label)
                .font(.system(size: 11.5, weight: subTab == id ? .semibold : .medium))
                .foregroundStyle(subTab == id ? LiquidGlassPalette.inkPrimary(scheme) : LiquidGlassPalette.inkSecondary(scheme))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(subTab == id ? Color.white.opacity(scheme == .dark ? 0.16 : 0.92) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    // 1. Pinned Top Canvas + Independent Scrollable Multi-Style Showcase Drawer
    private var pinnedCanvasAndDrawerView: some View {
        let filteredWidgets: [BentoWidgetID] = {
            if let spot = bentoStore.spotlightWidget { return [spot] }
            if bentoStore.selectedCategory == .all { return BentoWidgetID.allCases }
            return BentoWidgetID.allCases.filter { $0.category == bentoStore.selectedCategory }
        }()

        return VStack(alignment: .leading, spacing: 10) {
            // PINNED TOP CANVAS (Never scrolls away!)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 6) {
                        Circle().fill(LiquidGlassPalette.sapphire).frame(width: 7, height: 7)
                        Text("灵动岛首屏置顶画布（已用 \(bentoStore.usedCells)/\(bentoStore.gridMaxCells) 格 · 悬停卡片换样式或拖拽排序）")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    Spacer()
                    HStack(spacing: 3) {
                        ForEach([8, 12, 16], id: \.self) { cap in
                            Button("\(cap)格") { bentoStore.setCapacity(cap) }
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5, weight: bentoStore.gridMaxCells == cap ? .semibold : .regular))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(bentoStore.gridMaxCells == cap ? Color.white.opacity(scheme == .dark ? 0.18 : 0.94) : .clear, in: Capsule())
                        }
                    }
                    .padding(2)
                    .liquidGlassWell(cornerRadius: 12)
                }

                BentoDenseCanvasGridView(bentoStore: bentoStore, editable: true, rowHeight: 68, spacing: 7)
            }
            .padding(11)
            .liquidGlassWell(cornerRadius: 16)

            // Category Filter / Spotlight Header
            HStack {
                if let spot = bentoStore.spotlightWidget {
                    HStack(spacing: 8) {
                        Text("正在挑选「\(spot.title)」的 \(spot.variants.count) 款样式与尺寸")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(LiquidGlassPalette.sapphire)
                        Button("← 查看全部 \(BentoWidgetID.allCases.count) 个组件") {
                            bentoStore.spotlightWidget = nil
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .liquidGlassPill()
                    }
                } else {
                    HStack(spacing: 3) {
                        ForEach(BentoCategory.allCases) { cat in
                            Button(cat.title) { bentoStore.selectedCategory = cat }
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5, weight: bentoStore.selectedCategory == cat ? .semibold : .regular))
                                .padding(.horizontal, 9).padding(.vertical, 3.5)
                                .background(bentoStore.selectedCategory == cat ? Color.white.opacity(scheme == .dark ? 0.16 : 0.92) : .clear, in: Capsule())
                        }
                    }
                    .padding(2)
                    .liquidGlassWell(cornerRadius: 14)
                }
                Spacer()
                Text("点按直接选用或拖入上方画布")
                    .font(.system(size: 10.5))
                    .foregroundStyle(LiquidGlassPalette.inkTertiary(scheme))
            }

            // INDEPENDENT SCROLLABLE MULTI-STYLE DRAWER
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(filteredWidgets) { wid in
                        let currentKey = bentoStore.activeCanvas.first(where: { $0.widgetID == wid })?.variantKey
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(wid.title).font(.system(size: 12, weight: .semibold))
                                Text(wid.subtitle).font(.system(size: 10.5)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme)).lineLimit(1)
                                Spacer()
                                Text("共 \(wid.variants.count) 款样式")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .liquidGlassPill()
                            }

                            VariantShowcaseFlowView(widget: wid, activeVariantKey: currentKey) { chosenKey in
                                bentoStore.selectOrInsert(widget: wid, variantKey: chosenKey)
                            }
                        }
                        .padding(11)
                        .liquidGlassWell(cornerRadius: 15)
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 2)
            }
        }
    }

    // 2. Top Tab Bar Customization (Max 8 Tabs, Always Active-Only Expanded Label)
    private var topTabsCustomizationView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("启用模块与显示顺序").font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        Text("已选 \(tabModel.selection.enabled.count)/\(IslandModuleSelection.maxEnabledCount) 个（最多 \(IslandModuleSelection.maxEnabledCount) 个）")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(LiquidGlassPalette.sapphire)
                    }
                    ForEach(IslandModule.allCases) { module in
                        let isEnabled = tabModel.selection.enabled.contains(module)
                        let atCap = !isEnabled && tabModel.selection.enabled.count >= IslandModuleSelection.maxEnabledCount
                        HStack {
                            Image(systemName: module.islandSymbolName).frame(width: 20).foregroundStyle(LiquidGlassPalette.sapphire)
                            Text(module.title).font(.system(size: 12.5, weight: .medium))
                            Spacer()
                            if let index = tabModel.selection.enabled.firstIndex(of: module) {
                                Button { tabModel.move(module, to: index - 1) } label: { Image(systemName: "chevron.up") }
                                    .buttonStyle(.borderless).disabled(index == 0).accessibilityLabel("上移\(module.title)")
                                Button { tabModel.move(module, to: index + 1) } label: { Image(systemName: "chevron.down") }
                                    .buttonStyle(.borderless).disabled(index == tabModel.selection.enabled.count - 1).accessibilityLabel("下移\(module.title)")
                            }
                            Toggle("", isOn: Binding(
                                get: { isEnabled },
                                set: { enabled in
                                    if !enabled && tabModel.selection.enabled.count <= 1 { return }
                                    if enabled && tabModel.selection.enabled.count >= IslandModuleSelection.maxEnabledCount {
                                        telemetry.showToast("顶栏 Tab 最多启用 \(IslandModuleSelection.maxEnabledCount) 个，请先关闭一个")
                                        return
                                    }
                                    tabModel.setEnabled(module, enabled)
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(atCap)
                        }
                        .opacity(atCap ? 0.55 : 1.0)
                        .padding(.vertical, 3)
                    }
                }
                .padding(12)
                .liquidGlassWell(cornerRadius: 14)
            }
        }
    }

    // 3. Non-Destructive Sync Hub Settings
    private var syncHubSettingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("非破坏并存合并保障 · 新连接绝不覆盖已有内容").font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        Text("独立主键隔离")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(LiquidGlassPalette.sapphire)
                            .padding(.horizontal, 8).padding(.vertical, 2).liquidGlassPill()
                    }
                    Text("您在灵动岛内自建的日程（\(syncHub.localEvents.count) 条）、待办（\(syncHub.localTodos.count) 条）和屏幕便签拥有独立存储主键。无论何时开启本地日历、Google 日历、提醒事项或备忘录连接，外部数据仅做并列合并展示，绝不覆盖已有内容；随时断开连接也完整保留岛内记录。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .liquidGlassWell(cornerRadius: 14)

                VStack(alignment: .leading, spacing: 10) {
                    Text("日程数据源（可多选并存，自动按 iCalUID 去重）").font(.system(size: 12.5, weight: .semibold))
                    HStack {
                        Label("macOS 本地日历 (EventKit · Calendar / iCloud)", systemImage: "apple.logo").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Toggle("", isOn: Binding(get: { syncHub.appleCalEnabled }, set: { _ in syncHub.toggleAppleCalendar() }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    Divider()
                    HStack {
                        Label("Google 日历 (互联网账户 CalDAV 或私密 iCal 链接)", systemImage: "globe").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("配置链接") { syncHub.showingGoogleConnectSheet = true }.controlSize(.small)
                        Toggle("", isOn: Binding(get: { syncHub.googleCalEnabled }, set: { _ in syncHub.toggleGoogleCalendar() }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
                .padding(12)
                .liquidGlassWell(cornerRadius: 14)

                VStack(alignment: .leading, spacing: 10) {
                    Text("随手便签与待办清单（自由可选，也可完全不连接仅用岛内存储）").font(.system(size: 12.5, weight: .semibold))
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("连接本地「提醒事项」(Apple Reminders)", systemImage: "checklist").font(.system(size: 12, weight: .medium))
                            Text(syncHub.appleRemindersEnabled ? "已与岛内待办合并显示" : "未连接 · 当前仅保存在灵动岛内").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { syncHub.appleRemindersEnabled }, set: { _ in syncHub.toggleAppleReminders() }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("连接本地「备忘录」(Apple Notes)", systemImage: "note.text").font(.system(size: 12, weight: .medium))
                            Text(syncHub.appleNotesEnabled ? "已并存展示本地备忘录（不覆盖岛内便签）" : "未连接 · 当前仅保存在灵动岛内").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { syncHub.appleNotesEnabled }, set: { _ in syncHub.toggleAppleNotes() }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
                .padding(12)
                .liquidGlassWell(cornerRadius: 14)
            }
        }
    }

    // 3b. AI Quota Read-Only Sync & Low-Quota Alert Settings (No Fake Draggable Sliders)
    private var aiQuotaSettingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("AI 实时余量连接 · 只读遥测同步与低余量预警").font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        Text("免 CLI 实时直读")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(LiquidGlassPalette.sapphire)
                            .padding(.horizontal, 8).padding(.vertical, 2).liquidGlassPill()
                    }
                    Text("各平台额度由本机应用状态、授权窗口或 API 账单自动只读同步（不可手动拖拽篡改），您可自由开关在灵动岛内的展示并设定低余量提醒阈值。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .liquidGlassWell(cornerRadius: 14)

                ForEach(telemetry.aiProviders) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { item.enabled },
                                set: { _ in telemetry.toggleAIProviderEnabled(item.id) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)

                            Text("\(item.name) · \(item.plan)")
                                .font(.system(size: 12.5, weight: .semibold))

                            Text(item.badge)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(LiquidGlassPalette.sapphire)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .liquidGlassPill()

                            Spacer()

                            Text(item.lastSyncedText)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(LiquidGlassPalette.inkTertiary(scheme))

                            Button {
                                telemetry.syncAIProviderNow(item.id)
                            } label: {
                                Label(item.id == "cursor" ? "同步本机" : "立即同步", systemImage: "arrow.clockwise")
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                            .controlSize(.small)
                        }

                        // 100% Read-Only Optical Progress Bar (Never a draggable slider!)
                        HStack(spacing: 10) {
                            Text(item.windowText)
                                .font(.system(size: 10.5))
                                .foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                                .frame(width: 96, alignment: .leading)
                                .lineLimit(1)

                            MultiSegmentTelemetryBar(
                                primaryFraction: Double(item.percent) / 100.0,
                                secondaryFraction: 0
                            )
                            .opacity(item.enabled ? 1.0 : 0.4)

                            Text("\(item.percent)%")
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(item.percent <= max(10, item.alertThreshold) ? Color.orange : LiquidGlassPalette.sapphire)
                                .frame(width: 40, alignment: .trailing)
                        }

                        HStack(spacing: 6) {
                            Text("低余量提醒阈值：")
                                .font(.system(size: 10.5))
                                .foregroundStyle(LiquidGlassPalette.inkTertiary(scheme))
                            ForEach([(20, "< 20% 预警"), (10, "< 10% 预警"), (0, "不提醒")], id: \.0) { val, label in
                                let selected = item.alertThreshold == val
                                Button {
                                    telemetry.setAIProviderAlertThreshold(item.id, threshold: val)
                                } label: {
                                    Text(label)
                                        .font(.system(size: 10, weight: selected ? .semibold : .regular))
                                        .foregroundStyle(selected ? LiquidGlassPalette.sapphire : LiquidGlassPalette.inkSecondary(scheme))
                                        .padding(.horizontal, 8).padding(.vertical, 2.5)
                                        .liquidGlassPill(selected: selected)
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                    }
                    .padding(12)
                    .liquidGlassWell(cornerRadius: 14)
                }
            }
        }
    }

    // 4. Real Hardware & Live Compact Capsule Visual DIY Composer
    private var hardwareAndCompactSettingsView: some View {
        let hw = telemetry.hardware
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Live 1:1 Top-Bezel Visual Preview + 3 Shell Cards + 9-Slot DIY Composer
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Circle().fill(LiquidGlassPalette.sapphire).frame(width: 7, height: 7)
                        Text("收起态小胶囊 · 1:1 屏幕顶边实时预览与自由拼装").font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        Text("已拼装 \(bentoStore.compactSlots.count)/3 槽位")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(LiquidGlassPalette.sapphire)
                    }

                    // Simulated Top Screen Edge Preview Stage
                    VStack(spacing: 6) {
                        HStack {
                            Text(" Finder · 文件 · 编辑").font(.system(size: 9.5))
                            Spacer()
                            Text("屏幕顶边 1:1 实时预览").font(.system(size: 9.5))
                            Spacer()
                            Text("16:30").font(.system(size: 9.5, design: .monospaced))
                        }
                        .foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                        .padding(.horizontal, 10)

                        LiveCompactCapsulePreviewView(bentoStore: bentoStore)
                    }
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(
                            colors: [
                                LiquidGlassPalette.sapphire.opacity(0.13),
                                Color.secondary.opacity(0.10),
                                LiquidGlassPalette.sapphireLight.opacity(0.11)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )

                    // 3 Shell Style Cards with Visual Miniature Previews
                    HStack(spacing: 8) {
                        ForEach(CompactShellStyle.allCases) { sh in
                            let active = bentoStore.compactShell == sh
                            Button {
                                withAnimation(.easeOut(duration: 0.16)) { bentoStore.compactShell = sh }
                            } label: {
                                VStack(spacing: 6) {
                                    Group {
                                        if sh == .hairline {
                                            Capsule().fill(LiquidGlassPalette.sapphire.opacity(0.75)).frame(width: 56, height: 4)
                                        } else if sh == .obsidianNotch {
                                            Text("CPU 38% · GPU 41%")
                                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 9).padding(.vertical, 4)
                                                .background(Color(red: 0.06, green: 0.07, blue: 0.10), in: Capsule())
                                        } else {
                                            Text("CPU 38% · GPU 41%")
                                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                                .padding(.horizontal, 9).padding(.vertical, 4)
                                                .liquidGlassPill(selected: true)
                                        }
                                    }
                                    .frame(height: 24)

                                    Text(sh.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(active ? LiquidGlassPalette.sapphire : LiquidGlassPalette.inkPrimary(scheme))
                                    Text(sh.subtitle)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(LiquidGlassPalette.inkTertiary(scheme))
                                        .lineLimit(1)
                                }
                                .padding(9)
                                .frame(maxWidth: .infinity)
                                .liquidGlassTile(cornerRadius: 14)
                                .overlay {
                                    if active {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(LiquidGlassPalette.sapphire, lineWidth: 2)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if bentoStore.compactShell != .hairline {
                        // Active Ordered Slots Bar
                        HStack(spacing: 6) {
                            ForEach(Array(bentoStore.compactSlots.enumerated()), id: \.element.id) { idx, slot in
                                HStack(spacing: 4) {
                                    Text("\(idx + 1)")
                                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white)
                                        .frame(width: 15, height: 15)
                                        .background(LiquidGlassPalette.sapphire, in: Circle())
                                    Text(slot.title).font(.system(size: 10.5, weight: .semibold))
                                    if idx > 0 {
                                        Button { bentoStore.moveCompactSlot(at: idx, delta: -1) } label: { Image(systemName: "chevron.left").font(.system(size: 8.5)) }.buttonStyle(.plain)
                                    }
                                    if idx < bentoStore.compactSlots.count - 1 {
                                        Button { bentoStore.moveCompactSlot(at: idx, delta: 1) } label: { Image(systemName: "chevron.right").font(.system(size: 8.5)) }.buttonStyle(.plain)
                                    }
                                    Button { bentoStore.toggleCompactSlot(slot) } label: { Image(systemName: "xmark").font(.system(size: 8.5)) }.buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .liquidGlassPill(selected: true)
                            }
                            Spacer()
                        }

                        // 9 Live Data Token Grid
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                            ForEach(CompactCapsuleSlot.allCases) { slot in
                                let idx = bentoStore.compactSlots.firstIndex(of: slot)
                                let isOn = idx != nil
                                Button {
                                    bentoStore.toggleCompactSlot(slot)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(slot.title).font(.system(size: 10.5, weight: isOn ? .semibold : .medium)).lineLimit(1)
                                            Text(LiveCompactCapsulePreviewView.slotPreviewString(slot, telemetry: telemetry, syncHub: syncHub, focusStore: FocusTimerStore.shared))
                                                .font(.system(size: 9.5, design: .monospaced))
                                                .foregroundStyle(LiquidGlassPalette.sapphire)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 2)
                                        Text(idx.map { "#\($0 + 1)" } ?? "+")
                                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                            .foregroundStyle(LiquidGlassPalette.sapphire)
                                    }
                                    .padding(.horizontal, 9).padding(.vertical, 6)
                                    .liquidGlassWell(cornerRadius: 10)
                                    .overlay {
                                        if isOn {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .strokeBorder(LiquidGlassPalette.sapphire, lineWidth: 1.5)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(12)
                .liquidGlassWell(cornerRadius: 15)

                // Real Hardware Readout Card
                VStack(alignment: .leading, spacing: 8) {
                    Text("本机真实传感器直读（只读系统内核，无伪造型号选择）").font(.system(size: 12.5, weight: .semibold))
                    HStack(spacing: 10) {
                        Text("机型：\(hw.marketingName) (\(hw.modelIdentifier))").font(.system(size: 11.5, design: .monospaced))
                        Spacer()
                        Text("芯片：\(hw.chipFull) (\(hw.coreCount)核)").font(.system(size: 11.5, design: .monospaced))
                    }
                    HStack(spacing: 10) {
                        Text(String(format: "统一内存：%.1f / %.0f GB", hw.ramUsedGB, hw.ramTotalGB)).font(.system(size: 11.5, design: .monospaced))
                        Spacer()
                        Text(String(format: "内置闪存：可用 %.0f GB / %@", hw.ssdAvailableGB, hw.ssdTotalDisplay)).font(.system(size: 11.5, design: .monospaced))
                    }
                    TextField("可选：自定义设备显示昵称（留空显示真实机型）", text: $telemetry.customNickname)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(12)
                .liquidGlassWell(cornerRadius: 14)
            }
        }
    }
}

struct LiveCompactCapsulePreviewView: View {
    @ObservedObject var bentoStore: IslandBentoStore
    @ObservedObject var telemetry = SystemTelemetryStore.shared
    @ObservedObject var syncHub = MoriqSyncHub.shared
    @ObservedObject var focusStore = FocusTimerStore.shared
    @Environment(\.colorScheme) private var scheme

    static func slotPreviewString(_ slot: CompactCapsuleSlot, telemetry: SystemTelemetryStore, syncHub: MoriqSyncHub, focusStore: FocusTimerStore) -> String {
        switch slot {
        case .cpu: return "CPU \(Int(telemetry.cpuPercent.rounded()))%"
        case .gpu: return "GPU \(Int(telemetry.gpuPercent.rounded()))%"
        case .ram: return "内存 \(Int(telemetry.hardware.ramPercent.rounded()))%"
        case .net: return String(format: "↓ %.1fM", telemetry.netDownMBps)
        case .battery: return String(format: "%d%% · %.0fW", telemetry.batteryPercent, telemetry.powerWatts)
        case .aiQuota:
            let top = telemetry.aiProviders.first(where: \.enabled) ?? telemetry.aiProviders.first
            return top.map { "\($0.name) \($0.percent)%" } ?? "AI 84%"
        case .meeting:
            let ev = syncHub.mergedEvents(for: MoriqSyncHub.dateKey(from: Date())).first
            return ev.map { "\($0.sortKey) \(String($0.title.prefix(5)))" } ?? "今日空闲"
        case .focus:
            return focusStore.displayTime
        case .music:
            return "♪ 音乐"
        }
    }

    var body: some View {
        if bentoStore.compactShell == .hairline {
            Capsule()
                .fill(LiquidGlassPalette.sapphire.opacity(0.78))
                .frame(width: 72, height: 4.5)
                .frame(height: 28)
        } else {
            let texts = bentoStore.compactSlots.map {
                Self.slotPreviewString($0, telemetry: telemetry, syncHub: syncHub, focusStore: focusStore)
            }
            let obsidian = bentoStore.compactShell == .obsidianNotch
            HStack(spacing: 7) {
                ForEach(Array(texts.enumerated()), id: \.offset) { i, txt in
                    if i > 0 {
                        Text("·").opacity(0.35)
                    }
                    Text(txt)
                }
            }
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(obsidian ? Color.white : LiquidGlassPalette.inkPrimary(scheme))
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background {
                if obsidian {
                    Capsule()
                        .fill(Color(red: 0.05, green: 0.06, blue: 0.09))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
                }
            }
            .modifier(ConditionalCompactGlassModifier(enabled: !obsidian))
        }
    }
}

private struct ConditionalCompactGlassModifier: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.liquidGlassPanel(cornerRadius: 14, strong: true)
        } else {
            content
        }
    }
}

private struct VariantShowcaseFlowView: View {
    let widget: BentoWidgetID
    let activeVariantKey: String?
    let onSelect: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let rows = chunkVariants(widget.variants)
        let rowHeights: [CGFloat] = rows.map { r in
            (r.contains(where: { $0.h == 2 }) ? 140 : 68) + 26
        }
        let totalH = rowHeights.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * 8
        GeometryReader { geo in
            let spacing: CGFloat = 8
            let unitW = max(96, (geo.size.width - spacing * 3) / 4.0)
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(row) { vr in
                            let isActive = activeVariantKey == vr.key
                            let previewH: CGFloat = vr.h == 2 ? 140 : 68
                            let cardW = unitW * CGFloat(vr.w) + spacing * CGFloat(max(0, vr.w - 1))
                            VStack(alignment: .leading, spacing: 4) {
                                BentoWidgetTileView(entry: BentoCanvasEntry(widgetID: widget, variantKey: vr.key), previewOnly: true)
                                    .frame(height: previewH)
                                    .overlay {
                                        if isActive {
                                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                                .strokeBorder(LiquidGlassPalette.sapphire, lineWidth: 2)
                                        }
                                    }
                                    .padding(2) // Prevents top/right selection border clipping!
                                    .contentShape(Rectangle())
                                    .onTapGesture { onSelect(vr.key) }
                                    .onDrag {
                                        NSItemProvider(object: "moriq_bento:\(widget.rawValue):\(vr.key)" as NSString)
                                    }

                                HStack {
                                    Text(vr.title)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(isActive ? LiquidGlassPalette.sapphire : LiquidGlassPalette.inkSecondary(scheme))
                                        .lineLimit(1)
                                    Spacer(minLength: 2)
                                    Text(isActive ? "使用中 ✓" : "+ 选用")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(LiquidGlassPalette.sapphire)
                                }
                                .padding(.horizontal, 4)
                            }
                            .frame(width: cardW)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(height: totalH)
    }

    private func chunkVariants(_ list: [BentoVariantSpec]) -> [[BentoVariantSpec]] {
        var rows: [[BentoVariantSpec]] = []
        var cur: [BentoVariantSpec] = []
        var colsUsed = 0
        for v in list {
            if colsUsed + v.w > 4 && !cur.isEmpty {
                rows.append(cur)
                cur = []
                colsUsed = 0
            }
            cur.append(v)
            colsUsed += v.w
        }
        if !cur.isEmpty { rows.append(cur) }
        return rows
    }
}
