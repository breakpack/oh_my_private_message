import Combine
import CryptoKit
import Foundation
import SwiftData
import SwiftUI

struct PeerSummary: Identifiable, Hashable {
    let id: String
    let name: String
}

struct PairingRequest: Identifiable {
    let id: UUID
    let senderID: String
    let agreementKey: Data
    let signingKey: Data
}

struct IncomingText: Codable {
    var kind = "text"
    let text: String
}

struct IncomingAttachment: Codable {
    var kind = "file"
    let name: String
    let data: Data
}

struct FileChunk: Codable {
    var kind = "fileChunk"
    let transferID: UUID
    let name: String
    let index: Int
    let count: Int
    let sha256: String
    let data: Data
}

struct Bubble: Identifiable {
    let id = UUID()
    let text: String
}

@MainActor final class MessengerModel: ObservableObject {
    static let shared = MessengerModel()
    let container: ModelContainer
    let identity = DeviceIdentity()
    @Published var peers: [PeerSummary] = []
    @Published var nearbyDevices: [NearbyDevice] = []
    @Published var selectedPeerID = ""
    @Published var messages: [ChatMessage] = []
    @Published var bubbles: [Bubble] = []
    @Published var relayStatus = "오프라인"
    @Published var networkMode = UserDefaults.standard.string(forKey: "networkMode") ?? "근거리"
    @Published var relayAddress = UserDefaults.standard.string(forKey: "relayAddress") ?? "wss://"
    @Published var downloadFolder = UserDefaults.standard.string(forKey: "downloadFolder") ??
        (NSHomeDirectory() + "/Downloads/PrivateChat")
    @Published var catStyle = UserDefaults.standard.string(forKey: "catStyle") ?? "cat01"
    @Published var bubbleDuration = UserDefaults.standard.double(forKey: "bubbleDuration") == 0 ? 6 :
        UserDefaults.standard.double(forKey: "bubbleDuration")
    @Published var isTyping = false
    @Published var invitationInput = ""
    @Published var invitationStatus = ""
    @Published var pairingRequests: [PairingRequest] = []

    private let context: ModelContext
    private let relay: RelayClient
    private let lan: LANDiscovery
    private var subscriptions = Set<AnyCancellable>()
    private var queuedBubbles: [Bubble] = []
    private var bubbleTimers: [UUID: Task<Void, Never>] = [:]
    private var retryAttempts: [UUID: Int] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var outboundPairingRequests: [UUID: String] = [:]

    private init() {
        container = try! ModelContainer(for: ChatMessage.self, OutboxEntry.self, SavedPeer.self,
                                        IncomingTransfer.self, ReceivedEnvelope.self)
        context = ModelContext(container)
        relay = RelayClient(identity: identity)
        lan = LANDiscovery(identity: identity)
        lan.start()
        lan.$nearbyDevices.sink { [weak self] devices in
            self?.nearbyDevices = devices
            self?.flushOutbox()
        }.store(in: &subscriptions)
        lan.onPacket = { [weak self] in self?.receiveLANPacket($0) }
        reloadPeers()
        relay.onStatus = { [weak self] in self?.relayStatus = $0 }
        relay.onFrame = { [weak self] in self?.receive(senderID: $0, messageID: $1, ciphertext: $2, overLAN: false) }
        relay.onAcknowledgement = { [weak self] in self?.removeOutbox(id: $0, from: $1) }
        relay.onReady = { [weak self] in self?.flushOutbox() }
        selectPeer(peers.first?.id)
    }

    func persistSettings() {
        let defaults = UserDefaults.standard
        defaults.set(networkMode, forKey: "networkMode")
        defaults.set(relayAddress, forKey: "relayAddress")
        defaults.set(downloadFolder, forKey: "downloadFolder")
        defaults.set(catStyle, forKey: "catStyle")
        defaults.set(bubbleDuration, forKey: "bubbleDuration")
        if networkMode == "인터넷" {
            lan.stop()
            if let url = URL(string: relayAddress), url.scheme == "wss", url.host != nil { relay.connect(to: url) }
            else { relay.disconnect() }
        } else {
            relay.disconnect()
            lan.start()
        }
    }

