# macOS 설치 및 직접 빌드

## GitHub에서 받기

저장소의 [Releases](https://github.com/breakpack/oh_my_private_message/releases)에서 `PrivateCat-macOS.zip`을 내려받아 압축을 풀고 `PrivateCat.app`을 응용 프로그램 폴더로 옮깁니다. 이 앱은 Apple Developer ID로 서명·공증되지 않았으므로 첫 실행에서 macOS가 차단할 수 있습니다. Finder에서 앱을 Control-클릭하고 **열기**를 선택해 실행을 승인하세요. 격리 속성을 제거하려면 터미널에서 아래 명령을 쓸 수 있습니다.

```sh
xattr -dr com.apple.quarantine /Applications/PrivateCat.app
```

## Xcode로 빌드

macOS 14 이상과 Xcode가 설치된 Mac에서 저장소를 내려받아 다음 명령을 실행합니다.

```sh
xcodebuild -project MacApp/PrivateCat.xcodeproj -target PrivateCat -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

앱은 `build/Build/Products/Release/PrivateCat.app`에 생성됩니다. Xcode에서 `MacApp/PrivateCat.xcodeproj`를 열고 `PrivateCat` 대상을 선택해 빌드해도 됩니다. 로컬에서 빌드한 미서명 앱도 Gatekeeper 안내가 나올 수 있습니다.

Apple Developer ID 인증서가 없는 상태에서는 자동 업데이트, notarization, Apple이 검증한 배포자 표시를 제공할 수 없습니다. 직접 빌드하거나 각 기기에서 Gatekeeper 실행을 승인해 사용하세요.
