import Foundation

/// 进程单例守卫：基于 flock 的跨进程互斥锁。
/// 持锁进程退出（含崩溃）后内核自动释放锁，无需手动清理。
struct ProcessSingleton {
    let lockFileURL: URL
    private var fileDescriptor: Int32?

    init(lockFileURL: URL) {
        self.lockFileURL = lockFileURL
    }

    /// 尝试获取独占锁。成功返回 true 并持有锁；失败（已有实例持锁）返回 false。
    mutating func tryAcquire() -> Bool {
        guard fileDescriptor == nil else { return true } // 已持有
        let fd = open(lockFileURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            fileDescriptor = fd
            return true
        }
        close(fd)
        return false
    }

    /// 释放锁并关闭文件描述符。
    mutating func release() {
        guard let fd = fileDescriptor else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fileDescriptor = nil
    }
}
