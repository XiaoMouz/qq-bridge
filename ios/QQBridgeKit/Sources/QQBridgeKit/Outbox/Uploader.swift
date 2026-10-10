// 上传媒体（docs/design.md 4.6"上传秒传"）：先算 sha256 问服务端有没有，有就直接用（秒传）；
// 没有就按 tus 1.0 核心协议上传：PATCH 从 Upload-Offset 续传，断了用 HEAD 查进度接着传。
import CryptoKit
import Foundation
import QQBridgeProto

public struct UploadedMedia: Sendable, Equatable {
  public let sha256: String
  public let size: Int64
  /// 服务端已有，没传。
  public let instant: Bool
}

public enum UploadError: Error, Equatable {
  case server(Int)
  case badResponse
}

extension APIClient {
  /// 上传一段数据（图片、语音等），返回服务端里的 sha256。
  public func upload(_ data: Data, mime: String, name: String = "", chunkSize: Int = 1 << 20) async throws -> UploadedMedia {
    let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    var req = Qqbridge_V1_PrepareUploadRequest()
    req.sha256 = sha
    req.size = UInt64(data.count)
    req.mime = mime
    req.name = name
    let prepared = try await media.prepareUpload(request: req, headers: headers).get()
    if prepared.exists { return UploadedMedia(sha256: sha, size: Int64(data.count), instant: true) }
    guard let url = URL(string: prepared.uploadURL, relativeTo: config.baseURL)?.absoluteURL else { throw UploadError.badResponse }

    var offset = Int(prepared.offset)
    var attempts = 0
    while offset < data.count {
      var patch = URLRequest(url: url)
      patch.httpMethod = "PATCH"
      patch.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
      patch.setValue("1.0.0", forHTTPHeaderField: "tus-resumable")
      patch.setValue("application/offset+octet-stream", forHTTPHeaderField: "content-type")
      patch.setValue(String(offset), forHTTPHeaderField: "upload-offset")
      let end = min(offset + chunkSize, data.count)
      do {
        let (_, response) = try await URLSession.shared.upload(for: patch, from: data.subdata(in: offset..<end))
        guard let http = response as? HTTPURLResponse else { throw UploadError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw UploadError.server(http.statusCode) }
        offset = Int(http.value(forHTTPHeaderField: "upload-offset") ?? "") ?? end
        attempts = 0
      } catch {
        // 网络断了：查一下服务端收到了多少，接着传（最多连续失败 3 次）。
        attempts += 1
        if attempts > 3 { throw error }
        try await Task.sleep(for: .seconds(attempts))
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        head.setValue("1.0.0", forHTTPHeaderField: "tus-resumable")
        if let (_, r) = try? await URLSession.shared.data(for: head), let h = r as? HTTPURLResponse,
          let o = Int(h.value(forHTTPHeaderField: "upload-offset") ?? "")
        {
          offset = o
        }
      }
    }
    return UploadedMedia(sha256: sha, size: Int64(data.count), instant: false)
  }

  /// 标记已读到 maxSeq（服务端会回写 QQ，并同步到其他设备）。
  @discardableResult
  public func markRead(chatId: Int64, maxSeq: Int64) async throws -> Bool {
    var req = Qqbridge_V1_MarkReadRequest()
    req.chatID = chatId
    req.maxSeq = maxSeq
    return try await dialogs.markRead(request: req, headers: headers).get().changed
  }
}
