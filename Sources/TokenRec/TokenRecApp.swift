import SwiftUI

@main
struct TokenRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store: UsageStore

    /// 单实例守卫：已有实例持锁时直接退出（状态栏不出现重复图标）
    private var singleton: ProcessSingleton

    init() {
        var guard_ = ProcessSingleton(lockFileURL: Self.lockFileURL)
        guard guard_.tryAcquire() else {
            exit(0)
        }
        singleton = guard_
        _store = StateObject(wrappedValue: UsageStore())
    }

    private static var lockFileURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tokenrec.lock")
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Label {
            Text(store.todayTokens, format: .number.notation(.compactName))
        } icon: {
            Image(systemName: "chart.line.uptrend.xyaxis")
        }
        .help("TokenRec: 今日已消耗 \(store.todayTokens) tokens")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
