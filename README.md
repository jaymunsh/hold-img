# HoldImg

GrabIt/Snipaste 스타일의 macOS 플로팅 스크린샷 유틸리티.
화면 영역을 캡처하면 모든 윈도우 위에 떠 있는 이미지 창이 즉시 표시됩니다.

## 빌드 & 실행

```bash
make build   # swift build -c release → build/HoldImg.app 조립 + 서명
make run     # 빌드 후 앱 실행
```

Xcode 없이 SwiftPM + `Scripts/build-app.sh`로 `.app` 번들을 만듭니다.

### 서명

`~/.local/share/holdimg-dev/holdimg.keychain-db`에 "HoldImg Local Dev"
자체 서명 인증서가 있으면 그걸로 서명합니다 — 재빌드해도 서명 ID가
유지되어 화면 기록 권한이 리셋되지 않습니다. 없으면 ad-hoc 서명으로
폴백되며, 이 경우 매 빌드마다 권한을 다시 허용해야 합니다.

키체인 암호는 repo에 포함하지 않습니다. 스크립트는
`HOLDIMG_KEYCHAIN_PASSWORD` 환경변수 또는
`~/.local/share/holdimg-dev/keychain-password`(chmod 600) 파일에서 읽습니다.

<details><summary>로컬 개발용 인증서 만드는 법</summary>

```bash
mkdir -p ~/.local/share/holdimg-dev && cd ~/.local/share/holdimg-dev
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
  -days 3650 -nodes -subj "/CN=HoldImg Local Dev" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,digitalSignature"
openssl pkcs12 -export -out cert.p12 -inkey key.pem -in cert.pem -password pass:<암호>
security create-keychain -p <암호> holdimg.keychain-db
security import cert.p12 -k holdimg.keychain-db -P <암호> -T /usr/bin/codesign
security import cert.pem -k holdimg.keychain-db -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k <암호> holdimg.keychain-db
printf '%s' '<암호>' > keychain-password && chmod 600 keychain-password
```

배포용 릴리즈는 Apple Developer ID 인증서 + notarization을 사용하세요.
</details>

## 최초 실행 — 화면 기록 권한

처음 캡처를 시도하면 macOS가 "화면 기록" 권한을 요구합니다.
앱의 안내 알림에서 "설정 열기"를 누르거나, 시스템 설정 → 개인정보 보호
및 보안 → 화면 기록에서 HoldImg를 허용한 뒤 다시 캡처하세요.
(권한 변경 후 앱 재시작이 필요할 수 있습니다.)

## 검증

CLT(Command Line Tools) 전용 환경에는 XCTest가 없어 `swift test`는
불가합니다. 대신 좌표 변환 로직은 독립 Swift 스크립트로 검증했고,
영역 캡처→플로팅→클립보드 복사는 수동으로 확인했습니다.

## 기능

- **영역 캡처** `⌃⌥C` — 화면이 프리즈되고 드래그로 영역 선택 → 즉시 플로팅 (Retina 네이티브 2x 해상도)
  - 비율 고정: `1` 자유 · `2` 1:1 · `3` 4:3 · `4` 16:9 · `5` 16:10 — 드래그 중에도 누르면 선택이 즉시 리셰이프
  - `6` 픽셀 크기 직접 입력(예 `1920x1080`) → 해당 크기 박스가 커서를 따라다니고 클릭으로 캡처
- **윈도우 캡처** `⌃⌥W` — 호버로 윈도우 하이라이트 후 클릭 캡처
- **마지막 영역 재캡처** `⌃⌥R` — 같은 영역 즉시 재촬영
- **클립보드 붙여넣기** `⌃⌥V` — 클립보드의 이미지를 플로팅 창으로
- **모든 창 숨기기/보이기** `⌃⌥H` — 띄워둔 창 전체를 잠시 치웠다가 그대로 복귀
- **닫은 창 복원** `⌃⌥Z` — 마지막으로 닫은 창을 원래 위치·크기로 다시 표시 (최대 10개까지 순서대로 복원)
- 이미지 파일(JPG/PNG 등)을 메뉴에서 열어 플로팅 (포토프레임)
- 캡처 화면에서 `M`으로 돋보기 토글(기본 꺼짐) + `C`로 픽셀 HEX 컬러 복사
- 상단 힌트 바: 동작 칩(M 돋보기 · C 컬러 복사 · Esc 취소) + 비율 칩(`1. 자유`~`6. 직접입력`, 현재 비율 하이라이트)

## 플로팅 창 조작

| 동작 | 방법 |
|---|---|
| 이동 | 드래그 (화면/다른 창 모서리·중앙에 자동 스냅), 방향키 1pt / `⇧방향키` 10pt 미세 이동 |
| 회전/반전 | `R` 90° 시계, `⇧R` 반시계, `F` 좌우 반전 — 이미지에 실제 적용 |
| 파일로 드래그 | 우클릭 드래그 — Finder/슬랙/메일 등에 이미지로 드롭 |
| 크기 조절 | 스크롤 (커서 기준 줌), 모서리·가장자리 드래그 — 기본 비율 유지, `L` 또는 툴바 🔒 해제 시 자유. 조절 중 하단에 치수 배지 표시 |
| 축소/복원 | 더블클릭 — 썸네일로 접기/펴기 |
| 이미지 복사 | 클릭 또는 `⌘C` |
| 저장 | `⌘S` (PNG/JPEG) |
| 펜으로 표시 | `P` — 주석 모드 진입 (아래 도구 참고) |
| 텍스트 추출 | 툴바 OCR 버튼 또는 우클릭 메뉴 — Vision으로 텍스트 인식 → 클립보드 복사 |
| 항상 위 토글 | `T` 또는 우클릭 메뉴 |
| 클릭-스루 모드 | `G` 또는 우클릭 메뉴 (마우스가 창을 통과) |
| 투명도 | `⌥스크롤` 또는 우클릭 메뉴 |
| 닫기 | `⌘W` 또는 `Esc` |

창 위에 마우스를 올리면 우측 상단에 툴바가 나타납니다 — 펜 · 복사 ·
저장 · OCR · 비율 잠금 · 닫기 버튼.

펜 모드(`P`)에서는 주석 도구를 제공합니다 — **펜(자유곡선) · 형광펜(반투명 강조 밴드) · 화살표 ·
사각형 · 모자이크 · 텍스트**, 색상 4색, 되돌리기(`⌘Z`), 전체 지우기.
모자이크는 민감정보를 가릴 때 유용하고, 텍스트는 클릭한 지점에 바로
입력됩니다. 완료(✓)하면 주석이 원본 해상도로 이미지에 굽혀서
복사/저장에 그대로 반영됩니다. `Esc`/`P`는 버리고 종료.

메뉴바 아이콘에서 최근 캡처 히스토리 재표시, 전체 창 닫기,
클릭-스루 일괄 해제, 설정, 단축키 보기를 제공합니다.
단축키는 설정에서 모두 재지정할 수 있습니다.
