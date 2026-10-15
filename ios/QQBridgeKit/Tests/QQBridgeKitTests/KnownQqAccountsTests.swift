import QQBridgeProto
import Testing
@testable import QQBridgeKit

struct KnownQqAccountsTests {
  @Test func keptCacheRemembersQqAccountsUntilForgotten() throws {
    let store = try LocalStore.inMemory()
    var a = Qqbridge_V1_QqAccountInfo()
    a.id = 1
    a.uin = 1114096791
    try store.setQqAccounts([a])
    // 同步时服务端要求重来（tooLong）也会 reset，那时记着的号不能跟着丢。
    try store.reset()
    #expect(try store.knownQqAccounts() == [1: 1114096791])
    try store.forgetQqAccounts()
    #expect(try store.knownQqAccounts().isEmpty)
    #expect(try store.selfUin(qqAccountId: 1) == 0)
  }
}
