import SwiftUI

@main
struct TokenRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store: UsageStore

    init() {
        _store = StateObject(wrappedValue: UsageStore())
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            MenuBarLabel(records: store.records)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let records: [UsageRecord]

    private var todayTokens: Int {
        UsageAggregator.aggregate(records, granularity: .hour).last?.totalTokens ?? 0
    }

    var body: some View {
        Label {
            Text(todayTokens, format: .number.notation(.compactName))
        } icon: {
            Image(systemName: "chart.line.uptrend.xyaxis")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
