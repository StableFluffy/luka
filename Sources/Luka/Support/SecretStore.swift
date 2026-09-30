import CryptoKit
import Foundation
import IOKit

/// Keeps the API key AES-GCM encrypted in Application Support, without the Keychain.
/// The key is derived from a random per-install salt and this Mac's hardware UUID,
/// so the file is useless when copied elsewhere.
enum SecretStore {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Luka", isDirectory: true)
    }
    private static var secretURL: URL { directory.appendingPathComponent("credentials") }
    private static var saltURL: URL { directory.appendingPathComponent("salt") }

    static func read() -> String? {
        guard let blob = try? Data(contentsOf: secretURL), let salt = try? Data(contentsOf: saltURL),
              let box = try? AES.GCM.SealedBox(combined: blob),
              let plain = try? AES.GCM.open(box, using: key(salt: salt)) else { return nil }
        let value = String(decoding: plain, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    static func save(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let fm = FileManager.default
        guard !trimmed.isEmpty else {
            try? fm.removeItem(at: secretURL)
            return
        }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let salt = (try? Data(contentsOf: saltURL)) ?? {
            let fresh = Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
            write(fresh, to: saltURL)
            return fresh
        }()
        guard let sealed = try? AES.GCM.seal(Data(trimmed.utf8), using: key(salt: salt)).combined else { return }
        write(sealed, to: secretURL)
    }

    private static func write(_ data: Data, to url: URL) {
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func key(salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(machineID.utf8)), salt: salt,
                               info: Data("luka.api-key".utf8), outputByteCount: 32)
    }

    private static let machineID: String = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        return uuid ?? NSUserName()
    }()
}
