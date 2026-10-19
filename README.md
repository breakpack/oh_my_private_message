# PrivateCat

PrivateCat은 macOS 14 이상에서 동작하는 메뉴 막대 1:1 메신저입니다. 화면 위의 고양이는 이동할 수 있고, 대화 기록과 전송 대기열은 각 Mac에 저장합니다. 메시지와 파일은 발신 기기에서 암호화하며, 선택형 릴레이 서버는 접속 경로만 메모리에 두고 암호문을 전달합니다.

## macOS 앱 빌드

Xcode를 설치한 뒤 `MacApp/PrivateCat.xcodeproj`를 열어 `PrivateCat` 스킴을 빌드합니다. 앱은 SwiftUI, AppKit, Network, CryptoKit, SwiftData를 사용합니다. `LSUIElement` 설정으로 Dock 아이콘을 숨기며, 근거리 검색에는 Bonjour 서비스 `_privatecat._tcp`를 사용합니다.

GitHub Actions도 macOS 앱을 빌드하고 태그 릴리스에 `PrivateCat-macOS.zip`을 첨부합니다. Apple Developer ID 서명 및 notarization 인증서는 설정되어 있지 않아 이 패키지는 서명되지 않습니다. 처음 실행할 때 Gatekeeper가 막으면 Finder에서 앱을 우클릭해 **열기**를 한 번 선택하거나 터미널에서 `xattr -dr com.apple.quarantine /Applications/PrivateCat.app`을 실행합니다. 본인 Mac에서 직접 빌드하면 Xcode에서 실행하거나 `CODE_SIGNING_ALLOWED=NO`로 빌드할 수 있습니다. 자세한 설치 절차는 [MacApp/INSTALL.md](MacApp/INSTALL.md)를 참고하세요.

기본 전역 단축키는 ⌥⇧M입니다. 설정에서 단축키 키 코드, 고양이 모양 5종, 말풍선 표시 시간, 받을 파일 폴더, 네트워크 모드를 바꿀 수 있습니다. 기본 다운로드 폴더는 `~/Downloads/PrivateChat`입니다. 근거리 페어링은 연결 요청과 수락/거절로 진행합니다. 인터넷 페어링은 양쪽 사용자가 서로의 초대 QR 또는 복사 가능한 코드를 추가합니다.

## 릴레이 실행

Node.js 22 이상과 Docker Compose가 필요합니다. `Relay/`에서 실행합니다.

```sh
npm ci
npm test
docker compose up --build -d
```

Compose는 기존 `npm_default` Docker 네트워크에 릴레이를 연결하고 호스트 포트는 열지 않습니다. Nginx Proxy Manager에서 WebSocket 지원을 켜고, upstream scheme `http`, hostname `privatecat-relay`, port `8080`으로 Proxy Host를 설정합니다. Cloudflare Tunnel에서 사용할 공개 hostname을 NPM의 80 포트로 연결한 뒤, 앱에는 `wss://<공개 hostname>`을 입력합니다. WebSocket 경로는 `/relay`입니다. 이 저장소와 함께 배포된 서버 주소는 `wss://privatecat.breakpack.cc`입니다. NPM 네트워크 이름이 다르면 `NPM_DOCKER_NETWORK`로 지정할 수 있습니다.

릴레이에는 DB, 계정, 메시지·파일 저장소, 오프라인 대기열이 없습니다. 오프라인 메시지는 발신 기기의 로컬 대기열에 남고 상대가 다시 연결되면 재전송합니다.

## 파일과 검증

첨부 파일은 최대 8 MiB까지 보낼 수 있으며, 암호화된 512 KiB 청크로 나눕니다. 수신 기기는 청크를 로컬에 저장하고 SHA-256을 확인한 뒤 임시 파일을 지정 폴더로 옮깁니다. 이미지는 대화창에서 미리 볼 수 있습니다.

`npm test`는 릴레이 연결 인증, 실시간 전달, 확인 응답, 오프라인 프레임 미보관을 확인합니다. CryptoKit 자가 검사는 저장소 루트에서 다음 명령으로 실행할 수 있습니다.

```sh
swiftc -parse-as-library MacApp/Security.swift MacApp/Tests/CryptoSelfCheck.swift -o /tmp/privatecat-crypto-self-check
/tmp/privatecat-crypto-self-check
```

현재 환경에는 Xcode가 없어 앱 전체 빌드와 두 Mac 간 네트워크 검증은 남아 있습니다. 페어링 요청은 수락하거나 거절할 때까지 앱 메모리에 보관됩니다. 초대 QR은 앱에서 보여 주지만 카메라로 QR을 스캔하는 기능은 없습니다.
