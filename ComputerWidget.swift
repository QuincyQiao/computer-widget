import AppKit
import SwiftUI
import IOKit
import ServiceManagement

/// 电脑活动：几块卡片——总览（CPU 大数字，GPU、内存两个圆环）、CPU 分类（渲染、云同步、Claude、浏览器、其他程序、系统）、
/// 渲染排队（可选，设了排队文件夹才有；每个位子谁在用，点开看排着的全部）、最占 CPU（显示几个自己调，点开看前 20 个）。百分比都按整台电脑算（8 个核加起来是 100%）。
/// 哪几块显示、先后顺序在「自定义」里勾、拖。布局按 360 点的设计宽度画，窗口变宽变窄整体缩放；
/// 窗口高度决定显示前几块，压矮从排在最后的那块开始收起，最矮只剩顶上的排队状态（和充电小组件一个做法）。
/// 同一个数只显示一处：顶上的排队状态只在渲染排队那块没显示时出现，CPU 分类的合计只在总览没显示时出现。
/// CPU 满了以后再看百分比看不出满到什么程度，旁边加「超载几倍」：1 分钟平均负载 ÷ 核数，也就是每个核有几个线程在抢。

enum Module: String, CaseIterable, Identifiable {
    case overview, cpu, queue, hogs
    var id: String { rawValue }
    var name: String {
        switch self {
        case .overview: "总览"
        case .cpu: "CPU 分类"
        case .queue: "渲染排队"
        case .hogs: "最占 CPU"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .cpu: "chart.bar.fill"
        case .queue: "square.stack.3d.up.fill"
        case .hogs: "flame.fill"
        }
    }
}

/// 用户自己定的：显示哪几块、先后、最占 CPU 显示几个。存在 UserDefaults
@MainActor final class Settings: ObservableObject {
    static let shared = Settings()
    static let hogRange = 1...10
    /// 改了以后叫一声：模块开关、顺序变了要把窗口撑到全显示；只改了个数就保持现在显示几块
    var onChange: ((_ modulesChanged: Bool) -> Void)?

    @Published var order: [Module] { didSet { save(); onChange?(true) } }
    @Published var hidden: Set<Module> { didSet { save(); onChange?(true) } }
    @Published var hogCount: Int { didSet { save(); onChange?(false) } }

    var shown: [Module] { order.filter { !hidden.contains($0) } }
    /// 没设排队文件夹就没有渲染排队这一块
    static var modules: [Module] { Module.allCases.filter { $0 != .queue || RenderQueue.folder != nil } }

    init() {
        let d = UserDefaults.standard
        let saved = (d.stringArray(forKey: "moduleOrder") ?? []).compactMap(Module.init(rawValue:))
        order = saved.filter(Settings.modules.contains) + Settings.modules.filter { !saved.contains($0) }
        hidden = Set((d.stringArray(forKey: "hiddenModules") ?? []).compactMap(Module.init(rawValue:)))
        let count = d.integer(forKey: "hogCount")
        hogCount = Settings.hogRange.contains(count) ? count : 3
    }

    /// 预览、自测里改着玩，不写进用户的设置
    var persist = true

    func save() {
        guard persist else { return }
        let d = UserDefaults.standard
        d.set(order.map(\.rawValue), forKey: "moduleOrder")
        d.set(hidden.map(\.rawValue), forKey: "hiddenModules")
        d.set(hogCount, forKey: "hogCount")
    }

    func reset() {
        order = Settings.modules
        hidden = []
        hogCount = 3
    }
}

@MainActor enum WidgetLayout {
    static let width: CGFloat = 360
    static let widths: ClosedRange<CGFloat> = 320...640
    static let pad: CGFloat = 14
    static let gap: CGFloat = 10
    static let header: CGFloat = 30
    static let inset: CGFloat = 14                                   // 卡片内边距
    static let titleRow: CGFloat = 18

    static func tile(_ module: Module) -> CGFloat {
        let n = CGFloat(Settings.shared.hogCount)
        return switch module {
        case .overview: 2 * 16 + 80
        case .cpu: 2 * inset + titleRow + 12 + 10 + 14 + 3 * 17 + 2 * 8
        case .queue: 2 * inset + titleRow + 10 + 4 * 28 + 3 * 6
        case .hogs: 2 * inset + titleRow + 10 + n * 24 + (n - 1) * 4
        }
    }

    /// 显示前 k 块时多高（k = 0 只剩顶上一条）
    static func height(_ k: Int) -> CGFloat {
        pad + header + Settings.shared.shown.prefix(k).reduce(0) { $0 + gap + tile($1) } + pad
    }

    static var all: Int { Settings.shared.shown.count }

    /// 这个高度显示前几块（吸到最近的一档）
    static func count(for height: CGFloat) -> Int {
        (0...all).min { abs(self.height($0) - height) < abs(self.height($1) - height) } ?? all
    }

    /// 拖出来的尺寸：宽度夹在范围里，高度吸到最近的一档
    static func fitted(_ proposed: NSSize) -> NSSize {
        let width = min(max(proposed.width, widths.lowerBound), widths.upperBound).rounded()
        let zoom = width / self.width
        return NSSize(width: width, height: (height(count(for: proposed.height / zoom)) * zoom).rounded())
    }
}

// MARK: - 类别

enum Category: Int, CaseIterable {
    case render, sync, claude, browser, other, system

    var name: String {
        switch self {
        case .render: "渲染"
        case .sync: "云同步"
        case .claude: "Claude"
        case .browser: "浏览器"
        case .other: "其他程序"
        case .system: "系统"
        }
    }
}

/// 程序名归类。proc_name 给的是可执行文件名（最多 32 字节）；Python 看路径认是不是引擎的。
enum Classifier {
    static let render: Set<String> = ["chrome-headless-shell", "ffmpeg", "ffprobe", "node"]
    static let sync: Set<String> = ["fileproviderd", "bird", "cloudd", "Dropbox", "Google Drive", "OneDrive",
                                    "OneDrive Sync Service", "OneDrive File Provider", "BaiduNetdisk"]
    static let browser: Set<String> = ["Google Chrome", "Safari", "Arc", "Firefox", "Microsoft Edge"]

    /// 浏览器和 Electron 的 Helper 算进它的程序，各版本 Python 算一个
    static func program(_ raw: String) -> String {
        var name = raw
        if let helper = name.range(of: " Helper") { name = String(name[..<helper.lowerBound]) }
        if name.hasPrefix("com.apple.WebKit") { return "com.apple.WebKit" }
        if name.lowercased().hasPrefix("python") { return "Python" }
        return name.isEmpty ? "?" : name
    }

    static func category(program: String, path: String?) -> Category {
        if program == "Python" {
            // 排队文件夹所在的工程里跑的 Python 算渲染
            guard let path, let root = RenderQueue.folder?.deletingLastPathComponent().path else { return .other }
            return path.hasPrefix(root + "/") ? .render : .other
        }
        if render.contains(program) { return .render }
        if sync.contains(program) { return .sync }
        if program.lowercased().hasPrefix("claude") { return .claude }
        if browser.contains(program) { return .browser }
        return .other
    }

    /// 列表里显示的名字
    static func display(_ program: String, _ category: Category) -> String {
        switch program {
        case "chrome-headless-shell": "渲染画面"
        case "ffmpeg": "视频编码"
        case "node": "渲染调度"
        case "Python": category == .render ? "制作脚本" : "Python"
        case "fileproviderd": "云盘同步"
        case "bird", "cloudd": "iCloud"
        case "Google Chrome": "Chrome"
        case "com.apple.WebKit": "网页进程"           // 查不到是谁开的才剩这个
        case "Molan", "MolanPreview": "墨览"
        case "WebThumbnailExtension": "访达缩略图"
        case "claude": "Claude Code"
        case "Claude": "Claude 桌面版"          // 和 CPU 分类里的「Claude」那一类分开
        default: program
        }
    }
}

// MARK: - 采样

struct Hog: Equatable {
    let name: String
    let category: Category
    let cpu: Double
    var count = 1            // 这个程序有几个进程（Chrome、Claude 的 Helper 都算进来）
}

struct Slot: Equatable {
    let label: String       // "1" "2" "3" "快"
    var open: Bool          // 内存偏紧时第 3 个位子不放新活
    var job: String?
    var detail: String?
    var minutes: Int?
}

/// 排着的一条
struct QueueItem: Equatable {
    let name: String
    let detail: String
    let minutes: Int?
}

struct Snapshot: Equatable {
    var cpu: Double?
    var load: Double?                    // 1 分钟平均负载：在用的加排队等的线程数
    var byCategory: [Category: Double] = [:]
    var gpu: Double?
    var memoryUsed: Double = 0
    var memoryTotal: Double = 0
    var swapUsed: Double = 0
    var pressure: Int32 = 1
    var slots: [Slot] = []
    var waiting: [QueueItem] = []        // 普通队，先来的在前
    var waitingQuick: [QueueItem] = []   // 快道
    var hogs: [Hog] = []                 // 最多 20 个，按 CPU 从多到少

    var longestWait: Int? { (waiting + waitingQuick).compactMap(\.minutes).max() }

    /// CPU 满了以后，抢 CPU 的线程是核数的几倍；没满或只多一点就不算
    var overload: Double? {
        guard let cpu, cpu >= 0.9, let load, load / Probe.cores >= 1.5 else { return nil }
        return load / Probe.cores
    }
}

