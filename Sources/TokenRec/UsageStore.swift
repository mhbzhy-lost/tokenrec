import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var records: [UsageRecord] = []
    @Published private(set) var lastError: String?
    // 预计算指标（后台聚合一次发布，避免 UI body 内重复 O(n) 聚合）
    @Published private(set) var todayTokens = 0
    @Published private(set) var monthTokens = 0
    @Published private(set) var totalTokens = 0
    @Published private(set) var hourlyPoints: [UsagePoint] = []
    @Published private(set) var dailyPoints: [UsagePoint] = []
    @Published private(set) var weeklyPoints: [UsagePoint] = []
    @Published private(set) var monthlyPoints: [UsagePoint] = []

    private let scanner: SessionScanner
    private var monitoringTimer: Timer?
    /// 文件级缓存：key=文件 URL，value=(mtime, size, 已解析字节偏移, 已解析记录)。
    /// 增量策略：size 增大（append-only）→ 从 parsedOffset 只解析新增行；
    /// size 变小或同尺寸但 mtime 变化（重写）→ 全量重解析。
    private var fileCache: [URL: (mtime: Date, size: Int, parsedOffset: Int64, parsed: [UsageRecord])] = [:]
    private var isRefreshing = false

    init(scanner: SessionScanner = SessionScanner()) {
        self.scanner = scanner
        startMonitoring()
    }

    func refresh() {
        guard !isRefreshing else { return } // 后台解析慢于轮询周期时跳过本轮，不累积
        isRefreshing = true
        let dir = scanner.resolveSessionDir() // 主线程仅做轻量目录解析
        let cacheSnapshot = fileCache
        Task.detached(priority: .utility) { [weak self] in
            // 递归收集 var/sessions 下全部 *.jsonl：顶层 = pi 主进程会话，嵌套目录 = subagent 进程会话
            // （pi-subagents 将子代理会话写入 <parent-session>/<hash>/run-N/session.jsonl，均为权威记录）
            let files = SessionScanner.allSessionFiles(in: dir)
            let currentMeta = Self.fileMeta(for: files)
            // 8 路并发解析（未变化走缓存、追加走增量、重写走全量），主线程仅赋值
            let results = Self.parseFilesConcurrently(files, meta: currentMeta, cache: cacheSnapshot)
            var merged: [UsageRecord] = []
            var newCache: [URL: (mtime: Date, size: Int, parsedOffset: Int64, parsed: [UsageRecord])] = [:]
            for url in files {
                guard let meta = currentMeta[url], let result = results[url] else { continue }
                merged += result.records
                newCache[url] = (meta.mtime, meta.size, result.offset, result.records)
            }
            let now = Date()
            let hourlyPoints = UsageAggregator.aggregate(merged, granularity: .hour, now: now)
            let dailyPoints = UsageAggregator.aggregate(merged, granularity: .day, now: now)
            let weeklyPoints = UsageAggregator.aggregate(merged, granularity: .week, now: now)
            let monthlyPoints = UsageAggregator.aggregate(merged, granularity: .month, now: now)
            let todayTokens = dailyPoints.last?.totalTokens ?? 0
            let monthTokens = monthlyPoints.last?.totalTokens ?? 0
            let totalTokens = merged.reduce(0) { $0 + $1.totalTokens }
            await MainActor.run {
                guard let self else { return }
                self.fileCache = newCache // 整表替换，天然清理已消失文件
                self.records = merged
                self.hourlyPoints = hourlyPoints
                self.dailyPoints = dailyPoints
                self.weeklyPoints = weeklyPoints
                self.monthlyPoints = monthlyPoints
                self.todayTokens = todayTokens
                self.monthTokens = monthTokens
                self.totalTokens = totalTokens
                self.isRefreshing = false
            }
        }
    }

    /// 单文件解析策略：未变化→复用缓存；size 增大→尾部增量；重写/截断→全量。
    /// 后台线程调用（非隔离纯函数）。
    nonisolated private static func parseFile(
        url: URL,
        mtime: Date,
        size: Int,
        cached: (mtime: Date, size: Int, parsedOffset: Int64, parsed: [UsageRecord])?
    ) -> (records: [UsageRecord], offset: Int64) {
        guard let cached else {
            return ((try? UsageParser.parseSession(url: url)) ?? [], Int64(size))
        }
        if size == cached.size, mtime == cached.mtime {
            return (cached.parsed, cached.parsedOffset) // 未变化
        }
        if size > cached.size {
            // append-only 追加：只解析新增行（从已解析偏移开始），拼接缓存
            let new = (try? UsageParser.parseSession(url: url, fromOffset: cached.parsedOffset)) ?? []
            return (cached.parsed + new, Int64(size))
        }
        // size 变小或同尺寸重写：全量重解析
        return ((try? UsageParser.parseSession(url: url)) ?? [], Int64(size))
    }

    func startMonitoring() {
        monitoringTimer?.invalidate()
        refresh()
        // 5 分钟轮询兜底 + 用户点击面板时（ContentView onAppear）立即刷新
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
    }

    // MARK: - 后台收集（非 MainActor）

    nonisolated private static func fileMeta(for files: [URL]) -> [URL: (mtime: Date, size: Int)] {
        var result: [URL: (mtime: Date, size: Int)] = [:]
        for url in files {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = values.contentModificationDate, let size = values.fileSize else { continue }
            result[url] = (mtime, size)
        }
        return result
    }

    /// 8 路并发逐文件解析（未变化走缓存、追加走增量、重写走全量）。
    /// 返回 [URL: (records, offset)]；合并顺序由调用方按文件序保证，语义不变。
    nonisolated private static func parseFilesConcurrently(
        _ files: [URL],
        meta: [URL: (mtime: Date, size: Int)],
        cache: [URL: (mtime: Date, size: Int, parsedOffset: Int64, parsed: [UsageRecord])]
    ) -> [URL: (records: [UsageRecord], offset: Int64)] {
        let lock = NSLock()
        nonisolated(unsafe) var result: [URL: (records: [UsageRecord], offset: Int64)] = [:]
        let semaphore = DispatchSemaphore(value: 8)
        let group = DispatchGroup()
        for url in files {
            guard let m = meta[url] else { continue }
            group.enter()
            semaphore.wait()
            DispatchQueue.global(qos: .utility).async {
                defer {
                    semaphore.signal()
                    group.leave()
                }
                let r = parseFile(url: url, mtime: m.mtime, size: m.size, cached: cache[url])
                lock.lock()
                result[url] = r
                lock.unlock()
            }
        }
        group.wait()
        return result
    }
}
