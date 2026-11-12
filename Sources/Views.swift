import SwiftUI
import UIKit

// MARK: - 首页：口播稿列表
struct RootView: View {
    @EnvironmentObject var store: AppStore
    @State private var showEditor = false
    @State private var editingScript: Script?
    @State private var prompterScript: Script?
    @State private var pendingDelete: Script?

    var body: some View {
        NavigationView {
            List {
                if store.scripts.isEmpty {
                    Text("还没有口播稿\n点右上角 ＋ 新建一份")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 60)
                        .listRowSeparator(.hidden)
                }

                ForEach(store.scripts) { script in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(script.title.isEmpty ? "未命名" : script.title)
                            .font(.headline)
                        HStack(spacing: 10) {
                            Text("\(script.charCount) 字")
                            Text("·")
                            Text(dateText(script.updatedAt))
                            Spacer()
                            Button("编辑") {
                                editingScript = script
                                showEditor = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                            Button("提词") {
                                prompterScript = script
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { prompterScript = script }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDelete = script
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("我的口播稿")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        editingScript = nil
                        showEditor = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showEditor) {
                EditorView(script: editingScript)
                    .environmentObject(store)
            }
            .fullScreenCover(item: $prompterScript) { script in
                PrompterView(script: script)
                    .environmentObject(store)
            }
            .alert("删除这份口播稿？", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let s = pendingDelete { store.delete(id: s.id) }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("删除后无法恢复")
            }
        }
        .navigationViewStyle(.stack)
    }

    private func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f.string(from: d)
    }
}

// MARK: - 编辑器
struct EditorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let script: Script?

    @State private var title = ""
    @State private var text = ""
    @State private var didLoad = false

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("给稿子起个名字", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16)

                TextEditor(text: $text)
                    .font(.system(size: 16))
                    .lineSpacing(4)
                    .padding(.horizontal, 12)
                    .onChange(of: text) { newValue in
                        if newValue.count > AppStore.maxChars {
                            text = String(newValue.prefix(AppStore.maxChars))
                        }
                    }

                HStack {
                    Spacer()
                    Text("\(text.count) / \(AppStore.maxChars) 字")
                        .font(.caption)
                        .foregroundColor(text.count >= AppStore.maxChars ? .red : .secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .navigationTitle(script == nil ? "新建口播稿" : "编辑口播稿")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                title = script?.title ?? ""
                text = script?.text ?? ""
            }
        }
        .navigationViewStyle(.stack)
    }

    private func save() {
        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if var existing = script {
            existing.title = finalTitle.isEmpty ? "未命名" : finalTitle
            existing.text = text
            existing.updatedAt = Date()
            store.update(existing)
        } else {
            store.add(Script(title: finalTitle.isEmpty ? "未命名" : finalTitle, text: text))
        }
        dismiss()
    }
}

// MARK: - 画中画宿主视图
struct LayerHost: UIViewRepresentable {
    @Binding var view: UIView?

    func makeUIView(context: Context) -> VideoLayerHostView {
        let v = VideoLayerHostView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        DispatchQueue.main.async { view = v }
        return v
    }

    func updateUIView(_ uiView: VideoLayerHostView, context: Context) {}
}
