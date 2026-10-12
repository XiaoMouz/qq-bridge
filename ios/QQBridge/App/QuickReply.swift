// App 内横幅和快速回复：前台收到别的会话的消息时顶部弹一条横幅（不发系统通知），
// 点开是浮层：就是完整的聊天页（ChatScreen 的浮层模式），右上角可以展开成完整会话。上划横幅收起。
import QQBridgeKit
import QQBridgeProto
import SwiftUI

struct InAppBannerView: View {
  let banner: InAppBanner
  let onTap: () -> Void
  let onDismiss: () -> Void
  @State private var drag: CGFloat = 0

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "bubble.left.fill").foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        Text(banner.title).font(.subheadline.bold()).lineLimit(1)
        Text(banner.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    .padding(.horizontal, 10)
    .offset(y: min(0, drag))
    .contentShape(Rectangle())
    .onTapGesture(perform: onTap)
    .gesture(
      DragGesture()
        .onChanged { drag = $0.translation.height }
        .onEnded { v in
          if v.translation.height < -30 { onDismiss() } else { withAnimation(.spring) { drag = 0 } }
        }
    )
  }
}

/// 底部的一行提示（转发成功等）。带会话的显示"查看"，点一下打开那个会话。
struct AppToast: Identifiable, Equatable {
  let id = UUID()
  let text: String
  var chatId: Int64? = nil
}

struct AppToastView: View {
  let toast: AppToast
  let onOpen: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      Text(toast.text).font(.subheadline).lineLimit(2)
      if toast.chatId != nil {
        Spacer(minLength: 4)
        Text("查看").font(.subheadline.bold()).foregroundStyle(.tint)
        Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tint)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .glassEffect(.regular.interactive(), in: Capsule())
    .padding(.horizontal, 16)
    .contentShape(Capsule())
    .onTapGesture { if toast.chatId != nil { onOpen() } }
  }
}
