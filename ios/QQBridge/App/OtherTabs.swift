import QQBridgeKit
import QQBridgeProto
import SwiftUI

// MARK: - 搜索：会话（本地按名字、备注、号码即时筛选）+ 聊天记录（服务端全文搜索）

struct SearchView: View {
  let session: Session
  @Environment(AppModel.self) private var model
  #if DEBUG
  // 调试：模拟器里系统搜索栏收不到注入的按键，启动时用环境变量 QQB_SEARCH 预填搜索词。
  @State private var query = ProcessInfo.processInfo.environment["QQB_SEARCH"] ?? ""
  #else
  @State private var query = ""
  #endif
  @State private var dialogs: [DialogItem] = []
  @State private var results: [Qqbridge_V1_Message] = []
  @State private var searching = false
  @State private var searched = ""

  var body: some View {
    NavigationStack {
      List {
        let matches = matchedDialogs
        if !matches.isEmpty {
          Section("会话") {
            ForEach(matches.prefix(20)) { item in
              NavigationLink(value: item.id) {
                HStack(spacing: 12) {
                  AvatarView(sha256: item.peer?.avatarSha256, title: item.title, seed: item.dialog.peerID, size: 40)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).lineLimit(1)
                    Text(item.isGroup ? "群 \(String(item.dialog.peerID))" : "QQ \(String(item.dialog.peerID))")
                      .font(.caption).foregroundStyle(.secondary)
                  }
                }
              }
            }
          }
        }
        if !results.isEmpty {
          Section("聊天记录") {
            ForEach(results, id: \.searchKey) { m in
              NavigationLink(value: m.chatID) {
                VStack(alignment: .leading, spacing: 4) {
                  HStack {
                    Text(chatTitle(m.chatID)).font(.subheadline.bold()).lineLimit(1)
                    Spacer()
                    Text(Format.listTime(m.time)).font(.caption).foregroundStyle(.secondary)
                  }
                  Text(Format.preview(m)).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                }
              }
            }
          }
        } else if !query.isEmpty, searched != query {
          Section {
            Button { Task { await search() } } label: {
              Label("在聊天记录里搜索「\(query)」", systemImage: "magnifyingglass")
            }
          }
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("搜索")
      .navigationDestination(for: Int64.self) { ChatScreen(session: session, chatId: $0) }
      .searchable(text: $query, prompt: "搜索会话和聊天记录")
      .onSubmit(of: .search) { Task { await search() } }
      .onChange(of: query) { _, _ in results = [] }
      .overlay {
        if searching { ProgressView() } else if !query.isEmpty, searched == query, results.isEmpty, matchedDialogs.isEmpty {
          ContentUnavailableView.search(text: query)
        }
      }
      .task {
        do {
          for try await list in session.store.observeDialogs(limit: 5000) { dialogs = list }
        } catch {}
      }
    }
  }

  private var matchedDialogs: [DialogItem] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return [] }
    return dialogs.filter { item in
      item.title.localizedCaseInsensitiveContains(q)
        || (item.peer?.name.localizedCaseInsensitiveContains(q) ?? false)
        || (item.peer?.remark.localizedCaseInsensitiveContains(q) ?? false)
        || String(item.dialog.peerID).contains(q)
    }
  }

  private func chatTitle(_ chatId: Int64) -> String {
    dialogs.first { $0.id == chatId }?.title ?? "会话 \(chatId)"
  }

  private func search() async {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return }
    searching = true
    defer { searching = false }
    var req = Qqbridge_V1_SearchMessagesRequest()
    req.query = q
    req.limit = 50
    results = (try? await session.api.messages.searchMessages(request: req, headers: session.api.headers).get().messages) ?? []
    searched = q
  }
}

extension Qqbridge_V1_Message {
  var searchKey: String { "\(chatID):\(seq)" }
}