    func reloadPeers() {
        let saved = (try? context.fetch(FetchDescriptor<SavedPeer>())) ?? []
        peers = saved.map { PeerSummary(id: $0.id, name: $0.name) }.sorted { $0.name < $1.name }
    }

    func acceptInvitation(name: String = "친구") {
        do {
            let invite = try DeviceIdentity.parseInvitation(invitationInput)
            guard invite.id != identity.id else { invitationStatus = "내 기기의 초대 코드는 추가할 수 없습니다."; return }
            let peer = SavedPeer(id: invite.id, name: name, publicKey: invite.agreementKey,
                                 signingPublicKey: invite.signingKey)
            context.insert(peer)
            try context.save()
            invitationInput = ""
            invitationStatus = "상대를 추가했습니다."
            reloadPeers()
            selectPeer(invite.id)
        } catch { invitationStatus = error.localizedDescription }
    }

    func requestPairing(with device: NearbyDevice) {
        let requestID = UUID()
        let agreement = identity.agreementPublicKey.base64URL
        let proof = Data("pair-request:\(requestID.uuidString):\(identity.id):\(agreement)".utf8)
        do {
            let packet: [String: Any] = ["type": "pair-request", "id": requestID.uuidString,
                                         "from": identity.id, "agreementKey": agreement,
                                         "signingKey": identity.signingPublicKey.base64URL,
                                         "signature": try identity.sign(proof).base64URL]
            outboundPairingRequests[requestID] = device.id
            Task { try? await lan.send(packet, to: device.id) }
            invitationStatus = "승인 요청을 보냈습니다."
        } catch { invitationStatus = error.localizedDescription }
    }

    func acceptPairingRequest(_ request: PairingRequest) {
        guard peer(id: request.senderID) == nil else { pairingRequests.removeAll { $0.id == request.id }; return }
        do {
            context.insert(SavedPeer(id: request.senderID, name: "친구", publicKey: request.agreementKey,
                                     signingPublicKey: request.signingKey))
            try context.save()
            let agreement = identity.agreementPublicKey.base64URL
            let proof = Data("pair-accepted:\(request.id.uuidString):\(identity.id):\(agreement)".utf8)
            let packet: [String: Any] = ["type": "pair-accepted", "id": request.id.uuidString,
                                         "from": identity.id, "agreementKey": agreement,
                                         "signingKey": identity.signingPublicKey.base64URL,
                                         "signature": try identity.sign(proof).base64URL]
            Task { try? await lan.send(packet, to: request.senderID) }
            pairingRequests.removeAll { $0.id == request.id }
            reloadPeers()
            selectPeer(request.senderID)
        } catch { invitationStatus = error.localizedDescription }
    }

    func declinePairingRequest(_ request: PairingRequest) {
        pairingRequests.removeAll { $0.id == request.id }
    }

