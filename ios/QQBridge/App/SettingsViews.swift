// 设置：顶部是登录着的 QQ，下面三个子页——偏好、存储（本机缓存 + 服务器存储的可视化占用）、关于（服务器与后台状态）。
import Charts
import QQBridgeKit
import QQBridgeProto
import SwiftUI

struct SettingsView: View {
  let session: Session
  @Environment(AppModel.self) private var model
  @State private var status: Qqbridge_V1_GetStatusResponse?
  @State private var statusError = false
  @State private var avatars = AvatarBook()
  @State private var showQqLogin = false
  @State private var confirmLogout = false

  var body: some View {
    NavigationStack {
      Form {
        Section { qqCard }
        Section {
          NavigationLink { PreferencesView() } label: { Label("偏好", systemImage: "slider.horizontal.3") }
          NavigationLink { StorageView(session: session) } label: { Label("存储", systemImage: "internaldrive") }
          NavigationLink { AboutView(session: session) } label: { Label("关于", systemImage: "info.circle") }
        }
        Section {
          Button("退出登录", role: .destructive) { confirmLogout = true }
        }
      }
      .navigationTitle("设置")
      .task { await loadStatus() }
      .refreshable { await loadStatus() }
      .sheet(isPresented: $showQqLogin, onDismiss: { Task { await loadStatus() } }) { QqLoginSheet(session: session) }
      .confirmationDialog("退出后本机缓存会被清空", isPresented: $confirmLogout, titleVisibility: .visible) {
        Button("退出登录", role: .destructive) { Task { await model.logout() } }
      }
    }
  }

  /// 本地优先：先用上次记下的 QQ 信息，静默刷新后再换成新的。
  @ViewBuilder private var qqCard: some View {
    if let qq = status?.qq.first ?? model.qqAccount {
      HStack(spacing: 14) {
        AvatarView(sha256: avatars.sha256[qq.uin] ?? model.qqAvatarSha256 ?? localAvatar(qq.uin), title: qq.nickname, seed: qq.uin, size: 60)
          .onAppear { avatars.want(qq.uin, session: session) }
          .onChange(of: avatars.sha256[qq.uin]) { _, sha in if let sha { model.setQqAvatar(sha) } }
        VStack(alignment: .leading, spacing: 4) {
          Text(qq.nickname.isEmpty ? String(qq.uin) : qq.nickname).font(.title3.bold())
          Text("QQ \(String(qq.uin))").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
          Label(qq.connected ? "在线" : "已掉线", systemImage: "circle.fill")
            .font(.caption)
            .foregroundStyle(qq.connected ? .green : .orange)
            .labelStyle(StatusDotLabelStyle())
        }
        Spacer()
      }
      .padding(.vertical, 4)
      if !qq.connected {
        Button("扫码登录 QQ", systemImage: "qrcode.viewfinder") { showQqLogin = true }
      }
    } else if status != nil {
      Button("还没有登录 QQ · 扫码登录", systemImage: "qrcode.viewfinder") { showQqLogin = true }
    } else if statusError {
      Label("连不上服务器", systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
    } else {
      HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 20)
    }
  }

  private func localAvatar(_ uin: Int64) -> String? {
    guard let sha = (try? session.store.peer(kind: .user, peerId: uin))?.avatarSha256, !sha.isEmpty else { return nil }
    return sha
  }

  private func loadStatus() async {
    do {
      status = try await session.api.admin.getStatus(request: .init(), headers: session.api.headers).get()
      statusError = false
    } catch {
      statusError = true
    }
  }
}

/// 小圆点 + 文字。
struct StatusDotLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) {
      configuration.icon.font(.system(size: 7))
      configuration.title
    }
  }
}

// MARK: - 偏好

struct PreferencesView: View {
  @AppStorage(DialogRow.linesKey) private var previewLines = 2

  var body: some View {
    Form {
      Section("消息列表") {
        Picker("预览行数", selection: $previewLines) {
          Text("两行").tag(2)
          Text("三行").tag(3)
        }
      }
    }
    .navigationTitle("偏好")
    .navigationBarTitleDisplayMode(.inline)
  }
}

// MARK: - 存储

