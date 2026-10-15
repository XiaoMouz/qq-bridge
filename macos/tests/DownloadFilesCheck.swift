import CryptoKit
import Foundation

@main
struct DownloadFilesCheck {
  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let destination = root.appendingPathComponent("Downloads", isDirectory: true)
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let content = Data("验收文件".utf8)
    try content.write(to: source)
    let sha = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
    try MacDownloadFiles.verify(source, sha256: sha)
    do {
      try MacDownloadFiles.verify(source, sha256: String(repeating: "0", count: 64))
      fatalError("未拒绝内容校验失败的文件")
    } catch is CocoaError {}

    for unsafe in ["../../outside.txt", "a/b\\c:d\u{0}.txt", "", ".", "..", String(repeating: "图", count: 300) + "." + String(repeating: "片", count: 100)] {
      let name = MacDownloadFiles.safeName(unsafe, fallback: sha)
      precondition(!name.isEmpty && name != "." && name != "..")
      precondition(!name.contains("/") && !name.contains("\\") && !name.contains("\u{0}"))
      precondition(name.utf8.count <= 255)
    }
    let existing = destination.appendingPathComponent("same.txt")
    try Data("用户已有文件".utf8).write(to: existing)
    DispatchQueue.concurrentPerform(iterations: 16) { _ in
      do { _ = try MacDownloadFiles.save(source, name: "same.txt", to: destination) }
      catch { fatalError("并行保存失败：\(error)") }
    }
    let original = try String(contentsOf: existing, encoding: .utf8)
    precondition(original == "用户已有文件")
    let saved = try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
    precondition(saved.count == 17)
    for file in saved where file.lastPathComponent != existing.lastPathComponent {
      let bytes = try Data(contentsOf: file)
      precondition(bytes == content)
    }

    // 用户可能已有同名目录或指向其他文件的链接，也必须另取名字，不能跟随链接覆盖。
    let folder = destination.appendingPathComponent("folder.txt", isDirectory: true)
    try fm.createDirectory(at: folder, withIntermediateDirectories: false)
    let folderSaved = try MacDownloadFiles.save(source, name: "folder.txt", to: destination)
    precondition(folderSaved.lastPathComponent == "folder (1).txt")
    let folderContents = try fm.contentsOfDirectory(atPath: folder.path)
    precondition(folderContents.isEmpty)
    let link = destination.appendingPathComponent("link.txt")
    try fm.createSymbolicLink(at: link, withDestinationURL: existing)
    let linkSaved = try MacDownloadFiles.save(source, name: "link.txt", to: destination)
    precondition(linkSaved.lastPathComponent == "link (1).txt")
    let afterLink = try String(contentsOf: existing, encoding: .utf8)
    let linkTarget = try fm.destinationOfSymbolicLink(atPath: link.path)
    precondition(afterLink == "用户已有文件")
    precondition(linkTarget == existing.path)

    // 真实文件系统错误：源文件消失、目标不再是目录，失败后不留下 .download 或最终文件。
    let beforeFailure = Set(try fm.contentsOfDirectory(atPath: destination.path))
    for (input, output) in [(root.appendingPathComponent("missing"), destination), (source, existing)] {
      do {
        _ = try MacDownloadFiles.save(input, name: "failed.txt", to: output)
        fatalError("无效源文件或目标目录没有报错")
      } catch {}
    }
    let afterFailure = Set(try fm.contentsOfDirectory(atPath: destination.path))
    let finalOriginal = try String(contentsOf: existing, encoding: .utf8)
    precondition(afterFailure == beforeFailure)
    precondition(finalOriginal == "用户已有文件")
    print("下载文件检查通过：名称与哈希校验、16 个并发同名保存、目录和链接冲突、失败无残留且原文件未覆盖")
  }
}