/// 系统库里有、头文件没写的函数：这个进程是替谁开的（活动监视器也靠它把网页进程算到对应程序名下）
@_silgen_name("responsibility_get_pid_responsible_for_pid")
func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

enum Probe {
    static let cores = Double(ProcessInfo.processInfo.processorCount)
    static let nanosecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    static func load() -> Double? {
        var averages = [Double](repeating: 0, count: 3)
        return getloadavg(&averages, 3) == 3 ? averages[0] : nil
    }

    static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var busy: UInt64 = 0, total: UInt64 = 0
        for core in 0..<Int(count) {
            func ticks(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[core * Int(CPU_STATE_MAX) + Int(state)])) }
            let used = ticks(CPU_STATE_USER) + ticks(CPU_STATE_SYSTEM) + ticks(CPU_STATE_NICE)
            busy += used
            total += used + ticks(CPU_STATE_IDLE)
        }
        return (busy, total)
    }

    /// 自己的进程（root 的进程不给普通用户读用量，算进「系统」）：pid → (程序名, 累计 CPU 秒)
    static func processes() -> [Int32: (name: String, seconds: Double)] {
        var pids = [Int32](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let found = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        var result: [Int32: (String, Double)] = [:]
        var name = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(max(found, 0)) where pid > 0 {
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard status == 0 else { continue }
            name[0] = 0
            proc_name(pid, &name, UInt32(name.count))
            result[pid] = (String(cString: name), Double(usage.ri_user_time + usage.ri_system_time) * nanosecondsPerTick / 1e9)
        }
        return result
    }

    static func path(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }

    /// 网页进程（com.apple.WebKit.*）是替开它的程序干活的，不一定是 Safari：墨览、访达预览、邮件都会开。查是谁开的
    static func host(of pid: Int32, known: [Int32: (name: String, seconds: Double)]) -> String? {
        let host = responsibility_get_pid_responsible_for_pid(pid)
        guard host > 0, host != pid else { return nil }
        if let name = known[host]?.name, !name.isEmpty { return name }
        var name = [CChar](repeating: 0, count: 256)
        proc_name(host, &name, UInt32(name.count))
        return name[0] == 0 ? nil : String(cString: name)
    }

    static func gpu() -> Double? {
        let accelerator = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard accelerator != 0 else { return nil }
        defer { IOObjectRelease(accelerator) }
        let stats = IORegistryEntryCreateCFProperty(accelerator, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        return (stats?["Device Utilization %"] as? NSNumber).map { $0.doubleValue / 100 }
    }

    /// 已用内存按活动监视器的算法：App 内存、联动内存和压缩
    static func memory() -> (used: Double, total: Double, swap: Double, pressure: Int32) {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        _ = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size) }
        }
        let pages = Double(stats.internal_page_count) - Double(stats.purgeable_count)
            + Double(stats.wire_count) + Double(stats.compressor_page_count)
        var swap = xsw_usage()
        var length = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &length, nil, 0)
        var pressure: Int32 = 1
        length = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &length, nil, 0)
        return (pages * Double(vm_kernel_page_size), Double(ProcessInfo.processInfo.physicalMemory), Double(swap.xsu_used), pressure)
    }
}

/// 渲染排队（可选）：排队程序在一个文件夹里放锁文件，位子是 N.lock、快.lock，号在 排号/、排号快/（文件名是领号时刻加进程号），
/// 内容是 JSON（cwd、cmd、at）。有进程锁着的才算占着；只读，不删别人没清的旧号。
/// 设了排队文件夹才有这一块：defaults write local.computer.activity.widget queueFolder ~/某处/排队
enum RenderQueue {
    static var folder: URL? = UserDefaults.standard.string(forKey: "queueFolder").map {
        URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
    }

    /// 这个文件有没有进程锁着：没人锁返回 nil，锁着返回里面写的内容
    static func held(_ url: URL) -> [String: Any]? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// 期名：在某一期的 视频/_制作源文件/ 里起的就是那一期（去掉开头的编号），别处起的用文件夹名
    static func jobName(_ info: [String: Any]) -> String {
        guard let cwd = info["cwd"] as? String else { return "另一个排队进程" }
        let url = URL(fileURLWithPath: cwd)
        guard url.lastPathComponent == "_制作源文件" else { return url.lastPathComponent }
        let name = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        if let cut = name.firstIndex(of: "_"), name[..<cut].allSatisfy(\.isNumber), name.index(after: cut) < name.endIndex {
            return String(name[name.index(after: cut)...])
        }
        return name
    }

    /// 命令缩成一眼看懂的几个字
    static func jobDetail(_ info: [String: Any]) -> String {
        let cmd = (info["cmd"] as? String) ?? ""
        let parts = cmd.split(separator: " ").map(String.init)
        if parts.contains("render.mjs") {
            if let i = parts.firstIndex(of: "--recheck") { return "重查 " + (i + 1 < parts.count ? short(parts[i + 1]) : "") }
            if let i = parts.firstIndex(of: "--shots") { return parts.indices.contains(i + 1) && parts[i + 1] == "stale" ? "补渲过期段" : "渲 " + short(parts[i + 1]) }
            if let i = parts.firstIndex(of: "--shot") { return "渲 " + (i + 1 < parts.count ? short(parts[i + 1]) : "") }
            if parts.contains("--stills") { return "静帧" }
            if parts.contains("--sheets") || parts.contains("--sheet") { return "联系表" }
            return "渲染"
        }
        // run assemble h、python assemble.py 这两种写法都认
        let words = Set(parts.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent })
        if words.contains("assemble") { return "拼片" }
        if words.contains("check") { return "终检" }
        if words.contains("deliver") { return "交付" }
        if words.contains("regress") { return "回归" }
        if cmd.contains("预跑终检") { return "预跑终检" }
        if let script = parts.first(where: { $0.hasSuffix(".sh") || $0.hasSuffix(".py") || $0.hasSuffix(".command") }) {
            return URL(fileURLWithPath: script).deletingPathExtension().lastPathComponent
        }
        return String(cmd.prefix(18))
    }

    static func short(_ list: String) -> String {
        let ids = list.split(separator: ",")
        return ids.count > 2 ? "\(ids[0]) 等 \(ids.count) 段" : list
    }

    static func minutes(_ info: [String: Any], now: Date) -> Int? {
        (info["at"] as? Double).map { max(0, Int(now.timeIntervalSince1970 - $0) / 60) }
    }

    static func read(pressure: Int32, now: Date = Date()) -> (slots: [Slot], waiting: [QueueItem], quick: [QueueItem]) {
        guard let folder else { return ([], [], []) }
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let normal = pressure <= 1 ? 3 : 2                     // 内存紧张时少开一个位子
        let numbered = names.compactMap { $0.hasSuffix(".lock") ? Int($0.dropLast(5)) : nil }
        var slots: [Slot] = []
        for i in 0..<max(3, (numbered.max() ?? 0) + 1) {
            let info = held(folder.appendingPathComponent("\(i).lock"))
            if info == nil && i >= 3 { continue }              // 有人用 RENDER_SLOTS 多开的位子，占着才显示
            slots.append(Slot(label: "\(i + 1)", open: i < normal, job: info.map(jobName), detail: info.map(jobDetail),
                              minutes: info.flatMap { minutes($0, now: now) }))
        }
        let quick = held(folder.appendingPathComponent("快.lock"))
        slots.append(Slot(label: "快", open: true, job: quick.map(jobName), detail: quick.map(jobDetail),
                          minutes: quick.flatMap { minutes($0, now: now) }))
        /// 号的文件名是领号时刻加进程号，按名字排就是先后
        func tickets(_ sub: String) -> [QueueItem] {
            let dir = folder.appendingPathComponent(sub)
            return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.first?.isNumber == true && $0.hasSuffix(".json") }.sorted()
                .compactMap { name in
                    held(dir.appendingPathComponent(name)).map { QueueItem(name: jobName($0), detail: jobDetail($0), minutes: minutes($0, now: now)) }
                }
        }
        return (slots, tickets("排号"), tickets("排号快"))
    }
}

/// 看得见每 2 秒采一次，被别的窗口挡住每 15 秒，隐藏了停
@MainActor final class Monitor: ObservableObject {
    @Published var snapshot = Snapshot()
    @Published var pinned = false
    /// 鼠标在小组件上：右下角的拉伸手柄显深一点（命令行工具链没有 @State 的宏，放在这里）
    @Published var hovering = false
    private var timer: Timer?
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastProcesses: [Int32: (name: String, seconds: Double)] = [:]
    private var lastTime = Date()
    private var paths: [Int32: String?] = [:]
    private let me = ProcessInfo.processInfo.processIdentifier
    private let queue = DispatchQueue(label: "computer-activity.sample", qos: .utility)
    private var sampling = false

    init(preview: Snapshot? = nil) {
        if let preview { snapshot = preview }
    }

    enum Pace { case off, slow, live }
    private var pace = Pace.off

