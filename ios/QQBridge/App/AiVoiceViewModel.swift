import Foundation
import Observation
import QQBridgeKit
import QQBridgeProto

@MainActor
protocol AiVoiceService {
  func categories() async throws -> [Qqbridge_V1_AiVoiceCategory]
  func send(voiceId: String, text: String) async throws
}

@MainActor
struct SessionAiVoiceService: AiVoiceService {
  let session: Session
  let chatId: Int64
  func categories() async throws -> [Qqbridge_V1_AiVoiceCategory] {
    var req = Qqbridge_V1_ListAiVoicesRequest(); req.chatID = chatId
    return try await session.api.messages.listAiVoices(request: req, headers: session.api.headers).get().categories
  }
  func send(voiceId: String, text: String) async throws {
    var req = Qqbridge_V1_SendAiVoiceRequest(); req.chatID = chatId; req.voiceID = voiceId; req.text = text
    _ = try await session.api.messages.sendAiVoice(request: req, headers: session.api.headers).get()
  }
}

@MainActor @Observable
final class AiVoiceViewModel {
  var text: String
  private(set) var categories: [Qqbridge_V1_AiVoiceCategory] = []
  private(set) var category = 0
  private(set) var voiceId: String?
  private(set) var isLoading = false
  private(set) var hasLoaded = false
  private(set) var isSending = false
  private(set) var loadError: String?
  var sendError: String?
  private(set) var completedText: String?
  @ObservationIgnored private let service: any AiVoiceService
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var sendTask: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var sendGeneration = UUID()
  @ObservationIgnored private var completion: (@MainActor (String) -> Void)?
  @ObservationIgnored private var completionDelivered = false

  init(service: any AiVoiceService, text: String) { self.service = service; self.text = text }
  var voices: [Qqbridge_V1_AiVoice] { categories.indices.contains(category) ? categories[category].voices : [] }
  var canSend: Bool {
    !isSending && completedText == nil && voiceId != nil && voices.contains { $0.id == voiceId } && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func selectCategory(_ index: Int) {
    guard !isSending, categories.indices.contains(index), category != index else { return }
    category = index
    voiceId = voices.first?.id
  }
  func selectVoice(_ id: String) {
    guard !isSending, voices.contains(where: { $0.id == id }) else { return }
    voiceId = id
  }

  func start() { if !hasLoaded, loadError == nil { load() } }

  @discardableResult
  func load() -> Task<Void, Never>? {
    if let loadTask { return loadTask }
    guard !isSending else { return nil }
    isLoading = true; loadError = nil
    let request = generation
    let next = Task { [weak self, service] in
      do {
        let result = try await service.categories()
        guard let self, generation == request, !Task.isCancelled else { return }
        let oldName = categories.indices.contains(category) ? categories[category].name : nil
        categories = result
        category = result.firstIndex { $0.name == oldName } ?? result.firstIndex { !$0.voices.isEmpty } ?? 0
        if !voices.contains(where: { $0.id == voiceId }) { voiceId = voices.first?.id }
        hasLoaded = true; isLoading = false; loadTask = nil
      } catch {
        guard let self, generation == request, !Task.isCancelled else { return }
        loadError = Self.timedOut(error) ? "加载超时，请重试" : LoadState.describe(error); isLoading = false; loadTask = nil
      }
    }
    loadTask = next
    return next
  }

  @discardableResult
  func send(onSent: @escaping @MainActor (String) -> Void) -> Task<Void, Never>? {
    guard canSend, !isLoading, let voiceId else { return nil }
    let sentText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let request = UUID(); sendGeneration = request
    completion = onSent
    isSending = true; sendError = nil
    let next = Task { [weak self, service] in
      do {
        try await service.send(voiceId: voiceId, text: sentText)
        guard let self, sendGeneration == request else { return }
        isSending = false; sendTask = nil; completedText = sentText
        deliverCompletion()
      } catch {
        guard let self, sendGeneration == request else { return }
        isSending = false; sendTask = nil; completion = nil
        sendError = Self.timedOut(error) ? "发送结果未确认，请先查看聊天记录后再决定是否重试。" : LoadState.describe(error)
      }
    }
    sendTask = next
    return next
  }

  func resume(onSent: @escaping @MainActor (String) -> Void) {
    guard !completionDelivered else { completion = nil; return }
    completion = onSent
    deliverCompletion()
  }

  private func deliverCompletion() {
    guard let text = completedText, !completionDelivered, let callback = completion else { return }
    completionDelivered = true; completion = nil
    callback(text)
  }

  private static func timedOut(_ error: any Error) -> Bool {
    (error as? URLError)?.code == .timedOut || (error as? APIError)?.code == .deadlineExceeded
  }

  // 离开只停止加载和 UI 回调；QQ 发送不能撤销。同一个模型恢复时保留进行中/完成状态。
  // 真正销毁表单后重新创建模型不在此保护范围内，不能据此声称服务端具备幂等保证。
  func cancel() {
    generation = UUID()
    loadTask?.cancel(); loadTask = nil; isLoading = false
    completion = nil
  }
}
