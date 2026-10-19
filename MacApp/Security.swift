import CryptoKit
import Foundation
import Security

struct DeviceIdentity {
    let id: String
    let signingKey: Curve25519.Signing.PrivateKey
    let agreementKey: Curve25519.KeyAgreement.PrivateKey

    init() {
        signingKey = Self.loadOrCreate("signing-key") { Curve25519.Signing.PrivateKey() }
        agreementKey = Self.loadOrCreate("agreement-key") { Curve25519.KeyAgreement.PrivateKey() }
        id = Self.routeID(for: signingKey.publicKey.rawRepresentation)
    }

    init(signingKey: Curve25519.Signing.PrivateKey, agreementKey: Curve25519.KeyAgreement.PrivateKey) {
        self.signingKey = signingKey
        self.agreementKey = agreementKey
        id = Self.routeID(for: signingKey.publicKey.rawRepresentation)
    }

    var signingPublicKey: Data { signingKey.publicKey.rawRepresentation }
    var agreementPublicKey: Data { agreementKey.publicKey.rawRepresentation }
    var invitationCode: String {
        ["privatecat", id, agreementPublicKey.base64URL, signingPublicKey.base64URL].joined(separator: ":")
    }

    func sign(_ challenge: Data) throws -> Data { try signingKey.signature(for: challenge) }

    func seal(_ plaintext: Data, for peerID: String, peerPublicKey: Data) throws -> Data {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let secret = try agreementKey.sharedSecretFromKeyAgreement(with: peer)
        let key = messageKey(secret: secret, otherID: peerID)
        return try ChaChaPoly.seal(plaintext, using: key).combined
    }

    func open(_ ciphertext: Data, from peerID: String, peerPublicKey: Data) throws -> Data {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let secret = try agreementKey.sharedSecretFromKeyAgreement(with: peer)
        let key = messageKey(secret: secret, otherID: peerID)
        return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: ciphertext), using: key)
    }

    static func parseInvitation(_ code: String) throws -> (id: String, agreementKey: Data, signingKey: Data) {
        let fields = code.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", maxSplits: 3)
        guard fields.count == 4, fields[0] == "privatecat",
              let agreement = Data(base64URL: String(fields[2])), agreement.count == 32,
              let signing = Data(base64URL: String(fields[3])), signing.count == 32,
              routeID(for: signing) == fields[1] else { throw InvitationError.invalidCode }
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreement)
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: signing)
        return (String(fields[1]), agreement, signing)
    }

    static func routeID(for signingPublicKey: Data) -> String {
        Data(SHA256.hash(data: signingPublicKey)).base64URL
    }

    private func messageKey(secret: SharedSecret, otherID: String) -> SymmetricKey {
        let identities = [id, otherID].sorted().joined(separator: ":")
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(),
                                              sharedInfo: Data("PrivateCat v1:\(identities)".utf8),
                                              outputByteCount: 32)
    }

    private static func loadOrCreate(_ account: String, create: () -> Curve25519.Signing.PrivateKey) -> Curve25519.Signing.PrivateKey {
        if let bytes = keychainData(account: account), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes) { return key }
        let key = create()
        saveKeychainData(Data(key.rawRepresentation), account: account)
        return key
    }

    private static func loadOrCreate(_ account: String, create: () -> Curve25519.KeyAgreement.PrivateKey) -> Curve25519.KeyAgreement.PrivateKey {
        if let bytes = keychainData(account: account), let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes) { return key }
        let key = create()
        saveKeychainData(key.rawRepresentation, account: account)
        return key
    }

    private static func keychainData(account: String) -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: "PrivateCat",
                                          kSecAttrAccount: account, kSecReturnData: true,
                                          kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        return status == errSecSuccess ? result as? Data : nil
    }

    private static func saveKeychainData(_ data: Data, account: String) {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: "PrivateCat", kSecAttrAccount: account] as CFDictionary
        SecItemDelete(query)
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: "PrivateCat",
                    kSecAttrAccount: account, kSecValueData: data] as CFDictionary, nil)
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL value: String) {
        let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: padded)
    }
}

enum InvitationError: LocalizedError {
    case invalidCode
    var errorDescription: String? { "초대 코드가 올바르지 않습니다." }
}
