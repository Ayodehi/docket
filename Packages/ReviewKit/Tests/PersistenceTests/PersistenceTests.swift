import Foundation
import Testing
@testable import Persistence

@Suite struct KeychainStoreTests {
    @Test func saveLoadReplaceDelete() throws {
        let store = KeychainStore(service: "Docket.tests.\(UUID().uuidString)")
        defer { try? store.deleteAll() }

        #expect(try store.load() == nil)
        try store.save(token: "fake-token-1", account: "you")
        #expect(try store.load() == Credential(account: "you", token: "fake-token-1"))

        try store.save(token: "fake-token-2", account: "you-again")
        #expect(try store.load() == Credential(account: "you-again", token: "fake-token-2"))

        try store.deleteAll()
        #expect(try store.load() == nil)
        try store.deleteAll()
    }
}

@Suite struct FileStoreTests {
    private func tempStore() -> FileStore {
        FileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("DocketTests-\(UUID().uuidString)"))
    }

    @Test func roundTripWithUserOnlyPermissions() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        #expect(try store.load([String].self, from: "x.json") == nil)
        try store.save(["a", "b"], as: "x.json")
        #expect(try store.load([String].self, from: "x.json") == ["a", "b"])

        let file = try FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent("x.json").path)
        let dir = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        #expect((file[.posixPermissions] as? Int) == 0o600)
        #expect((dir[.posixPermissions] as? Int) == 0o700)

        try store.removeAll()
        #expect(try store.load([String].self, from: "x.json") == nil)
    }
}

@Suite struct SettingsStoreTests {
    @Test func codableValues() throws {
        let suite = "DocketTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)

        #expect(store.value([String: Int].self, forKey: "k") == nil)
        store.set(["a": 1], forKey: "k")
        #expect(store.value([String: Int].self, forKey: "k") == ["a": 1])
        store.set(Optional<[String: Int]>.none, forKey: "k")
        #expect(store.value([String: Int].self, forKey: "k") == nil)
    }
}
