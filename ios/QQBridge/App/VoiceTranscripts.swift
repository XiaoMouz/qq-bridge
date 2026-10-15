import Foundation
import Observation
import QQBridgeKit
import QQBridgeProto

@MainActor
protocol VoiceTranscriptionService {
  func transcribe(chatId: Int64, seq: Int64) async throws -> String
}

@MainActor
struct SessionVoiceTranscriptionService: VoiceTranscriptionService {
  let session: Session
  func transcribe(chatId: Int64, seq: Int64) async throws -> String {
    var request = Qqbridge_V1_TranscribeVoiceRequest()
    request.chatID = chatId; request.seq = seq
    return try await session.api.messages.transcribeVoice(request: request, headers: session.api.headers).get().text
  }
}

/// 显示状态与识别缓存分开；收起已识别的文字不会删除结果或再次请求 QQ。
@MainActor @Observable
final class VoiceTranscripts {
  static let shared = VoiceTranscripts()
  enum State: Equatable {
    case loading
    case text(String)
    case failed(String)
  }

  private(set) var states: [String: State]
  static let autoKey = "autoTranscribeVoice"
  private static let storeKey = "voiceTranscripts"
  private static let hiddenKey = "hiddenVoiceTranscripts"
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var cached: [String: String]
  @ObservationIgnored private var hidden: Set<String> = []
  @ObservationIgnored private var requests: [String: (id: UUID, task: Task<Void, Never>)] = [:]

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let saved = defaults.dictionary(forKey: Self.storeKey) as? [String: String] ?? [:]
    let hidden = Set(defaults.stringArray(forKey: Self.hiddenKey) ?? [])
    self.hidden = hidden
    cached = saved; states = saved.filter { !hidden.contains($0.key) }.mapValues { .text($0) }
  }

  isolated deinit { for request in requests.values { request.task.cancel() } }

  func state(chatId: Int64, seq: Int64) -> State? { states["\(chatId):\(seq)"] }

  func transcribe(chatId: Int64, seq: Int64, session: Session) {
    transcribe(chatId: chatId, seq: seq, service: SessionVoiceTranscriptionService(session: session))
  }

  @discardableResult
  func transcribe(chatId: Int64, seq: Int64, service: any VoiceTranscriptionService) -> Task<Void, Never>? {
    let key = "\(chatId):\(seq)"
    if hidden.remove(key) != nil { saveHidden() }
    if let text = cached[key] { states[key] = .text(text); return nil }
    if let request = requests[key] { return request.task }
    states[key] = .loading
    let id = UUID()
    let task = Task { [weak self] in
      do {
        let text = try await service.transcribe(chatId: chatId, seq: seq)
        guard let self, requests[key]?.id == id, !Task.isCancelled else { return }
        requests[key] = nil
        cached[key] = text; states[key] = .text(text)
        save()
      } catch {
        guard let self, requests[key]?.id == id, !Task.isCancelled else { return }
        requests[key] = nil
        let reason: String
        switch (error as? URLError)?.code {
        case .notConnectedToInternet, .networkConnectionLost: reason = "网络连接不可用，请稍后重试"
        case .timedOut: reason = "识别超时，请重试"
        default: reason = LoadState.describe(error)
        }
        states[key] = .failed(reason)
      }
    }
    requests[key] = (id, task)
    return task
  }

  func hide(chatId: Int64, seq: Int64) {
    let key = "\(chatId):\(seq)"
    requests.removeValue(forKey: key)?.task.cancel()
    states[key] = nil
    hidden.insert(key)
    saveHidden()
  }

  func autoTranscribe(chatId: Int64, seq: Int64, session: Session) {
    autoTranscribe(chatId: chatId, seq: seq, service: SessionVoiceTranscriptionService(session: session))
  }

  func autoTranscribe(chatId: Int64, seq: Int64, service: any VoiceTranscriptionService) {
    let key = "\(chatId):\(seq)"
    guard defaults.bool(forKey: Self.autoKey), !hidden.contains(key) else { return }
    // 滚动与列表刷新会重复触发出现事件；识别失败只由用户主动重试。
    if case .failed = states[key] { return }
    transcribe(chatId: chatId, seq: seq, service: service)
  }

  func toggle(chatId: Int64, seq: Int64, session: Session) {
    toggle(chatId: chatId, seq: seq, service: SessionVoiceTranscriptionService(session: session))
  }

  func toggle(chatId: Int64, seq: Int64, service: any VoiceTranscriptionService) {
    switch state(chatId: chatId, seq: seq) {
    case .text: hide(chatId: chatId, seq: seq)
    case .loading: break
    default: transcribe(chatId: chatId, seq: seq, service: service)
    }
  }

  private func save() {
    // 保持原有磁盘格式和 500 条上限，已有识别结果无需迁移。
    defaults.set(persistedCache, forKey: Self.storeKey)
    saveHidden()
  }

  private var persistedCache: [String: String] {
    cached.count > 500 ? Dictionary(uniqueKeysWithValues: cached.sorted { $0.key > $1.key }.prefix(500).map { ($0.key, $0.value) }) : cached
  }

  private func saveHidden() {
    // 收起是显示偏好；重启后也不应因为保留了缓存而重新展开。
    // 只需保存仍在磁盘缓存中的隐藏结果，两份数据按同一批 key 裁剪，避免重新展开。
    defaults.set(hidden.intersection(persistedCache.keys).sorted(), forKey: Self.hiddenKey)
  }
}
