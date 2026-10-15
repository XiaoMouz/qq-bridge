import Foundation

@main
struct DroppedFileCheck {
  static func check(_ value: Bool) { precondition(value) }
  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("drop-check-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("原文件.txt")
    let content = Data("拖放生命周期检查".utf8)
    try content.write(to: source)
    let staging = root.appendingPathComponent("staging")
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)

    let first = try DroppedFile(copying: source, temporaryRoot: staging)
    let second = try DroppedFile(copying: source, temporaryRoot: staging)
    precondition(first.url != second.url)
    precondition(first.url.lastPathComponent == source.lastPathComponent)
    try check(Data(contentsOf: first.url) == content)
    first.discard()
    first.discard()
    precondition(!fm.fileExists(atPath: first.url.deletingLastPathComponent().path))
    try check(Data(contentsOf: second.url) == content)
    try check(Data(contentsOf: source) == content)
    second.discard()

    var abandoned: DroppedFile? = try DroppedFile(copying: source, temporaryRoot: staging)
    let abandonedDirectory = abandoned!.url.deletingLastPathComponent()
    abandoned = nil
    precondition(!fm.fileExists(atPath: abandonedDirectory.path))

    // 目录拒绝发生在暂存目录创建前，原目录及里面的内容保持原样。
    let folder = root.appendingPathComponent("不能发送的文件夹")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let nested = folder.appendingPathComponent("保留.txt")
    try content.write(to: nested)
    do { _ = try DroppedFile(copying: folder, temporaryRoot: staging); preconditionFailure("目录被接收") }
    catch { precondition(error as? DroppedFile.ImportError == .directory) }
    try check(fm.contentsOfDirectory(atPath: staging.path).isEmpty)
    try check(Data(contentsOf: nested) == content)

    let symlink = root.appendingPathComponent("link.txt")
    try fm.createSymbolicLink(at: symlink, withDestinationURL: source)
    do { _ = try DroppedFile(copying: symlink, temporaryRoot: staging); preconditionFailure("符号链接被接收") }
    catch { precondition(error as? DroppedFile.ImportError == .unsupported) }
    try check(fm.contentsOfDirectory(atPath: staging.path).isEmpty)

    // 接收层将失败项保留下来，混合拖入不会变成静默部分成功。
    let invalid = DroppedItem(receiving: folder)
    precondition(invalid.file == nil && invalid.failure?.contains(folder.lastPathComponent) == true)
    let valid = DroppedItem(receiving: source)
    precondition(valid.failure == nil && valid.file != nil)
    valid.file?.discard()

    // 暂存位置不可创建时，不删除调用方给出的已有文件，也不损坏原附件。
    let blockedRoot = root.appendingPathComponent("不是目录")
    try content.write(to: blockedRoot)
    do { _ = try DroppedFile(copying: source, temporaryRoot: blockedRoot); preconditionFailure("无效暂存位置被接收") }
    catch { }
    try check(Data(contentsOf: blockedRoot) == content)
    try check(Data(contentsOf: source) == content)

    let missing = source.appendingPathExtension("missing")
    do { _ = try DroppedFile(copying: missing, temporaryRoot: staging); preconditionFailure("缺失文件被接收") }
    catch { }
    try check(fm.contentsOfDirectory(atPath: staging.path).isEmpty)
    print("拖放中转检查通过：内容/文件名、同名隔离、显式/自动清理、目录与链接拒绝、失败保留；未发送消息")
  }
}
