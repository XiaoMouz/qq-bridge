#if DEBUG && targetEnvironment(macCatalyst)
import OSLog

/// 临时定位真实 Finder 拖放：只记录阶段与类型，不读取或记录文件内容、路径。
enum MacDropDiagnostics {
  private static let logger = Logger(subsystem: "com.xiaomouz.betterchat.mac", category: "FileDrop")

  static func record(_ event: String) {
    logger.notice("\(event, privacy: .public)")
  }
}

#endif
