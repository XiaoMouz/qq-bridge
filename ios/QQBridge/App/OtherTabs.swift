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
  /// 本地缓存的全部好友和群（还没聊过的也能搜到备注、昵称）。
  @State private var contacts: [Qqbridge_V1_Peer] = []
  @State private var avatars = AvatarBook()
  @State private var path = NavigationPath()
  @State private var results: [Qqbridge_V1_Message] = []
  @State private var searching = false
  @State private var searched = ""

  var body: some View {
    NavigationStack(path: $path) {
      List {
        let matches = matchedDialogs
        let people = matchedContacts
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
        if !people.isEmpty {
          Section("联系人") {
            ForEach(people.prefix(20), id: \.searchKey) { p in
              Button { Task { await open(p) } } label: {
                HStack(spacing: 12) {
                  // 本地资料里常没有头像（只有聊过的人才有）：显示到时向服务端要。
                  AvatarView(sha256: !p.avatarSha256.isEmpty ? p.avatarSha256 : (p.kind == .group ? avatars.groupSha256[p.peerID] : avatars.sha256[p.peerID]),
                             title: Self.name(p), seed: p.peerID, size: 40)
                    .onAppear {
                      guard p.avatarSha256.isEmpty else { return }
                      if p.kind == .group { avatars.wantGroup(p.peerID, session: session) } else { avatars.want(p.peerID, session: session) }
                    }
                  VStack(alignment: .leading, spacing: 2) {
                    Text(Self.name(p)).lineLimit(1).foregroundStyle(.primary)
                    Text(p.kind == .group ? "群 \(String(p.peerID))" : (!p.remark.isEmpty && !p.name.isEmpty ? "\(p.name) · QQ \(String(p.peerID))" : "QQ \(String(p.peerID))"))
                      .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
        if searching { ProgressView() } else if !query.isEmpty, searched == query, results.isEmpty, matchedDialogs.isEmpty, matchedContacts.isEmpty {
          ContentUnavailableView.search(text: query)
        }
      }
      .task {
        contacts = ((try? session.store.peers(kind: .user, friendsOnly: true)) ?? []) + ((try? session.store.peers(kind: .group)) ?? [])
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

  /// 已经在"会话"里出现的就不重复列出。
  private var matchedContacts: [Qqbridge_V1_Peer] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return [] }
    let shown = Set(matchedDialogs.map { "\($0.isGroup ? 2 : 1):\($0.dialog.peerID)" })
    return contacts.filter { p in
      !shown.contains(p.searchKey)
        && (p.remark.localizedCaseInsensitiveContains(q) || p.name.localizedCaseInsensitiveContains(q) || String(p.peerID).contains(q))
    }
  }

  static func name(_ p: Qqbridge_V1_Peer) -> String {
    !p.remark.isEmpty ? p.remark : (!p.name.isEmpty ? p.name : String(p.peerID))
  }

  private func open(_ p: Qqbridge_V1_Peer) async {
    guard let id = try? await DialogActions.openChat(session, scene: p.kind == .group ? .group : .friend, peerId: p.peerID) else { return }
    path.append(id)
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

extension Qqbridge_V1_Peer {
  var searchKey: String { "\(kind == .group ? 2 : 1):\(peerID)" }
}
