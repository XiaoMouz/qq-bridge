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
  @AppStorage(VoiceTranscripts.autoKey) private var autoTranscribe = false

  var body: some View {
    Form {
      Section("消息列表") {
        Picker("预览行数", selection: $previewLines) {
          Text("两行").tag(2)
          Text("三行").tag(3)
        }
      }
      Section {
        Toggle("自动语音转文字", isOn: $autoTranscribe)
      } header: {
        Text("语音消息")
      } footer: {
        Text("打开后，聊天里出现的语音消息自动用 QQ 的识别转成文字，显示在语音下面。关闭时可以点语音右边的按钮或长按「转文字」。")
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
  /// 本机按类型的占用（消息 = 本地数据库）。
  @State private var localStats: [StorageGroupStat] = []
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

  // 本机：按类型的分段条（媒体缓存 + 消息），每类一行，点进去看各会话的占比。
  @ViewBuilder private var localSection: some View {
    Section {
      let total = localStats.reduce(Int64(0)) { $0 + $1.bytes }
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          Text(Bytes.text(total)).font(.title2.bold().monospacedDigit())
          Text("缓存上限 \(cacheCapGB == 0 ? "不限" : "\(cacheCapGB) GB")").font(.subheadline).foregroundStyle(.secondary)
          Spacer()
        }
        CapacityBar(
          segments: localStats.map { .init(name: $0.group.name, bytes: $0.bytes, color: $0.group.color) },
          total: max(total, 1)
        )
      }
      .padding(.vertical, 4)
      ForEach(localStats.filter { $0.bytes > 0 }) { stat in
        NavigationLink {
          StorageChatsView(session: session, source: .local, group: stat.group)
        } label: {
          StorageGroupRow(stat: stat, total: total)
        }
      }
      Picker("缓存上限", selection: $cacheCapGB) {
        ForEach([1, 2, 5, 10, 0], id: \.self) { Text($0 == 0 ? "不限" : "\($0) GB").tag($0) }
      }
      Picker("保留", selection: $cacheDays) {
        ForEach([3, 7, 30, 0], id: \.self) { Text($0 == 0 ? "永久" : "\($0) 天").tag($0) }
      }
      Button("清空媒体缓存", role: .destructive) { confirmClear = true }
    } header: {
      Text("本机")
    } footer: {
      Text("媒体缓存超出上限或保留期会自动清理；消息是本机保存的聊天记录。")
    }
  }

  // 服务器：按类型的环形图 + 每类一行（点进去看各会话的占比），以及占用最多的会话、去重和冷热存储。
  @ViewBuilder private var serverSection: some View {
    Section("服务器") {
      if let o = overview {
        let stats = serverStats(o)
        let total = stats.reduce(Int64(0)) { $0 + $1.bytes }
        Chart(stats) { s in
          SectorMark(angle: .value("大小", Double(s.bytes)), innerRadius: .ratio(0.62), angularInset: 1)
            .foregroundStyle(s.group.color.gradient)
            .cornerRadius(3)
        }
        .chartBackground { _ in
          VStack(spacing: 2) {
            Text(Bytes.text(total)).font(.title3.bold().monospacedDigit())
            Text("服务器上的全部").font(.caption).foregroundStyle(.secondary)
          }
        }
        .frame(height: 200)
        .padding(.vertical, 8)
        ForEach(stats) { stat in
          NavigationLink {
            if stat.group == .other {
              ServerOtherView(overview: o)
            } else {
              StorageChatsView(session: session, source: .server, group: stat.group)
            }
          } label: {
            StorageGroupRow(stat: stat, total: total)
          }
        }
        NavigationLink {
          StorageChatsView(session: session, source: .server, group: .image, allMedia: true)
        } label: {
          Label("占用最多的会话", systemImage: "chart.bar.fill")
        }
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

  private func serverStats(_ o: Qqbridge_V1_GetStorageOverviewResponse) -> [StorageGroupStat] {
    var bytes: [StorageGroup: Int64] = [:]
    var counts: [StorageGroup: Int] = [:]
    for c in o.categories {
      let g = StorageGroup.of(server: c.category)
      bytes[g, default: 0] += Int64(c.bytes)
      counts[g, default: 0] += Int(c.count)
    }
    bytes[.message] = Int64(o.messageBytes)
    counts[.message] = Int(o.messageCount)
    return StorageGroup.allCases.compactMap { g in
      guard let b = bytes[g], b > 0 else { return nil }
      return StorageGroupStat(group: g, bytes: b, count: counts[g] ?? 0)
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
    let byKind = (try? session.store.cacheUsageByKind()) ?? [:]
    var stats = StorageGroup.allCases.compactMap { g -> StorageGroupStat? in
      guard g != .message else { return nil }
      let parts = g.localKinds.compactMap { byKind[$0] }
      return StorageGroupStat(group: g, bytes: parts.reduce(0) { $0 + $1.bytes }, count: parts.reduce(0) { $0 + $1.count })
    }
    if let m = try? session.store.messageUsage() {
      stats.insert(StorageGroupStat(group: .message, bytes: m.total, count: m.byChat.reduce(0) { $0 + $1.count }), at: 5)
    }
    localStats = stats
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
              NavigationLink {
                StorageItemsView(session: session, source: .server, group: Self.group(k.kind), chatId: chatId, title: "\(title) · \(Self.kindName(k.kind))")
              } label: {
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

  static func group(_ k: Qqbridge_V1_MediaKind) -> StorageGroup {
    switch k {
    case .image: .image
    case .video: .video
    case .audio: .audio
    case .file: .file
    case .sticker: .sticker
    default: .other
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

/// 服务器上"其他"的组成：头像、旧版生成的缩略图和转码等，并解释它们是什么。
struct ServerOtherView: View {
  let overview: Qqbridge_V1_GetStorageOverviewResponse

  var body: some View {
    List {
      let others = overview.categories.filter { StorageGroup.of(server: $0.category) == .other && $0.bytes > 0 }
      Section {
        ForEach(others, id: \.category) { c in
          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
              Text(StorageCategoryStyle.name(c.category))
              Spacer()
              Text(Bytes.text(Int64(c.bytes))).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
              Text(Self.explain(c.category)).font(.caption).foregroundStyle(.secondary)
              Spacer(minLength: 12)
              Text("\(c.count) 份").font(.caption).foregroundStyle(.tertiary).fixedSize()
            }
          }
          .padding(.vertical, 2)
        }
      }
    }
    .navigationTitle("其他")
    .navigationBarTitleDisplayMode(.inline)
  }

  static func explain(_ category: String) -> String {
    switch category {
    case "avatar": "好友、群和群友的头像。"
    case "derived": "改用 QQ 自带缩略图之前，服务端为每张图片自己生成的缩略图（约 320px）和预览图（约 1280px），现在只有更早的消息还在用；另有语音转成的 AAC（QQ 的语音是 silk 格式，iPhone 放不了，这部分仍在用）。"
    default: "没有挂在任何消息上的内容（例如上传了但没发出去的）。"
    }
  }
}
