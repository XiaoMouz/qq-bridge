// 语音转文字、AI 语音，都用 QQ 自己的：
// - 转文字：长按语音消息「转文字」，服务端让 QQ 识别（要几秒），文字显示在语音气泡下面，本机记住。
// - AI 语音：群聊里选一个 QQ 的 AI 角色，把一段文字读成语音发到群里（QQ 只在群聊提供）。
import QQBridgeKit
import SwiftUI

/// 语音气泡下面的识别结果。
struct VoiceTranscriptView: View {
  let chatId: Int64
  let seq: Int64
  let outgoing: Bool
  var transcripts: VoiceTranscripts = .shared

  var body: some View {
    if let state = transcripts.state(chatId: chatId, seq: seq) {
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
