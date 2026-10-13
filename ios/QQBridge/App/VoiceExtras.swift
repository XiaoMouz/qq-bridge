// 语音转文字、AI 语音，都用 QQ 自己的：
// - 转文字：长按语音消息「转文字」，服务端让 QQ 识别（要几秒），文字显示在语音气泡下面，本机记住。
// - AI 语音：群聊里选一个 QQ 的 AI 角色，把一段文字读成语音发到群里（QQ 只在群聊提供）。
import AVFoundation
import QQBridgeKit
import QQBridgeProto
import SwiftUI

/// 语音消息的识别结果（会话 id:seq → 文字），存在本机。
@MainActor
@Observable
final class VoiceTranscripts {
  static let shared = VoiceTranscripts()

  enum State: Equatable {
    case loading
    case text(String)
    case failed(String)
  }

  private(set) var states: [String: State] = [:]
  private static let storeKey = "voiceTranscripts"
  /// 设置：语音消息出现时自动转文字。
  static let autoKey = "autoTranscribeVoice"
  /// 手动收起过的（自动转文字时不再自己展开）。
  private var hidden: Set<String> = []

  private init() {
    let saved = UserDefaults.standard.dictionary(forKey: Self.storeKey) as? [String: String] ?? [:]
    states = saved.mapValues { .text($0) }
  }

  func state(chatId: Int64, seq: Int64) -> State? { states["\(chatId):\(seq)"] }

  func transcribe(chatId: Int64, seq: Int64, session: Session) {
    let key = "\(chatId):\(seq)"
    if case .text = states[key] { return }
    if states[key] == .loading { return }
    states[key] = .loading
    Task {
      var req = Qqbridge_V1_TranscribeVoiceRequest()
      req.chatID = chatId
      req.seq = seq
      do {
        let text = try await session.api.messages.transcribeVoice(request: req, headers: session.api.headers).get().text
        states[key] = .text(text)
        save()
      } catch {
        states[key] = .failed(LoadState.describe(error))
      }
    }
  }

  func hide(chatId: Int64, seq: Int64) {
    let key = "\(chatId):\(seq)"
    states[key] = nil
    hidden.insert(key)
    save()
  }

  /// 自动转文字（设置打开时语音气泡出现就调用）：手动收起过的、已经有结果的不再转。
  func autoTranscribe(chatId: Int64, seq: Int64, session: Session) {
    guard UserDefaults.standard.bool(forKey: Self.autoKey), !hidden.contains("\(chatId):\(seq)") else { return }
    if case .failed = states["\(chatId):\(seq)"] { return }
    transcribe(chatId: chatId, seq: seq, session: session)
  }

  /// 语音旁边的按钮：没转过就转，转出来了就收起，收起了再点就重新显示。
  func toggle(chatId: Int64, seq: Int64, session: Session) {
    let key = "\(chatId):\(seq)"
    switch states[key] {
    case .text: hide(chatId: chatId, seq: seq)
    case .loading: break
    default:
      hidden.remove(key)
      states[key] = nil
      transcribe(chatId: chatId, seq: seq, session: session)
    }
  }

  /// 只存识别出来的（最多 500 条）。
  private func save() {
    var out: [String: String] = [:]
    for (k, v) in states { if case .text(let t) = v { out[k] = t } }
    if out.count > 500 { out = Dictionary(uniqueKeysWithValues: out.sorted { $0.key > $1.key }.prefix(500).map { ($0.key, $0.value) }) }
    UserDefaults.standard.set(out, forKey: Self.storeKey)
  }
}

/// 语音气泡下面的识别结果。
struct VoiceTranscriptView: View {
  let chatId: Int64
  let seq: Int64
  let outgoing: Bool

  var body: some View {
    if let state = VoiceTranscripts.shared.state(chatId: chatId, seq: seq) {
      Group {
        switch state {
        case .loading:
          HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("正在转文字…")
          }
        case .text(let t):
          Text(t.isEmpty ? "没有识别出文字" : t).textSelection(.enabled)
        case .failed(let e):
          Text("转文字失败：\(e)")
        }
      }
      .font(.subheadline)
      .opacity(0.85)
      .padding(.top, 4)
      // 按文字本身的宽度，最多 260 再换行、全部显示：短的识别结果不把气泡撑宽，长的不截断。
      .fixedSize(horizontal: false, vertical: true)
      .modifier(CappedWidth(max: 260))
      .transition(.opacity)
    }
  }
}

