import Foundation

struct SessionDescriptor: Equatable, Sendable {
    let url: URL
    let sessionId: String
    let cwd: String
    let subagentRunId: String?
}

struct SessionScanner {
    private let userDefaults: UserDefaults
    private let environment: [String: String]
    private let fileManager: FileManager
    private let homeDirectory: URL

    init(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.userDefaults = userDefaults
        self.environment = environment
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    func resolveSessionDir() -> URL {
        let configured = normalizedPath(userDefaults.string(forKey: "sessionDir"))
        let environmentPath = normalizedPath(environment["PI_CODING_AGENT_SESSION_DIR"])
        let currentPi = homeDirectory.appendingPathComponent("pi-config/var/sessions")
        let legacy = homeDirectory.appendingPathComponent(".pi/agent/sessions")
        let candidates = [configured, environmentPath].compactMap { $0 }.map(expandHome(in:)) + [currentPi, legacy]
        return candidates.first(where: containsJSONL(in:)) ?? legacy
    }

    static func allSessionFiles(in directory: URL, fileManager: FileManager = .default) -> [URL] {
        recursiveFiles(in: directory, fileManager: fileManager) { $0.pathExtension == "jsonl" }
    }

    static func sessionDescriptors(in directory: URL, fileManager: FileManager = .default) -> [SessionDescriptor] {
        allSessionFiles(in: directory, fileManager: fileManager).compactMap(sessionDescriptor(at:))
    }

    static func projectCwds(from sessionFiles: [URL]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for file in sessionFiles.sorted(by: { $0.path < $1.path }) {
            // cwd 属于 session 级属性，恒在文件头部（首条 session entry）；
            // 只读文件前 64KB 找前 20 行，避免全量读入（864 个文件全量逐行解析是 CPU 热点）
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            let head = data.prefix(64 * 1024)
            let text = String(decoding: head, as: UTF8.self)
            var linesChecked = 0
            for line in text.split(whereSeparator: \.isNewline) {
                linesChecked += 1
                if linesChecked > 20 { break }
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let cwd = object["cwd"] as? String,
                      !cwd.isEmpty,
                      seen.insert(cwd).inserted else { continue }
                result.append(cwd)
            }
        }
        return result
    }

    static func subagentArtifactDirs(for projectCwds: [String], fileManager: FileManager = .default) -> [URL] {
        projectCwds.compactMap { cwd in
            let artifacts = URL(fileURLWithPath: cwd).appendingPathComponent(".pi-subagents/artifacts")
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: artifacts.path, isDirectory: &isDirectory) && isDirectory.boolValue ? artifacts : nil
        }.sorted(by: { $0.path < $1.path })
    }

    static func allSubagentFiles(in artifactDirs: [URL], fileManager: FileManager = .default) -> [URL] {
        recursiveFiles(in: artifactDirs, fileManager: fileManager) {
            $0.lastPathComponent.hasSuffix("_transcript.jsonl") || $0.lastPathComponent.hasSuffix("_meta.json")
        }
    }

    private func normalizedPath(_ path: String?) -> String? {
        guard let value = path?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func containsJSONL(in directory: URL) -> Bool {
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return true }
        }
        return false
    }

    private func expandHome(in path: String) -> URL {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    private static func sessionDescriptor(at url: URL) -> SessionDescriptor? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        var sessionId: String?
        var cwd: String?
        var subagentRunId: String?
        for (index, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            if index >= 20 { break }
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            if object["type"] as? String == "session" {
                sessionId = object["id"] as? String
                cwd = object["cwd"] as? String
            } else if object["type"] as? String == "session_info", let name = object["name"] as? String {
                subagentRunId = runId(fromSessionName: name)
            }
        }
        guard let sessionId, !sessionId.isEmpty, let cwd, !cwd.isEmpty else { return nil }
        return SessionDescriptor(url: url, sessionId: sessionId, cwd: cwd, subagentRunId: subagentRunId)
    }

    private static func runId(fromSessionName name: String) -> String? {
        let pattern = #"^subagent-(?:executor|spark|delegate)-([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})-[0-9]+$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name) else { return nil }
        return String(name[range]).lowercased()
    }

    private static func recursiveFiles(in directories: [URL], fileManager: FileManager, where predicate: (URL) -> Bool) -> [URL] {
        directories.flatMap { directory -> [URL] in
            guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
            return enumerator.compactMap { $0 as? URL }.filter { url in
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
                return predicate(url)
            }
        }.sorted(by: { $0.path < $1.path })
    }

    private static func recursiveFiles(in directory: URL, fileManager: FileManager, where predicate: (URL) -> Bool) -> [URL] {
        recursiveFiles(in: [directory], fileManager: fileManager, where: predicate)
    }
}
