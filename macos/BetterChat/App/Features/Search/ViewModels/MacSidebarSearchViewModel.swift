import Foundation
import Observation
import QQBridgeKit
import QQBridgeProto

/// 会话来源只读接口：与会话列表共用同一份观察结果，搜索不再另开一条数据库观察。
@MainActor
protocol MacDialogSource: AnyObject {
  var items: [DialogItem] { get }
}
extension MacDialogsViewModel: MacDialogSource {}

/// 消息分区的侧栏搜索：会话/联系人即时匹配，聊天记录在停止输入 300 毫秒后查询服务端。
/// 查询改变时取消旧任务，并用代次隔离忽略取消的迟到回包；打开联系人同样只接受最新一次选择。
@MainActor
@Observable
final class MacSidebarSearchViewModel {
  enum ResultID: Hashable {
    case dialog(Int64), contact(String), message(String)
  }
  struct Result: Identifiable, Equatable {
    let id: ResultID
    let title: String
    let subtitle: String
    var trailing: String? = nil
    var avatar: MacAvatar? = nil
    var busy = false
    var subtitleLines = 1
    /// 副标题里要高亮的搜索词（聊天记录结果）。
    var highlight: String? = nil
  }
  struct Group: Equatable {
    let title: String
    let results: [Result]
  }

  private(set) var term = ""
  private(set) var messages: [Qqbridge_V1_Message] = []
  private(set) var isLoading = false
  private var searchError: String?
  private var contactError: String?
  private var failedContact: Qqbridge_V1_Peer?
  private(set) var selected: ResultID?
  /// 选择结果后交给协调器的导航意图。
  @ObservationIgnored var route: ((MacSidebarRoute) -> Void)?

  @ObservationIgnored private let service: any MacSearchService
  @ObservationIgnored private weak var dialogSource: (any MacDialogSource)?
  @ObservationIgnored private let opening = MacChatOpenRequest()
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  private var contacts: [Qqbridge_V1_Peer] = []
  // 忙碌状态直接读取请求状态机，避免请求取消已结束、行里却仍留着第二份 loading 标记。
  private var openingKey: String? { opening.peerKey }
  let avatars = AvatarBook()

  init(service: any MacSearchService, dialogs: any MacDialogSource) {
    self.service = service
    self.dialogSource = dialogs
  }
  deinit {
    task?.cancel()
  }

  // MARK: 意图

  func update(query: String) {
    let next = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard next != term else { return }
    run(next)
  }

  func retry() {
    guard openingKey == nil else { return }
    if let failedContact { open(failedContact) }
    else if searchError != nil { run(term) }
  }

  func cancel() { run("") }

  /// 只放弃正在等待的“打开联系人”请求，保留查询词、已有结果与选中项。
  /// 离开消息分区、或由别处（会话列表、通知、联系人）打开会话时调用：
  /// MacChatOpenRequest 换代后，早先请求即使稍后返回也不会再发出路由，离开后再回来同样如此。
  func cancelPendingOpen() { cancelOpening() }

  func select(_ id: ResultID?) {
    selected = id
    guard let id else { return }
    switch id {
    case .dialog(let chat):
      guard matchedDialogs.contains(where: { $0.id == chat }) else { return }
      cancelOpening()
      route?(.chat(chat))
    case .contact(let key):
      guard let peer = matchedPeople.first(where: { MacPeerPresentation.key($0) == key }) else { return }
      open(peer)
    case .message(let key):
      guard let message = messages.first(where: { MacMessagePresentation.key($0) == key }) else { return }
      cancelOpening()
      route?(.message(chatId: message.chatID, seq: message.seq))
    }
  }

  func wantAvatar(for id: ResultID) {
    guard case .contact(let key) = id, let peer = contacts.first(where: { MacPeerPresentation.key($0) == key }),
          peer.avatarSha256.isEmpty else { return }
    service.requestAvatar(for: peer, in: avatars)
  }

  // MARK: 输出

  var hasResults: Bool { !groups.isEmpty }
  // 本地联系人可以在历史搜索仍挂起时打开。两种失败分别保留，重试不串到另一个请求。
  var error: String? { contactError ?? searchError }
  var retryTitle: String { failedContact == nil ? "重试搜索" : "重新打开会话" }
  var canRetry: Bool { error != nil && openingKey == nil }
  var showsEmptyState: Bool { !term.isEmpty && !isLoading && error == nil && groups.isEmpty }

