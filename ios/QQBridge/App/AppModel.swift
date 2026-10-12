// App 的全局状态：登录与否、同步引擎的连接状态。界面只观察这里和本地库。
import Foundation
import Observation
import QQBridgeKit
import QQBridgeProto

@MainActor
@Observable
final class AppModel {
  enum Phase {
    case launching
    case loggedOut
    case ready(Session)
  }

  private(set) var phase: Phase = .launching
  private(set) var connection: ConnectionState = .connecting
  /// 正在输入：会话 id → 截止时间。
  private(set) var typing: [Int64: Date] = [:]
  private(set) var activeCall: Qqbridge_V1_Call?
  /// QQ 是否在线（插件连着服务端）：nil = 还不知道（比如服务器本身连不上）。
  private(set) var qqOnline: Bool?
  /// 登录着的 QQ（昵称、号码、在线状态）：每次查状态时更新，并存在本机，设置页打开时直接显示。
  private(set) var qqAccount: Qqbridge_V1_QqStatus? = AppModel.cachedQqAccount()
  /// 自己的头像（图片本身在本地媒体缓存里，这里只记 sha256）。
  private(set) var qqAvatarSha256: String? = UserDefaults.standard.string(forKey: AppModel.qqAvatarKey)

  func setQqAvatar(_ sha256: String) {
    guard sha256 != qqAvatarSha256 else { return }
    qqAvatarSha256 = sha256
    UserDefaults.standard.set(sha256, forKey: Self.qqAvatarKey)
  }
  /// 点了通知、要打开的会话（会话列表接手后清空）。
  var pendingChat: Int64?
  /// 未读角标（图标角标和"消息"标签上的数字）：见 DialogItem.badgeCount。
  var unreadBadge = 0
  /// 再点一次"消息"标签：会话列表跳到下一个有未读的会话。
  var nextUnreadTick = 0
  /// 正在看的会话：前台收到它的推送时不弹横幅。
  /// 屏幕上的聊天页（按出现顺序）：最后一个是正在看的会话。按登记号增删，和页面出现 / 消失的先后无关
  /// （以前直接记一个会话号，从通知进会话时旧页的「消失」晚于新页的「出现」，会把正在看的会话清掉，结果又弹了这个会话的横幅）。
  private(set) var visibleChats: [VisibleChat] = []
  var openChatId: Int64? { visibleChats.last?.chatId }

  func chatAppeared(_ token: UUID, chatId: Int64) {
    visibleChats.removeAll { $0.token == token }
    visibleChats.append(VisibleChat(token: token, chatId: chatId))
    clearNotifications(chatId: chatId)
  }

  func chatDisappeared(_ token: UUID) {
    visibleChats.removeAll { $0.token == token }
  }
  /// 顶部的 App 内横幅（前台收到别的会话的消息）。
  var banner: InAppBanner?
  /// 点了横幅：快速回复的浮层。
  var quickReplyChat: Int64?
  /// 跳到某个会话的某条消息（从查找聊天记录、共享媒体等子页面回到聊天看上下文）。
  var messageJump: MessageJump?

  func openMessage(chatId: Int64, seq: Int64) {
    messageJump = MessageJump(chatId: chatId, seq: seq)
    if openChatId != chatId { pendingChat = chatId }
  }

  /// 底部的一行提示（例如转发成功），带会话的点一下打开那个会话。
  private(set) var toast: AppToast?

  func showToast(_ t: AppToast) {
    toast = t
    Task {
      try? await Task.sleep(for: .seconds(t.chatId == nil ? 3 : 6))
      if toast?.id == t.id { toast = nil }
    }
  }

  func dismissToast() { toast = nil }
  private var statusTask: Task<Void, Never>?

