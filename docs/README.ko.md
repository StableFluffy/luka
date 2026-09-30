<p align="center">
  <img src="assets/icon.png" width="128" alt="Luka">
</p>

<h1 align="center">Luka</h1>

<p align="center">
  <strong>Mac에서 들리는 모든 소리에 실시간 자막을.</strong><br>
  통화, 영상, 회의를 듣는 그대로 받아쓰고 번역합니다. 누가 말하는지도 함께.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-black?style=flat-square" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6.2-F05138?style=flat-square" alt="Swift 6.2">
  <img src="https://img.shields.io/badge/speech-Soniox%20stt--rt--v5-FF6A3D?style=flat-square" alt="Soniox">
  <a href="../LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT"></a>
</p>

<p align="center">
  <a href="../README.md">English</a> | <b>한국어</b> | <a href="README.zh.md">中文</a>
</p>

<p align="center">
  <img src="assets/hero.png" width="820" alt="Luka 대화록 창과 자막">
</p>

---

## 설치

1. [Releases](../../../releases)에서 `Luka-<버전>.dmg`를 받아 **Luka**를 **응용 프로그램**으로 끌어 놓습니다.
2. Luka를 엽니다. 아직 공증되지 않은 빌드라 처음 한 번은 macOS가 막습니다.
   **시스템 설정 › 개인정보 보호 및 보안** → 아래로 스크롤 → **그래도 열기**.
   또는 터미널에서 한 번: `xattr -dr com.apple.quarantine /Applications/Luka.app`
3. 첫 화면에 [Soniox API 키](https://console.soniox.com)를 붙여 넣습니다.
4. <kbd>⌃</kbd><kbd>⌥</kbd><kbd>N</kbd>을 누르고 **시스템 오디오 녹음**을 허용합니다.

macOS 26 이상이 필요합니다. Soniox는 오디오 시간당 과금됩니다([요금](https://soniox.com/pricing)).

## 자막

<p align="center">
  <img src="assets/captions.png" width="720" alt="자막 스트립">
</p>

어떤 앱 위에도, 전체 화면 영상 위에도 떠 있는 글래스 자막. 포커스를 뺏지 않습니다.

| 동작 | 결과 |
| --- | --- |
| 위·아래 가장자리 끌기 | 줄 수 조절 (1–6) |
| 옆 가장자리 끌기 | 너비 조절 |
| 화면 가운데 근처에 놓기 | 중앙에 맞춤 |
| 마우스 올리기 | 언어·입력·크기·잠금 컨트롤 |
| 화자 이름 클릭 | 이름 바꾸기, 전체에 즉시 반영 |
| 잠금 <kbd>⌃</kbd><kbd>⌥</kbd><kbd>L</kbd> | 클릭 통과, 올리면 **잠금 해제** 버튼 |

## 세션

받아쓰기마다 사이드바에 세션으로 쌓이고 자동 저장됩니다.
제목은 클릭해서 바로 수정. <kbd>⌘</kbd><kbd>.</kbd>로 끝낸 뒤 **이어서 듣기**, 줄 편집, <kbd>⇧</kbd><kbd>⌘</kbd><kbd>C</kbd>로 전체 복사.

한 사람이 두 화자로 나뉘었다면 이름을 눌러 **같은 사람으로 합치기**.

## 단축키

어느 앱에서나:

| 키 | 동작 |
| --- | --- |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>N</kbd> | 새 받아쓰기 |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>R</kbd> | 시작 / 일시정지 |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>C</kbd> | 자막 보기 / 숨기기 |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>T</kbd> | 대화록 보기 / 숨기기 |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>L</kbd> | 자막 잠금 / 해제 |

Luka 안에서: <kbd>⌘</kbd><kbd>E</kbd> 지금 말하는 사람 이름 짓기, <kbd>⌘</kbd><kbd>1</kbd> / <kbd>⌘</kbd><kbd>2</kbd> 창 전환, <kbd>⌘</kbd><kbd>+</kbd> <kbd>⌘</kbd><kbd>−</kbd> 글자 크기, <kbd>⌘</kbd><kbd>↑</kbd> <kbd>⌘</kbd><kbd>↓</kbd> 자막 줄 수.

## 모드

| 모드 | 용도 |
| --- | --- |
| 번역 | 어떤 언어로 말해도 한 언어로 |
| 양방향 | 대화용, 양쪽을 서로의 언어로 |
| 받아쓰기 | 번역 없이 받아 적기 |

Mac 오디오, 마이크, 또는 둘 다. 인터페이스는 English, 한국어, 中文.

## 개인정보

오디오는 Mac에서 Soniox로 WebSocket으로 바로 갑니다. Luka 서버는 없습니다.
API 키는 `~/Library/Application Support/Luka/`에 AES-GCM으로 암호화되어 저장되고, 세션은 그 옆에 JSON 파일로 남습니다.

## 소스에서 빌드

```sh
./scripts/build-app.sh --install   # ~/Applications/Luka.app
./scripts/build-app.sh --dmg       # build/Luka-<버전>.dmg
swift test                         # 녹음된 Soniox 스트림 재생 테스트
```

Xcode 26 / Swift 6.2.

## 라이선스

MIT
