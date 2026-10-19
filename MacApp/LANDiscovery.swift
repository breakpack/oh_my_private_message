import Combine
import Foundation
import Network

private let maxLocalPacketBytes = 1_050_000

private final class CompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var sent = false
    func beginSend() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished, !sent else { return false }
        sent = true
        return true
    }
    func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}

struct NearbyDevice: Identifiable {
    let id: String
    let invitationCode: String
}

@MainActor final class LANDiscovery: ObservableObject {
    @Published private(set) var nearbyDevices: [NearbyDevice] = []
    var onPacket: (([String: Any]) -> Void)?

    private var browser: NWBrowser?
    private var listener: NWListener?
    private var endpoints: [String: NWEndpoint] = [:]
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]
    private let identity: DeviceIdentity

    init(identity: DeviceIdentity) { self.identity = identity }

    func start() {
        guard browser == nil else { return }
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: String(identity.id.prefix(16)), type: "_privatecat._tcp",
                txtRecord: NWTXTRecord(["deviceId": identity.id,
                                        "agreementKey": identity.agreementPublicKey.base64URL,
                                        "signingKey": identity.signingPublicKey.base64URL]))
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                Task { @MainActor in self?.receiveOnePacket(on: connection) }
            }
            listener.start(queue: .main)
            self.listener = listener

            let browser = NWBrowser(for: .bonjour(type: "_privatecat._tcp", domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                let ownID = self.identity.id
                var found: [String: NWEndpoint] = [:]
                let devices = results.compactMap { result -> NearbyDevice? in
                    guard case .bonjour(let record) = result.metadata,
                          let id = record["deviceId"], id != ownID,
                          let agreement = record["agreementKey"], let signing = record["signingKey"] else { return nil }
                    found[id] = result.endpoint
                    return NearbyDevice(id: id, invitationCode: "privatecat:\(id):\(agreement):\(signing)")
                }
                Task { @MainActor in
                    self.endpoints = found
                    self.nearbyDevices = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                        .values.sorted { $0.id < $1.id }
                }
            }
            browser.start(queue: .main)
            self.browser = browser
        } catch {
            nearbyDevices = []
        }
    }

    func stop() {
        browser?.cancel()
        listener?.cancel()
        browser = nil
        listener = nil
        endpoints = [:]
        nearbyDevices = []
    }

    func send(_ packet: [String: Any], to peerID: String) async throws {
        guard let endpoint = endpoints[peerID] else { throw LANError.peerUnavailable }
        let connection = NWConnection(to: endpoint, using: .tcp)
        let gate = CompletionGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.beginSend() else { return }
                    var bytes = (try? JSONSerialization.data(withJSONObject: packet)) ?? Data()
                    bytes.append(0x0A)
                    connection.send(content: bytes, completion: .contentProcessed { error in
                        guard gate.finish() else { return }
                        connection.cancel()
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    })
                case .failed(let error):
                    guard gate.finish() else { return }
                    connection.cancel(); continuation.resume(throwing: error)
                case .cancelled:
                    if gate.finish() { continuation.resume(throwing: LANError.peerUnavailable) }
                default: break
                }
            }
            connection.start(queue: .main)
        }
    }

    private func receiveOnePacket(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxLocalPacketBytes) { [weak self] data, _, _, error in
            guard let self else { connection.cancel(); return }
            Task { @MainActor in self.processReceived(data, error: error, connection: connection) }
        }
    }

    private func processReceived(_ data: Data?, error: NWError?, connection: NWConnection) {
            if let data { self.receiveBuffers[ObjectIdentifier(connection), default: Data()].append(data) }
            let key = ObjectIdentifier(connection)
            guard (self.receiveBuffers[key]?.count ?? 0) <= maxLocalPacketBytes else {
                self.receiveBuffers[key] = nil
                connection.cancel()
                return
            }
            if let buffer = self.receiveBuffers[key], let newline = buffer.firstIndex(of: 0x0A) {
                self.receiveBuffers[key] = nil
                let packetData = buffer[..<newline]
                if let packet = try? JSONSerialization.jsonObject(with: Data(packetData)) as? [String: Any] {
                    self.onPacket?(packet)
                }
                connection.cancel()
            } else if error != nil { self.receiveBuffers[key] = nil; connection.cancel() }
            else { self.receiveOnePacket(on: connection) }
    }
}

enum LANError: LocalizedError {
    case peerUnavailable
    var errorDescription: String? { "근처 기기를 찾을 수 없습니다." }
}