    func setPace(_ next: Pace) {
        guard next != pace else { return }
        pace = next
        timer?.invalidate(); timer = nil
        guard next != .off else {
            lastTicks = nil; lastProcesses = [:]               // 隔了很久再看，不拿旧数算平均
            return
        }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: next == .live ? 2 : 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    private func sample() {
        guard !sampling else { return }
        sampling = true
        let previous = (lastTicks, lastProcesses, lastTime, paths, me)
        queue.async { [weak self] in
            let result = Monitor.measure(previousTicks: previous.0, previousProcesses: previous.1, since: previous.2,
                                         paths: previous.3, me: previous.4)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.lastTicks = result.ticks; self.lastProcesses = result.processes
                    self.lastTime = result.time; self.paths = result.paths
                    var snapshot = result.snapshot
                    if snapshot.cpu == nil {                   // 刚开始采、还没有两次可比：CPU 先沿用上次的
                        snapshot.cpu = self.snapshot.cpu; snapshot.byCategory = self.snapshot.byCategory; snapshot.hogs = self.snapshot.hogs
                    }
                    self.snapshot = snapshot
                    self.sampling = false
                }
            }
        }
    }

    nonisolated static func measure(previousTicks: (busy: UInt64, total: UInt64)?, previousProcesses: [Int32: (name: String, seconds: Double)],
                                    since: Date, paths oldPaths: [Int32: String?], me: Int32)
        -> (snapshot: Snapshot, ticks: (busy: UInt64, total: UInt64)?, processes: [Int32: (name: String, seconds: Double)], time: Date, paths: [Int32: String?]) {
        let now = Date()
        let ticks = Probe.cpuTicks()
        let processes = Probe.processes()
        var paths = oldPaths.filter { processes[$0.key] != nil }
        let memory = Probe.memory()
        var snap = Snapshot()
        snap.memoryUsed = memory.used; snap.memoryTotal = memory.total; snap.swapUsed = memory.swap; snap.pressure = memory.pressure
        snap.gpu = Probe.gpu()
        snap.load = Probe.load()
        let queue = RenderQueue.read(pressure: memory.pressure, now: now)
        snap.slots = queue.slots; snap.waiting = queue.waiting; snap.waitingQuick = queue.quick
        guard let ticks, let previousTicks, ticks.total > previousTicks.total, !previousProcesses.isEmpty else {
            return (snap, ticks, processes, now, paths)               // 内存、GPU、排队先有；CPU 等下一次
        }
        let total = Double(ticks.busy - previousTicks.busy) / Double(ticks.total - previousTicks.total)
        let wall = max(now.timeIntervalSince(since), 0.5)
        var byCategory: [Category: Double] = [:]
        var programs: [String: Hog] = [:]
        for (pid, process) in processes {
            var program = Classifier.program(process.name)
            if program == "com.apple.WebKit", let host = Probe.host(of: pid, known: processes) {
                program = Classifier.program(host)
            }
            var path: String?
            if program == "Python" {
                if paths[pid] == nil { paths[pid] = .some(Probe.path(pid)) }
                path = paths[pid] ?? nil
            }
            let category = Classifier.category(program: program, path: path)
            var share = 0.0
            if let before = previousProcesses[pid], before.name == process.name {
                share = max(0, process.seconds - before.seconds) / wall / Probe.cores
            }
            byCategory[category, default: 0] += share
            guard pid != me else { continue }
            let key = Classifier.display(program, category)
            let sum = programs[key]
            programs[key] = Hog(name: key, category: category, cpu: (sum?.cpu ?? 0) + share, count: (sum?.count ?? 0) + 1)
        }
        let visible = byCategory.values.reduce(0, +)
        snap.cpu = min(max(total, visible), 1)
        byCategory[.system] = max(0, (snap.cpu ?? 0) - visible)
        snap.byCategory = byCategory
        snap.hogs = programs.values.filter { $0.cpu >= 0.001 }.sorted { $0.cpu > $1.cpu }.prefix(20).map { $0 }
        return (snap, ticks, processes, now, paths)
    }
}

// MARK: - 界面

struct Palette {
    let scheme: ColorScheme
    var dark: Bool { scheme == .dark }
    var ink: Color { dark ? .white : Color(red: 0.10, green: 0.12, blue: 0.15) }
    var track: Color { ink.opacity(dark ? 0.09 : 0.07) }
    var tileFill: Color { dark ? Color.white.opacity(0.055) : Color.white.opacity(0.62) }
    var tileStroke: Color { dark ? Color.white.opacity(0.07) : Color.black.opacity(0.045) }
    var blue: Color { dark ? Color(red: 0.40, green: 0.68, blue: 1.0) : Color(red: 0.12, green: 0.44, blue: 0.92) }
    var green: Color { dark ? Color(red: 0.45, green: 0.90, blue: 0.64) : Color(red: 0.08, green: 0.55, blue: 0.34) }
    var amber: Color { dark ? Color(red: 1.0, green: 0.74, blue: 0.33) : Color(red: 0.82, green: 0.50, blue: 0.04) }
    var red: Color { dark ? Color(red: 1.0, green: 0.47, blue: 0.43) : Color(red: 0.80, green: 0.22, blue: 0.20) }

    func color(_ category: Category) -> Color {
        switch category {
        case .render: blue
        case .sync: dark ? Color(red: 1.0, green: 0.62, blue: 0.30) : Color(red: 0.93, green: 0.47, blue: 0.10)
        case .claude: dark ? Color(red: 0.93, green: 0.56, blue: 0.44) : Color(red: 0.80, green: 0.41, blue: 0.29)
        case .browser: dark ? Color(red: 0.71, green: 0.57, blue: 1.0) : Color(red: 0.52, green: 0.34, blue: 0.90)
        case .other: dark ? Color(red: 0.42, green: 0.83, blue: 0.80) : Color(red: 0.08, green: 0.58, blue: 0.55)
        case .system: ink.opacity(dark ? 0.36 : 0.26)
        }
    }

    /// 内存压力的颜色：正常绿、偏紧琥珀、紧张红
    func pressure(_ level: Int32) -> Color { level >= 4 ? red : level >= 2 ? amber : green }
}

struct MaterialView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// 右下角拖着调大小，左上角不动；宽度整体缩放，高度吸到「显示前几块」（窗口代理的 windowWillResize）
struct ResizeGrip: NSViewRepresentable {
    final class Handle: NSView {
        private var startFrame = NSRect.zero
        private var startMouse = NSPoint.zero
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            startFrame = window?.frame ?? .zero
            startMouse = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let mouse = window.convertPoint(toScreen: event.locationInWindow)
            let proposed = NSSize(width: startFrame.width + mouse.x - startMouse.x, height: startFrame.height - mouse.y + startMouse.y)
            let size = window.delegate?.windowWillResize?(window, to: proposed) ?? proposed
            window.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - size.height, width: size.width, height: size.height), display: true)
        }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
        }
    }
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) {}
}

func percent(_ value: Double?) -> String {
    guard let value else { return "—" }
    let p = value * 100
    return p > 0 && p < 1 ? "<1%" : String(format: "%.0f%%", p)
}

/// 倍数：10 以下留一位小数（2.0 写成 2），10 以上取整
func times(_ value: Double) -> String {
    value >= 9.95 ? String(format: "%.0f", value) : String(format: "%.1f", value).replacingOccurrences(of: ".0", with: "")
}

func gigabytes(_ bytes: Double) -> String {
    let g = bytes / 1_073_741_824
    return g >= 10 ? String(format: "%.0f GB", g) : String(format: "%.1f GB", g)
}

func waitText(_ minutes: Int) -> String {
    minutes < 60 ? "\(minutes) 分" : minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分"
}

struct WidgetActions {
    var togglePin: () -> Void = {}
    var showMenu: () -> Void = {}
    var showQueue: () -> Void = {}
    var showHogs: () -> Void = {}
    var showSettings: () -> Void = {}
}

/// 圆环读数：GPU 是中性色，内存按压力着色
struct Gauge: View {
    let value: Double?
    let label: String
    let color: Color
    let ink: Color
    var labelColor: Color?

    var body: some View {
        let fraction = max(min(value ?? 0, 1), 0.005)
        ZStack {
            Circle().stroke(ink.opacity(0.07), lineWidth: 7)
            Circle().trim(from: 0, to: fraction)
                .stroke(AngularGradient(colors: [color.opacity(fraction > 0.97 ? 1 : 0.38), color], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * fraction)),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.8), value: fraction)
            VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(value.map { String(format: "%.0f", $0 * 100) } ?? "—")
                        .font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("%").font(.system(size: 9, weight: .medium)).foregroundStyle(ink.opacity(0.5))
                }
                Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(labelColor ?? ink.opacity(0.5))
            }
        }
        .frame(width: 72, height: 72)
    }
}

/// 「− 5 +」：最占 CPU 显示几个（卡片里和自定义里共用）
struct CountStepper: View {
    @ObservedObject var settings: Settings
    let p: Palette

    var body: some View {
        HStack(spacing: 0) {
            step("minus", -1)
            Text("\(settings.hogCount)").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                .frame(width: 18)
            step("plus", 1)
        }
        .padding(.horizontal, 2)
        .background(p.track, in: Capsule())
        .foregroundStyle(p.ink.opacity(0.7))
    }

    private func step(_ symbol: String, _ delta: Int) -> some View {
        let next = settings.hogCount + delta
        let ok = Settings.hogRange.contains(next)
        return Button { if ok { settings.hogCount = next } } label: {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold)).frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain).opacity(ok ? 1 : 0.3).help(delta < 0 ? "少显示一个" : "多显示一个")
    }
}

