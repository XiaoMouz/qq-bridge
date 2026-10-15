import QQBridgeKit
import QQBridgeProto
import Foundation

enum MacStorageFailure {
  static func describe(_ error: Error) -> String {
    if (error as? URLError)?.code == .timedOut || (error as? APIError)?.code == .deadlineExceeded {
      return "加载超时，请重试"
    }
    if let error = error as? URLError,
       [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost].contains(error.code) {
      return "连接不可用，请检查网络后重试"
    }
    return LoadState.describe(error)
  }
}

struct MacStorageItemsPage {
  let items: [StorageItemModel]
  let more: Bool
}

struct MacStorageOpenedFile {
  let url: URL
  let temporary: Bool
  func removeIfTemporary() { if temporary { try? FileManager.default.removeItem(at: url) } }
}

@MainActor protocol MacStorageFileService {
  func file(for item: StorageItemModel) async throws -> MacStorageOpenedFile
}

struct MacSessionStorageFileService: MacStorageFileService {
  let session: Session
  func file(for item: StorageItemModel) async throws -> MacStorageOpenedFile {
    let name = MacDownloadFiles.safeName(item.name ?? "", fallback: "\(item.sha256.prefix(12)).\(item.fileExtension)")
    if item.group == .file {
      let url = try await MacDownloads.shared.file(sha: item.sha256, name: name, session: session)
      return MacStorageOpenedFile(url: url, temporary: false)
    }
    let source = try await session.media.file(for: item.sha256, chatId: item.chatId)
    try Task.checkCancellation()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StoragePreview", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = try await Task.detached(priority: .utility) {
      try MacDownloadFiles.save(source, name: name, to: directory)
    }.value
    return MacStorageOpenedFile(url: url, temporary: true)
  }
}

@MainActor
protocol MacStorageItemsService {
  func page(offset: UInt32) async throws -> MacStorageItemsPage
}

struct MacSessionStorageItemsService: MacStorageItemsService {
  let session: Session
  let source: StorageChatsView.Source
  let group: StorageGroup
  let chatID: Int64?

  func page(offset: UInt32) async throws -> MacStorageItemsPage {
    switch source {
    case .local:
      let store = session.store, chatID = chatID, kinds = group.localKinds
      let items = try await Task.detached(priority: .utility) {
        try store.cacheItems(chatId: chatID, kinds: kinds, limit: 61, offset: Int(offset))
      }.value
      return MacStorageItemsPage(items: items.prefix(60).map(StorageItemModel.init(local:)), more: items.count > 60)
    case .server:
      var request = Qqbridge_V1_ListStorageItemsRequest()
      request.chatID = chatID ?? 0
      request.categories = group.serverCategories
      request.offset = offset
      request.limit = 60
      let response = try await session.api.media.listStorageItems(request: request, headers: session.api.headers).get()
      return MacStorageItemsPage(items: response.items.map(StorageItemModel.init(server:)), more: response.more)
    }
  }
}
