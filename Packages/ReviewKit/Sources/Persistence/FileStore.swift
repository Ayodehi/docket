import Foundation

/// JSON files in a user-only folder, written atomically. Used for the PR cache, the
/// notification ledger, and snoozes in `~/Library/Application Support/Docket/`.
public struct FileStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func applicationSupport(folder: String = "Docket") throws -> FileStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return FileStore(directory: base.appendingPathComponent(folder, isDirectory: true))
    }

    public func save<T: Encodable>(_ value: T, as name: String, encoder: JSONEncoder = JSONEncoder()) throws {
        try ensureDirectory()
        let url = fileURL(name)
        try encoder.encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Returns `nil` when the file does not exist. Throws when it exists but cannot be decoded.
    public func load<T: Decodable>(_ type: T.Type, from name: String, decoder: JSONDecoder = JSONDecoder()) throws -> T? {
        let url = fileURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    public func remove(_ name: String) throws {
        let url = fileURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Deletes every file in the folder ("Clear cache" and sign out).
    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(_ name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: false)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
