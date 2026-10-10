import QQBridgeKit
import SwiftUI

struct LoginView: View {
  @Environment(AppModel.self) private var model
  static let tailscale = "xiaomouzs-huawei-mate-mini.tail7bb0fe.ts.net"
  #if targetEnvironment(simulator)
    @AppStorage("server") private var server = "127.0.0.1:8080"
  #else
    @AppStorage("server") private var server = LoginView.tailscale
  #endif
  @State private var username = "owner"
  @State private var password = ""
  @State private var busy = false
  @State private var error: String?
  @State private var reachability: String = ""

  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack {
            TextField("例如 127.0.0.1:8080", text: $server)
              .keyboardType(.asciiCapable)
              .textContentType(.URL)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            Menu {
              Button("本机（模拟器）") { server = "127.0.0.1:8080" }
              Button("Tailscale") { server = Self.tailscale }
            } label: {
              Image(systemName: "list.bullet")
            }
          }
        } header: {
          Text("服务器")
        } footer: {
          VStack(alignment: .leading, spacing: 4) {
            Text("实际连接：\(AppModel.normalize(server)?.absoluteString ?? "地址不对")")
            Text(reachability)
          }
        }
        .task(id: server) { await checkServer() }
        Section("账号") {
          TextField("用户名", text: $username)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          SecureField("密码", text: $password)
            .textContentType(.password)
            .onSubmit(login)
        }
        if let error {
          Section { Text(error).foregroundStyle(.red) }
        }
        Section {
          Button(action: login) {
            HStack {
              Spacer()
              if busy { ProgressView() } else { Text("登录").bold() }
              Spacer()
            }
          }
          .disabled(busy || username.isEmpty || password.isEmpty)
        }
      }
      .navigationTitle("QQ Bridge")
      .onAppear {
        if server.trimmingCharacters(in: .whitespaces).isEmpty {
          #if targetEnvironment(simulator)
            server = "127.0.0.1:8080"
          #else
            server = Self.tailscale
          #endif
        }
      }
    }
  }

  /// 不登录也能测服务器通不通：随便调一个要登录的接口，回"未登录"就说明连上了。
  private func checkServer() async {
    guard let url = AppModel.normalize(server) else {
      reachability = ""
      return
    }
    reachability = "正在检查…"
    try? await Task.sleep(for: .milliseconds(400))  // 输入时别每个字都发请求
    if Task.isCancelled { return }
    var req = URLRequest(url: url.appending(path: "healthz"), timeoutInterval: 5)
    req.httpMethod = "GET"
    do {
      let (_, response) = try await URLSession.shared.data(for: req)
      let ok = (response as? HTTPURLResponse)?.statusCode == 200
      reachability = ok ? "✓ 服务器连得上" : "✗ 地址能连上，但不是 QQ Bridge 服务器"
    } catch {
      if !Task.isCancelled { reachability = "✗ 连不上：\(error.localizedDescription)" }
    }
  }

  private func login() {
    busy = true
    error = nil
    Task {
      defer { busy = false }
      do {
        try await model.login(server: server, username: username, password: password)
      } catch let e as APIError where e.isUnauthenticated {
        self.error = "用户名或密码不对"
      } catch let e as APIError {
        self.error = "登录失败：\(e.message)"
      } catch {
        self.error = "连不上服务器：\(error.localizedDescription)"
      }
    }
  }
}
