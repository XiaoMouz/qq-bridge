// 输入栏的语音部分：按住录音的麦克风按钮、录音时替换输入框的录音条（时长 + 实时波形）。
import SwiftUI

/// 按住开始录音，松开发送；按住时往左滑过一段距离，松开就取消。
struct MicButton: View {
  let recorder: VoiceRecorder
  let onStart: () -> Void
  let onFinish: (_ cancelled: Bool) -> Void
  /// 左滑多远算取消。
  static let cancelDistance: CGFloat = 100
  @State private var pressing = false

  var body: some View {
    Image(systemName: "mic.fill")
      .font(.body.weight(.semibold))
      .foregroundStyle(recorder.recording ? .white : .secondary)
      .frame(width: 36, height: 36)
      .background(Circle().fill(recorder.recording ? AnyShapeStyle(recorder.willCancel ? Color.gray : Color.red) : AnyShapeStyle(.clear)))
      .scaleEffect(recorder.recording ? 1.35 : 1)
      .animation(.spring(duration: 0.25), value: recorder.recording)
      .padding(.bottom, 2)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            if !pressing {
              pressing = true
              onStart()
            }
            recorder.willCancel = value.translation.width < -Self.cancelDistance
          }
          .onEnded { value in
            pressing = false
            onFinish(value.translation.width < -Self.cancelDistance)
          }
      )
      .sensoryFeedback(.impact, trigger: recorder.recording)
      .accessibilityLabel("按住录语音")
  }
}

/// 录音中替换输入框：红点 + 时长 + 波形，右边提示左滑取消。
struct RecordingBar: View {
  let recorder: VoiceRecorder

  var body: some View {
    HStack(spacing: 10) {
      Circle().fill(.red).frame(width: 8, height: 8)
        .opacity(Int(recorder.elapsed * 2) % 2 == 0 ? 1 : 0.3)
      Text(Self.format(recorder.elapsed)).font(.body.monospacedDigit())
      Waveform(levels: recorder.levels)
        .frame(height: 24)
      Text(recorder.willCancel ? "松开取消" : "‹ 左滑取消")
        .font(.footnote)
        .foregroundStyle(recorder.willCancel ? .red : .secondary)
        .fixedSize()
    }
    .padding(.horizontal, 14)
    .frame(height: 40)
    .frame(maxWidth: .infinity)
    .glassEffect(.regular, in: .rect(cornerRadius: 20))
  }

  static func format(_ t: TimeInterval) -> String {
    let s = Int(t)
    return String(format: "%d:%02d", s / 60, s % 60)
  }
}

/// 最近一段音量的竖条（新的在右边）。
struct Waveform: View {
  let levels: [CGFloat]

  var body: some View {
    GeometryReader { geo in
      let bar: CGFloat = 2
      let gap: CGFloat = 2
      let count = max(Int(geo.size.width / (bar + gap)), 1)
      let shown = Array(levels.suffix(count))
      HStack(alignment: .center, spacing: gap) {
        Spacer(minLength: 0)
        ForEach(shown.indices, id: \.self) { i in
          Capsule().frame(width: bar, height: max(3, geo.size.height * shown[i]))
        }
      }
      .frame(maxHeight: .infinity)
      .foregroundStyle(.tint)
    }
  }
}
