import CoreTransferable
import Darwin
import Foundation
import UniformTypeIdentifiers

/// 图片查看器的 Mac 分享项。2026-10-15 实测：直接分享缓存文件（以 sha 命名、没有扩展名）时，
/// 分享面板标题是 sha，「拷贝」后粘到聊天里被当成普通文件。导出时才拷一份带图片扩展名的临时副本。
struct MacShareImage: Transferable {
  let sha256: String
  let source: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .image) { image in
      SentTransferredFile(try await MacImageShareFile.export(image.source, sha256: image.sha256))
    }
  }
}

enum MacImageShareFile {
  enum ShareError: LocalizedError {
    case invalidSource
    var errorDescription: String? { "原图不可用" }
  }

  static var defaultDirectory: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("BetterChatShare", isDirectory: true)
  }

  /// 原样拷贝（不转码，GIF 保留动画）到 `<sha>.<扩展名>`。同一张图重复分享复用已有副本；
  /// 放在临时目录，分享完成后接收方仍能读取，由系统择机清理。
  @concurrent
  static func export(_ source: URL, sha256: String, into directory: URL = defaultDirectory) async throws -> URL {
    // 缓存按内容哈希命名，sha 合法即可直接作文件名，不会带入路径分隔符。
    guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else { throw ShareError.invalidSource }
    let fm = FileManager.default
    // attributesOfItem 不跟随符号链接：缓存失效、被换成目录或链接都拒绝。
    guard let attributes = try? fm.attributesOfItem(atPath: source.path),
          attributes[.type] as? FileAttributeType == .typeRegular else { throw ShareError.invalidSource }
    // ImageFile.ext 认不出时会退回原文件的扩展名，只接受短的字母数字。
    let detected = ImageFile.ext(of: source).lowercased()
    let ext = (1...8).contains(detected.count) && detected.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
      ? detected : "jpg"
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent("\(sha256.lowercased()).\(ext)")
    let size = attributes[.size] as? Int
    if let existing = try? fm.attributesOfItem(atPath: destination.path),
       existing[.type] as? FileAttributeType == .typeRegular, existing[.size] as? Int == size {
      return destination
    }
    // 先写到同目录的临时名再原子改名：失败不留半份文件，并发导出同一张图也只会得到完整内容。
    let staging = directory.appendingPathComponent(".\(sha256.lowercased())-\(UUID().uuidString).partial")
    do {
      try fm.copyItem(at: source, to: staging)
      guard rename(staging.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    } catch {
      try? fm.removeItem(at: staging)
      throw error
    }
    return destination
  }
}