  var groups: [Group] {
    guard !term.isEmpty else { return [] }
    var groups: [Group] = []
    let dialogs = matchedDialogs.prefix(20).map { item in
      Result(id: .dialog(item.id), title: item.title,
             subtitle: "\(item.isGroup ? "群" : "QQ") \(String(item.dialog.peerID))",
             avatar: MacAvatar(sha256: item.peer?.avatarSha256, title: item.title, seed: item.dialog.peerID))
    }
    if !dialogs.isEmpty { groups.append(Group(title: "会话", results: dialogs)) }
    let people = matchedPeople.prefix(20).map { peer in
      let name = MacPeerPresentation.name(peer)
      let key = MacPeerPresentation.key(peer)
      let sha = peer.avatarSha256.isEmpty
        ? (peer.kind == .group ? avatars.groupSha256[peer.peerID] : avatars.sha256[peer.peerID])
        : peer.avatarSha256
      return Result(id: .contact(key), title: name, subtitle: MacPeerPresentation.searchSubtitle(peer),
                    avatar: MacAvatar(sha256: sha, title: name, seed: peer.peerID), busy: openingKey == key)
    }
    if !people.isEmpty { groups.append(Group(title: "联系人", results: people)) }
    let chats = Dictionary((dialogSource?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    // 2026-10-17 实机：以前只有会话名和正文，看不出是谁说的；补上发送人、会话头像和关键词高亮（和 iOS 搜索一致）。
    let found = messages.map { message in
      let chat = chats[message.chatID]
      let title = chat?.title ?? "会话"
      return Result(id: .message(MacMessagePresentation.key(message)), title: title,
                    subtitle: "\(service.senderName(message))：\(Format.preview(message))",
                    trailing: Format.listTime(message.time),
                    avatar: MacAvatar(sha256: chat?.peer?.avatarSha256, title: title, seed: chat?.dialog.peerID ?? message.chatID),
                    subtitleLines: 3, highlight: term)
    }
    if !found.isEmpty { groups.append(Group(title: "聊天记录", results: found)) }
    return groups
  }

  // MARK: 内部

  private var matchedDialogs: [DialogItem] {
    guard !term.isEmpty else { return [] }
    return (dialogSource?.items ?? []).filter {
      $0.title.localizedCaseInsensitiveContains(term) || String($0.dialog.peerID).contains(term)
        || ($0.peer?.name.localizedCaseInsensitiveContains(term) ?? false)
        || ($0.peer?.remark.localizedCaseInsensitiveContains(term) ?? false)
    }
  }

  private var matchedPeople: [Qqbridge_V1_Peer] {
    guard !term.isEmpty else { return [] }
    let shown = Set(matchedDialogs.map { MacPeerPresentation.key(isGroup: $0.isGroup, peerID: $0.dialog.peerID) })
    return contacts.filter { !shown.contains(MacPeerPresentation.key($0)) && MacPeerPresentation.matches($0, term) }
  }

  private func run(_ next: String) {
    task?.cancel()
    task = nil
    cancelOpening()
    let id = UUID()
    generation = id
    term = next
    selected = nil
    messages = []
    searchError = nil
    guard !next.isEmpty else { isLoading = false; contacts = []; return }
    contacts = service.localContacts()
    isLoading = true
    task = Task { [weak self, service] in
      do {
        try await Task.sleep(for: .milliseconds(300))
        let found = try await service.searchMessages(next, limit: 50)
        guard let self, self.generation == id, !Task.isCancelled else { return }
        self.messages = found
        self.isLoading = false
        self.task = nil
      } catch {
        guard let self, self.generation == id, !Task.isCancelled else { return }
        self.searchError = LoadState.describe(error)
        self.isLoading = false
        self.task = nil
      }
    }
  }

  private func open(_ peer: Qqbridge_V1_Peer) {
    contactError = nil
    failedContact = nil
    let key = MacPeerPresentation.key(peer)
    let service = service
    opening.start(peerKey: key) {
      try await service.openChat(with: peer)
    } opened: { [weak self] chat in
      self?.route?(.chat(chat))
    } failed: { [weak self] failure in
      self?.failedContact = peer
      self?.contactError = LoadState.describe(failure)
    }
  }

  private func cancelOpening() {
    opening.cancel()
    contactError = nil
    failedContact = nil
  }
}
