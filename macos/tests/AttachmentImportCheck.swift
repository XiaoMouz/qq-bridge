import Foundation

@MainActor
private final class ImportGate {
  var continuation: CheckedContinuation<Void, Never>?
  func wait() async { await withCheckedContinuation { continuation = $0 } }
  func finish() { continuation?.resume(); continuation = nil }
}

@main
struct AttachmentImportCheck {
  @MainActor static func until(_ condition: () -> Bool) async {
    for _ in 0..<10_000 {
      if condition() { return }
      await Task.yield()
    }
    preconditionFailure("导入未到达预期状态")
  }
  @MainActor static func main() async {
    var owner: AttachmentQueue<String>? = AttachmentQueue()
    let receivingPage = owner!
    let unrelated = AttachmentQueue<String>()
    let slow = ImportGate()
    var fastRead = false
    var completions: [Bool] = []
    owner!.enqueueImport({
      await slow.wait()
      return .init(attachments: ["先选的视频"])
    }, completion: { completions.append($0) })
    owner!.enqueueImport({
      fastRead = true
      return .init(attachments: ["后选的文件"], failures: ["第三项无法读取"])
    }, completion: { completions.append($0) })
    precondition(receivingPage.pendingImports == 2)
    owner = nil
    await until { fastRead && slow.continuation != nil }
    precondition(receivingPage.items.isEmpty && completions.isEmpty)
    slow.finish()
    await until { receivingPage.pendingImports == 0 }
    precondition(receivingPage.items == ["先选的视频", "后选的文件"])
    precondition(completions == [true, false])
    precondition(receivingPage.importError == "第三项无法读取")
    precondition(unrelated.items.isEmpty && unrelated.importError == nil)

    receivingPage.enqueueImport { .init(attachments: ["再选的图片"]) }
    await until { receivingPage.pendingImports == 0 }
    precondition(receivingPage.importError == "第三项无法读取")
    receivingPage.enqueueImport { .init(failures: ["下一批读取失败"]) }
    await until { receivingPage.pendingImports == 0 }
    precondition(receivingPage.importError == "第三项无法读取\n下一批读取失败")
    receivingPage.importError = nil
    receivingPage.enqueueImport { .init(attachments: ["重试成功"]) }
    await until { receivingPage.pendingImports == 0 }
    precondition(receivingPage.importError == nil && receivingPage.items.last == "重试成功")
    precondition(receivingPage.items.count == 4)
    print("附件导入检查通过：并发读取/顺序提交、页面移交、草稿隔离、失败保留、错误累积与重试")
  }
}
