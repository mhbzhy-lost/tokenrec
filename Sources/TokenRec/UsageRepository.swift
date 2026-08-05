import Foundation

struct UsageLoadError: Equatable, Sendable {
    let path: String
    let message: String
}

struct UsageLoadResult: Equatable, Sendable {
    let records: [UsageRecord]
    let errors: [UsageLoadError]
}

protocol UsageLoading: Sendable {
    func load(sessionDir: URL) async -> UsageLoadResult
}

enum UsageFileSource: Sendable {
    case session
    case transcript
    case meta
}

enum UsageFileParserError: Error, CustomStringConvertible {
    case malformedUsageJSON(line: Int)
    case malformedMetaJSON

    var description: String {
        switch self {
        case .malformedUsageJSON(let line): "malformed usage JSON at line \(line)"
        case .malformedMetaJSON: "malformed subagent meta JSON"
        }
    }
}

struct UsageParsedFile: Sendable {
    let records: [UsageRecord]
    let parsedOffset: Int64
}

struct UsageFileParser: Sendable {
    private let operation: @Sendable (URL, UsageFileSource, Int64) throws -> UsageParsedFile

    init(_ operation: @escaping @Sendable (URL, UsageFileSource, Int64) throws -> UsageParsedFile) {
        self.operation = operation
    }

    func parse(url: URL, source: UsageFileSource, fromOffset: Int64) throws -> UsageParsedFile {
        try operation(url, source, fromOffset)
    }

    static let live = UsageFileParser { url, source, offset in
        switch source {
        case .session:
            return try parseSessionChunk(url: url, fromOffset: offset)
        case .transcript:
            let text = try String(contentsOf: url, encoding: .utf8)
            try validateUsageJSONLines(text)
            let records = try UsageParser.parseSubagentTranscript(text)
            return UsageParsedFile(records: records, parsedOffset: try fileSize(url))
        case .meta:
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let data = text.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil else {
                throw UsageFileParserError.malformedMetaJSON
            }
            let records = try UsageParser.parseSubagentMeta(text)
            return UsageParsedFile(records: records, parsedOffset: try fileSize(url))
        }
    }

    private static func parseSessionChunk(url: URL, fromOffset: Int64) throws -> UsageParsedFile {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, fromOffset)))
        let data = try handle.readToEnd() ?? Data()
        guard !data.isEmpty else { return UsageParsedFile(records: [], parsedOffset: fromOffset) }

        var consumed = data.count
        if data.last != 0x0A {
            let finalLineStart = (data.lastIndex(of: 0x0A).map { data.index(after: $0) }) ?? data.startIndex
            let finalLine = data[finalLineStart...]
            if (try? JSONSerialization.jsonObject(with: Data(finalLine))) == nil {
                consumed = data.distance(from: data.startIndex, to: finalLineStart)
            }
        }
        guard consumed > 0 else { return UsageParsedFile(records: [], parsedOffset: fromOffset) }
        let parseable = String(decoding: data.prefix(consumed), as: UTF8.self)
        try validateUsageJSONLines(parseable)
        let records = try UsageParser.parseSession(parseable)
        return UsageParsedFile(records: records, parsedOffset: fromOffset + Int64(consumed))
    }

    private static func validateUsageJSONLines(_ text: String) throws {
        for (index, line) in text.split(whereSeparator: \.isNewline).enumerated() where line.contains("usage") {
            guard let data = String(line).data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil else {
                throw UsageFileParserError.malformedUsageJSON(line: index + 1)
            }
        }
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let value = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return Int64(value)
    }
}

