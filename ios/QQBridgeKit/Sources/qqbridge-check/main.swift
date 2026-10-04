// 命令行验收：在 Mac 上用 QQBridgeKit 连真实服务端走一遍客户端主流程（不需要 Xcode）。
//   swift run qqbridge-check [--server http://127.0.0.1:8080] [--user owner] [--listen 20]
// 密码在终端里输入（不回显）。结束时吊销这次登录产生的设备令牌，本地数据放在临时目录、用完删除。
import Foundation
import QQBridgeKit
import QQBridgeProto

func arg(_ name: String, _ fallback: String) -> String {
  let args = CommandLine.arguments
  if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
  return fallback
}

func step(_ title: String) { print("\n== \(title)") }

let server = URL(string: arg("--server", "http://127.0.0.1:8080"))!
let user = arg("--user", "owner")
let listenSeconds = Int(arg("--listen", "20")) ?? 20
guard let raw = getpass("\(user) 的密码: ") else { exit(1) }
let password = String(cString: raw)

let container = FileManager.default.temporaryDirectory.appendingPathComponent("qqbridge-check-\(UUID().uuidString)")
let tokens = MemoryTokenStore()
var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
  print(ok ? "  ✓ \(what)" : "  ✗ \(what)")
  if !ok { failures += 1 }
}

do {
  step("登录")
  let session = try await Session.login(
    config: ServerConfig(baseURL: server),
    username: user,
    password: password,
    deviceName: "qqbridge-check",
    tokens: tokens,
    container: container
  )
  defer { try? FileManager.default.removeItem(at: container) }

  step("会话列表（GetDifference 全量）")
  let t0 = Date()
  try await session.sync.catchUp()
  let dialogs = try session.store.dialogs()
  print("  pts = \(try session.store.pts())，\(dialogs.count) 个会话，用时 \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
  check(!dialogs.isEmpty, "拿到了会话")

  step("预取首屏（GetChatDifferences）")
  let t1 = Date()
  await session.sync.prefetch()
  let prefetched = try dialogs.prefix(30).filter { try session.store.chatState(chatId: $0.chatID).chatPts > 0 }.count
  print("  \(prefetched) 个会话已有首屏，用时 \(String(format: "%.2f", Date().timeIntervalSince(t1)))s")

  if let top = dialogs.first {
    step("打开最近的会话 \(top.chatID)，往上翻两页")
    try await session.sync.openChat(top.chatID)
    let first = try session.store.messages(chatId: top.chatID, limit: 1000).count
    let a = try await session.sync.loadOlder(top.chatID)
    let b = try await session.sync.loadOlder(top.chatID)
    let state = try session.store.chatState(chatId: top.chatID)
    print("  首屏 \(first) 条，翻页 +\(a) +\(b)，chat_pts = \(state.chatPts)，已加载区间 \(state.loadedRanges.map { "\($0.lo)…\($0.hi)" })")
    check(first > 0, "首屏有消息")
    check(state.loadedRanges.count == 1, "已加载的是一段连续区间")

    step("下载一张缩略图")
    let thumbs = try session.store.messages(chatId: top.chatID, limit: 1000).flatMap(\.segments).compactMap { seg -> String? in
      if case .image(let img)? = seg.kind, !img.media.thumbSha256.isEmpty { return img.media.thumbSha256 }
      return nil
    }
    if let sha = thumbs.last {
      let file = try await session.media.file(for: sha, chatId: top.chatID)
      let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
      print("  \(sha.prefix(12))… \(size) 字节（已按 sha256 校验）")
      check(size > 0, "缩略图下载并校验通过")
    } else {
      print("  这几页里没有图片，跳过")
    }
  }

  step("实时推送：听 \(listenSeconds) 秒（这期间可以在 QQ 里发条消息试试）")
  let events = await session.sync.events()
  await session.sync.start()
  let before = try session.store.pts()
  let listener = Task {
    for await e in events {
      switch e {
      case .connection(let s): print("  连接：\(s)")
      case .typing(let t): print("  正在输入：会话 \(t.chatID)")
      case .call(let c): print("  通话：\(c.phase) \(c.peerName)")
      }
    }
  }
  try await Task.sleep(for: .seconds(listenSeconds))
  listener.cancel()
  await session.sync.stop()
  print("  pts \(before) → \(try session.store.pts())")

  step("退出：吊销这次的设备令牌")
  await session.logout(tokens: tokens)
  print(failures == 0 ? "\n全部通过" : "\n\(failures) 项没通过")
  exit(failures == 0 ? 0 : 1)
} catch {
  print("\n失败：\(error)")
  exit(1)
}
