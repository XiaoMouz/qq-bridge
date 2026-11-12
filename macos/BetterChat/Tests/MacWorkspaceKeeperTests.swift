import Testing
import UIKit
@testable import BetterChat

@MainActor
private final class FakeWorkspace: MacKeptWorkspace {
  var tornDown = 0
  func tearDown() { tornDown += 1 }
}

/// 代表右栏聊天页：带一个滚动视图，检查重开窗口后滚动位置还在。
@MainActor
private final class ScrollingPage: UIViewController {
  let scroll = UIScrollView()
  override func loadView() {
    scroll.contentSize = CGSize(width: 400, height: 5000)
    view = scroll
  }
}

/// ⌘W 关掉主窗口再重开（2026-11-12 用户反馈丢了消息位置、先闪占位页）：工作区不随窗口释放，新窗口接回同一个根控制器。
@Suite(.serialized)
@MainActor
struct MacWorkspaceKeeperTests {
  @Test func sameSessionReusesWorkspaceUntilLogout() {
    let keeper = MacWorkspaceKeeper<FakeWorkspace>()
    let session = NSObject()
    var made = 0
    let first = keeper.coordinator(for: session) { made += 1; return FakeWorkspace() }
    let reopened = keeper.coordinator(for: session) { made += 1; return FakeWorkspace() }
    #expect(first === reopened && made == 1 && first.tornDown == 0)

    // 换了账号（新的 Session）：旧工作区拆掉，再建新的。
    let other = keeper.coordinator(for: NSObject()) { made += 1; return FakeWorkspace() }
    #expect(other !== first && made == 2 && first.tornDown == 1)

    keeper.discard()
    #expect(other.tornDown == 1 && keeper.coordinator == nil)
  }

  @Test func reopenedWindowAdoptsKeptPageWithScrollPosition() throws {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let page = ScrollingPage()

    var closed: UIWindow? = UIWindow(windowScene: scene)
    weak var firstHost: MacWorkspaceWindowHost?
    do {
      let host = MacWorkspaceWindowHost(content: page)
      firstHost = host
      closed?.rootViewController = host
      closed?.makeKeyAndVisible()
      host.view.layoutIfNeeded()
    }
    page.scroll.contentOffset = CGPoint(x: 0, y: 1234)
    #expect(page.view.window === closed)

    // 新窗口先建好、接回页面，旧窗口这时还没释放（实际的关窗顺序不保证）。
    let reopened = UIWindow(windowScene: scene)
    let secondHost = MacWorkspaceWindowHost(content: page)
    reopened.rootViewController = secondHost
    reopened.makeKeyAndVisible()
    secondHost.view.layoutIfNeeded()
    #expect(page.parent === secondHost)
    #expect(page.view.window === reopened)
    #expect(firstHost?.children.isEmpty ?? true)

    // 旧窗口这时才释放：页面不能被它带走。
    closed?.isHidden = true
    closed?.rootViewController = nil
    closed = nil
    #expect(page.parent === secondHost && page.view.window === reopened)
    #expect(page.scroll.contentOffset.y == 1234)

    reopened.isHidden = true
    reopened.rootViewController = nil
  }
}
