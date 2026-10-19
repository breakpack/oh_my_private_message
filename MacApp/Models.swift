import Foundation
import SwiftData

@Model final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var peerID: String
    var text: String
    var date: Date
    var isOutgoing: Bool
    var attachmentName: String?
    var attachmentPath: String?

    init(id: UUID = UUID(), peerID: String, text: String, date: Date = .now,
         isOutgoing: Bool, attachmentName: String? = nil, attachmentPath: String? = nil) {
        self.id = id
        self.peerID = peerID
        self.text = text
        self.date = date
        self.isOutgoing = isOutgoing
        self.attachmentName = attachmentName
        self.attachmentPath = attachmentPath
    }
}

@Model final class OutboxEntry {
    @Attribute(.unique) var id: UUID
    var peerID: String
    var ciphertext: Data
    var createdAt: Date

    init(id: UUID, peerID: String, ciphertext: Data, createdAt: Date = .now) {
        self.id = id
        self.peerID = peerID
        self.ciphertext = ciphertext
        self.createdAt = createdAt
    }
}

@Model final class SavedPeer {
    @Attribute(.unique) var id: String
    var name: String
    var publicKey: Data
    var signingPublicKey: Data

    init(id: String, name: String, publicKey: Data, signingPublicKey: Data) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.signingPublicKey = signingPublicKey
    }
}

@Model final class IncomingTransfer {
    @Attribute(.unique) var id: String
    var peerID: String
    var name: String
    var count: Int
    var sha256: String
    var chunks: Data

    init(id: String, peerID: String, name: String, count: Int, sha256: String, chunks: Data) {
        self.id = id
        self.peerID = peerID
        self.name = name
        self.count = count
        self.sha256 = sha256
        self.chunks = chunks
    }
}

@Model final class ReceivedEnvelope {
    @Attribute(.unique) var id: String
    var peerID: String
    var receivedAt: Date

    init(id: String, peerID: String, receivedAt: Date = .now) {
        self.id = id
        self.peerID = peerID
        self.receivedAt = receivedAt
    }
}
