import CryptoKit
import Darwin
import Foundation

/// 文件名来自 QQ，不能让路径分隔符或重名文件覆盖用户已有内容。
enum MacDownloadFiles {
  static func safeName(_ name: String, fallback: String) -> String {
    let clean = name.components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)).joined(separator: "_")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, clean != ".", clean != ".." else { return fallback }
    // APFS 单个文件名最长 255 字节；留出重名编号的空间，并保留扩展名。
    var ext = (clean as NSString).pathExtension
    while ext.utf8.count > 40 { ext.removeLast() }
    var stem = ext.isEmpty ? clean : (clean as NSString).deletingPathExtension
    while stem.utf8.count > 200 { stem.removeLast() }
    return ext.isEmpty ? stem : "\(stem).\(ext)"
  }

  static func verify(_ url: URL, sha256: String) throws {
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    var hash = SHA256()
    while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
    guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
      throw CocoaError(.fileReadCorruptFile)
    }
  }

  static func save(_ source: URL, name: String, to directory: URL) throws -> URL {
    let staging = directory.appendingPathComponent(".betterchat-\(UUID().uuidString).download")
    defer { try? FileManager.default.removeItem(at: staging) }
    // 大文件先完整写到同目录的临时文件，失败时不留下看似下载完成的半份文件。
    try FileManager.default.copyItem(at: source, to: staging)
    let ext = (name as NSString).pathExtension
    let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
    for index in 0..<10000 {
      try Task.checkCancellation()
      let candidate = index == 0 ? name : "\(stem) (\(index))" + (ext.isEmpty ? "" : ".\(ext)")
      let url = directory.appendingPathComponent(candidate)
      // 2026-10-14 并发实测：FileManager.moveItem 的存在检查有竞争窗口。
      // 让内核原子地拒绝覆盖，不能先检查存在再重命名。
      if renamex_np(staging.path, url.path, UInt32(RENAME_EXCL)) == 0 { return url }
      let failure = errno
      if failure == EEXIST { continue }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
    }
    throw CocoaError(.fileWriteFileExists)
  }
}