    func selectPeer(_ id: String?) {
        selectedPeerID = id ?? ""
        guard !selectedPeerID.isEmpty else { messages = []; return }
        let peerID = selectedPeerID
        messages = ((try? context.fetch(FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.peerID == peerID }, sortBy: [SortDescriptor(\.date)]))) ?? [])
    }

    func sendText(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let peer = peer(id: selectedPeerID) else { return }
        let item = ChatMessage(peerID: peer.id, text: text, isOutgoing: true)
        context.insert(item)
        messages.append(item)
        do {
            let sealed = try identity.seal(JSONEncoder().encode(IncomingText(text: text)), for: peer.id,
                                           peerPublicKey: peer.publicKey)
            let outbox = OutboxEntry(id: item.id, peerID: peer.id, ciphertext: sealed)
            context.insert(outbox)
            try context.save()
            deliver(outbox)
        } catch { relayStatus = "암호화 오류: \(error.localizedDescription)" }
    }

    func sendFile(_ url: URL) {
        guard let peer = peer(id: selectedPeerID) else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count <= 8 * 1_024 * 1_024 else {
            relayStatus = "첨부 파일은 8MB까지 보낼 수 있습니다."
            return
        }
        let directory = URL(fileURLWithPath: downloadFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let chatText = ["png", "jpg", "jpeg", "gif", "heic"].contains(url.pathExtension.lowercased())
            ? "사진을 보냈어요!" : url.lastPathComponent
        let message = ChatMessage(id: id, peerID: peer.id, text: chatText, isOutgoing: true,
                                  attachmentName: url.lastPathComponent, attachmentPath: url.path)
        context.insert(message)
        messages.append(message)
        do {
            let chunkSize = 512 * 1_024
            let chunkCount = max(1, Int(ceil(Double(data.count) / Double(chunkSize))))
            let digest = Data(SHA256.hash(data: data)).base64URL
            for index in 0..<chunkCount {
                let start = index * chunkSize
                let end = min(data.count, start + chunkSize)
                let chunkData = data.subdata(in: start..<end)
                let chunk = FileChunk(transferID: id, name: url.lastPathComponent, index: index,
                                      count: chunkCount, sha256: digest, data: chunkData)
                let sealed = try identity.seal(JSONEncoder().encode(chunk), for: peer.id, peerPublicKey: peer.publicKey)
                context.insert(OutboxEntry(id: UUID(), peerID: peer.id, ciphertext: sealed))
            }
            try context.save()
            flushOutbox()
        } catch { relayStatus = "첨부 파일 암호화 오류: \(error.localizedDescription)" }
    }

    func updateTyping(_ value: Bool) { isTyping = value }

    private func receive(senderID: String, messageID: String, ciphertext: Data, overLAN: Bool) {
        guard let messageUUID = UUID(uuidString: messageID),
              let peer = peer(id: senderID),
              let plaintext = try? identity.open(ciphertext, from: senderID, peerPublicKey: peer.publicKey) else { return }
        if (try? context.fetch(FetchDescriptor<ReceivedEnvelope>(predicate: #Predicate { $0.id == messageID })).first) != nil {
            acknowledge(messageID, to: senderID, overLAN: overLAN)
            return
        }
        if let chunk = try? JSONDecoder().decode(FileChunk.self, from: plaintext), chunk.kind == "fileChunk" {
            receiveChunk(chunk, senderID: senderID, messageID: messageUUID, overLAN: overLAN)
            return
        }
        let message: ChatMessage
        if let incoming = try? JSONDecoder().decode(IncomingAttachment.self, from: plaintext), incoming.kind == "file" {
            let directory = URL(fileURLWithPath: downloadFolder, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = uniqueDestination(directory.appendingPathComponent(safeAttachmentName(incoming.name)))
            guard (try? incoming.data.write(to: destination, options: .atomic)) != nil else { return }
            let imageExtensions = ["png", "jpg", "jpeg", "gif", "heic"]
            let text = imageExtensions.contains(destination.pathExtension.lowercased()) ? "사진을 보냈어요!" : destination.lastPathComponent
            message = ChatMessage(id: messageUUID, peerID: senderID, text: text, isOutgoing: false,
                                  attachmentName: destination.lastPathComponent, attachmentPath: destination.path)
        } else if let incoming = try? JSONDecoder().decode(IncomingText.self, from: plaintext) {
            message = ChatMessage(id: messageUUID, peerID: senderID, text: incoming.text, isOutgoing: false)
        } else { return }
        context.insert(message)
        context.insert(ReceivedEnvelope(id: messageID, peerID: senderID))
        guard (try? context.save()) != nil else { context.delete(message); return }
        if senderID == selectedPeerID { messages.append(message) }
        acknowledge(messageID, to: senderID, overLAN: overLAN)
        showBubble(message.text)
    }

    private func showBubble(_ text: String) {
        let bubble = Bubble(text: text)
        queuedBubbles.append(bubble)
        promoteBubbles()
    }

    private func flushOutbox() {
        let queued = (try? context.fetch(FetchDescriptor<OutboxEntry>())) ?? []
        for entry in queued { deliver(entry) }
    }

    private func removeOutbox(id: UUID, from peerID: String) {
        guard let entry = try? context.fetch(FetchDescriptor<OutboxEntry>()).first(where: { $0.id == id }) else { return }
        guard entry.peerID == peerID else { return }
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        retryAttempts[id] = nil
        context.delete(entry)
        try? context.save()
    }

    private func peer(id: String) -> SavedPeer? {
        try? context.fetch(FetchDescriptor<SavedPeer>(predicate: #Predicate { $0.id == id })).first
    }

    private func uniqueDestination(_ original: URL) -> URL {
        guard FileManager.default.fileExists(atPath: original.path) else { return original }
        let stem = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension
        return original.deletingLastPathComponent().appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8)).\(ext)")
    }

    private func safeAttachmentName(_ name: String) -> String {
        let lastComponent = URL(fileURLWithPath: name).lastPathComponent
        return lastComponent == "." || lastComponent == ".." || lastComponent.isEmpty ? "attachment" : lastComponent
    }

    private func promoteBubbles() {
        while bubbles.count < 4, !queuedBubbles.isEmpty {
            let bubble = queuedBubbles.removeFirst()
            bubbles.append(bubble)
            bubbleTimers[bubble.id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.bubbleDuration ?? 6))
                guard let self else { return }
                self.bubbles.removeAll { $0.id == bubble.id }
                self.bubbleTimers[bubble.id] = nil
                self.promoteBubbles()
            }
        }
    }

    private func deliver(_ entry: OutboxEntry) {
        if networkMode == "인터넷" {
            Task { try? await relay.send(id: entry.id, to: entry.peerID, ciphertext: entry.ciphertext) }
        } else {
            let packet: [String: Any] = ["type": "frame", "id": entry.id.uuidString, "from": identity.id,
                                         "to": entry.peerID, "ciphertext": entry.ciphertext.base64URL]
            Task { try? await lan.send(packet, to: entry.peerID) }
        }
        scheduleRetry(for: entry.id)
    }

    private func scheduleRetry(for id: UUID) {
        guard retryTasks[id] == nil else { return }
        let attempt = retryAttempts[id, default: 0]
        let delay = min(60, 5 << min(attempt, 4))
        retryAttempts[id] = min(attempt + 1, 5)
        retryTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.retryTasks[id] = nil
            guard let entry = try? self.context.fetch(FetchDescriptor<OutboxEntry>()).first(where: { $0.id == id }) else { return }
            self.deliver(entry)
        }
    }

    private func acknowledge(_ messageID: String, to peerID: String, overLAN: Bool) {
        if overLAN {
            let packet: [String: Any] = ["type": "ack", "id": messageID, "from": identity.id, "to": peerID]
            Task { try? await lan.send(packet, to: peerID) }
        } else { relay.acknowledge(id: messageID, to: peerID) }
    }

    private func receiveLANPacket(_ packet: [String: Any]) {
        guard let type = packet["type"] as? String, let sender = packet["from"] as? String else { return }
        if type == "pair-request" { receivePairingRequest(packet, senderID: sender); return }
        if type == "pair-accepted" { receivePairingAcceptance(packet, senderID: sender); return }
        guard peer(id: sender) != nil else { return }
        if type == "frame", let id = packet["id"] as? String,
           let ciphertext = (packet["ciphertext"] as? String).flatMap(Data.init(base64URL:)) {
            receive(senderID: sender, messageID: id, ciphertext: ciphertext, overLAN: true)
        } else if type == "ack", let id = packet["id"] as? String, let uuid = UUID(uuidString: id) {
            removeOutbox(id: uuid, from: sender)
        }
    }

    private func receivePairingRequest(_ packet: [String: Any], senderID: String) {
        guard let requestID = (packet["id"] as? String).flatMap(UUID.init(uuidString:)),
              let agreement = (packet["agreementKey"] as? String).flatMap(Data.init(base64URL:)), agreement.count == 32,
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreement)) != nil,
              let signing = (packet["signingKey"] as? String).flatMap(Data.init(base64URL:)), signing.count == 32,
              DeviceIdentity.routeID(for: signing) == senderID,
              let signature = (packet["signature"] as? String).flatMap(Data.init(base64URL:)) else { return }
        let proof = Data("pair-request:\(requestID.uuidString):\(senderID):\(agreement.base64URL)".utf8)
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: signing),
              publicKey.isValidSignature(signature, for: proof), peer(id: senderID) == nil,
              !pairingRequests.contains(where: { $0.id == requestID }) else { return }
        pairingRequests.append(PairingRequest(id: requestID, senderID: senderID,
                                              agreementKey: agreement, signingKey: signing))
    }

    private func receivePairingAcceptance(_ packet: [String: Any], senderID: String) {
        guard let requestID = (packet["id"] as? String).flatMap(UUID.init(uuidString:)),
              outboundPairingRequests[requestID] == senderID,
              let agreement = (packet["agreementKey"] as? String).flatMap(Data.init(base64URL:)), agreement.count == 32,
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreement)) != nil,
              let signing = (packet["signingKey"] as? String).flatMap(Data.init(base64URL:)), signing.count == 32,
              DeviceIdentity.routeID(for: signing) == senderID,
              let signature = (packet["signature"] as? String).flatMap(Data.init(base64URL:)) else { return }
        let proof = Data("pair-accepted:\(requestID.uuidString):\(senderID):\(agreement.base64URL)".utf8)
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: signing),
              publicKey.isValidSignature(signature, for: proof) else { return }
        do {
            context.insert(SavedPeer(id: senderID, name: "친구", publicKey: agreement, signingPublicKey: signing))
            try context.save()
            outboundPairingRequests[requestID] = nil
            invitationStatus = "상대가 요청을 승인했습니다."
            reloadPeers()
            selectPeer(senderID)
        } catch { invitationStatus = error.localizedDescription }
    }

    private func receiveChunk(_ chunk: FileChunk, senderID: String, messageID: UUID, overLAN: Bool) {
        let key = "incoming-\(chunk.transferID.uuidString)"
        guard chunk.count > 0, chunk.count <= 16, chunk.index >= 0, chunk.index < chunk.count,
              chunk.data.count <= 512 * 1_024 else { return }
        var state = (try? context.fetch(FetchDescriptor<IncomingTransfer>(predicate: #Predicate { $0.id == key }))).first
        if state == nil {
            state = IncomingTransfer(id: key, peerID: senderID, name: chunk.name, count: chunk.count,
                                     sha256: chunk.sha256, chunks: Data())
            context.insert(state!)
        }
        guard let state, state.peerID == senderID, state.count == chunk.count,
              chunk.index >= 0, chunk.index < state.count else { return }
        var pieces = (try? JSONDecoder().decode([Int: Data].self, from: state.chunks)) ?? [:]
        pieces[chunk.index] = chunk.data
        state.chunks = (try? JSONEncoder().encode(pieces)) ?? Data()
        context.insert(ReceivedEnvelope(id: messageID.uuidString, peerID: senderID))
        guard (try? context.save()) != nil else { return }
        acknowledge(messageID.uuidString, to: senderID, overLAN: overLAN)
        guard pieces.count == state.count else { return }
        let fileData = (0..<state.count).reduce(into: Data()) { $0.append(pieces[$1] ?? Data()) }
        guard fileData.count <= 8 * 1_024 * 1_024,
              Data(SHA256.hash(data: fileData)).base64URL == state.sha256 else {
            context.delete(state); try? context.save(); return
        }
        let directory = URL(fileURLWithPath: downloadFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = uniqueDestination(directory.appendingPathComponent(safeAttachmentName(state.name)))
        let temporary = directory.appendingPathComponent(".privatecat-\(chunk.transferID.uuidString).part")
        try? FileManager.default.removeItem(at: temporary)
        guard (try? fileData.write(to: temporary, options: Data.WritingOptions.atomic)) != nil,
              (try? FileManager.default.moveItem(at: temporary, to: destination)) != nil else { return }
        let imageExtensions = ["png", "jpg", "jpeg", "gif", "heic"]
        let text = imageExtensions.contains(destination.pathExtension.lowercased()) ? "사진을 보냈어요!" : destination.lastPathComponent
        let message = ChatMessage(id: chunk.transferID, peerID: senderID, text: text, isOutgoing: false,
                                  attachmentName: destination.lastPathComponent, attachmentPath: destination.path)
        context.insert(message)
        context.delete(state)
        guard (try? context.save()) != nil else { return }
        if senderID == selectedPeerID { messages.append(message) }
        showBubble(message.text)
    }
}