struct ActivityView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var settings: Settings
    var actions = WidgetActions()
    var liveBackground = true
    @Environment(\.colorScheme) var scheme
    private var p: Palette { Palette(scheme: scheme) }
    private var s: Snapshot { monitor.snapshot }
    private var ink: Color { p.ink }
    private var hovering: Bool { monitor.hovering }
    /// 平时是渲染的蓝；内存偏紧、紧张时跟着变
    private var accent: Color { s.pressure >= 2 ? p.pressure(s.pressure) : p.blue }

    var body: some View {
        GeometryReader { geo in
            let zoom = geo.size.width / WidgetLayout.width
            let height = geo.size.height / zoom
            let corner = RoundedRectangle(cornerRadius: 26 * zoom, style: .continuous)
            content(count: WidgetLayout.count(for: height))
                .frame(width: WidgetLayout.width, height: height, alignment: .top)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .background { background(zoom: zoom) }
                .clipShape(corner)
                .overlay {
                    corner.strokeBorder(LinearGradient(colors: [Color.white.opacity(p.dark ? 0.2 : 0.8), ink.opacity(0.06)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                }
                .overlay(alignment: .bottomTrailing) { if liveBackground { grip(zoom: zoom) } }
                .contentShape(corner)
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
        }
        .foregroundStyle(ink)
        .onHover { monitor.hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("电脑活动小组件")
    }

    private func content(count: Int) -> some View {
        let visible = Array(settings.shown.prefix(count))
        return VStack(alignment: .leading, spacing: WidgetLayout.gap) {
            header(showQueue: RenderQueue.folder != nil && !visible.contains(.queue))
            ForEach(visible, id: \.self) { module in card(module, visible: visible) }
        }
        .padding(WidgetLayout.pad)
        .animation(.smooth(duration: 0.35), value: settings.shown)
    }

    private func background(zoom: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            if liveBackground {
                MaterialView()
            } else {
                p.dark ? Color(red: 0.12, green: 0.13, blue: 0.15) : Color(red: 0.90, green: 0.91, blue: 0.92)
            }
            (p.dark ? Color(red: 0.05, green: 0.06, blue: 0.09).opacity(0.64) : Color(red: 0.95, green: 0.96, blue: 0.97).opacity(0.62))
            RadialGradient(colors: [accent.opacity(p.dark ? 0.18 : 0.12), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 340 * zoom)
        }
        .animation(.smooth(duration: 0.6), value: s.pressure)
    }

    private func grip(zoom: CGFloat) -> some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 13, y: 3)); path.addLine(to: CGPoint(x: 3, y: 13))
                path.move(to: CGPoint(x: 14, y: 9)); path.addLine(to: CGPoint(x: 9, y: 14))
            }
            .stroke(ink.opacity(hovering ? 0.4 : 0.14), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            .frame(width: 22, height: 22)
            .scaleEffect(zoom, anchor: .topLeading)
            .frame(width: 22 * zoom, height: 22 * zoom, alignment: .topLeading)
            .animation(.easeOut(duration: 0.2), value: hovering)
            ResizeGrip()
        }
        .frame(width: 22 * zoom, height: 22 * zoom)
        .help("拖动调整大小")
    }

    // 顶上一条：排队状态（点开看全部；渲染排队那块显示着就不重复），自定义、置顶、菜单
    private func header(showQueue: Bool) -> some View {
        HStack(spacing: 4) {
            if showQueue {
                Button(action: actions.showQueue) {
                    HStack(spacing: 6) {
                        Circle().fill(queueBusy ? p.blue : ink.opacity(0.3)).frame(width: 6, height: 6)
                            .shadow(color: queueBusy ? p.blue.opacity(0.6) : .clear, radius: 3)
                        Text(queuePill).font(.system(size: 11, weight: .semibold)).monospacedDigit().fixedSize()
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(ink.opacity(0.35))
                    }
                    .padding(.horizontal, 11).frame(height: 26)
                    .background((queueBusy ? p.blue : ink).opacity(p.dark ? 0.14 : 0.09), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain).help("查看全部排队")
                .transition(.opacity)
            }
            Spacer(minLength: 6)
            iconButton("slider.horizontal.3", action: actions.showSettings, help: "自定义：显示哪几块、先后")
            iconButton(monitor.pinned ? "pin.fill" : "pin", action: actions.togglePin,
                       help: monitor.pinned ? "已置顶，点击改为桌面显示" : "桌面显示，点击始终置顶", strong: monitor.pinned)
            iconButton("ellipsis", action: actions.showMenu, help: "更多")
        }
        .frame(height: WidgetLayout.header)
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void, help: String, strong: Bool = false) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: symbol == "ellipsis" ? 14 : 11.5, weight: .medium))
                .frame(width: 26, height: 26).foregroundStyle(ink.opacity(strong ? 0.75 : 0.45))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    private var queueBusy: Bool { s.slots.contains { $0.job != nil } }
    private var queuePill: String {
        let open = s.slots.filter { $0.label != "快" && $0.open }.count
        let busy = s.slots.filter { $0.label != "快" && $0.job != nil }.count
        let waiting = s.waiting.count + s.waitingQuick.count
        let head = busy > 0 ? "渲染 \(busy)/\(open)" : "渲染空闲"
        return waiting > 0 ? "\(head) · 排队 \(waiting)" : head
    }

    // 卡片

    private func card(_ module: Module, visible: [Module]) -> some View {
        Group {
            switch module {
            case .overview: overview
            case .cpu: cpuCard(showTotal: !visible.contains(.overview))
            case .queue: queueCard
            case .hogs: hogCard
            }
        }
        .padding(module == .overview ? 16 : WidgetLayout.inset)
        .frame(width: WidgetLayout.width - 2 * WidgetLayout.pad, height: WidgetLayout.tile(module), alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(p.tileFill))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(p.tileStroke, lineWidth: 0.6))
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
    }

    private func title<Trailing: View>(_ module: Module, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 6) {
            Image(systemName: module.symbol).font(.system(size: 9.5, weight: .semibold))
            Text(module.name).font(.system(size: 11.5, weight: .semibold))
            Spacer(minLength: 6)
            trailing()
        }
        .foregroundStyle(ink.opacity(0.5))
        .frame(height: WidgetLayout.titleRow)
    }

    // 总览：CPU 大数字；右边 GPU、内存两个圆环
    private var overview: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: "cpu").font(.system(size: 9.5, weight: .semibold))
                    Text("CPU").font(.system(size: 11.5, weight: .semibold))
                    overloadBadge.padding(.leading, 3)
                }
                .foregroundStyle(ink.opacity(0.5))
                .frame(height: 16)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(s.cpu.map { String(format: "%.0f", $0 * 100) } ?? "—")
                        .font(.system(size: 54, weight: .light, design: .rounded)).monospacedDigit()
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.25), value: s.cpu.map { Int($0 * 100) })
                    Text("%").font(.system(size: 18, weight: .light)).foregroundStyle(ink.opacity(0.55))
                }
            }
            .help(cpuHelp)
            Spacer(minLength: 0)
            Gauge(value: s.gpu, label: "GPU", color: ink.opacity(p.dark ? 0.85 : 0.72), ink: ink)
                .help("显卡占用：渲染画面主要用它")
            Gauge(value: s.memoryTotal > 0 ? s.memoryUsed / s.memoryTotal : nil,
                  label: s.pressure >= 4 ? "内存紧张" : s.pressure >= 2 ? "内存偏紧" : "内存", color: p.pressure(s.pressure), ink: ink,
                  labelColor: s.pressure >= 2 ? p.pressure(s.pressure) : nil)
                .help(memoryHelp)
        }
        .frame(height: 80)
    }

    /// CPU 满了才有：每个核有几个线程在抢
    @ViewBuilder private var overloadBadge: some View {
        if let overload = s.overload {
            let color = overload >= 5 ? p.red : p.amber
            Text("超载 \(times(overload)) 倍").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                .foregroundStyle(color)
                .padding(.horizontal, 6).frame(height: 16)
                .background(color.opacity(p.dark ? 0.18 : 0.12), in: Capsule())
                .fixedSize()
                .help(cpuHelp)
        }
    }

    private var cpuHelp: String {
        guard let cpu = s.cpu else { return "还在读" }
        var lines = ["\(Int(Probe.cores)) 个核平均忙了 \(percent(cpu))"]
        if let load = s.load {
            let ratio = load / Probe.cores
            lines.append("过去一分钟平均约 \(Int(load.rounded())) 个线程在抢 CPU，是核数的 \(times(ratio)) 倍")
            if s.overload != nil { lines.append("平均每个线程只分到约 1/\(times(ratio)) 个核：前台和要紧的先轮到，后台的等得更久") }
        }
        return lines.joined(separator: "\n")
    }

    private var memoryHelp: String {
        var lines = ["内存用了 \(gigabytes(s.memoryUsed)) / \(gigabytes(s.memoryTotal))",
                     s.pressure >= 4 ? "系统觉得内存很紧张，程序会明显变慢" : s.pressure >= 2 ? "系统觉得内存偏紧，新的渲染只开 2 个位子" : "内存够用"]
        if s.swapUsed >= 1_073_741_824 {
            lines.append("另外借了 \(gigabytes(s.swapUsed)) 硬盘当内存用（虚拟内存）：内存不够时系统把一部分挪到硬盘上，借得越多越卡")
        }
        return lines.joined(separator: "\n")
    }

    // CPU 分类：分色条和图例；合计只在总览没显示时写（不然和总览的大数字重复）
    private func cpuCard(showTotal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            title(.cpu) {
                if showTotal {
                    Text("共 \(percent(s.cpu))").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(ink.opacity(0.62)).help(cpuHelp)
                    overloadBadge
                }
            }
            categoryBar.padding(.top, 12)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .leading), GridItem(.flexible(), spacing: 16, alignment: .leading)],
                      alignment: .leading, spacing: 8) {
                ForEach(Category.allCases, id: \.self) { category in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(p.color(category)).frame(width: 7, height: 7)
                        Text(category.name).font(.system(size: 11, weight: .medium)).foregroundStyle(ink.opacity(0.62))
                        Spacer(minLength: 4)
                        Text(percent(s.cpu == nil ? nil : s.byCategory[category] ?? 0))
                            .font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                    }
                    .frame(height: 17)
                }
            }
            .padding(.top, 14)
        }
    }

    private var categoryBar: some View {
        GeometryReader { geo in
            let shares = Category.allCases.map { ($0, s.byCategory[$0] ?? 0) }.filter { $0.1 >= 0.004 }
            HStack(spacing: 2) {
                ForEach(shares, id: \.0) { category, share in
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(p.color(category))
                        .frame(width: max(3, (geo.size.width - CGFloat(shares.count) * 2) * share))
                }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .background(p.track, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .animation(.smooth(duration: 0.6), value: s.byCategory)
        }
        .frame(height: 10)
    }

    // 渲染排队：每个位子一行；点右上角看排着的全部
    private var queueCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(.queue) {
                Button(action: actions.showQueue) {
                    HStack(spacing: 4) {
                        Text(queueSummary).font(.system(size: 11, weight: .medium)).monospacedDigit()
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(ink.opacity(s.waiting.count + s.waitingQuick.count > 0 ? 0.72 : 0.45))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("查看全部排队")
            }
            VStack(spacing: 6) {
                ForEach(Array(s.slots.prefix(4).enumerated()), id: \.offset) { _, slot in SlotRow(slot: slot, p: p) }
            }
            .padding(.top, 10)
        }
    }

    private var queueSummary: String {
        let count = s.waiting.count + s.waitingQuick.count
        guard count > 0 else { return "没有排着的" }
        return "排着 \(count)" + (s.longestWait.map { " · 最久 \(waitText($0))" } ?? "")
    }

    // 最占 CPU：显示几个用「− +」调，「全部」看前 20 个
    private var hogCard: some View {
        let shown = Array(s.hogs.prefix(settings.hogCount))
        return VStack(alignment: .leading, spacing: 0) {
            title(.hogs) {
                CountStepper(settings: settings, p: p)
                Button(action: actions.showHogs) {
                    HStack(spacing: 3) {
                        Text("全部").font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(ink.opacity(0.6)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.leading, 4).help("看前 20 个")
            }
            VStack(spacing: 4) {
                ForEach(0..<settings.hogCount, id: \.self) { i in
                    HogRow(rank: i + 1, hog: i < shown.count ? shown[i] : nil, top: s.hogs.first?.cpu ?? 0.01, p: p)
                }
            }
            .padding(.top, 10)
        }
    }
}

/// 最占 CPU 一行（卡片和全部清单共用）
struct HogRow: View {
    let rank: Int
    let hog: Hog?
    let top: Double
    let p: Palette
    var showCategory = false

    var body: some View {
        let ink = p.ink
        HStack(spacing: 8) {
            Text("\(rank)").font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(ink.opacity(0.32)).frame(width: 14, alignment: .leading)
            if let hog {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(p.color(hog.category)).frame(width: 7, height: 7)
                Text(hog.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                if hog.count > 1 {
                    Text("×\(hog.count)").font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(ink.opacity(0.36))
                }
                if showCategory {
                    Text(hog.category.name).font(.system(size: 10, weight: .medium)).foregroundStyle(ink.opacity(0.36)).lineLimit(1)
                }
                Spacer(minLength: 6)
                Capsule().fill(p.track).frame(width: 44, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(p.color(hog.category)).frame(width: 44 * min(hog.cpu / max(top, 0.01), 1), height: 4)
                    }
                Text(percent(hog.cpu)).font(.system(size: 12.5, weight: .medium, design: .rounded)).monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            } else {
                Text("—").font(.system(size: 12)).foregroundStyle(ink.opacity(0.2))
                Spacer()
            }
        }
        .frame(height: 24)
    }
}

/// 渲染位子一行（卡片和排队清单共用）
struct SlotRow: View {
    let slot: Slot
    let p: Palette

    var body: some View {
        let busy = slot.job != nil
        let ink = p.ink
        HStack(spacing: 10) {
            ZStack {
                if busy {
                    Circle().fill(p.blue.opacity(p.dark ? 0.22 : 0.14))
                } else {
                    Circle().strokeBorder(ink.opacity(slot.open ? 0.16 : 0.08), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
                Text(slot.label).font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(busy ? p.blue : ink.opacity(slot.open ? 0.35 : 0.2))
            }
            .frame(width: 22, height: 22)
            if let job = slot.job {
                VStack(alignment: .leading, spacing: 1) {
                    Text(job).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(slot.detail ?? "").font(.system(size: 10, weight: .medium)).foregroundStyle(ink.opacity(0.45)).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(slot.minutes.map(waitText) ?? "").font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(ink.opacity(0.5))
            } else {
                Text(slot.open ? "空闲" : "关").font(.system(size: 11, weight: .medium)).foregroundStyle(ink.opacity(slot.open ? 0.35 : 0.22))
                Spacer()
            }
        }
        .frame(height: 28)
    }
}

/// 弹窗的外壳：标题行、自己铺的底色（弹窗的半透明底在桌面层上会透出后面窗口的深色，深色字就看不清了）
struct PopoverShell<Content: View>: View {
    let title: String
    let symbol: String
    let trailing: String
    let p: Palette
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.ink.opacity(0.5))
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(trailing).font(.system(size: 11, weight: .medium)).foregroundStyle(p.ink.opacity(0.5))
            }
            .padding(.bottom, 12)
            content()
        }
        .padding(18)
        .frame(width: 330)
        .foregroundStyle(p.ink)
        .background(p.dark ? Color(red: 0.12, green: 0.13, blue: 0.15) : Color(red: 0.97, green: 0.97, blue: 0.98), ignoresSafeAreaEdges: .all)
    }
}

/// 点排队弹出来的全部清单：在跑的、普通队、快道，先来的在前
struct QueueListView: View {
    @ObservedObject var monitor: Monitor
    /// 离屏预览画不出滚动区里的东西，预览时不滚
    var scrolls = true
    @Environment(\.colorScheme) var scheme
    private var p: Palette { Palette(scheme: scheme) }
    private var s: Snapshot { monitor.snapshot }
    private var running: [Slot] { s.slots.filter { $0.job != nil } }

    /// 清单本身多高：按行数算好，超过 640 就滚动（滚动区自己没有理想高度，弹窗会被压扁）
    private var listHeight: CGFloat {
        let rows = max(running.count, 1) + max(s.waiting.count, 1) + s.waitingQuick.count
        let groups: CGFloat = s.waitingQuick.isEmpty ? 2 : 3
        return min(CGFloat(rows) * 36 + groups * 30, 640)
    }

    var body: some View {
        PopoverShell(title: "渲染排队", symbol: Module.queue.symbol, trailing: running.isEmpty ? "都空着" : "\(running.count) 条在跑", p: p) {
            if scrolls { ScrollView { list }.scrollIndicators(.never).frame(height: listHeight) } else { list }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            group("在跑")
            if running.isEmpty { empty("没有在跑的") }
            ForEach(Array(running.enumerated()), id: \.offset) { _, slot in SlotRow(slot: slot, p: p) }
            group("排着 · \(s.waiting.count)").padding(.top, 10)
            if s.waiting.isEmpty { empty("没有排着的") }
            ForEach(Array(s.waiting.enumerated()), id: \.offset) { i, item in row(i + 1, item) }
            if !s.waitingQuick.isEmpty {
                group("快道排着 · \(s.waitingQuick.count)").padding(.top, 10)
                ForEach(Array(s.waitingQuick.enumerated()), id: \.offset) { i, item in row(i + 1, item) }
            }
        }
    }

    private func group(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.ink.opacity(0.48)).padding(.bottom, 2)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(p.ink.opacity(0.32)).frame(height: 22)
    }

    private func row(_ order: Int, _ item: QueueItem) -> some View {
        let ink = p.ink
        return HStack(spacing: 10) {
            Text("\(order)").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(ink.opacity(0.4)).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(item.detail).font(.system(size: 10, weight: .medium)).foregroundStyle(ink.opacity(0.45)).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let minutes = item.minutes {
                Text("等了 \(waitText(minutes))").font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(minutes >= 60 ? p.amber : ink.opacity(0.5))
            }
        }
        .frame(height: 30)
    }
}

/// 最占 CPU 的全部（前 20 个）
struct HogListView: View {
    @ObservedObject var monitor: Monitor
    var scrolls = true
    @Environment(\.colorScheme) var scheme
    private var p: Palette { Palette(scheme: scheme) }
    private var hogs: [Hog] { monitor.snapshot.hogs }

    var body: some View {
        PopoverShell(title: "最占 CPU", symbol: Module.hogs.symbol, trailing: "前 \(hogs.count) 个 · 按整台电脑算", p: p) {
            if scrolls {
                ScrollView { list }.scrollIndicators(.never).frame(height: min(CGFloat(max(hogs.count, 1)) * 28, 600))
            } else { list }
        }
    }

    private var list: some View {
        VStack(spacing: 4) {
            if hogs.isEmpty {
                Text("还在读").font(.system(size: 11, weight: .medium)).foregroundStyle(p.ink.opacity(0.32)).frame(height: 24)
            }
            ForEach(Array(hogs.enumerated()), id: \.offset) { i, hog in
                HogRow(rank: i + 1, hog: hog, top: hogs.first?.cpu ?? 0.01, p: p, showCategory: true)
            }
        }
    }
}

/// 自定义：显示哪几块（开关）、先后（拖动）、最占 CPU 显示几个
struct ModuleSettingsView: View {
    @ObservedObject var settings: Settings
    /// 离屏预览画不出 List，预览时用普通的竖排
    var live = true
    @Environment(\.colorScheme) var scheme
    private var p: Palette { Palette(scheme: scheme) }

    var body: some View {
        PopoverShell(title: "自定义", symbol: "slider.horizontal.3", trailing: "拖动调先后", p: p) {
            VStack(alignment: .leading, spacing: 0) {
                if live {
                    List {
                        ForEach(settings.order) { module in row(module).listRowSeparator(.hidden).listRowBackground(Color.clear) }
                            .onMove { settings.order.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .frame(height: CGFloat(settings.order.count) * 44 + 4)
                } else {
                    VStack(spacing: 0) { ForEach(settings.order) { row($0) } }
                }
                Rectangle().fill(p.ink.opacity(0.08)).frame(height: 1).padding(.vertical, 12)
                HStack {
                    Image(systemName: Module.hogs.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.ink.opacity(0.45))
                        .frame(width: 26)
                    Text("最占 CPU 显示").font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    CountStepper(settings: settings, p: p)
                    Text("个").font(.system(size: 12, weight: .medium)).foregroundStyle(p.ink.opacity(0.5))
                }
                .frame(height: 30)
                HStack {
                    Spacer()
                    Button("恢复默认") { settings.reset() }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(p.blue)
                }
                .padding(.top, 10)
            }
        }
    }

    private func row(_ module: Module) -> some View {
        let on = !settings.hidden.contains(module)
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .medium)).foregroundStyle(p.ink.opacity(0.3))
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill((on ? p.blue : p.ink).opacity(on ? 0.14 : 0.06))
                Image(systemName: module.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(on ? p.blue : p.ink.opacity(0.35))
            }
            .frame(width: 28, height: 28)
            Text(module.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(p.ink.opacity(on ? 1 : 0.45))
            Spacer()
            // 自己画的开关：和卡片一个蓝，离屏预览也画得出来
            Button {
                if on { settings.hidden.insert(module) } else { settings.hidden.remove(module) }
            } label: {
                Capsule().fill(on ? p.blue : p.ink.opacity(0.14))
                    .frame(width: 34, height: 20)
                    .overlay(alignment: on ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 16, height: 16).shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5).padding(2)
                    }
                    .animation(.smooth(duration: 0.2), value: on)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain).help(on ? "不显示这一块" : "显示这一块")
        }
        .frame(height: 40)
        .contentShape(Rectangle())
    }
}

