import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var records: [UsageRecord] = []

    private let scanner: SessionScanner
    private var monitoringTimer: Timer?

    init(scanner: SessionScanner = SessionScanner()) {
        self.scanner = scanner
    }

    func refresh() {
        let sessionFiles = SessionScanner.allSessionFiles(in: scanner.resolveSessionDir())
        var collected = sessionFiles.flatMap { (try? UsageParser.parseSession(url: $0)) ?? [] }

        let artifactDirs = SessionScanner.subagentArtifactDirs(for: SessionScanner.projectCwds(from: sessionFiles))
        let subagentFiles = SessionScanner.allSubagentFiles(in: artifactDirs)
        let transcriptRunIDs = Set(subagentFiles.compactMap { file in
            file.lastPathComponent.hasSuffix("_transcript.jsonl") ? UsageParser.subagentRunId(from: file) : nil
        })

        for file in subagentFiles {
            if file.lastPathComponent.hasSuffix("_transcript.jsonl") {
                collected += (try? UsageParser.parseSubagentTranscript(url: file)) ?? []
            } else if file.lastPathComponent.hasSuffix("_meta.json"),
                      let runID = UsageParser.subagentRunId(from: file),
                      !transcriptRunIDs.contains(runID) {
                collected += (try? UsageParser.parseSubagentMeta(url: file)) ?? []
            }
        }
        records = collected
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
}
