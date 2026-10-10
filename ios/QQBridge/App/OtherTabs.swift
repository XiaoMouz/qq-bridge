import QQBridgeKit
import QQBridgeProto
import SwiftUI

// MARK: - 联系人

struct ContactsView: View {
  let session: Session
  @State private var friends: [Qqbridge_V1_Peer] = []
  @State private var groups: [Qqbridge_V1_Peer] = []
  @State private var showGroups = false
  @State private var error: String?

  var body: some View {
    NavigationStack {
      List {
        Picker("", selection: $showGroups) {
          Text("好友 \(friends.count)").tag(false)
          Text("群聊 \(groups.count)").tag(true)
        }
        .pickerStyle(.segmented)
        .listRowSeparator(.hidden)
        ForEach(showGroups ? groups : friends, id: \.peerID) { p in
          HStack(spacing: 12) {
            AvatarView(sha256: p.avatarSha256, title: displayName(p), seed: p.peerID, size: 40)
            VStack(alignment: .leading) {
              Text(displayName(p))
              if !p.sign.isEmpty { Text(p.sign).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
          }
        }
      }
      .listStyle(.plain)
      .navigationTitle("联系人")
      .refreshable { await load(refresh: true) }
      .task { await load(refresh: false) }
      .overlay { if let error { ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(error)) } }
    }
  }

  private func displayName(_ p: Qqbridge_V1_Peer) -> String {
    !p.remark.isEmpty ? p.remark : (!p.name.isEmpty ? p.name : String(p.peerID))
  }

  private func load(refresh: Bool) async {
    let api = session.api
    if refresh { _ = await api.contacts.refreshContacts(request: .init(), headers: api.headers) }
    do {
      friends = try await api.contacts.listFriends(request: .init(), headers: api.headers).get().friends
      groups = try await api.contacts.listGroups(request: .init(), headers: api.headers).get().groups
      error = nil
    } catch {
      self.error = "\(error)"
    }
  }
}

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

// MARK: - 设置

struct SettingsView: View {
  let session: Session
  @Environment(AppModel.self) private var model
  @State private var usage: MediaCacheUsage?
  @AppStorage("cacheCapGB") private var cacheCapGB = 2
  @AppStorage("cacheDays") private var cacheDays = 7
  @State private var confirmLogout = false

  var body: some View {
    NavigationStack {
      Form {
        Section("服务器") {
          LabeledContent("地址", value: session.api.config.baseURL.absoluteString)
          LabeledContent("状态", value: statusText)
        }
        Section {
          LabeledContent("已用", value: usage.map { ByteCountFormatter.string(fromByteCount: $0.totalBytes, countStyle: .file) } ?? "…")
          Picker("上限", selection: $cacheCapGB) {
            ForEach([1, 2, 5, 10, 0], id: \.self) { Text($0 == 0 ? "不限" : "\($0) GB").tag($0) }
          }
          Picker("保留", selection: $cacheDays) {
            ForEach([3, 7, 30, 0], id: \.self) { Text($0 == 0 ? "永久" : "\($0) 天").tag($0) }
          }
          Button("清空缓存", role: .destructive) {
            Task {
              _ = try? await session.media.clear()
              await refreshUsage()
            }
          }
        } header: {
          Text("本机媒体缓存")
        } footer: {
          Text("原件都在服务器上，这里只缓存看过的缩略图和媒体；超出上限或保留期的会自动清理。")
        }
        Section {
          Button("退出登录", role: .destructive) { confirmLogout = true }
        }
      }
      .navigationTitle("设置")
      .task { await refreshUsage() }
      .onChange(of: cacheCapGB) { applyLimits() }
      .onChange(of: cacheDays) { applyLimits() }
      .confirmationDialog("退出后本机缓存会被清空", isPresented: $confirmLogout, titleVisibility: .visible) {
        Button("退出登录", role: .destructive) { Task { await model.logout() } }
      }
    }
  }

  private var statusText: String {
    switch model.connection {
    case .online: "已连接"
    case .connecting: "正在同步"
    case .offline: "离线"
    case .unauthenticated: "需要重新登录"
    }
  }

  private func applyLimits() {
    let limits = MediaCacheLimits(
      capBytes: cacheCapGB == 0 ? nil : Int64(cacheCapGB) * 1024 * 1024 * 1024,
      retentionDays: cacheDays == 0 ? nil : cacheDays
    )
    Task {
      try? await session.media.setLimits(limits)
      await refreshUsage()
    }
  }

  private func refreshUsage() async {
    usage = try? await session.media.usage()
  }
}