// MARK: - 窗口和菜单

final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var monitor: Monitor!
    var settings: Settings { Settings.shared }
    var panel: WidgetPanel!
    var host: NSHostingView<ActivityView>!
    var menu: NSMenu!
    var pinItem: NSMenuItem!
    var loginItem: NSMenuItem!
    let queuePopover = NSPopover(), hogPopover = NSPopover(), settingsPopover = NSPopover()
    /// 现在显示前几块（拖高矮、改设置时跟着变）
    var visibleCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.computer.activity.widget")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        monitor = Monitor()
        monitor.pinned = UserDefaults.standard.bool(forKey: "pinned")
        panel = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: WidgetLayout.width, height: WidgetLayout.height(WidgetLayout.all)),
                            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.title = "电脑活动"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.delegate = self
        let actions = WidgetActions(togglePin: { [weak self] in self?.togglePin() }, showMenu: { [weak self] in self?.showMenu() },
                                    showQueue: { [weak self] in self?.toggle(self?.queuePopover) },
                                    showHogs: { [weak self] in self?.toggle(self?.hogPopover) },
                                    showSettings: { [weak self] in self?.toggle(self?.settingsPopover) })
        host = NSHostingView(rootView: ActivityView(monitor: monitor, settings: settings, actions: actions))
        host.sizingOptions = []
        panel.contentView = host
        setUp(queuePopover, QueueListView(monitor: monitor))
        setUp(hogPopover, HogListView(monitor: monitor))
        setUp(settingsPopover, ModuleSettingsView(settings: settings))
        settings.onChange = { [weak self] modulesChanged in self?.relayout(showAll: modulesChanged) }
        createMenu()
        restoreFrame()
        updateLevel()
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSampling() }
        }
        // 本机别的程序（快捷指令、测试脚本）发这个通知就弹出对应的清单：object 是 queue、hogs 或 settings
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.computer.activity.widget.show"),
                                                            object: nil, queue: .main) { [weak self] note in
            let which = note.object as? String
            MainActor.assumeIsolated {
                guard let self else { return }
                let target = which == "hogs" ? self.hogPopover : which == "settings" ? self.settingsPopover : self.queuePopover
                if !target.isShown { self.toggle(target) }
            }
        }
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [self] in updateSampling() }
    }

    func setUp(_ popover: NSPopover, _ view: some View) {
        popover.behavior = .transient
        popover.animates = true
        let controller = NSHostingController(rootView: AnyView(view))
        controller.sizingOptions = [.preferredContentSize]          // 条数变了，弹窗跟着变高变矮
        popover.contentViewController = controller
    }

    /// 弹窗弹在小组件旁边，点别处收起；同时只开一个
    func toggle(_ popover: NSPopover?) {
        guard let popover else { return }
        if popover.isShown { popover.performClose(nil); return }
        for other in [queuePopover, hogPopover, settingsPopover] where other !== popover && other.isShown { other.performClose(nil) }
        NSApp.activate()
        popover.show(relativeTo: host.bounds, of: host, preferredEdge: .minX)
        updateSampling()
    }

    func updateSampling() {
        let visible = panel.occlusionState.contains(.visible) || queuePopover.isShown || hogPopover.isShown
        monitor.setPace(!panel.isVisible ? .off : visible ? .live : .slow)
    }

    func restoreFrame() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let d = UserDefaults.standard
        let width = d.object(forKey: "width") as? Double ?? 340
        let height = d.object(forKey: "height") as? Double ?? WidgetLayout.height(WidgetLayout.all) * width / WidgetLayout.width
        let size = WidgetLayout.fitted(NSSize(width: width, height: height))
        let fallback = NSRect(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24, width: size.width, height: size.height)
        var frame = fallback
        if let x = d.object(forKey: "positionX") as? Double, let top = d.object(forKey: "positionTop") as? Double {
            frame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { frame = fallback }
        panel.setFrame(onScreen(frame), display: false)
        updateLimits()
        visibleCount = WidgetLayout.count(for: panel.frame.height * WidgetLayout.width / panel.frame.width)
    }

    /// 设置变了：开关、顺序变了就撑到全部显示；只改了最占 CPU 的个数就保持现在显示几块，高度跟着变
    func relayout(showAll: Bool) {
        let frame = panel.frame, zoom = frame.width / WidgetLayout.width
        let count = showAll ? WidgetLayout.all : min(visibleCount, WidgetLayout.all)
        let height = (WidgetLayout.height(count) * zoom).rounded()
        updateLimits()
        panel.setFrame(onScreen(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)), display: true, animate: true)
        visibleCount = count
    }

    func updateLimits() {
        panel.minSize = WidgetLayout.fitted(.zero)
        panel.maxSize = WidgetLayout.fitted(NSSize(width: 10_000, height: 10_000))
    }

    func onScreen(_ frame: NSRect) -> NSRect {
        let area = { (screen: NSScreen) -> CGFloat in
            let overlap = screen.visibleFrame.intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        guard let visible = NSScreen.screens.max(by: { area($0) < area($1) })?.visibleFrame else { return frame }
        var moved = frame
        moved.origin.x = max(min(frame.minX, visible.maxX - frame.width), visible.minX)
        moved.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return moved
    }

    func saveFrame() {
        let d = UserDefaults.standard
        d.set(panel.frame.minX, forKey: "positionX")
        d.set(panel.frame.maxY, forKey: "positionTop")
        d.set(panel.frame.width, forKey: "width")
        d.set(panel.frame.height, forKey: "height")
    }

    /// 没有菜单栏图标：菜单只从小组件右上角「…」打开
    func createMenu() {
        let menu = NSMenu()
        menu.delegate = self
        func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
            return item
        }
        pinItem = item("始终置顶", #selector(togglePin))
        menu.addItem(.separator())
        _ = item("自定义…", #selector(openSettings))
        _ = item("查看全部排队", #selector(openQueue))
        _ = item("最占 CPU 全部", #selector(openHogs))
        menu.addItem(.separator())
        loginItem = item("登录时打开", #selector(toggleLogin))
        _ = item("恢复默认大小", #selector(resetSize))
        menu.addItem(.separator())
        for note in ["按住任意位置拖动；拖右下角：左右放大缩小，上下收起展开",
                     "压矮从排在最后的那块开始收起；显示哪几块、先后在「自定义」里改",
                     "百分比都按整台电脑算：8 个核加起来是 100%",
                     "超载几倍：CPU 满了以后，每个核平均有几个线程在抢（过去一分钟）；鼠标停在 CPU 上看细数",
                     "顶上的排队状态只在「渲染排队」那块收起或关掉时显示",
                     "GPU：显卡占用，渲染画面主要用它",
                     "内存圆环：绿够用、黄偏紧（新渲染只开 2 个位子）、红紧张；鼠标停在上面看借了多少硬盘当内存",
                     "系统：WindowServer、内核这类读不到明细的系统进程；云同步：iCloud 这类云盘",
                     "看得见时每 2 秒刷新，被别的窗口挡住时每 15 秒"] {
            menu.addItem(withTitle: note, action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出电脑活动", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        self.menu = menu
    }

    func showMenu() { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        pinItem.state = monitor.pinned ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func openSettings() { panel.orderFrontRegardless(); if !settingsPopover.isShown { toggle(settingsPopover) } }
    @objc func openQueue() { panel.orderFrontRegardless(); if !queuePopover.isShown { toggle(queuePopover) } }
    @objc func openHogs() { panel.orderFrontRegardless(); if !hogPopover.isShown { toggle(hogPopover) } }
    @objc func showWidget() { panel.orderFrontRegardless(); updateSampling() }
    @objc func togglePin() {
        monitor.pinned.toggle()
        UserDefaults.standard.set(monitor.pinned, forKey: "pinned")
        updateLevel()
    }
    @objc func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "无法更改登录项"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
    @objc func resetSize() {
        let frame = panel.frame
        let size = WidgetLayout.fitted(NSSize(width: 340, height: WidgetLayout.height(WidgetLayout.all) * 340 / WidgetLayout.width))
        panel.setFrame(onScreen(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)), display: true, animate: true)
    }
    func updateLevel() {
        panel.level = monitor.pinned ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize { WidgetLayout.fitted(frameSize) }
    func windowDidResize(_ notification: Notification) {
        panel.invalidateShadow(); saveFrame()
        visibleCount = WidgetLayout.count(for: panel.frame.height * WidgetLayout.width / panel.frame.width)
    }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWidget(); return true }
}

// MARK: - 图标、预览、自测

func makeIcon(at path: String) {
    let image = NSImage(size: NSSize(width: 1024, height: 1024))
    image.lockFocus()
    let rect = NSRect(x: 72, y: 72, width: 880, height: 880)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 205, yRadius: 205)
    NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.24, alpha: 1),
                        NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)])!.draw(in: shape, angle: -60)
    // 三根分色的条，和小组件里 CPU 分类一样的颜色
    let colors: [(NSColor, CGFloat)] = [(NSColor(calibratedRed: 0.40, green: 0.68, blue: 1.0, alpha: 1), 0.34),
                                        (NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.30, alpha: 1), 0.16),
                                        (NSColor(calibratedRed: 0.93, green: 0.56, blue: 0.44, alpha: 1), 0.10),
                                        (NSColor(calibratedRed: 0.71, green: 0.57, blue: 1.0, alpha: 1), 0.10),
                                        (NSColor(calibratedWhite: 1, alpha: 0.35), 0.12)]
    for (row, scale) in [(0, 1.0), (1, 0.72), (2, 0.48)] {
        let y = 600 - CGFloat(row) * 150
        let full = NSRect(x: 232, y: y, width: 560, height: 64)
        NSColor(calibratedWhite: 1, alpha: 0.08).setFill()
        NSBezierPath(roundedRect: full, xRadius: 32, yRadius: 32).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: full, xRadius: 32, yRadius: 32).addClip()
        var x: CGFloat = 232
        for (color, share) in colors {
            let w = 560 * share * scale
            color.setFill()
            NSRect(x: x, y: y, width: w - 6, height: 64).fill()
            x += w
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    image.unlockFocus()
    if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
       let png = bitmap.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

/// 拿编的数据画几种状态（浅色、深色），给自己看排版；不动用户存的设置
@MainActor func renderPreviews(into folder: String, live: Snapshot?) {
    _ = NSApplication.shared
    let settings = Settings.shared
    settings.persist = false
    var busy = Snapshot()
    busy.cpu = 1
    busy.load = 152
    busy.byCategory = [.render: 0.27, .sync: 0.16, .claude: 0.05, .browser: 0.07, .other: 0.13, .system: 0.25]
    busy.gpu = 0.74
    busy.memoryUsed = 20.6 * 1_073_741_824; busy.memoryTotal = 24 * 1_073_741_824; busy.swapUsed = 4.7 * 1_073_741_824
    busy.pressure = 1
    busy.slots = [Slot(label: "1", open: true, job: "产品宣传片", detail: "重渲第 3 段", minutes: 38),
                  Slot(label: "2", open: true, job: "纪录片第 2 集", detail: "补渲过期段", minutes: 22),
                  Slot(label: "3", open: true, job: nil, detail: nil, minutes: nil),
                  Slot(label: "快", open: true, job: "教程合集", detail: "静帧", minutes: 1)]
    busy.waiting = [QueueItem(name: "发布会回放", detail: "收尾", minutes: 115),
                    QueueItem(name: "纪录片第 3 集", detail: "补渲过期段", minutes: 82),
                    QueueItem(name: "教程合集", detail: "重查 14 段", minutes: 78),
                    QueueItem(name: "开箱视频", detail: "拼片", minutes: 51),
                    QueueItem(name: "访谈剪辑", detail: "收尾", minutes: 30),
                    QueueItem(name: "品牌短片", detail: "收尾", minutes: 22)]
    busy.waitingQuick = [QueueItem(name: "封面图", detail: "联系表", minutes: 2)]
    let names: [(String, Category, Int)] = [("视频编码", .render, 4), ("渲染画面", .render, 14), ("云盘同步", .sync, 1), ("Claude 桌面版", .claude, 44),
                                            ("Python", .other, 69), ("Chrome", .browser, 23), ("渲染调度", .render, 7), ("iCloud", .sync, 2),
                                            ("BackgroundShortcutRunner", .other, 1), ("WeChat", .other, 6), ("Finder", .other, 1), ("Claude Code", .claude, 26)]
    busy.hogs = names.enumerated().map { i, n in Hog(name: n.0, category: n.1, cpu: 0.2 * pow(0.72, Double(i)), count: n.2) }
    var tight = busy
    tight.pressure = 2
    tight.slots[2].open = false
    tight.cpu = 0.93; tight.load = 9                     // 没到超载
    var overloaded = busy
    overloaded.load = 22                                 // 超载不到 5 倍是琥珀色

    func write(_ view: some View, _ name: String, _ scheme: ColorScheme) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 2
        guard let image = renderer.nsImage, let data = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
    }
    func widget(_ name: String, _ snap: Snapshot, count: Int? = nil) {
        for scheme in [ColorScheme.light, .dark] {
            write(ActivityView(monitor: Monitor(preview: snap), settings: settings, liveBackground: false)
                .frame(width: WidgetLayout.width, height: WidgetLayout.height(count ?? WidgetLayout.all)), name, scheme)
        }
    }
    settings.order = Settings.modules; settings.hidden = []; settings.hogCount = 3
    widget("all", busy)
    for k in 0..<WidgetLayout.all { widget("fold\(k)", busy, count: k) }
    widget("tight", tight)
    widget("amber", overloaded)
    if let live { widget("live", live) }
    settings.hidden = [.overview]                        // 总览不显示时，合计和超载挪到 CPU 分类
    widget("no-overview", busy)
    settings.hidden = []
    settings.hogCount = 6
    widget("hogs6", busy)
    settings.order = Array(Settings.modules.reversed()); settings.hidden = [.cpu]; settings.hogCount = 3
    widget("custom", busy)
    settings.order = Settings.modules; settings.hidden = []
    for scheme in [ColorScheme.light, .dark] {
        write(QueueListView(monitor: Monitor(preview: busy), scrolls: false), "pop-queue", scheme)
        write(HogListView(monitor: Monitor(preview: busy), scrolls: false), "pop-hogs", scheme)
        settings.hidden = [.cpu]
        write(ModuleSettingsView(settings: settings, live: false), "pop-settings", scheme)
        settings.hidden = []
    }
}

@MainActor func selfTest() {
    precondition(Classifier.program("Google Chrome Helper (Renderer)") == "Google Chrome")
    precondition(Classifier.program("Claude Helper (Renderer)") == "Claude")
    precondition(Classifier.program("python3.12") == "Python")
    precondition(Classifier.category(program: "chrome-headless-shell", path: nil) == .render)
    RenderQueue.folder = URL(fileURLWithPath: "/x/工程/排队")
    precondition(Classifier.category(program: "Python", path: "/x/工程/环境/py312/bin/python3.12") == .render)
    precondition(Classifier.category(program: "Python", path: "/opt/homebrew/bin/python3") == .other)
    precondition(Classifier.category(program: "fileproviderd", path: nil) == .sync)
    precondition(Classifier.category(program: "claude", path: nil) == .claude)
    precondition(Classifier.category(program: "Google Chrome", path: nil) == .browser)
    precondition(Classifier.category(program: "WeChat", path: nil) == .other)
    precondition(Classifier.display("Claude", .claude) == "Claude 桌面版" && Classifier.display("claude", .claude) == "Claude Code")
    // 网页进程算进开它的程序；查不到是谁开的就不算浏览器
    precondition(Classifier.program("com.apple.WebKit.WebContent") == "com.apple.WebKit")
    precondition(Classifier.category(program: "com.apple.WebKit", path: nil) == .other)
    precondition(Classifier.display("MolanPreview", .other) == "墨览")
    // 超载：CPU 满了、负载超过核数 1.5 倍才算
    precondition(times(19.04) == "19" && times(2.34) == "2.3" && times(2.02) == "2" && times(9.97) == "10")
    var load = Snapshot(); load.cpu = 1; load.load = Probe.cores * 19
    precondition(abs((load.overload ?? 0) - 19) < 0.001)
    load.load = Probe.cores * 1.2
    precondition(load.overload == nil)
    load.cpu = 0.7; load.load = Probe.cores * 5
    precondition(load.overload == nil)
    precondition(RenderQueue.jobName(["cwd": "/a/节目/01_第一期/视频/_制作源文件"]) == "第一期")
    precondition(RenderQueue.jobName(["cwd": "/Users/x/项目"]) == "项目")
    precondition(RenderQueue.jobDetail(["cmd": "node render.mjs --v h --shots stale"]) == "补渲过期段")
    precondition(RenderQueue.jobDetail(["cmd": "node render.mjs --v h --recheck a,b,c,d"]) == "重查 a 等 4 段")
    precondition(RenderQueue.jobDetail(["cmd": "python -u /x/tools/assemble.py h"]) == "拼片")
    precondition(RenderQueue.jobDetail(["cmd": "run assemble h"]) == "拼片")
    precondition(RenderQueue.jobDetail(["cmd": "python /x/tools/check.py"]) == "终检")
    precondition(RenderQueue.jobDetail(["cmd": "bash 收尾_1030.sh"]) == "收尾_1030")
    // 布局：显示的块越多越高；关掉一块、少显示几个最占 CPU 都变矮；拖出来的高度吸到最近的一档
    let settings = Settings.shared
    settings.persist = false
    let saved = (settings.order, settings.hidden, settings.hogCount)
    settings.order = Module.allCases; settings.hidden = []; settings.hogCount = 3
    precondition(WidgetLayout.all == 4)
    for k in 0..<4 { precondition(WidgetLayout.height(k) < WidgetLayout.height(k + 1)) }
    let full3 = WidgetLayout.height(4)
    settings.hogCount = 8
    precondition(WidgetLayout.height(4) > full3 && WidgetLayout.height(3) == WidgetLayout.height(3))
    settings.hogCount = 3
    precondition(WidgetLayout.fitted(NSSize(width: 360, height: 10_000)).height == full3.rounded())
    precondition(WidgetLayout.fitted(NSSize(width: 360, height: WidgetLayout.height(2) + 8)).height == WidgetLayout.height(2).rounded())
    precondition(WidgetLayout.count(for: 0) == 0)
    settings.hidden = [.cpu]
    precondition(WidgetLayout.all == 3 && WidgetLayout.height(3) < full3 && !settings.shown.contains(.cpu))
    settings.order = [.queue, .overview, .cpu, .hogs]
    precondition(settings.shown == [.queue, .overview, .hogs])
    settings.order = saved.0; settings.hidden = saved.1; settings.hogCount = saved.2
    // 排队文件夹：一个位子被这个进程锁着、两个号锁着（按文件名先后）、一个号没人锁（旧号不算）
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("computer-widget-test-\(getpid())")
    try? FileManager.default.createDirectory(at: dir.appendingPathComponent("排号"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    RenderQueue.folder = dir
    func lockedFile(_ url: URL, _ json: String) -> Int32 {
        FileManager.default.createFile(atPath: url.path, contents: Data(json.utf8))
        let fd = open(url.path, O_RDWR)
        precondition(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)
        return fd
    }
    let now = Date().timeIntervalSince1970
    let a = lockedFile(dir.appendingPathComponent("1.lock"), #"{"pid":1,"cwd":"/x/01_第一期/视频/_制作源文件","cmd":"node render.mjs --v h --shot open","at":\#(now - 600)}"#)
    let b = lockedFile(dir.appendingPathComponent("排号/0002_9.json"), #"{"pid":9,"cwd":"/x","cmd":"bash x.sh","at":\#(now - 1800)}"#)
    let c = lockedFile(dir.appendingPathComponent("排号/0001_7.json"), #"{"pid":7,"cwd":"/x/03_第三期/视频/_制作源文件","cmd":"python -u /e/tools/assemble.py h","at":\#(now - 3700)}"#)
    FileManager.default.createFile(atPath: dir.appendingPathComponent("排号/0003_8.json").path, contents: Data("{}".utf8))
    FileManager.default.createFile(atPath: dir.appendingPathComponent("0.lock").path, contents: Data("{}".utf8))
    let q = RenderQueue.read(pressure: 1)
    precondition(q.slots.count == 4 && q.slots[0].job == nil && q.slots[1].job == "第一期" && q.slots[1].detail == "渲 open")
    precondition(q.slots[1].minutes == 10 && q.slots[2].open && q.slots[3].label == "快")
    precondition(q.waiting.map(\.name) == ["第三期", "x"] && q.waiting[0].detail == "拼片" && q.waiting[0].minutes == 61 && q.quick.isEmpty)
    var snap = Snapshot(); snap.waiting = q.waiting
    precondition(snap.longestWait == 61)
    precondition(!RenderQueue.read(pressure: 2).slots[2].open)
    close(a); close(b); close(c)
    precondition(RenderQueue.read(pressure: 1).waiting.isEmpty)
    print("自测通过")
}

/// 现在的真实读数（间隔 2 秒采两次）
func liveSnapshot() -> Snapshot {
    let me = ProcessInfo.processInfo.processIdentifier
    let first = Monitor.measure(previousTicks: nil, previousProcesses: [:], since: Date(), paths: [:], me: me)
    Thread.sleep(forTimeInterval: 2)
    return Monitor.measure(previousTicks: first.ticks, previousProcesses: first.processes, since: first.time, paths: first.paths, me: me).snapshot
}

if let index = CommandLine.arguments.firstIndex(of: "--make-icon"), CommandLine.arguments.count > index + 1 {
    makeIcon(at: CommandLine.arguments[index + 1])
} else if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
    let live = liveSnapshot()
    MainActor.assumeIsolated { renderPreviews(into: CommandLine.arguments[index + 1], live: live) }
} else if CommandLine.arguments.contains("--snapshot") {
    let s = liveSnapshot()
    print("负载 \(s.load.map { String(format: "%.0f", $0) } ?? "—")（核数的 \(s.load.map { times($0 / Probe.cores) } ?? "—") 倍）"
          + (s.overload.map { "  超载 \(times($0)) 倍" } ?? ""))
    print("CPU \(percent(s.cpu))  " + Category.allCases.map { "\($0.name) \(percent(s.byCategory[$0] ?? 0))" }.joined(separator: "  "))
    print("GPU \(percent(s.gpu))  内存 \(gigabytes(s.memoryUsed))/\(gigabytes(s.memoryTotal)) 虚拟内存 \(gigabytes(s.swapUsed)) 压力 \(s.pressure)")
    for slot in s.slots { print("位子 \(slot.label)：\(slot.job.map { "\($0) \(slot.detail ?? "") \(slot.minutes ?? 0) 分" } ?? (slot.open ? "空闲" : "关"))") }
    for (i, item) in s.waiting.enumerated() { print("排着 \(i + 1)：\(item.name) \(item.detail) 等了 \(item.minutes.map(waitText) ?? "—")") }
    for (i, item) in s.waitingQuick.enumerated() { print("快道排着 \(i + 1)：\(item.name) \(item.detail) 等了 \(item.minutes.map(waitText) ?? "—")") }
    for hog in s.hogs { print("最占：\(hog.name) ×\(hog.count)（\(hog.category.name)）\(percent(hog.cpu))") }
} else if CommandLine.arguments.contains("--quit-running") {
    MainActor.assumeIsolated {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "local.computer.activity.widget")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        for app in running { app.terminate() }
        let deadline = Date().addingTimeInterval(8)
        while running.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if running.contains(where: { !$0.isTerminated }) {
            fputs("请先从小组件右上角「…」退出电脑活动，再重新构建。\n", stderr)
            exit(2)
        }
    }
} else if CommandLine.arguments.contains("--self-test") {
    MainActor.assumeIsolated { selfTest() }
} else if let index = CommandLine.arguments.firstIndex(of: "--login"), CommandLine.arguments.count > index + 1 {
    // 和菜单里「登录时打开」一样：用 .app 里的可执行文件跑，登记的就是这个 App。--login on|off|status
    let service = SMAppService.mainApp
    do {
        switch CommandLine.arguments[index + 1] {
        case "on": try service.register()
        case "off": try service.unregister()
        default: break
        }
    } catch {
        fputs("改不了登录项：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
    if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    print(["未登记", "已开启", "要在系统设置里批准", "找不到"][min(Int(service.status.rawValue), 3)])
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
