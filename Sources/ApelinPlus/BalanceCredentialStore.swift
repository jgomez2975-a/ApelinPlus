import Foundation
import Security

// MARK: - Credential

/// What a balance query needs beyond the endpoint and the model key.
///
/// New-API and One-API relay balance is not readable with the `sk-` model
/// key: `/api/user/self` wants the site's own session token plus the
/// numeric user id, both of which the user copies from the site's console.
/// DeepSeek, OpenRouter and OpenAI take the model key itself, so they need
/// nothing here.
///
/// Kept apart from `BalanceSettings` on purpose: settings are written to a
/// JSON file the user can read, and a session token must not be.
public struct BalanceCredential: Codable, Sendable, Equatable {
    /// The site's access token, sent as `Authorization: Bearer`.
    public var accessToken: String?
    /// The site's numeric user id, sent as `New-Api-User`.
    public var userID: String?

    public init(accessToken: String? = nil, userID: String? = nil) {
        self.accessToken = accessToken
        self.userID = userID
    }

    public var isEmpty: Bool {
        (accessToken ?? "").isEmpty && (userID ?? "").isEmpty
    }
}

// MARK: - Store

/// Balance credentials in the keychain, one item per instance.
///
/// Service `wiki.qaq.apelin.balance`, account = the instance's UUID, so an
/// item is removed with the instance that owns it and nothing has to be
/// enumerated to keep the two in step.
public struct BalanceCredentialStore: Sendable {
    public enum Failure: Error, LocalizedError {
        case status(OSStatus)

        public var errorDescription: String? {
            switch self {
            case let .status(code): "The keychain refused the request (\(code))."
            }
        }
    }

    private let service: String

    public init(service: String = "wiki.qaq.apelin.balance") {
        self.service = service
    }

    // MARK: Read

    public func credential(for instanceID: UUID) throws -> BalanceCredential? {
        var query = baseQuery(instanceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return try? JSONDecoder().decode(BalanceCredential.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.status(status)
        }
    }

    // MARK: Write

    /// Replaces whatever was stored. An empty credential removes the item
    /// instead of storing a blank one.
    public func setCredential(_ credential: BalanceCredential, for instanceID: UUID) throws {
        if credential.isEmpty {
            try remove(instanceID)
            return
        }
        let data = try JSONEncoder().encode(credential)
        var query = baseQuery(instanceID)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let updateStatus = SecItemUpdate(baseQuery(instanceID) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw Failure.status(updateStatus) }
        default:
            throw Failure.status(status)
        }
    }

    public func remove(_ instanceID: UUID) throws {
        let status = SecItemDelete(baseQuery(instanceID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.status(status)
        }
    }

    // MARK: Query

    private func baseQuery(_ instanceID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: instanceID.uuidString,
        ]
    }
}
