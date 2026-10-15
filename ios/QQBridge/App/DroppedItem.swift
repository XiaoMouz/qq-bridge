import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// 系统的拖放链接只在接收回调期间有效；中转副本仅由这次拖放持有。
final class DroppedFile: Sendable {
  let url: URL
  private let directory: URL

  enum ImportError: LocalizedError {
    case directory, unsupported
    var errorDescription: String? {
      switch self {
      case .directory: "不能添加文件夹，请先压缩为 ZIP 文件"
      case .unsupported: "只能添加普通文件"
      }
    }
  }

  init(copying source: URL, temporaryRoot: URL = FileManager.default.temporaryDirectory) throws {
    guard source.isFileURL else { throw ImportError.unsupported }
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
    // 在 copyItem 之前拒绝目录，避免把整个文件夹拷完才发现不能发送。
    if values.isDirectory == true { throw ImportError.directory }
    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ImportError.unsupported }
    let directory = temporaryRoot.appendingPathComponent("drop-\(UUID().uuidString)", isDirectory: true)
    let destination = directory.appendingPathComponent(source.lastPathComponent)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: source, to: destination)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
    self.directory = directory
    url = destination
  }

  func discard() { try? FileManager.default.removeItem(at: directory) }
  deinit { try? FileManager.default.removeItem(at: directory) }
}

struct DroppedItem: Transferable {
  let file: DroppedFile?
  let failure: String?

  init(receiving source: URL) {
    do {
      file = try DroppedFile(copying: source)
      failure = nil
    } catch {
      file = nil
      failure = "\(source.lastPathComponent)：\(error.localizedDescription)"
    }
  }

  static var transferRepresentation: some TransferRepresentation {
    #if targetEnvironment(macCatalyst)
    // 2026-10-15 系统 NSItemProvider 实测：仅含 file-url 的来源被 .item 读成 URL 描述文件。
    // 先解析文件地址，再在安全作用域内复制原文件；非文件 URL 仍由 DroppedFile 拒绝。
    ProxyRepresentation(importing: { (url: URL) in
      #if DEBUG
      MacDropDiagnostics.record("Transferable URL callback")
      #endif
      return DroppedItem(receiving: url)
    })
    #endif
    FileRepresentation(importedContentType: .item) { received in
      #if DEBUG && targetEnvironment(macCatalyst)
      MacDropDiagnostics.record("Transferable file callback")
      #endif
      // 失败也交给页面汇总，不能让系统静默丢掉这一项后自动发送其余附件。
      return DroppedItem(receiving: received.file)
    }
  }
}
