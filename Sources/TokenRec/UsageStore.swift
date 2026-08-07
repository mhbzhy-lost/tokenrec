import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var summary = UsageSummary(
        todayTokens: 0,
        monthTokens: 0,
        totalTokens: 0,
        totalCost: 0,
        points: [:]
    )
    @Published private(set) var modelUsage: [ModelUsage] = []
    @Published private(set) var modelUsageByWindow: [UsageWindow: [ModelUsage]] = [:]
    @Published private(set) var windowPoints: [UsageWindow: [UsagePoint]] = [:]
    @Published private(set) var lastError: String?
    @Published private(set) var dataDirectory: URL

    private let repository: any UsageLoading
    private let scanner: SessionScanner
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private var monitoringTimer: Timer?
    private var isRefreshing = false

    init(
        repository: any UsageLoading = UsageRepository(),
        scanner: SessionScanner = SessionScanner(),
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .current,
        startsMonitoring: Bool = true
    ) {
        self.repository = repository
        self.scanner = scanner
        self.now = now
        self.calendar = calendar
        self.dataDirectory = scanner.resolveSessionDir()
        if startsMonitoring { startMonitoring() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let directory = scanner.resolveSessionDir()
        let result = await repository.load(sessionDir: directory)
        let now = now()
        let calendar = calendar
        let summary = await Task.detached(priority: .utility) {
            UsageAggregator.summarize(result.records, now: now, calendar: calendar)
        }.value
        let modelUsage = await Task.detached(priority: .utility) {
            UsageAggregator.byModel(result.records, window: .today, now: now, calendar: calendar)
        }.value
        let modelUsageByWindow = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: UsageWindow.allCases.map { window in
                (window, UsageAggregator.byModel(result.records, window: window, now: now, calendar: calendar))
            })
        }.value
        let windowPoints = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: UsageWindow.allCases.map { window in
                (window, UsageAggregator.points(records: result.records, window: window, now: now, calendar: calendar))
            })
        }.value

        dataDirectory = directory
        self.summary = summary
        self.modelUsage = modelUsage
        self.modelUsageByWindow = modelUsageByWindow
        self.windowPoints = windowPoints
        lastError = result.errors.isEmpty
            ? nil
            : result.errors.map { "\($0.path): \($0.message)" }.joined(separator: "\n")
    }

    func startMonitoring() {
        monitoringTimer?.invalidate()
        Task { await refresh() }
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
    }
}
