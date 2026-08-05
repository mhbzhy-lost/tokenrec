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
            let sessionFiles = SessionScanner.allSessionFiles(in: dir)
            let sessionMeta = Self.fileMeta(for: sessionFiles)
            let cwds = Self.projectCwdsCached(for: sessionFiles, meta: sessionMeta)
            let artifactDirs = SessionScanner.subagentArtifactDirs(for: cwds)
            let subagentFiles = SessionScanner.allSubagentFiles(in: artifactDirs)
            let files = sessionFiles + subagentFiles
            let currentMeta = sessionMeta.merging(Self.fileMeta(for: subagentFiles)) { _, new in new }
            let toParse = files.filter { url in
                guard let meta = currentMeta[url], let cached = cacheSnapshot[url] else { return true }
                return meta.mtime != cached.mtime || meta.size != cached.size
            }
            let parsed = Self.parseFiles(toParse)
            // 后台合并（旧缓存 + 新解析）与全部聚合，主线程仅赋值
            func recordsFor(_ url: URL) -> [UsageRecord] {
                if let fresh = parsed[url] { return fresh }
                return cacheSnapshot[url]?.parsed ?? []
            }
            let subagentForMerge = files.filter { $0.lastPathComponent.hasSuffix("_transcript.jsonl") || $0.lastPathComponent.hasSuffix("_meta.json") }
            let transcriptRunIDs = Set(subagentForMerge.compactMap { file in
                file.lastPathComponent.hasSuffix("_transcript.jsonl") ? UsageParser.subagentRunId(from: file) : nil
            })
            var merged: [UsageRecord] = []
            for url in sessionFiles { merged += recordsFor(url) }
            for url in subagentForMerge {
                let runID = UsageParser.subagentRunId(from: url)
                if url.lastPathComponent.hasSuffix("_meta.json"), let runID, transcriptRunIDs.contains(runID) {
                    continue // 已有 transcript，防重复
                }
                merged += recordsFor(url)
            }
            let now = Date()
            let hourlyPoints = UsageAggregator.aggregate(merged, granularity: .hour, now: now)
            let dailyPoints = UsageAggregator.aggregate(merged, granularity: .day, now: now)
            let weeklyPoints = UsageAggregator.aggregate(merged, granularity: .week, now: now)
            let monthlyPoints = UsageAggregator.aggregate(merged, granularity: .month, now: now)
            let todayTokens = hourlyPoints.last?.totalTokens ?? 0
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

    /// 后台线程解析：返回 [URL: 记录列表]（subagent transcript/meta 按各自解析器）。
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
                let records: [UsageRecord]
                if file.lastPathComponent.hasSuffix("_transcript.jsonl") {
                    records = (try? UsageParser.parseSubagentTranscript(url: file)) ?? []
                } else if file.lastPathComponent.hasSuffix("_meta.json") {
                    records = (try? UsageParser.parseSubagentMeta(url: file)) ?? []
                } else {
                    records = (try? UsageParser.parseSession(url: file)) ?? []
                }
                lock.lock()
                result[file] = records
                lock.unlock()
            }
        }
        group.wait()
        return result
    }

    // MARK: - projectCwds 缓存（cwd 变化频率极低，仅 session 文件清单+mtime 变化时重扫）

    private struct CwdCacheKey: Equatable {
        let path: String
        let mtime: Date
        let size: Int
    }

    nonisolated(unsafe) private static var cwdCacheLock = NSLock()
    nonisolated(unsafe) private static var cwdCacheKey: [CwdCacheKey] = []
    nonisolated(unsafe) private static var cwdCacheValue: [String] = []

    nonisolated private static func projectCwdsCached(for sessionFiles: [URL], meta: [URL: (mtime: Date, size: Int)]) -> [String] {
        let key = sessionFiles.map { CwdCacheKey(path: $0.path, mtime: meta[$0]?.mtime ?? .distantPast, size: meta[$0]?.size ?? -1) }
        cwdCacheLock.lock()
        defer { cwdCacheLock.unlock() }
        if key == cwdCacheKey { return cwdCacheValue }
        let cwds = SessionScanner.projectCwds(from: sessionFiles)
        cwdCacheKey = key
        cwdCacheValue = cwds
        return cwds
    }
}
