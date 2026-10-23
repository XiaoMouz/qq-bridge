import Foundation
import Observation
import QQBridgeKit
import Synchronization

@MainActor
@Observable
final class MacDownloads {
  static let shared = MacDownloads()
  private static let directoryKey = "mac.downloadDirectory"
  private static let filesKey = "mac.downloadedFiles"
  private var bookmark: Data?
  private var files: [String: SavedFile]
  private var inFlight: [String: Task<URL, Error>] = [:]
  /// 正在下载的进度（0...1），按 sha256。聊天里的文件气泡显示百分比：
  /// 2026-10-23 实测服务端那台 Mac 内存吃紧（大量换页）时 59 MB 的文件只有约 100 KB/s，没有进度看起来像点了没反应。
  private(set) var progress: [String: Double] = [:]
  // Quick Look 和分享面板会在调用返回后继续读取文件，目录授权保持到进程结束。
  // 按目录去重，避免每打开一份文件就增加一个安全作用域。
  private var accessedDirectories: [String: URL] = [:]

  private struct SavedFile: Codable {
    var name: String
    var directory: Data?
  }

  private init() {
    bookmark = UserDefaults.standard.data(forKey: Self.directoryKey)
    files = UserDefaults.standard.data(forKey: Self.filesKey).flatMap { try? JSONDecoder().decode([String: SavedFile].self, from: $0) } ?? [:]
  }

  var usesDefaultDirectory: Bool { bookmark == nil }
  var directoryPath: String { (try? directory(bookmark).path) ?? "目录不可用，请重新选择" }

