import Darwin
import Foundation
import XCTest

final class RuntimeVerificationScriptTests: XCTestCase {
    func testTeardownProbeStopsOnlyOwnedPidAndLeavesUnrelatedProcessAlive() throws {
        let sentinel = Process()
        sentinel.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sentinel.arguments = ["30"]
        try sentinel.run()
        defer {
            if sentinel.isRunning {
                sentinel.terminate()
                sentinel.waitUntilExit()
            }
        }

        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenrec-owned-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let verifier = Process()
        verifier.executableURL = URL(fileURLWithPath: "/bin/bash")
        verifier.arguments = [scriptURL.path, "--teardown-probe", pidFile.path]
        verifier.standardOutput = Pipe()
        verifier.standardError = Pipe()
        try verifier.run()
        verifier.waitUntilExit()

        XCTAssertEqual(verifier.terminationStatus, 0)
        let ownedPID = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertFalse(processExists(ownedPID), "验收脚本退出后必须回收自己启动的 PID")
        XCTAssertTrue(sentinel.isRunning, "teardown 不得误杀无关进程")
    }

    func testImmediateSecondExitProbeDoesNotFailDuringIdentityCapture() throws {
        let verifier = Process()
        verifier.executableURL = URL(fileURLWithPath: "/bin/bash")
        verifier.arguments = [scriptURL.path, "--immediate-exit-probe"]
        verifier.standardOutput = Pipe()
        verifier.standardError = Pipe()
        try verifier.run()
        verifier.waitUntilExit()

        XCTAssertEqual(verifier.terminationStatus, 0)
    }

    func testIdentityMismatchProbeRefusesToKillReusedPid() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenrec-mismatched-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let verifier = Process()
        verifier.executableURL = URL(fileURLWithPath: "/bin/bash")
        verifier.arguments = [scriptURL.path, "--identity-mismatch-probe", pidFile.path]
        verifier.standardOutput = Pipe()
        verifier.standardError = Pipe()
        try verifier.run()
        verifier.waitUntilExit()

        XCTAssertEqual(verifier.terminationStatus, 0)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer {
            if processExists(pid) {
                kill(pid, SIGTERM)
                for _ in 0..<50 where processExists(pid) { usleep(10_000) }
            }
        }
        XCTAssertTrue(processExists(pid), "identity 不匹配时必须 fail closed，不得仅凭 PID 清理")
    }

    private var scriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/verify-installed-app.sh")
    }

    private func processExists(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
