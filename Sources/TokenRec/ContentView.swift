import SwiftUI

struct ContentView: View {
    @ObservedObject var store: UsageStore
    @AppStorage("sessionDir") private var sessionDir = ""
    @State private var granularity: Granularity = .hour
    @State private var isEditingDirectory = false

    init(store: UsageStore) {
        self.store = store
    }

    /// 使用 store 预计算的各粒度数据（后台聚合一次，UI 不再重复 O(n) 计算）
    private var chartPoints: [UsagePoint] {
        switch granularity {
        case .hour: return store.hourlyPoints
        case .day: return store.dailyPoints
        case .week: return store.weeklyPoints
        case .month: return store.monthlyPoints
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("TokenRec")
                    .font(.title2.bold())
                Spacer()
                Button("设置目录") { isEditingDirectory = true }
            }

            UsageStatsView(todayTokens: store.todayTokens, monthTokens: store.monthTokens,
                           totalTokens: store.totalTokens)

            Picker("统计粒度", selection: $granularity) {
                ForEach(Granularity.allCases, id: \.self) { granularity in
                    Text(granularity.title).tag(granularity)
                }
            }
            .pickerStyle(.segmented)

            UsageChartView(points: chartPoints, granularity: granularity)

            HStack(spacing: 4) {
                Text("数据源：")
                Text(SessionScanner().resolveSessionDir().path)
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
        .onAppear { store.refresh() } // 点击状态栏打开面板时立即刷新（轮询已降至 5 分钟）
        .sheet(isPresented: $isEditingDirectory) {
            DirEditorSheet(sessionDir: $sessionDir) {
                store.refresh()
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