  private func directory(_ bookmark: Data?) throws -> URL {
    guard let bookmark else {
      return try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false).resolvingSymlinksInPath()
    }
    var stale = false
    let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
    if accessedDirectories[url.path] == nil {
      guard url.startAccessingSecurityScopedResource() else {
        throw DownloadError.directoryUnavailable
      }
      accessedDirectories[url.path] = url
    }
    return url
  }

  func selectDirectory(_ url: URL) throws {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw DownloadError.directoryUnavailable }
    let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    _ = try directory(data)
    bookmark = data
    UserDefaults.standard.set(data, forKey: Self.directoryKey)
  }

  func useDownloadsDirectory() {
    bookmark = nil
    UserDefaults.standard.removeObject(forKey: Self.directoryKey)
  }

  func savedURL(for sha: String) -> URL? {
    guard let record = files[sha], let root = try? directory(record.directory) else { return nil }
    let url = root.appendingPathComponent(record.name)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  func savedSet(_ shas: [String]) -> Set<String> { Set(shas.filter { savedURL(for: $0) != nil }) }

  /// 图片查看器也遵循下载目录设置；本地导出不登记成服务端媒体缓存。
  func export(_ source: URL, name: String) async throws -> URL {
    let destination = try directory(bookmark)
    let filename = MacDownloadFiles.safeName(name, fallback: "BetterChat-\(UUID().uuidString)")
    return try await Task.detached(priority: .utility) {
      try MacDownloadFiles.save(source, name: filename, to: destination)
    }.value
  }

  func file(sha: String, name: String, session: Session) async throws -> URL {
    guard sha.count == 64, sha.allSatisfy({ $0.isHexDigit }) else { throw DownloadError.invalidFile }
    if let saved = savedURL(for: sha) { return saved }
    if let running = inFlight[sha] { return try await running.value }
    // 下载开始时固定目标，过程中更改设置只影响后续下载。
    let targetBookmark = bookmark
    let destination = try directory(targetBookmark)
    guard FileManager.default.isWritableFile(atPath: destination.path) else { throw DownloadError.directoryUnavailable }
    let filename = MacDownloadFiles.safeName(name, fallback: sha)
    let work = Task {
      let cached = try await session.media.cachedFile(sha)
      let source: URL
      if let cached { source = cached }
      else {
        guard let signed = try await session.api.sign([sha])[sha] else { throw DownloadError.invalidFile }
        // 进度是异步送回来的，下载结束后才到的不再记（否则会一直显示「下载中」）。
        source = try await Self.download(signed.url) { [weak self] p in
          guard let self, self.inFlight[sha] != nil else { return }
          self.progress[sha] = p
        }
      }
      defer { if cached == nil { try? FileManager.default.removeItem(at: source) } }
      let saved = try await Task.detached(priority: .utility) {
        try MacDownloadFiles.verify(source, sha256: sha)
        return try MacDownloadFiles.save(source, name: filename, to: destination)
      }.value
      files[sha] = SavedFile(name: saved.lastPathComponent, directory: targetBookmark)
      UserDefaults.standard.set(try JSONEncoder().encode(files), forKey: Self.filesKey)
      return saved
    }
    inFlight[sha] = work
    progress[sha] = 0
    defer {
      inFlight[sha] = nil
      progress[sha] = nil
    }
    return try await work.value
  }

  /// 下到临时文件，边下边报进度（每过 1% 报一次，主线程上）。
  /// 2026-10-23 实测：传给 async 版 download(from:delegate:) 的任务代理收不到 didWriteData，进度一直是 0；
  /// 改用 downloadTask 并观察它的 progress。
  private static func download(_ url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
    let running = Mutex<(task: URLSessionDownloadTask, observation: NSKeyValueObservation)?>(nil)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
        let task = URLSession.shared.downloadTask(with: url) { file, response, error in
          running.withLock { $0?.observation.invalidate() }
          if let error { continuation.resume(throwing: error); return }
          guard let file, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            continuation.resume(throwing: MediaCacheError.http((response as? HTTPURLResponse)?.statusCode ?? 0))
            return
          }
          // 系统给的临时文件在回调返回后会被删，先挪走。
          let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
          do {
            try FileManager.default.moveItem(at: file, to: kept)
            continuation.resume(returning: kept)
          } catch {
            continuation.resume(throwing: error)
          }
        }
        let reporter = ProgressReporter(progress)
        let observation = task.progress.observe(\.fractionCompleted) { p, _ in reporter.update(p.fractionCompleted) }
        running.withLock { $0 = (task, observation) }
        task.resume()
      }
    } onCancel: {
      running.withLock { $0?.task.cancel() }
    }
  }

  /// 在访达里选中这个文件。Catalyst 没有 NSWorkspace 的 Swift 接口，从运行时取。
  static func reveal(_ url: URL) {
    guard let workspace = (NSClassFromString("NSWorkspace") as AnyObject?)?
      .perform(NSSelectorFromString("sharedWorkspace"))?.takeUnretainedValue() as? NSObject else { return }
    workspace.perform(NSSelectorFromString("activateFileViewerSelectingURLs:"), with: [url])
  }

  func trash(_ shas: [String]) throws {
    for sha in shas {
      guard let url = savedURL(for: sha) else { continue }
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
      files.removeValue(forKey: sha)
    }
    UserDefaults.standard.set(try JSONEncoder().encode(files), forKey: Self.filesKey)
  }

  enum DownloadError: LocalizedError {
    case directoryUnavailable, invalidFile
    var errorDescription: String? {
      switch self {
      case .directoryUnavailable: "下载目录不可访问或不可写，请在设置中重新选择目录。"
      case .invalidFile: "暂时无法下载这个文件，请稍后重试。"
      }
    }
  }
}

/// 下载进度可能从任意线程来，只把整百分比的变化送回主线程。
private final class ProgressReporter: Sendable {
  private let report: @MainActor (Double) -> Void
  private let last = Mutex(-1)

  init(_ report: @escaping @MainActor (Double) -> Void) { self.report = report }

  func update(_ fraction: Double) {
    let percent = Int(fraction * 100)
    guard last.withLock({ old in defer { old = percent }; return old != percent }) else { return }
    let report = report
    Task { @MainActor in report(Double(percent) / 100) }
  }
}