  /// 本地数据放这里（以后有 App Group 时换成共享容器，通知扩展也能读）。
  private let container: URL = {
    if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.xiaomouz.betterchat") {
      return group
    }
    return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].deletingLastPathComponent()
  }()

  private let tokens: any TokenStore = KeychainTokenStore()
  private var eventsTask: Task<Void, Never>?

  var session: Session? {
    if case .ready(let s) = phase { return s }
    return nil
  }

  /// 启动：钥匙串里有令牌就直接进去，没有就去登录页。
  func launch() {
    guard case .launching = phase else { return }
    if let saved = try? tokens.load(), let session = try? Session(config: saved.config, token: saved.token, container: container) {
      enter(session)
    } else {
      phase = .loggedOut
    }
  }

  func login(server: String, username: String, password: String) async throws {
    guard let url = Self.normalize(server) else { throw LoginError.badServer }
    let session = try await Session.login(
      config: ServerConfig(baseURL: url),
      username: username,
      password: password,
      deviceName: deviceName(),
      tokens: tokens,
      container: container
    )
    enter(session)
  }

  func logout() async {
    guard let session else { return }
    qqAccount = nil
    qqAvatarSha256 = nil
    UserDefaults.standard.removeObject(forKey: Self.qqAccountKey)
    UserDefaults.standard.removeObject(forKey: Self.qqAvatarKey)
    eventsTask?.cancel()
    statusTask?.cancel()
    await session.logout(tokens: tokens)
    phase = .loggedOut
  }

  /// 回到前台 / 进入后台。
  func setActive(_ active: Bool) {
    guard let session else { return }
    Task {
      if active {
        await session.sync.start()
        await self.refreshQqStatus()
      } else {
        await session.sync.stop()
        _ = try? session.store.trimMessages()
      }
    }
  }

  func isTyping(_ chatId: Int64) -> Bool {
    (typing[chatId] ?? .distantPast) > Date()
  }

  /// 问一次服务端 QQ 在不在线。
  func refreshQqStatus() async {
    guard let session else { return }
    do {
      let status = try await session.api.admin.getStatus(request: .init(), headers: session.api.headers).get()
      qqOnline = !status.qq.isEmpty && status.qq.allSatisfy(\.connected)
      qqAccount = status.qq.first
      UserDefaults.standard.set(try? status.qq.first?.serializedData(), forKey: Self.qqAccountKey)
    } catch {
      qqOnline = nil
    }
  }

  private static let qqAccountKey = "qqAccountCache"
  private static let qqAvatarKey = "qqAvatarCache"

  private static func cachedQqAccount() -> Qqbridge_V1_QqStatus? {
    guard let data = UserDefaults.standard.data(forKey: qqAccountKey) else { return nil }
    return try? Qqbridge_V1_QqStatus(serializedBytes: data)
  }

  private func enter(_ session: Session) {
    phase = .ready(session)
    registerForPush()
    Task.detached(priority: .utility) { await session.store.backfillMediaIndex() }
    statusTask?.cancel()
    statusTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refreshQqStatus()
        try? await Task.sleep(for: .seconds(60))
      }
    }
    eventsTask?.cancel()
    eventsTask = Task { [weak self] in
      let events = await session.sync.events()
      await session.sync.start()
      for await event in events {
        guard let self else { return }
        switch event {
        case .connection(let state):
          self.connection = state
          if state == .unauthenticated {
            await self.logout()
          }
        case .typing(let t):
          self.typing[t.chatID] = Date().addingTimeInterval(6)
        case .call(let call):
          self.activeCall = call.phase == .ended ? nil : call
        }
      }
    }
  }

  private func deviceName() -> String {
    #if targetEnvironment(simulator)
      "iOS 模拟器"
    #else
      ProcessInfo.processInfo.hostName
    #endif
  }

  /// 补全服务器地址：没写协议时，本机和局域网地址用 http，其他用 https；去掉多余的空白和结尾的斜杠。
  nonisolated static func normalize(_ input: String) -> URL? {
    var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
    while s.hasSuffix("/") { s.removeLast() }
    guard !s.isEmpty else { return nil }
    if !s.contains("://") {
      let host = s.split(separator: ":").first.map(String.init) ?? s
      let local = host == "localhost" || host.hasPrefix("127.") || host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasSuffix(".local")
      s = (local ? "http://" : "https://") + s
    }
    guard let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil else { return nil }
    return url
  }

  enum LoginError: LocalizedError {
    case badServer
    var errorDescription: String? { "服务器地址不对" }
  }
}
