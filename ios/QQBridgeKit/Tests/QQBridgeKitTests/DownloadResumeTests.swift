import Foundation
import Testing

@testable import QQBridgeKit

/// 弱网续传：本机起一个和媒体端点一样回 ETag、支持 Range 的服务，第一次传到一半就断开，
/// 下载器应从断点续上，而不是从头再下。
@Suite struct DownloadResumeTests {
  /// 第一次请求只发前一半就关连接；之后按 Range 正常发。记录每次请求的 Range 头。
  static let server = #"""
  import http.server, socketserver, sys, os
  body = bytes(range(256)) * 4096  # 1 MiB
  log = open(sys.argv[2], 'a', buffering=1)
  state = {'n': 0}
  class H(http.server.BaseHTTPRequestHandler):
      protocol_version = 'HTTP/1.1'
      def log_message(self, *a): pass
      def do_GET(self):
          state['n'] += 1
          rng = self.headers.get('Range')
          log.write(f"{state['n']} {rng}\n")
          start = int(rng.split('=')[1].split('-')[0]) if rng else 0
          self.send_response(206 if rng else 200)
          self.send_header('ETag', '"abc"')
          self.send_header('Accept-Ranges', 'bytes')
          self.send_header('Content-Length', str(len(body) - start))
          if rng: self.send_header('Content-Range', f'bytes {start}-{len(body)-1}/{len(body)}')
          self.end_headers()
          if state['n'] == 1:
              self.wfile.write(body[:len(body)//2]); self.wfile.flush()
              self.connection.shutdown(2); self.close_connection = True
              return
          self.wfile.write(body[start:])
  srv = socketserver.TCPServer(('127.0.0.1', 0), H)
  open(sys.argv[1], 'w').write(str(srv.server_address[1]))
  srv.serve_forever()
  """#

  @Test func resumesFromBreakPointAfterConnectionDrops() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let script = dir.appendingPathComponent("server.py"), portFile = dir.appendingPathComponent("port"),
      logFile = dir.appendingPathComponent("log")
    try Self.server.write(to: script, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-I", script.path, portFile.path, logFile.path]
    try process.run()
    defer { process.terminate() }
    var port = ""
    for _ in 0..<100 where port.isEmpty {
      try await Task.sleep(for: .milliseconds(50))
      port = (try? String(contentsOf: portFile, encoding: .utf8)) ?? ""
    }
    let session = URLSession(configuration: .ephemeral)
    let file = try await URLSessionDownloader(session: session).download(URL(string: "http://127.0.0.1:\(port)/media/x")!)
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(try Data(contentsOf: file) == Data(Array(0...255).map(UInt8.init)) * 4096)
    let requests = try String(contentsOf: logFile, encoding: .utf8).split(separator: "\n")
    #expect(requests.count == 2)
    // 第二次带 Range 从中间某处续，不是从 0 开始。
    #expect(requests.last?.contains("bytes=") == true)
    #expect(requests.last?.contains("bytes=0-") == false)
  }
}

private func * (data: Data, n: Int) -> Data {
  var out = Data(capacity: data.count * n)
  for _ in 0..<n { out.append(data) }
  return out
}
