// 超级表情：单独发的大号 QQ 表情（QQ 里会动的那种）。动画是 QQ 的 lottie，从服务端取（/qface，见 tools/qface-sync.py），
// 存在本机缓存里；没取到前显示静态大图。进到屏幕上播一次，点一下再播。
import Lottie
import QQBridgeKit
import SwiftUI

/// 表情资源的本机缓存（Caches/qface）：取过的不再请求。
@MainActor
enum QFaceAssets {
  private static var memory: [String: LottieAnimation] = [:]
  private static var running: [String: Task<LottieAnimation?, Never>] = [:]
  private static let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("qface", isDirectory: true)

  static func lottie(_ id: String, session: Session) async -> LottieAnimation? {
    if let hit = memory[id] { return hit }
    if let task = running[id] { return await task.value }
    let task = Task<LottieAnimation?, Never> {
      let file = dir.appendingPathComponent("\(id).json")
      var data = try? Data(contentsOf: file)
      if data == nil, let fetched = try? await session.api.qfaceAsset(id: id, kind: "lottie", name: "\(id).json") {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fetched.write(to: file)
        data = fetched
      }
      guard let data else { return nil }
      return await Task.detached(priority: .userInitiated) { try? LottieAnimation.from(data: data) }.value
    }
    running[id] = task
    let animation = await task.value
    running[id] = nil
    if let animation { memory[id] = animation }
    return animation
  }
}

struct SuperFaceView: View {
  let id: String
  let name: String
  var size: CGFloat = 120
  @Environment(\.session) private var session
  @State private var animation: LottieAnimation?
  /// 每次加一就从头播一遍。
  @State private var play = 0

  var body: some View {
    ZStack {
      if let animation {
        LottieView(animation: animation)
          .playing(loopMode: .playOnce)
          .id(play)
      } else if let image = QQFace.image(id, size: size) {
        Image(uiImage: image).resizable()
      } else {
        Text(verbatim: QQFace.text(id, name: name)).font(.title2)
      }
    }
    .frame(width: size, height: size)
    .contentShape(Rectangle())
    .onTapGesture { play += 1 }
    .accessibilityLabel(QQFace.text(id, name: name))
    .task(id: id) {
      guard let session else { return }
      animation = await QFaceAssets.lottie(id, session: session)
    }
  }
}
