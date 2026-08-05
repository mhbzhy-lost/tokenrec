import XCTest
@testable import TokenRec

final class ProcessSingletonTests: XCTestCase {
    private var lockURL: URL!

    override func setUp() {
        super.setUp()
        lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenrec-singleton-test-\(UUID().uuidString).lock")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: lockURL)
        super.tearDown()
    }

    func testFirstAcquireSucceedsSecondFails() {
        var first = ProcessSingleton(lockFileURL: lockURL)
        var second = ProcessSingleton(lockFileURL: lockURL)
        XCTAssertTrue(first.tryAcquire(), "第一个实例应成功获取锁")
        XCTAssertFalse(second.tryAcquire(), "第二个实例应获取失败（互斥）")
        first.release()
    }

    func testAcquireAfterReleaseSucceeds() {
        var first = ProcessSingleton(lockFileURL: lockURL)
        var second = ProcessSingleton(lockFileURL: lockURL)
        XCTAssertTrue(first.tryAcquire())
        first.release()
        XCTAssertTrue(second.tryAcquire(), "锁释放后应可重新获取")
        second.release()
    }

    func testDifferentLockFilesDoNotConflict() {
        let otherURL = lockURL.appendingPathExtension("other")
        defer { try? FileManager.default.removeItem(at: otherURL) }
        var first = ProcessSingleton(lockFileURL: lockURL)
        var other = ProcessSingleton(lockFileURL: otherURL)
        XCTAssertTrue(first.tryAcquire())
        XCTAssertTrue(other.tryAcquire(), "不同锁文件不应互斥")
        first.release()
        other.release()
    }

    func testReacquireAfterReleaseIsStable() {
        var singleton = ProcessSingleton(lockFileURL: lockURL)
        for _ in 0..<3 {
            XCTAssertTrue(singleton.tryAcquire())
            singleton.release()
        }
    }
}
