import Foundation

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
        let configuredPath = userDefaults.string(forKey: "sessionDir")
            ?? environment["PI_CODING_AGENT_SESSION_DIR"]
            ?? "~/.pi/agent/sessions"
        return expandHome(in: configuredPath)
    }

    static func allSessionFiles(in directory: URL, fileManager: FileManager = .default) -> [URL] {
        recursiveFiles(in: directory, fileManager: fileManager) { $0.pathExtension == "jsonl" }
    }

    static func projectCwds(from sessionFiles: [URL]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for file in sessionFiles.sorted(by: { $0.path < $1.path }) {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in contents.split(whereSeparator: \.isNewline) {
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

    private func expandHome(in path: String) -> URL {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
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