/// AI 语音：选角色（可试听）、写要读的话、发到群里。
struct AiVoiceSheet: View {
  let session: Session
  let chatId: Int64
  /// 输入框里已经写的话（默认读这段）。
  let initialText: String
  /// 发出去之后（输入框里的字是读出来的那段就清掉）。
  let onSent: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var categories: [Qqbridge_V1_AiVoiceCategory] = []
  @State private var category = 0
  @State private var voiceId: String?
  @State private var text = ""
  @State private var state = LoadState.loading
  @State private var sending = false
  @State private var error: String?
  @State private var player: AVPlayer?
  @State private var previewing: String?

  var body: some View {
    NavigationStack {
      Form {
        Section("要读的话") {
          TextField("输入文字", text: $text, axis: .vertical).lineLimit(2...6)
        }
        if categories.count > 1 {
          Picker("分类", selection: $category) {
            ForEach(categories.indices, id: \.self) { i in Text(categories[i].name).tag(i) }
          }
          .pickerStyle(.segmented)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
        }
        if categories.indices.contains(category) {
          Section("角色") {
            ForEach(categories[category].voices, id: \.id) { v in
              HStack {
                Button {
                  voiceId = v.id
                } label: {
                  HStack {
                    Text(v.name).foregroundStyle(.primary)
                    Spacer()
                    if voiceId == v.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                  }
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !v.previewURL.isEmpty {
                  Button { preview(v) } label: {
                    Image(systemName: previewing == v.id ? "stop.circle" : "play.circle").font(.title3)
                  }
                  .buttonStyle(.borderless)
                  .accessibilityLabel("试听")
                }
              }
            }
          }
        }
      }
      .overlay { state.overlay(empty: categories.isEmpty, emptyText: "这个群用不了 AI 语音", icon: "waveform") }
      .navigationTitle("AI 语音")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          if sending {
            ProgressView()
          } else {
            Button("发送") { Task { await send() } }
              .disabled(voiceId == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
      }
      .alert("发送失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }), presenting: error) { _ in
        Button("好") { error = nil }
      } message: { Text($0) }
      .task { await load() }
      .onDisappear { player?.pause() }
    }
  }

  private func load() async {
    text = initialText
    var req = Qqbridge_V1_ListAiVoicesRequest()
    req.chatID = chatId
    do {
      categories = try await session.api.messages.listAiVoices(request: req, headers: session.api.headers).get().categories
      voiceId = voiceId ?? categories.first?.voices.first?.id
      state = .loaded
    } catch {
      state = .failed(LoadState.describe(error))
    }
  }

  private func preview(_ v: Qqbridge_V1_AiVoice) {
    if previewing == v.id {
      player?.pause()
      previewing = nil
      return
    }
    guard let url = URL(string: v.previewURL) else { return }
    try? AVAudioSession.sharedInstance().setCategory(.playback)
    let p = AVPlayer(url: url)
    player = p
    previewing = v.id
    p.play()
  }

  private func send() async {
    guard let voiceId else { return }
    sending = true
    defer { sending = false }
    var req = Qqbridge_V1_SendAiVoiceRequest()
    req.chatID = chatId
    req.voiceID = voiceId
    req.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      _ = try await session.api.messages.sendAiVoice(request: req, headers: session.api.headers).get()
      onSent(req.text)
      dismiss()
    } catch {
      self.error = LoadState.describe(error)
    }
  }
}

/// 宽度最多 max：给子视图的建议宽度不超过 max，自身大小就是子视图的大小（不像 frame(maxWidth:) 会撑满到 max）。
struct CappedWidth: ViewModifier {
  let max: CGFloat

  func body(content: Content) -> some View {
    CappedWidthLayout(max: max) { content }
  }
}

private struct CappedWidthLayout: Layout {
  let max: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let child = subviews.first else { return .zero }
    let width = min(proposal.width ?? max, max)
    return child.sizeThatFits(ProposedViewSize(width: width, height: nil))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
  }
}
