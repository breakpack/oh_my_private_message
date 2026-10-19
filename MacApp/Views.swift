import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers

struct CatView: View {
    @ObservedObject var model: MessengerModel

    var body: some View {
        VStack(spacing: 5) {
            Button {
                AppDelegate.shared?.showChat()
            } label: {
                AnimatedCat(name: model.catStyle + (model.isTyping ? "_idle_blink_8fps" : "_idle_8fps"))
                    .frame(width: 80, height: 80)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("PrivateCat 대화 열기 · 드래그해서 이동")
            ForEach(Array(model.bubbles.prefix(4))) { bubble in TypingBubble(text: bubble.text) }
        }
        .padding(8)
        .fixedSize()
        .onChange(of: model.bubbles.count) { _, count in AppDelegate.shared?.resizeCatPanel(for: count) }
    }
}

private struct TypingBubble: View {
    let text: String
    @State private var visible = ""

    var body: some View {
        Text(visible).font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.primary).padding(.horizontal, 10).padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
            .frame(maxWidth: 220)
            .task(id: text) {
                visible = ""
                for character in text {
                    guard !Task.isCancelled else { return }
                    visible.append(character)
                    try? await Task.sleep(for: .milliseconds(35))
                }
            }
    }
}

private struct AnimatedCat: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.layer = CALayer()
        view.layer?.magnificationFilter = .nearest
        view.layer?.minificationFilter = .nearest
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = NSImage(named: name)
    }
}

struct ChatView: View {
    @ObservedObject var model: MessengerModel
    @State private var draft = ""
    @State private var showingFilePicker = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("상대", selection: $model.selectedPeerID) {
                    Text("상대를 선택하세요").tag("")
                    ForEach(model.peers) { peer in Text(peer.name).tag(peer.id) }
                }.frame(maxWidth: 220).onChange(of: model.selectedPeerID) { _, id in model.selectPeer(id) }
                Spacer()
                Text(model.relayStatus).font(.caption).foregroundStyle(.secondary)
                Button("설정") { AppDelegate.shared?.showSettings() }
            }.padding()
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.messages) { message in
                            HStack {
                                if message.isOutgoing { Spacer(minLength: 40) }
                                VStack(alignment: .leading, spacing: 5) {
                                    if let path = message.attachmentPath,
                                       ["png", "jpg", "jpeg", "gif", "heic"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
                                       let image = NSImage(contentsOfFile: path) {
                                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 200)
                                    }
                                    Text(message.text)
                                    Text(message.date, style: .time).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                .padding(10).background(message.isOutgoing ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12),
                                                       in: RoundedRectangle(cornerRadius: 12))
                                if !message.isOutgoing { Spacer(minLength: 40) }
                            }.id(message.id)
                        }
                    }.padding()
                }
                .onChange(of: model.messages.count) { _, _ in
                    if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack(alignment: .bottom) {
                Button { showingFilePicker = true } label: { Image(systemName: "paperclip") }
                    .help("파일 또는 사진 첨부")
                TextField("메시지 입력", text: $draft, axis: .vertical)
                    .lineLimit(1...4).onChange(of: draft) { _, value in model.updateTyping(!value.isEmpty) }
                    .onSubmit(send)
                Button("전송", action: send).keyboardShortcut(.return, modifiers: [])
            }.padding()
        }
        .frame(minWidth: 420, minHeight: 480)
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { model.sendFile(url) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in model.sendFile(url) } } }
            return true
        }
    }

    private func send() {
        model.sendText(draft)
        draft = ""
        model.updateTyping(false)
    }
}

struct ComposerView: View {
    @ObservedObject var model: MessengerModel
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Picker("상대", selection: $model.selectedPeerID) {
                ForEach(model.peers) { Text($0.name).tag($0.id) }
            }.frame(width: 130).onChange(of: model.selectedPeerID) { _, id in model.selectPeer(id) }
            TextField("메시지 입력 · Enter 전송 · Esc 닫기", text: $draft)
                .textFieldStyle(.plain).focused($focused)
                .onChange(of: draft) { _, value in model.updateTyping(!value.isEmpty) }
                .onSubmit(send)
            Button("전송", action: send)
                .keyboardShortcut(.return, modifiers: [])
        }
        .padding(14).frame(width: 560, height: 64)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onAppear { focused = true }
        .onExitCommand { AppDelegate.shared?.hideComposer() }
    }

    private func send() {
        model.sendText(draft)
        draft = ""
        model.updateTyping(false)
        AppDelegate.shared?.hideComposer()
    }
}

struct SettingsView: View {
    @ObservedObject var model: MessengerModel
    @State private var inviteImage: NSImage?
    @State private var shortcutKey = UserDefaults.standard.integer(forKey: "hotkeyCode") == 0 ? 46 : UserDefaults.standard.integer(forKey: "hotkeyCode")
    @State private var shortcutLabel = UserDefaults.standard.string(forKey: "hotkeyLabel") ?? "M"
    @State private var isRecordingShortcut = false
    @State private var shortcutMonitor: Any?