actor UsageRepository: UsageLoading {
    typealias ArtifactDirectoryResolver = @Sendable ([String]) -> [URL]

    private struct SelectedFile: Sendable {
        let url: URL
        let source: UsageFileSource
    }

    private struct FileSignature: Equatable, Sendable {
        let identity: UInt64
        let mtime: Date
        let size: Int64
        let headDigest: UInt64
        let tailDigest: UInt64
    }

    private struct CacheEntry: Sendable {
        let source: UsageFileSource
        let signature: FileSignature
        let parsedOffset: Int64
        let records: [UsageRecord]
    }

    private struct ParseJob: Sendable {
        let file: SelectedFile
        let signature: FileSignature
        let fromOffset: Int64
        let prefix: [UsageRecord]
    }

    private struct ParseOutcome: Sendable {
        let job: ParseJob
        let parsed: UsageParsedFile?
        let errorMessage: String?
    }

    private let parser: UsageFileParser
    private let artifactDirectories: ArtifactDirectoryResolver
    private var cache: [URL: CacheEntry] = [:]

    init(
        parser: UsageFileParser = .live,
        artifactDirectories: @escaping ArtifactDirectoryResolver = { SessionScanner.subagentArtifactDirs(for: $0) }
    ) {
        self.parser = parser
        self.artifactDirectories = artifactDirectories
    }

    func load(sessionDir: URL) async -> UsageLoadResult {
        let selected = selectedFiles(sessionDir: sessionDir)
        let liveURLs = Set(selected.map(\.url))
        var nextCache: [URL: CacheEntry] = [:]
        var recordsByURL: [URL: [UsageRecord]] = [:]
        var errors: [UsageLoadError] = []
        var jobs: [ParseJob] = []

        for file in selected {
            do {
                let signature = try Self.signature(for: file.url)
                if let cached = cache[file.url], cached.source == file.source, cached.signature == signature {
                    nextCache[file.url] = cached
                    recordsByURL[file.url] = cached.records
                    continue
                }

                var fromOffset: Int64 = 0
                var prefix: [UsageRecord] = []
                if file.source == .session,
                   let cached = cache[file.url],
                   cached.source == .session,
                   signature.identity == cached.signature.identity,
                   signature.size > cached.signature.size,
                   (try? Self.digest(url: file.url, offset: 0, count: min(4096, cached.signature.size))) == cached.signature.headDigest,
                   (try? Self.digest(url: file.url, offset: max(0, cached.signature.size - 4096), count: min(4096, cached.signature.size))) == cached.signature.tailDigest {
                    fromOffset = cached.parsedOffset
                    prefix = cached.records
                }
                jobs.append(ParseJob(file: file, signature: signature, fromOffset: fromOffset, prefix: prefix))
            } catch {
                if let cached = cache[file.url] {
                    nextCache[file.url] = cached
                    recordsByURL[file.url] = cached.records
                }
                errors.append(UsageLoadError(path: file.url.path, message: String(describing: error)))
            }
        }

        let outcomes = await Self.parse(jobs: jobs, with: parser)
        for outcome in outcomes {
            let url = outcome.job.file.url
            if let parsed = outcome.parsed {
                let records = outcome.job.prefix + parsed.records
                let entry = CacheEntry(source: outcome.job.file.source, signature: outcome.job.signature, parsedOffset: parsed.parsedOffset, records: records)
                nextCache[url] = entry
                recordsByURL[url] = records
            } else {
                if let cached = cache[url] {
                    nextCache[url] = cached
                    recordsByURL[url] = cached.records
                }
                errors.append(UsageLoadError(path: url.path, message: outcome.errorMessage ?? "unknown parse error"))
            }
        }

        cache = nextCache.filter { liveURLs.contains($0.key) }
        let records = selected.flatMap { recordsByURL[$0.url] ?? [] }
        return UsageLoadResult(records: records, errors: errors.sorted { $0.path < $1.path })
    }

    private func selectedFiles(sessionDir: URL) -> [SelectedFile] {
        let sessionFiles = SessionScanner.allSessionFiles(in: sessionDir)
        let descriptors = SessionScanner.sessionDescriptors(in: sessionDir)
        let childRunIds = Set(descriptors.compactMap(\.subagentRunId))
        var cwds = descriptors.map(\.cwd)
        cwds.append(contentsOf: SessionScanner.projectCwds(from: sessionFiles))
        let uniqueCwds = Array(Set(cwds)).sorted()
        let artifactFiles = SessionScanner.allSubagentFiles(in: artifactDirectories(uniqueCwds))

        var artifactsByRun: [String: [URL]] = [:]
        for url in artifactFiles {
            guard let runId = UsageParser.subagentRunId(from: url) else { continue }
            artifactsByRun[runId, default: []].append(url)
        }

        var selected = sessionFiles.map { SelectedFile(url: $0, source: .session) }
        for runId in artifactsByRun.keys.sorted() where !childRunIds.contains(runId) {
            let files = artifactsByRun[runId, default: []].sorted { $0.path < $1.path }
            if let transcript = files.first(where: { $0.lastPathComponent.hasSuffix("_transcript.jsonl") }) {
                selected.append(SelectedFile(url: transcript, source: .transcript))
            } else if let meta = files.first(where: { $0.lastPathComponent.hasSuffix("_meta.json") }) {
                selected.append(SelectedFile(url: meta, source: .meta))
            }
        }
        return selected
    }

    private nonisolated static func parse(jobs: [ParseJob], with parser: UsageFileParser) async -> [ParseOutcome] {
        await withTaskGroup(of: ParseOutcome.self, returning: [ParseOutcome].self) { group in
            var iterator = jobs.makeIterator()
            for _ in 0..<min(8, jobs.count) {
                if let job = iterator.next() { add(job, to: &group, parser: parser) }
            }
            var outcomes: [ParseOutcome] = []
            while let outcome = await group.next() {
                outcomes.append(outcome)
                if let job = iterator.next() { add(job, to: &group, parser: parser) }
            }
            return outcomes
        }
    }

    private nonisolated static func add(
        _ job: ParseJob,
        to group: inout TaskGroup<ParseOutcome>,
        parser: UsageFileParser
    ) {
        group.addTask {
            do {
                return ParseOutcome(job: job, parsed: try parser.parse(url: job.file.url, source: job.file.source, fromOffset: job.fromOffset), errorMessage: nil)
            } catch {
                return ParseOutcome(job: job, parsed: nil, errorMessage: String(describing: error))
            }
        }
    }

    private nonisolated static func signature(for url: URL) throws -> FileSignature {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let identity = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date) ?? .distantPast
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return FileSignature(
            identity: identity,
            mtime: mtime,
            size: size,
            headDigest: try digest(url: url, offset: 0, count: min(4096, size)),
            tailDigest: try digest(url: url, offset: max(0, size - 4096), count: min(4096, size))
        )
    }

    private nonisolated static func digest(url: URL, offset: Int64, count: Int64) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, offset)))
        let data = try handle.read(upToCount: Int(max(0, count))) ?? Data()
        return data.reduce(1_469_598_103_934_665_603) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
