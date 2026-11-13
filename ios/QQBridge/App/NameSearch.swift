// 名字匹配：原文包含，或者用拼音 / 首字母找中文名字（「zhangsan」「zs」都能找到「张三」）。
// 2026-11-13 用户要求搜索支持拼音、首字母。会话、联系人、选人、选会话的本地匹配都用这里；
// 群成员在服务端找（ContactService.SearchPeople，同样的规则）。
import Foundation
import QQBridgeProto

enum NameSearch {
  private struct Keys { let full: String; let initials: String }
  /// 名字不多（会话、好友几千个），转一次缓存起来；只在主线程用。
  nonisolated(unsafe) private static var cache: [String: Keys] = [:]
  private static let lock = NSLock()

  /// 搜索词规范化：去空格、小写。
  static func normalize(_ query: String) -> String {
    query.lowercased().filter { !$0.isWhitespace }
  }

  /// name 是否匹配 query（query 先 normalize）。
  static func matches(_ name: String, _ query: String) -> Bool {
    let q = normalize(query)
    guard !q.isEmpty, !name.isEmpty else { return false }
    let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.localizedCaseInsensitiveContains(raw) || name.localizedCaseInsensitiveContains(q) { return true }
    // 拼音只认字母和数字；带中文的搜索词上面已经按原文比过了。
    guard q.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
    let keys = keys(name)
    if keys.full.contains(q) { return true }
    // 单个字母按首字母只从开头算，免得「x」把一大堆名字都带出来。
    return q.count >= 2 ? keys.initials.contains(q) : keys.initials.hasPrefix(q)
  }

  static func matches(_ names: [String], _ query: String) -> Bool {
    names.contains { matches($0, query) }
  }

  private static func keys(_ name: String) -> Keys {
    lock.lock()
    if let k = cache[name] { lock.unlock(); return k }
    lock.unlock()
    // mandarinToLatin 把每个汉字转成带声调的拼音、字之间加空格；非中文部分原样保留。
    let latin = (name.applyingTransform(.mandarinToLatin, reverse: false) ?? name)
      .applyingTransform(.stripDiacritics, reverse: false) ?? name
    let parts = latin.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let k = Keys(full: parts.joined(), initials: String(parts.compactMap(\.first)))
    lock.lock()
    if cache.count > 20_000 { cache.removeAll() }
    cache[name] = k
    lock.unlock()
    return k
  }
}

extension Qqbridge_V1_Peer {
  /// 联系人按备注、名字、号码匹配（名字支持拼音）。
  func matchesSearch(_ query: String) -> Bool {
    NameSearch.matches([remark, name], query) || String(peerID).contains(NameSearch.normalize(query))
  }
}
