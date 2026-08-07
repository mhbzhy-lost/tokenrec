import SwiftUI

struct ContentView: View {
    @ObservedObject var store: UsageStore
    @AppStorage("sessionDir") private var sessionDir = ""
    @State private var window: UsageWindow = .today
    @State private var isEditingDirectory = false

    init(store: UsageStore) {
        self.store = store
    }

    private var chartPoints: [UsagePoint] {
        store.windowPoints[window] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("TokenRec")
                    .font(.title2.bold())
                Spacer()
                Button("设置目录") { isEditingDirectory = true }
            }

            UsageStatsView(
                todayTokens: store.summary.todayTokens,
                monthTokens: store.summary.monthTokens,
                totalTokens: store.summary.totalTokens,
                totalCost: store.summary.totalCost
            )

            Picker("统计口径", selection: $window) {
                ForEach(UsageWindow.allCases) { window in
                    Text(window.title).tag(window)
                }
            }
            .pickerStyle(.segmented)

            UsageChartView(points: chartPoints, window: window)

            ModelUsageView(modelUsage: store.modelUsageByWindow[window] ?? [], window: window)

            HStack(spacing: 4) {
                Text("数据源：")
                Text(store.dataDirectory.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .frame(width: 520)
        .onAppear { Task { await store.refresh() } }
        .sheet(isPresented: $isEditingDirectory) {
            DirEditorSheet(sessionDir: $sessionDir) {
                Task { await store.refresh() }
            }
        }
    }
}

struct DirEditorSheet: View {
    @Binding var sessionDir: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(sessionDir: Binding<String>, onSave: @escaping () -> Void) {
        _sessionDir = sessionDir
        self.onSave = onSave
        _draft = State(initialValue: sessionDir.wrappedValue.isEmpty ? SessionScanner().resolveSessionDir().path : sessionDir.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("会话目录").font(.headline)
            TextField("~/.pi/agent/sessions", text: $draft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    sessionDir = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 440)
    }
}
