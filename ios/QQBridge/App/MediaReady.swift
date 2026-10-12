// 媒体下好了 / 拿不到了的通知：服务端经 Subscribe 流推临时事件（MediaReadyUpdate），这里分发给正在等的界面
// （看大图、视频、聊天记录里的媒体、群精华、打开文件）。不用轮询。
// 用法：先 watch 登记要等什么，再发请求，最后 next 等事件（先登记再请求，事件来得比 await 早也不会漏）。
import Foundation
import QQBridgeProto

@MainActor
final class MediaReady {
  static let shared = MediaReady()

  @MainActor final class Watch {
    fileprivate let match: (Qqbridge_V1_MediaReadyUpdate) -> Bool
    /// 等的人还没来取的事件（登记之后、await 之前到的也留着）。
    private var buffer: [Qqbridge_V1_MediaReadyUpdate] = []
    private var waiting: CheckedContinuation<Qqbridge_V1_MediaReadyUpdate?, Never>?

    fileprivate init(_ match: @escaping (Qqbridge_V1_MediaReadyUpdate) -> Bool) {
      self.match = match
    }

    fileprivate func deliver(_ e: Qqbridge_V1_MediaReadyUpdate) {
      if let w = waiting {
        waiting = nil
        w.resume(returning: e)
      } else {
        buffer.append(e)
        if buffer.count > 16 { buffer.removeFirst() }
      }
    }

    /// 等下一个符合的事件；超时（连接断了、服务端没推）返回 nil，调用方再问一次服务端兜底。
    func next(timeout: Duration = .seconds(120)) async -> Qqbridge_V1_MediaReadyUpdate? {
      if !buffer.isEmpty { return buffer.removeFirst() }
      let timer = Task { [weak self] in
        try? await Task.sleep(for: timeout)
        guard !Task.isCancelled, let self, let w = self.waiting else { return }
        self.waiting = nil
        w.resume(returning: nil)
      }
      defer { timer.cancel() }
      return await withCheckedContinuation { waiting = $0 }
    }
  }

  private var watches: [ObjectIdentifier: Weak] = [:]

  private struct Weak {
    weak var watch: Watch?
  }

  /// 登记：某条消息（不在聊天记录里）的某个媒体。thumb：等缩略图 / 封面（nil = 都算）。
  func watch(chatId: Int64, seq: Int64, ord: UInt32? = nil, thumb: Bool? = nil) -> Watch {
    watch { e in
      e.chatID == chatId && e.seq == seq && e.node < 0 && (ord == nil || e.ord == ord!) && (thumb == nil || e.thumb == thumb!)
    }
  }

  /// 登记：聊天记录（会话里 seq 那条，展开到 path 那一层）里的媒体；node / ord 为 nil 时这一层的都算。
  func watchForward(chatId: Int64, seq: Int64, path: [Int32], node: Int? = nil, ord: UInt32? = nil) -> Watch {
    let key = path.map(String.init).joined(separator: ".")
    return watch { e in
      e.chatID == chatId && e.seq == seq && e.node >= 0 && e.forwardPath == key
        && (node == nil || Int(e.node) == node!) && (ord == nil || e.ord == ord!)
    }
  }

  /// 登记：某个会话里几条消息中任意一个媒体（群精华）。
  func watch(chatId: Int64, seqs: Set<Int64>) -> Watch {
    watch { e in e.chatID == chatId && seqs.contains(e.seq) && e.node < 0 }
  }

  func watch(_ match: @escaping (Qqbridge_V1_MediaReadyUpdate) -> Bool) -> Watch {
    let w = Watch(match)
    watches[ObjectIdentifier(w)] = Weak(watch: w)
    return w
  }

  /// 收到服务端的事件（AppModel 的事件循环调用）。
  func publish(_ e: Qqbridge_V1_MediaReadyUpdate) {
    for (key, entry) in watches {
      guard let w = entry.watch else {
        watches[key] = nil
        continue
      }
      if w.match(e) { w.deliver(e) }
    }
  }
}