struct StorageView: View {
  let session: Session
  @State private var usage: MediaCacheUsage?
  @State private var overview: Qqbridge_V1_GetStorageOverviewResponse?
  @State private var overviewError: String?
  @State private var dialogs: [Int64: DialogItem] = [:]
  @AppStorage("cacheCapGB") private var cacheCapGB = 2
  @AppStorage("cacheDays") private var cacheDays = 7
  @State private var confirmClear = false

  var body: some View {
    Form {
      localSection
      serverSection
      if let o = overview, !o.volumes.isEmpty { volumesSection(o) }
      if let o = overview, !o.chats.isEmpty { chatsSection(o) }
    }
    .navigationTitle("存储")
    .navigationBarTitleDisplayMode(.inline)
    .task { await refreshUsage() }
    .task { await loadOverview() }
    .task {
      do {
        for try await list in session.store.observeDialogs(limit: 5000) {
          dialogs = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
      } catch {}
    }
    .refreshable {
      await refreshUsage()
      await loadOverview()
    }
    .onChange(of: cacheCapGB) { applyLimits() }
    .onChange(of: cacheDays) { applyLimits() }
    .confirmationDialog("清空本机缓存？看过的图片和文件之后会重新下载。", isPresented: $confirmClear, titleVisibility: .visible) {
      Button("清空缓存", role: .destructive) {
        Task {
          _ = try? await session.media.clear()
          await refreshUsage()
        }
      }
    }
  }

  // 本机缓存：已用 / 上限的条，占用最多的几个会话。
  @ViewBuilder private var localSection: some View {
    Section("本机") {
      let used = usage?.totalBytes ?? 0
      let cap = cacheCapGB == 0 ? nil : Int64(cacheCapGB) * 1024 * 1024 * 1024
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          Text(Bytes.text(used)).font(.title2.bold().monospacedDigit())
          Text(cap.map { "/ \(Bytes.text($0))" } ?? "/ 不限").foregroundStyle(.secondary)
          Spacer()
          Text("\(usage?.fileCount ?? 0) 个文件").font(.caption).foregroundStyle(.secondary)
        }
        CapacityBar(segments: [.init(name: "已用", bytes: used, color: .accentColor)], total: cap ?? max(used, 1))
      }
      .padding(.vertical, 4)
      let top = (usage?.byChat ?? [:]).sorted { $0.value > $1.value }.prefix(5)
      ForEach(Array(top), id: \.key) { chatId, bytes in
        LabeledContent(dialogs[chatId]?.title ?? "会话 \(chatId)", value: Bytes.text(bytes))
      }
      Picker("上限", selection: $cacheCapGB) {
        ForEach([1, 2, 5, 10, 0], id: \.self) { Text($0 == 0 ? "不限" : "\($0) GB").tag($0) }
      }
      Picker("保留", selection: $cacheDays) {
        ForEach([3, 7, 30, 0], id: \.self) { Text($0 == 0 ? "永久" : "\($0) 天").tag($0) }
      }
      Button("清空缓存", role: .destructive) { confirmClear = true }
    }
  }

  // 服务器：按用途分类的环形图 + 图例，总占用和去重节省。
  @ViewBuilder private var serverSection: some View {
    Section("服务器") {
      if let o = overview {
        let cats = o.categories.filter { $0.bytes > 0 }
        let total = cats.reduce(UInt64(0)) { $0 + $1.bytes }
        Chart(cats, id: \.category) { c in
          SectorMark(angle: .value("大小", Double(c.bytes)), innerRadius: .ratio(0.62), angularInset: 1)
            .foregroundStyle(StorageCategoryStyle.color(c.category))
            .cornerRadius(3)
        }
        .chartBackground { _ in
          VStack(spacing: 2) {
            Text(Bytes.text(Int64(total))).font(.title3.bold().monospacedDigit())
            Text("共 \(cats.reduce(0) { $0 + Int($1.count) }) 份").font(.caption).foregroundStyle(.secondary)
          }
        }
        .frame(height: 200)
        .padding(.vertical, 8)
        ForEach(cats, id: \.category) { c in
          HStack(spacing: 10) {
            Circle().fill(StorageCategoryStyle.color(c.category)).frame(width: 10, height: 10)
            Text(StorageCategoryStyle.name(c.category))
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
              Text(Bytes.text(Int64(c.bytes))).monospacedDigit()
              Text("\(c.count) 份 · \(Self.percent(c.bytes, of: total))").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        LabeledContent("消息里的媒体（去重后）", value: Bytes.text(Int64(o.physicalBytes)))
        LabeledContent("去重省下", value: Bytes.text(Int64(o.dedupSavedBytes)))
        if o.coldTierEnabled {
          LabeledContent("热存储", value: Bytes.text(Int64(o.hotBytes)))
          LabeledContent("冷存储", value: Bytes.text(Int64(o.coldBytes)))
        }
      } else if let overviewError {
        Label(overviewError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
      } else {
        HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 40)
      }
    }
  }

  // 磁盘：热存储 / 冷存储所在的盘，本服务占用、其他占用、剩余。
  private func volumesSection(_ o: Qqbridge_V1_GetStorageOverviewResponse) -> some View {
    Section("磁盘") {
      ForEach(o.volumes, id: \.tier) { v in
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(v.tier == "cold" ? "冷存储（外接硬盘）" : "热存储（服务器硬盘）")
            Spacer()
            if v.available {
              Text("剩余 \(Bytes.text(Int64(v.freeBytes)))").font(.subheadline).foregroundStyle(.secondary)
            } else {
              Text("未连接").font(.subheadline).foregroundStyle(.orange)
            }
          }
          if v.available {
            let mine = Int64(v.tier == "cold" ? o.coldBytes : (o.coldTierEnabled ? o.hotBytes : o.categories.reduce(0) { $0 + $1.bytes }))
            let used = Int64(v.totalBytes) - Int64(v.freeBytes)
            CapacityBar(
              segments: [
                .init(name: "BetterChat", bytes: mine, color: .accentColor),
                .init(name: "其他", bytes: max(0, used - mine), color: .gray.opacity(0.5)),
              ],
              total: Int64(v.totalBytes)
            )
            HStack(spacing: 12) {
              Legend(color: .accentColor, text: "BetterChat \(Bytes.text(mine))")
              Legend(color: .gray.opacity(0.5), text: "其他 \(Bytes.text(max(0, used - mine)))")
              Spacer()
              Text("共 \(Bytes.text(Int64(v.totalBytes)))").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        .padding(.vertical, 4)
      }
    }
  }

  // 占用最多的会话：条形长度按逻辑占用，点进去看按类型的明细。
  private func chatsSection(_ o: Qqbridge_V1_GetStorageOverviewResponse) -> some View {
    Section("占用最多的会话") {
      let top = Array(o.chats.prefix(30))
      let maxBytes = top.map(\.logicalBytes).max() ?? 1
      ForEach(top, id: \.chatID) { c in
        NavigationLink {
          ChatStorageView(session: session, chatId: c.chatID, title: chatTitle(c))
        } label: {
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              AvatarView(sha256: dialogs[c.chatID]?.peer?.avatarSha256, title: chatTitle(c), seed: c.peerID, size: 28)
              Text(chatTitle(c)).lineLimit(1)
              Spacer()
              Text(Bytes.text(Int64(c.logicalBytes))).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { geo in
              Capsule().fill(Color.accentColor.gradient)
                .frame(width: max(4, geo.size.width * CGFloat(Double(c.logicalBytes) / Double(maxBytes))))
            }
            .frame(height: 5)
          }
        }
      }
    }
  }

  private func chatTitle(_ c: Qqbridge_V1_ChatStorage) -> String {
    dialogs[c.chatID]?.title ?? (c.scene == .group ? "群 \(String(c.peerID))" : "QQ \(String(c.peerID))")
  }

  private static func percent(_ part: UInt64, of total: UInt64) -> String {
    guard total > 0 else { return "0%" }
    let p = Double(part) / Double(total) * 100
    return p < 1 ? "<1%" : "\(Int(p.rounded()))%"
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

  private func loadOverview() async {
    var req = Qqbridge_V1_GetStorageOverviewRequest()
    req.limit = 30
    do {
      overview = try await session.api.media.getStorageOverview(request: req, headers: session.api.headers).get()
      overviewError = nil
    } catch {
      overviewError = LoadState.describe(error)
    }
  }
}

/// 一个会话在服务器上的占用：按媒体类型拆分。
struct ChatStorageView: View {
  let session: Session
  let chatId: Int64
  let title: String
  @State private var detail: Qqbridge_V1_GetChatStorageResponse?
  @State private var error: String?

  var body: some View {
    Form {
      if let d = detail {
        Section {
          LabeledContent("占用", value: Bytes.text(Int64(d.summary.logicalBytes)))
          LabeledContent("只在这个会话里", value: Bytes.text(Int64(d.summary.exclusiveBytes)))
          LabeledContent("内容数", value: "\(d.summary.blobCount)")
        }
        let kinds = d.kinds.filter { $0.logicalBytes > 0 }
        if !kinds.isEmpty {
          Section("按类型") {
            Chart(kinds, id: \.kind) { k in
              BarMark(x: .value("大小", Double(k.logicalBytes)), y: .value("类型", Self.kindName(k.kind)))
                .foregroundStyle(Self.kindColor(k.kind))
                .cornerRadius(4)
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(kinds.count) * 36 + 10)
            ForEach(kinds, id: \.kind) { k in
              LabeledContent {
                VStack(alignment: .trailing, spacing: 0) {
                  Text(Bytes.text(Int64(k.logicalBytes))).monospacedDigit()
                  Text(k.purgedCount > 0 ? "\(k.count) 份 · \(k.purgedCount) 份原件已清理" : "\(k.count) 份")
                    .font(.caption).foregroundStyle(.secondary)
                }
              } label: {
                Label { Text(Self.kindName(k.kind)) } icon: { Circle().fill(Self.kindColor(k.kind)).frame(width: 10, height: 10) }
              }
            }
          }
        }
      } else if let error {
        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
      } else {
        HStack { Spacer(); ProgressView(); Spacer() }
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .task {
      var req = Qqbridge_V1_GetChatStorageRequest()
      req.chatID = chatId
      do {
        detail = try await session.api.media.getChatStorage(request: req, headers: session.api.headers).get()
      } catch {
        self.error = LoadState.describe(error)
      }
    }
  }

  static func kindName(_ k: Qqbridge_V1_MediaKind) -> String {
    switch k {
    case .image: "图片"
    case .video: "视频"
    case .audio: "语音"
    case .file: "文件"
    case .sticker: "表情"
    default: "其他"
    }
  }

  static func kindColor(_ k: Qqbridge_V1_MediaKind) -> Color {
    switch k {
    case .image: .blue
    case .video: .purple
    case .audio: .orange
    case .file: .teal
    case .sticker: .pink
    default: .gray
    }
  }
}

enum StorageCategoryStyle {
  static func name(_ c: String) -> String {
    switch c {
    case "image": "图片原图"
    case "qq_thumb": "缩略图"
    case "sticker": "表情"
    case "video": "视频"
    case "record": "语音"
    case "file": "文件"
    case "group_file": "群文件"
    case "avatar": "头像"
    case "derived": "旧版生成的缩略图和转码"
    default: "其他"
    }
  }

  static func color(_ c: String) -> Color {
    switch c {
    case "image": .blue
    case "qq_thumb": .cyan
    case "sticker": .pink
    case "video": .purple
    case "record": .orange
    case "file": .teal
    case "group_file": .green
    case "avatar": .yellow
    case "derived": .indigo.opacity(0.6)
    default: .gray
    }
  }
}

/// 分段的容量条（总长 = total）。
struct CapacityBar: View {
  struct Segment {
    let name: String
    let bytes: Int64
    let color: Color
  }

  let segments: [Segment]
  let total: Int64

  var body: some View {
    GeometryReader { geo in
      HStack(spacing: 2) {
        ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
          if s.bytes > 0 {
            Rectangle().fill(s.color.gradient)
              .frame(width: max(3, geo.size.width * CGFloat(Double(s.bytes) / Double(max(total, 1)))))
          }
        }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.secondary.opacity(0.15))
      .clipShape(Capsule())
    }
    .frame(height: 10)
  }
}

struct Legend: View {
  let color: Color
  let text: String

  var body: some View {
    HStack(spacing: 4) {
      Circle().fill(color).frame(width: 8, height: 8)
      Text(text).font(.caption).foregroundStyle(.secondary)
    }
  }
}

enum Bytes {
  static func text(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
  }
}

// MARK: - 关于

struct AboutView: View {
  let session: Session
  @Environment(AppModel.self) private var model
  @State private var status: Qqbridge_V1_GetStatusResponse?
  @State private var error: String?

  var body: some View {
    Form {
      Section {
        VStack(spacing: 6) {
          Image(uiImage: Self.appIcon)
            .resizable()
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
          Text("BetterChat").font(.title2.bold())
          Text("版本 \(Self.version)").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
      }
      Section("服务器") {
        LabeledContent("地址") { Text(session.api.config.baseURL.absoluteString).textSelection(.enabled) }
        LabeledContent("连接", value: connectionText)
        if let s = status, s.serverStartedAt > 0 {
          LabeledContent("运行时长", value: Self.since(s.serverStartedAt))
        }
      }
      if let qq = status?.qq.first {
        Section("QQ 连接") {
          LabeledContent("状态", value: qq.connected ? "在线" : "已掉线")
          if qq.connectedAt > 0 { LabeledContent("上线时间", value: Self.dateTime(qq.connectedAt)) }
          if qq.lastEventAt > 0 { LabeledContent("最近收到消息", value: Self.relative(qq.lastEventAt)) }
          if !qq.pluginVersion.isEmpty { LabeledContent("插件版本", value: qq.pluginVersion) }
        }
      }
      if let s = status {
        Section("后台任务") {
          LabeledContent("待入库事件", value: s.inbox.failed > 0 ? "\(s.inbox.pending)（失败 \(s.inbox.failed)）" : "\(s.inbox.pending)")
          LabeledContent("媒体下载队列", value: "\(s.media.pending)" + (s.media.failed > 0 ? "（失败 \(s.media.failed)）" : ""))
          LabeledContent("待发送", value: s.outbox.failed > 0 ? "\(s.outbox.pending)（失败 \(s.outbox.failed)）" : "\(s.outbox.pending)")
          LabeledContent("存档缺口", value: s.archive.missingSeqs > 0 ? "\(s.archive.chatsWithHoles) 个会话 · \(s.archive.missingSeqs) 条" : "无")
        }
      } else if let error {
        Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
      }
    }
    .navigationTitle("关于")
    .navigationBarTitleDisplayMode(.inline)
    .task { await load() }
    .refreshable { await load() }
  }

  private var connectionText: String {
    switch model.connection {
    case .online: "已连接"
    case .connecting: "正在同步"
    case .offline: "离线"
    case .unauthenticated: "需要重新登录"
    }
  }

  private func load() async {
    do {
      status = try await session.api.admin.getStatus(request: .init(), headers: session.api.headers).get()
      error = nil
    } catch {
      self.error = LoadState.describe(error)
    }
  }

  /// App 图标（资源目录里的 AppIcon 不能直接按名字取，要从 Info.plist 找实际的文件名）。
  static var appIcon: UIImage {
    let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
    let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
    let files = primary?["CFBundleIconFiles"] as? [String]
    return files?.last.flatMap { UIImage(named: $0) } ?? UIImage()
  }

  static var version: String {
    let info = Bundle.main.infoDictionary
    return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
  }

  static func dateTime(_ unix: Int64) -> String {
    Date(timeIntervalSince1970: TimeInterval(unix)).formatted(.dateTime.month().day().hour().minute().locale(Format.locale))
  }

  static func relative(_ unix: Int64) -> String {
    Date(timeIntervalSince1970: TimeInterval(unix)).formatted(.relative(presentation: .named).locale(Format.locale))
  }

  static func since(_ unix: Int64) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince1970) - Int(unix))
    let days = seconds / 86400, hours = seconds % 86400 / 3600, minutes = seconds % 3600 / 60
    if days > 0 { return "\(days) 天 \(hours) 小时" }
    if hours > 0 { return "\(hours) 小时 \(minutes) 分钟" }
    return "\(minutes) 分钟"
  }
}