    var body: some View {
        Form {
            Section("연결") { connectionRows }
            Section("모양과 알림") { appearanceRows }
            Section("파일과 단축키") { fileRows }
        }
        .formStyle(.grouped).padding().frame(width: 460, height: 600)
        .onChange(of: model.networkMode) { _, _ in model.persistSettings() }
        .onChange(of: model.downloadFolder) { _, _ in model.persistSettings() }
        .onChange(of: model.catStyle) { _, _ in model.persistSettings() }
        .onChange(of: model.bubbleDuration) { _, _ in model.persistSettings() }
        .onAppear { inviteImage = qrImage(for: model.identity.invitationCode) }
        .onChange(of: isRecordingShortcut) { _, recording in
            if recording { startShortcutCapture() } else { stopShortcutCapture() }
        }
        .onDisappear { stopShortcutCapture() }
    }

    @ViewBuilder private var connectionRows: some View {
            Picker("네트워크 모드", selection: $model.networkMode) {
                Text("근거리 (Bonjour)").tag("근거리")
                Text("인터넷 (WSS)").tag("인터넷")
            }
            if model.networkMode == "근거리" {
                    Text("근처 기기에 연결 요청을 보내고, 상대의 승인을 기다립니다.")
                        .font(.caption).foregroundStyle(.secondary)
                if model.nearbyDevices.isEmpty { Text("검색 중인 근처 PrivateCat 기기가 없습니다.").font(.caption).foregroundStyle(.secondary) }
                ForEach(model.nearbyDevices) { device in
                    HStack {
                        Text(String(device.id.prefix(16))).font(.caption.monospaced())
                        Spacer()
                            Button("연결 요청") { model.requestPairing(with: device) }
                        }
                    }
                    ForEach(model.pairingRequests) { request in
                        HStack {
                            Text("요청 · \(request.senderID.prefix(12))")
                            Spacer()
                            Button("수락") { model.acceptPairingRequest(request) }
                            Button("거절") { model.declinePairingRequest(request) }
                        }
                    }
                }
            Text("초대 코드로 추가할 때는 상대도 내 코드를 추가해야 서로 메시지를 보낼 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
            if model.networkMode == "인터넷" {
                TextField("WSS 서버 주소", text: $model.relayAddress)
                    .onSubmit { model.persistSettings() }
                Text("상태: \(model.relayStatus)").font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("내 초대 코드") {
                Button("복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.identity.invitationCode, forType: .string)
                }
            }
            if let inviteImage { Image(nsImage: inviteImage).interpolation(.none).resizable().frame(width: 112, height: 112) }
            TextField("상대 초대 코드 붙여넣기", text: $model.invitationInput)
            HStack {
                Button("상대 추가") { model.acceptInvitation() }
                Text(model.invitationStatus).font(.caption).foregroundStyle(.secondary)
            }
    }

    @ViewBuilder private var appearanceRows: some View {
            Picker("고양이", selection: $model.catStyle) {
                ForEach(1...5, id: \.self) { index in Text("cat0\(index)").tag("cat0\(index)") }
            }
            Slider(value: $model.bubbleDuration, in: 2...30, step: 1) {
                Text("말풍선 표시 시간: \(Int(model.bubbleDuration))초")
            }
    }

    @ViewBuilder private var fileRows: some View {
            TextField("받을 파일 위치", text: $model.downloadFolder)
            HStack {
                Text("전역 단축키")
                Spacer()
                Text("현재: ⌥⇧\(shortcutLabel)").foregroundStyle(.secondary)
                Button(isRecordingShortcut ? "⌥⇧ 키를 누르세요…" : "단축키 설정") {
                    isRecordingShortcut = true
                }
            }
            if isRecordingShortcut {
                Text("⌥⇧를 누른 채 원하는 키를 입력하세요. Esc를 누르면 취소됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
    }

    private func startShortcutCapture() {
        stopShortcutCapture()
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                isRecordingShortcut = false
                return nil
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains([.option, .shift]),
                  !modifiers.contains([.command, .control]) else { return nil }

            shortcutKey = Int(event.keyCode)
            shortcutLabel = event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
            UserDefaults.standard.set(shortcutKey, forKey: "hotkeyCode")
            UserDefaults.standard.set(shortcutLabel, forKey: "hotkeyLabel")
            AppDelegate.shared?.registerHotKey(keyCode: UInt32(event.keyCode))
            isRecordingShortcut = false
            return nil
        }
    }

    private func stopShortcutCapture() {
        if let shortcutMonitor {
            NSEvent.removeMonitor(shortcutMonitor)
            self.shortcutMonitor = nil
        }
    }

    private func qrImage(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 112, height: 112))
    }
}
