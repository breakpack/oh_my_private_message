import CryptoKit
import Foundation

@main struct CryptoSelfCheck {
    static func main() throws {
        let alice = DeviceIdentity(signingKey: Curve25519.Signing.PrivateKey(),
                                   agreementKey: Curve25519.KeyAgreement.PrivateKey())
        let bob = DeviceIdentity(signingKey: Curve25519.Signing.PrivateKey(),
                                 agreementKey: Curve25519.KeyAgreement.PrivateKey())
        let plaintext = Data("authenticated private message".utf8)
        let sealed = try alice.seal(plaintext, for: bob.id, peerPublicKey: bob.agreementPublicKey)
        let opened = try bob.open(sealed, from: alice.id, peerPublicKey: alice.agreementPublicKey)
        precondition(opened == plaintext)

        var tampered = sealed
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        do {
            _ = try bob.open(tampered, from: alice.id, peerPublicKey: alice.agreementPublicKey)
            fatalError("Tampered ciphertext was accepted")
        } catch is CryptoKitError {
            // Authentication failure is the expected result.
        }

        let signature = try alice.sign(Data("challenge".utf8))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: alice.signingPublicKey)
        precondition(publicKey.isValidSignature(signature, for: Data("challenge".utf8)))
        print("Crypto self-check passed: key agreement, authenticated encryption and tamper rejection.")
    }
}
