import Foundation
import QQBridgeProto
import Testing
@testable import BetterChat

@MainActor private final class GroupFilesReplies: MacGroupFilesService {
  private(set) var count = 0
  private var pending: [Int: CheckedContinuation<Qqbridge_V1_ListGroupFilesResponse, any Error>] = [:]
  func load() async throws -> Qqbridge_V1_ListGroupFilesResponse {
    let index = count
    count += 1
    return try await withCheckedThrowingContinuation { pending[index] = $0 }
  }
  func wait(_ expected: Int) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while count < expected, ContinuousClock.now < deadline { await Task.yield() }
    #expect(count == expected)
  }
  func finish(_ index: Int, _ files: [Qqbridge_V1_GroupFile], folders: [Qqbridge_V1_GroupFolder] = []) {
    var result = Qqbridge_V1_ListGroupFilesResponse()
    result.files = files
    result.folders = folders
    pending.removeValue(forKey: index)?.resume(returning: result)
  }
  func fail(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: URLError(.timedOut)) }
}

@Suite(.serialized) @MainActor
struct MacGroupFilesTests {
  private func file(_ id: String, name: String = "file.txt") -> Qqbridge_V1_GroupFile {
    var file = Qqbridge_V1_GroupFile()
    file.id = id; file.name = name; file.size = 32; file.uploaderID = 7
    return file
  }

  @Test func firstFailureCanRetryAndEmptySuccessFinishesLoading() async {
    let service = GroupFilesReplies(), model: MacGroupFilesViewModel
    model = MacGroupFilesViewModel(service: service)
    let first = model.load()
    await service.wait(1); service.fail(0); await first.value
    #expect(model.error == "加载超时，请重试" && !model.hasLoaded && !model.isLoading)
    let retry = model.load()
    await service.wait(2); service.finish(1, []); await retry.value
    #expect(model.error == nil && model.hasLoaded && model.files.isEmpty && model.folders.isEmpty)
  }

  @Test func refreshFailureKeepsFoldersFilesAndSelectionThenMapsNewOperationIDs() async {
    let service = GroupFilesReplies(), model: MacGroupFilesViewModel
    model = MacGroupFilesViewModel(service: service)
    var folder = Qqbridge_V1_GroupFolder(); folder.id = "folder"; folder.name = "资料"
    let first = model.load()
    await service.wait(1); service.finish(0, [file("old")], folders: [folder]); await first.value
    model.selection = ["old"]
    let refresh = model.load()
    await service.wait(2); service.fail(1); await refresh.value
    #expect(model.selection == ["old"] && model.files.map(\.id) == ["old"] && model.folders.map(\.id) == ["folder"])
    let retry = model.load()
    await service.wait(3); service.finish(2, [file("new")], folders: [folder]); await retry.value
    #expect(model.selection == ["new"] && model.files.map(\.id) == ["new"] && model.error == nil)
  }

  @Test func selectionChangedDuringRefreshUsesLatestChoiceAndAmbiguousMatchesAreDropped() async {
    let service = GroupFilesReplies(), model: MacGroupFilesViewModel
    model = MacGroupFilesViewModel(service: service)
    let first = model.load()
    await service.wait(1); service.finish(0, [file("a", name: "a"), file("b", name: "b")]); await first.value
    model.selection = ["a"]
    let refresh = model.load()
    await service.wait(2)
    model.selection = ["b"]
    service.finish(1, [file("new-a", name: "a"), file("new-b", name: "b")]); await refresh.value
    #expect(model.selection == ["new-b"])
    let ambiguous = model.load()
    await service.wait(3)
    service.finish(2, [file("b1", name: "b"), file("b2", name: "b")]); await ambiguous.value
    #expect(model.selection.isEmpty)
  }

  @Test func overlappingRequestsShareOneLoadAndCancelledOldSuccessCannotReplaceNewSelection() async {
    let service = GroupFilesReplies(), model: MacGroupFilesViewModel
    model = MacGroupFilesViewModel(service: service)
    let old = model.load(), duplicate = model.load()
    await service.wait(1)
    model.cancel()
    #expect(!model.isLoading)
    let new = model.load()
    await service.wait(2); service.finish(1, [file("new")]); await new.value
    model.selection = ["new"]
    service.finish(0, [file("old")]); await old.value; await duplicate.value
    #expect(model.files.map(\.id) == ["new"] && model.selection == ["new"] && model.error == nil)
  }

  @Test func cancelledOldFailureDoesNotHideSuccessfulReload() async {
    let service = GroupFilesReplies(), model: MacGroupFilesViewModel
    model = MacGroupFilesViewModel(service: service)
    let old = model.load()
    await service.wait(1); model.cancel()
    let new = model.load()
    await service.wait(2); service.finish(1, [file("new")]); await new.value
    service.fail(0); await old.value
    #expect(model.error == nil && model.hasLoaded && !model.isLoading && model.files.map(\.id) == ["new"])
  }
}
