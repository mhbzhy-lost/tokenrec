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
    /// 文件级缓存：key=文件 URL，value=(mtime, size, 已解析记录)。仅重解析变化的文件。
    private var fileCache: [URL: (mtime: Date, size: Int, parsed: [UsageRecord])] = [:]
    private var isRefreshing = false

    init(scanner: SessionScanner = SessionScanner()) {
        self.scanner = scanner
        startMonitoring()
    }

    func refresh() {
        guard !isRefreshing else { return } // 后台解析慢于 10 秒周期时跳过本轮，不累积
        isRefreshing = true
        let dir = scanner.resolveSessionDir() // 主线程仅做轻量目录解析
        let cacheSnapshot = fileCache
        Task.detached(priority: .utility) { [weak self] in
            // 递归收集 var/sessions 下全部 *.jsonl：顶层 = pi 主进程会话，嵌套目录 = subagent 进程会话
            // （pi-subagents 将子代理会话写入 <parent-session>/<hash>/run-N/session.jsonl，均为权威记录；
            //  项目 .pi-subagents/artifacts 的 transcript 与嵌套会话内容重叠，不再扫描以避免双计）
            let files = SessionScanner.allSessionFiles(in: dir)
            let currentMeta = Self.fileMeta(for: files)
            let toParse = files.filter { url in
                guard let meta = currentMeta[url], let cached = cacheSnapshot[url] else { return true }
                return meta.mtime != cached.mtime || meta.size != cached.size
            }
            let parsed = Self.parseFiles(toParse)
            // 后台合并（旧缓存 + 新解析）与全部聚合，主线程仅赋值
            var merged: [UsageRecord] = []
            for url in files {
                if let fresh = parsed[url] {
                    merged += fresh
                } else if let cached = cacheSnapshot[url] {
                    merged += cached.parsed
                }
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
                for url in toParse {
                    if let meta = currentMeta[url], let records = parsed[url] {
                        self.fileCache[url] = (meta.mtime, meta.size, records)
                    }
                }
                // 移除已不存在的文件缓存
                let live = Set(files)
                self.fileCache = self.fileCache.filter { live.contains($0.key) }
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

    func startMonitoring() {
        monitoringTimer?.invalidate()
        refresh()
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
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

    /// 后台线程解析：返回 [URL: 记录列表]。
    /// 并发解析（限 8 路）加速首次全量加载；合并顺序由调用方按文件序保证，语义不变。
    nonisolated private static func parseFiles(_ files: [URL]) -> [URL: [UsageRecord]] {
        let lock = NSLock()
        nonisolated(unsafe) var result: [URL: [UsageRecord]] = [:]
        let semaphore = DispatchSemaphore(value: 8)
        let group = DispatchGroup()
        for file in files {
            group.enter()
            semaphore.wait()
            DispatchQueue.global(qos: .utility).async {
                defer {
                    semaphore.signal()
                    group.leave()
                }
                lock.lock()
                result[file] = (try? UsageParser.parseSession(url: file)) ?? []
                lock.unlock()
            }
        }
        group.wait()
        return result
    }
}
