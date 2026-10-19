# Indoor Sensor Simulator

**Mac에서 실내지도의 가상 사용자를 움직이며, iOS 앱의 현재 위치·길찾기·센서 처리를 테스트하는 도구입니다.** 실제 건물에 가지 않고도 이동, 층 변경, Wi-Fi 공유기와 BLE 비콘 배치를 바꿔 볼 수 있습니다.

> [!IMPORTANT]
> **처음이라면 아래 「1. 설치하기」 → 「2. 첫 테스트」 순서로 따라 하세요.**
> 이 저장소는 소스에서 Mac 앱을 빌드하는 방식으로 안내합니다. **테스트할 IMDF 지도와 iOS 앱은 별도로 준비해야 합니다.**

| 실행하는 것 | 역할 |
| --- | --- |
| **Indoor Sensor Simulator** — Mac 앱 | 지도를 열고 가상 사용자·공유기·비콘을 조작하는 컨트롤러 |
| **Xcode의 iOS Simulator** — 가상 iPhone/iPad | 테스트할 iOS 앱을 실행하고, Mac 컨트롤러가 보내는 위치나 센서 데이터를 받는 기기 |

**바로가기:** [설치하기](#1-설치하기) · [첫 테스트](#2-첫-테스트) · [조작법](#3-기본-조작법) · [센서 연결](#4-ios-앱에-센서-데이터-연결하기) · [문제 해결](#5-문제가-생겼을-때) · [기술 설명](#6-동작-구조와-기술-설명)

## 1. 설치하기

### 준비물

| 준비물 | 확인할 내용 |
| --- | --- |
| Mac | **macOS 15 이상**. 설치할 Xcode의 macOS 요구사항도 충족해야 합니다. |
| Xcode 전체 앱 | **Swift 6.0 이상**이 포함된 버전. Command Line Tools만 설치하면 iOS Simulator를 사용할 수 없습니다. |
| iOS Simulator 런타임 | 테스트할 앱이 실행되는 iOS 버전. 아래 센서 브리지 패키지를 연결하려면 **iOS 18 이상**이 필요합니다. |
| IMDF 지도 | 건물의 실내지도 폴더 또는 `.zip`. 지도 이미지나 PDF가 아닌 IMDF 데이터가 필요합니다. |
| 테스트할 iOS 앱 | Xcode에서 Simulator로 실행할 수 있는 앱. Mac 지도 조작만 확인할 때는 없어도 됩니다. |

Xcode는 [Apple 공식 다운로드 안내](https://developer.apple.com/xcode/resources/)에서 설치할 수 있습니다. Mac에 맞는 버전은 [Xcode 지원 환경](https://developer.apple.com/support/xcode/)을 확인하세요.

### ① Xcode를 한 번 설정합니다

1. Xcode를 열고 첫 실행 시 표시되는 추가 구성요소 설치와 사용권 동의를 완료합니다.
2. **Xcode → Settings → Components**에서 iOS 플랫폼 지원과 필요한 Simulator 런타임을 설치합니다. Xcode 버전에 따라 해당 항목이 **Platforms**에 표시될 수 있습니다. [Apple 설치 안내](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)
3. **Xcode → Settings → Locations → Command Line Tools**에서 설치한 Xcode를 선택합니다. [Apple 설정 안내](https://developer.apple.com/documentation/xcode/configuring-command-line-tools-settings)

Mac의 **터미널** 앱을 열고 다음 명령을 한 줄씩 실행해 확인합니다.

```sh
swift --version
xcode-select -p
xcrun simctl list devices booted
```

Swift 버전이 6.0 이상이고, 개발 도구 경로가 선택한 Xcode 앱 내부의 `Contents/Developer`를 가리키면 준비된 상태입니다. 마지막 명령에서 기기가 나오지 않아도 괜찮습니다. 아직 가상 iPhone을 켜지 않았기 때문입니다.

### ② 프로젝트를 다운로드하고 Mac 앱을 실행합니다

터미널에서 아래 명령을 **한 줄씩 순서대로** 실행합니다. 현재 폴더 아래에 `IndoorPositioningSimulator` 폴더가 만들어집니다.

```sh
git clone https://github.com/adap-c6-fingerprint/IndoorPositioningSimulator.git
cd IndoorPositioningSimulator
./Scripts/build-app.sh
open '.build/Indoor Sensor Simulator.app'
```

이미 프로젝트를 다운로드했다면 `git clone`을 다시 실행하지 말고, **`Package.swift`와 `Scripts`가 들어 있는 프로젝트 폴더로 이동한 뒤** 마지막 두 명령을 실행하세요.

빌드 중에는 터미널을 닫지 말고 완료될 때까지 기다립니다. **`Indoor Sensor Simulator` 창에 `1단계 · IMDF 지도 열기…` 버튼이 보이면 실행 성공입니다.** 이전에 지도를 열었다면 해당 지도가 바로 표시됩니다.

### ③ 다음 실행부터는 앱만 엽니다

프로젝트 폴더에서 다음 명령만 실행하면 됩니다.

```sh
open '.build/Indoor Sensor Simulator.app'
```

Finder에서 실행하려면 프로젝트 폴더를 연 뒤 **`⌘⇧.`**으로 숨김 항목을 표시하고, `.build` 안의 `Indoor Sensor Simulator.app`을 더블 클릭합니다. 소스가 바뀐 뒤에는 `./Scripts/build-app.sh`를 다시 실행하세요.

## 2. 첫 테스트

**처음에는 좌표 전달부터 확인하세요.** 테스트 앱이 `CLLocationManager`로 위치를 받는다면, 이 단계에서는 Swift 패키지를 추가하지 않아도 됩니다. Wi-Fi·BLE·Motion과 층·방향 데이터까지 받으려면 [4번 센서 연결](#4-ios-앱에-센서-데이터-연결하기)을 이어서 진행합니다.

### ① IMDF 지도를 엽니다

Mac 컨트롤러에서 **`1단계 · IMDF 지도 열기…`** 또는 왼쪽 **`IMDF 열기…`**를 누르고, 준비한 IMDF 폴더나 ZIP을 선택합니다. **가운데에 실내지도와 초록 점이 나타나면 지도 준비 완료입니다.** 초록 점은 조작할 가상 사용자이고, 부채꼴은 사용자가 바라보는 방향입니다.

IMDF는 층·방·시설의 모양과 좌표가 담긴 실내지도 형식입니다. 폴더 안에는 `level.geojson`이 있어야 합니다. 아래는 지도 파일 구성의 예입니다.

```text
my-building/
├── level.geojson       # 층 정보와 경계 — 필수
├── unit.geojson        # 방, 통로, 계단 등의 정보 — 있으면 함께 읽음
├── fixture.geojson     # 시설물의 모양 — 있으면 함께 읽음
├── venue.geojson       # 건물 이름 등 — 있으면 함께 읽음
└── manifest.json       # 지도 버전 등 — 있으면 함께 읽음
```

보유한 IMDF가 없다면 지도 담당자에게 데이터를 요청하세요. 형식과 활용 예는 [Apple의 실내지도 샘플 안내](https://developer.apple.com/documentation/mapkit/displaying-an-indoor-map)에서 확인할 수 있습니다. 한 번 연 지도는 다음 실행부터 자동으로 다시 열립니다.

### ② 테스트할 iOS 앱을 가상 iPhone에서 실행합니다

1. **테스트할 iOS 앱의 Xcode 프로젝트**를 엽니다.
2. Xcode 상단의 실행 대상을 실제 iPhone 대신 **iPhone Simulator 기기**로 선택합니다.
3. **`⌘R`**을 눌러 실행하고, 가상 iPhone 화면에 앱이 뜰 때까지 기다립니다.
4. 앱이 위치 권한을 요청하면 허용합니다. 앱에 위치 수신 기능과 위치 권한 설정이 있어야 좌표를 확인할 수 있습니다.

Mac 컨트롤러는 iOS 앱을 대신 실행하지 않습니다. Xcode에서 실행한 앱을 켜 둔 채 다음 단계로 넘어갑니다.

### ③ 위치를 보낼 기기를 선택합니다

Mac 컨트롤러 오른쪽 **`빠른 시작 → 위치 보낼 기기`**에서 방금 실행한 Simulator를 선택합니다. 목록에 없다면 옆의 **새로고침 아이콘**을 누릅니다.

오른쪽 **`iOS Simulator 연결 → Core Location도 주입`**을 켭니다. 해당 영역에 **`선택한 기기 이름에 전달 중`** 상태가 표시되면 좌표를 보내고 있는 상태입니다.

### ④ 지도 위에서 이동합니다

Mac 컨트롤러의 지도 영역을 클릭한 뒤 **키보드 방향키를 길게 누르거나**, 지도 위 **화면 방향 버튼을 길게 누릅니다**. 초록 점이 이동하고, 연결한 iOS 앱에서 수신하는 위치도 바뀌는지 확인합니다.

> [!TIP]
> **첫 확인 기준:** Mac 지도에서 초록 점이 움직이고, 위치를 수신하도록 구현한 iOS 앱에서 좌표 또는 현재 위치 표시가 바뀌면 성공입니다.
> **`센서 브리지 0개 앱`은 좌표만 전달할 때 정상입니다.** 이 숫자는 아래 4번의 센서 클라이언트를 연결했을 때 증가합니다.

iOS 앱에 현재 위치 표시나 길찾기 기능이 없다면 이 도구가 해당 UI를 추가해 주지는 않습니다. 현재 위치를 나타내는 Blue Dot과 경로 계산은 테스트할 앱이 처리합니다.

## 3. 기본 조작법

| 하고 싶은 일 | 조작 방법 |
| --- | --- |
| 사용자 이동 | 지도 영역 클릭 후 방향키 길게 누르기 또는 화면 방향 버튼 길게 누르기 |
| 사용자 위치 옮기기 | 초록 점을 드래그해 이동 가능한 공간에 놓기 |
| 지도 확대·축소 | 트랙패드 핀치, 우측 상단 `− / +`, `⌘- / ⌘+` |
| 지도 전체 보기 | 우측 상단 확대 비율 버튼 또는 `⌘0` |
| 확대된 지도 이동 | 트랙패드 두 손가락 스와이프 |
| 표시할 층 선택 | 왼쪽 층 목록에서 선택 |
| 보행 중 위층·아래층 이동 | 계단·엘리베이터·에스컬레이터 안으로 이동한 뒤 오른쪽 `위층 / 아래층` 버튼 누르기 |
| 공유기·비콘 배치 변경 | 보라색 Wi-Fi 또는 주황색 BLE 비콘을 드래그 |
| 공유기·비콘 추가 | 왼쪽 신호원 목록의 `+ Wi-Fi / + Beacon` 버튼 |
| 신호 세기 조절 | 신호원을 선택한 뒤 오른쪽에서 `1m 기준 RSSI`와 감쇠 계수 조절 |
| 배치 저장·불러오기 | 왼쪽 `시나리오 저장… / 시나리오 열기…`. 다시 사용할 때는 해당 IMDF 지도를 먼저 열고 시나리오 JSON을 불러오기 |

벽과 시설물은 통과할 수 없습니다. 이동이 멈추면 방향을 바꾸거나 초록 점을 통로 쪽으로 옮겨 보세요.

### 테스트 목적에 맞는 모드 선택

오른쪽 **`테스트 모드 → Wi-Fi 위치 기반 측위`**로 전송할 센서 프레임의 모드를 바꿉니다.

| 목적 | 토글 | 동작 |
| --- | --- | --- |
| **길찾기 QA** — 경로 생성·재탐색·도착 판정 확인 | **끔** | 노이즈 없이 가상 사용자의 위치·층·방향을 전달하는 `groundTruth` 모드 |
| **측위 QA** — 신호가 약하거나 부족할 때의 동작 확인 | **켬** | Wi-Fi·BLE 신호와 노이즈가 포함된 `radioBased` 모드. 앱의 측위 엔진이나 Debug 어댑터에서 이를 처리 |

**센서 브리지를 연결하고 앱에서 모드를 처리해야 위 동작이 반영됩니다.** `Core Location도 주입`으로 보내는 좌표는 두 모드 모두 가상 사용자의 좌표입니다. 토글만으로 iOS의 실제 Wi-Fi·BLE 센서나 외부 측위 SDK의 계산 결과가 바뀌지는 않습니다.

## 4. iOS 앱에 센서 데이터 연결하기

**좌표 전달을 넘어, 가짜 Wi-Fi·BLE 관측값과 움직임 센서, 층·방향을 앱에서 받아야 할 때 진행합니다.** 같은 Mac에서 실행하는 iOS Simulator 앱이 Swift 패키지의 클라이언트로 Mac 컨트롤러에 연결하는 방식입니다.

### ① Swift 패키지를 추가합니다

1. 테스트할 iOS 앱의 Xcode에서 **File → Add Package Dependencies… → Add Local…**을 선택합니다.
2. 다운로드한 **`IndoorPositioningSimulator` 폴더**를 선택합니다. `Package.swift`가 들어 있는 폴더입니다.
3. 제품 목록에서 **`IndoorPositioningSimulation`**을 선택하고, 테스트할 **iOS 앱 타깃**에 추가합니다. Mac 실행 파일인 `IMDFSimulator`와 구분하세요.
4. 앱 타깃의 최소 iOS 버전이 **18 이상**인지 확인합니다.

자세한 메뉴 흐름은 [Apple의 로컬 패키지 추가 안내](https://developer.apple.com/documentation/xcode/editing-a-package-dependency-as-a-local-package)를 참고하세요.

### ② 먼저 센서 데이터 수신을 확인합니다

다음은 **연결 확인용 SwiftUI 화면**입니다. iOS 앱에 추가한 뒤, 테스트할 화면에서 `SimulationConnectionCheckView()`를 표시하세요. Mac 컨트롤러에서 지도를 열어 둔 상태로 iOS 앱을 다시 실행합니다.

```swift
import IndoorPositioningSimulation
import SwiftUI

struct SimulationConnectionCheckView: View {
    @State private var status = "센서 연결 대기 중"

    var body: some View {
        Text(status)
            .task {
                #if DEBUG && targetEnvironment(simulator)
                do {
                    let client = try SimulationSessionClient()
                    defer { client.stop() }

                    for await frame in client.frames() {
                        guard !Task.isCancelled else { break }
                        status = "Wi-Fi \(frame.wifi.count)개 · BLE \(frame.bluetooth.count)개"
                    }
                } catch {
                    status = error.localizedDescription
                }
                #else
                status = "Debug iOS Simulator에서 실행하세요"
                #endif
            }
    }
}
```

**Mac 컨트롤러에 `센서 브리지 1개 앱`이 표시되고, iOS 화면의 대기 문구가 Wi-Fi·BLE 개수로 바뀌면 연결 성공입니다.** 신호원이 없는 위치에서는 개수가 0일 수 있습니다. 기본 연결 주소는 같은 Mac의 `127.0.0.1:57575`입니다.

### ③ 앱의 위치·센서 처리에 연결합니다

위 예제는 수신 여부만 표시합니다. 실제 현재 위치나 길찾기에 사용하려면 앱의 담당 코드에 데이터를 전달해야 합니다.

| 받은 값 | 앱에서 연결할 곳 |
| --- | --- |
| `frame.device.position.coordinate` | Debug 위치 공급자의 위도·경도 |
| `frame.device.position.levelOrdinal` | 층 정보 |
| `frame.device.headingDegrees` | 사용자가 바라보는 방향 |
| `frame.wifi`, `frame.bluetooth`, `frame.motion` | 자체 측위 엔진의 센서 입력 |
| `frame.positioningMode` | `.groundTruth`이면 좌표·층·방향을 그대로 사용하고, `.radioBased`이면 앱의 측위 처리로 전달 |

Wi-Fi·BLE 관측값은 각각의 `observedAt`이 바뀐 경우에 새 측정값으로 처리합니다. 기존 앱의 위치 공급자·센서 프로토콜에 Debug 어댑터를 연결하는 구성을 권장합니다.

Mac 컨트롤러를 켜 둔 채 iOS 앱을 재실행하면 클라이언트가 다시 연결됩니다. 여러 iOS 앱을 동시에 연결할 수도 있습니다.

## 5. 문제가 생겼을 때

| 증상 | 먼저 확인할 것 |
| --- | --- |
| `swift` 또는 `simctl`을 찾을 수 없음, 개발 도구 경로 오류 | Xcode 전체 앱 설치와 첫 실행을 완료하고, `Settings → Locations → Command Line Tools`에서 Xcode를 선택합니다. |
| `./Scripts/build-app.sh` 파일을 찾을 수 없음 | 터미널에서 `pwd`와 `ls`로 현재 폴더를 확인합니다. `Package.swift`와 `Scripts`가 보이는 프로젝트 폴더에서 실행해야 합니다. |
| `.app`이 없거나 열리지 않음 | 먼저 `./Scripts/build-app.sh`가 오류 없이 끝났는지 확인합니다. 앱 경로의 공백을 포함해 `open '.build/Indoor Sensor Simulator.app'`을 실행합니다. |
| IMDF 지도가 열리지 않음 | 폴더나 ZIP 안에 `level.geojson`과 유효한 층 경계 데이터가 있는지 확인합니다. 개별 GeoJSON 파일이나 지도 이미지를 선택하지 않습니다. |
| `iOS Simulator를 먼저 실행하세요` 표시 | Xcode에서 테스트 앱을 iPhone Simulator 대상으로 실행한 뒤 Mac 컨트롤러의 새로고침 아이콘을 누릅니다. 부팅된 기기만 목록에 나옵니다. |
| Mac의 점은 움직이는데 iOS 앱 위치는 그대로 | `위치 보낼 기기`, `Core Location도 주입`, 앱의 위치 권한과 실제로 사용하는 위치 공급자를 확인합니다. 외부 측위 SDK를 사용하는 앱은 별도 Debug 어댑터가 필요할 수 있습니다. |
| `센서 브리지 0개 앱` 표시 | 좌표만 전달한다면 정상입니다. 센서 연결이 목적이라면 패키지를 iOS 앱 타깃에 추가하고 `client.frames()`를 구독하는 화면이나 코드를 실행했는지 확인합니다. |
| 방향키를 눌러도 움직이지 않음 | Mac 컨트롤러의 지도 영역을 클릭하거나 화면 방향 버튼을 사용합니다. 벽·시설물에 막혔다면 다른 방향으로 이동합니다. |
| `위층 / 아래층`으로 이동하지 않음 | 지도에 연결 가능한 층이 있는지, 사용자가 계단·엘리베이터·에스컬레이터 안에 있는지 확인합니다. |
| 센서 서버가 연결되지 않음 | Mac 컨트롤러를 여러 개 실행했다면 하나만 남기고 다시 실행합니다. 기본 포트 `57575`가 다른 프로그램에서 사용 중인지도 확인합니다. |

## 6. 동작 구조와 기술 설명

### 구성

```text
IMDF archive
     │
     ▼
Indoor Sensor Simulator.app
  ├─ 방향키 연속 이동 / 충돌 검사 / 층 이동
  ├─ Wi-Fi AP · BLE beacon 배치 편집
  ├─ Core Location ── simctl ─────────▶ iOS Simulator OS
  └─ SensorFrame ─── localhost:57575 ─▶ iOS 앱 Swift 센서 브리지
                                           │
                          ┌────────────────┴───────────────┐
                          ▼                                ▼
                    자체 측위 엔진                 Debug 위치 어댑터
                    원시 센서 입력                 앱 UI·길찾기 QA
```

- `IndoorPositioningSimulation`: iOS 18/macOS 15용 Swift Package 라이브러리
- `IMDFSimulator`: SwiftUI macOS 컨트롤러 실행 파일
- `SimulationSessionServer`: Mac의 TCP 센서 프레임 발행기
- `SimulationSessionClient`: 여러 iOS 앱이 동시에 붙을 수 있는 자동 재연결 클라이언트

Mac 앱을 종료하지 않는 한 대상 앱을 재실행해도 같은 세션에 다시 연결된다.

### 두 가지 테스트 모드의 세부 동작

Inspector의 `Wi-Fi 위치 기반 측위` 토글로 QA 목적을 분리한다.

- 켜짐 · **측위 QA**: Wi-Fi/BLE 개수, RSSI, 거리 감쇠와 센서 노이즈가 위치
  가용성·정확도·흔들림에 영향을 준다. 공유기와 비콘 배치 및 측위 실패 조건을
  테스트할 때 사용한다.
- 꺼짐 · **길찾기 QA**: `positioningMode`가 `groundTruth`로 전송된다. 센서 생성기는
  노이즈 설정과 무관하게 모든 랜덤 노이즈를 0으로 강제하고, Debug 위치 어댑터는
  radio coverage 판정을 건너뛰어 가상 디바이스의 좌표·층·방향을 그대로 사용한다.
  위치가 보장된 상태에서 경로 생성, 재탐색, 도착 판정과 현재 위치 UI를 테스트한다.

길찾기 QA에서도 Wi-Fi/BLE 관측값은 디버깅을 위해 전달하지만 거리 모델의 결정적인
값만 사용하며 Blue Dot에는 영향을 주지 않는다. 모드를 다시 켜면 기존 측위 QA
동작과 `현실적 센서 노이즈` 설정이 복원된다.

### 센서 프레임

`SimulationSensorFrame`과 Motion은 기본 50Hz로 발행된다. Wi-Fi 관측은 1Hz,
Bluetooth 관측은 10Hz로 갱신되며 frame에는 각 센서의 최신 snapshot과
`observedAt`이 들어간다. 입력별 source는 같은 관측값을 중복 발행하지 않는다.

- Ground truth: WGS84 위도·경도, IMDF level ordinal, 방향, 보행 여부, 속도
- Wi-Fi: BSSID, SSID, RSSI(dBm), channel, frequency(MHz)
- Bluetooth: peripheral UUID, name, RSSI, iBeacon UUID/major/minor/measured power
- Motion: user acceleration, gravity, rotation rate, magnetic field, attitude,
  quaternion, magnetic heading

기본 보행은 휴대폰을 손에 고정한 상태, 1.125m/s로 설정했다. 방향키를 누르는 동안
계속 이동하며 마지막으로 누른 방향이 디바이스 방향과 시야 부채꼴이 된다.

`현실적 센서 노이즈`는 기본으로 켜진다. 정지 중에는 Wi-Fi RSSI 0.75dB, BLE RSSI
1.2dB 수준의 느린 드리프트만 적용하고, 보행 중에는 각각 3dB와 4dB까지 변동 폭을
키운다. 가속도·중력·자이로·자기장·방향에도 노이즈를 적용한다. Radio 노이즈는
시간 상관성을 가지므로 값이 프레임마다 완전히 독립적으로 튀지 않으며, 약한 신호는
`-95dBm` 경계를 오가며 탐지 목록에서 나타났다 사라질 수 있다. 같은 seed에서는
동일한 파형을 만들어 회귀 QA가 재현 가능하다. Inspector의 토글로 noise-free
baseline과 비교할 수 있다.

센서 프레임의 radio coverage 진단은 관측 가능한 Wi-Fi와 Bluetooth가 3개
미만이면 무조건 `insufficient`로 표시한다. 3개 이상에서는 개수와 RSSI 기반
유효 신호량을 함께 평가해 `limited` 또는 `sufficient`를 정한다. 이 값은 QA
경고이며 실제 위치 계산은 대상 앱의 측위 엔진이 담당한다.

Wi-Fi와 BLE RSSI는 1m 기준 신호 세기와 path-loss exponent를 사용하는 log-distance
모델로 계산한다. 신호원을 드래그하거나 inspector의 값을 바꾸면 다음 프레임부터
관측값이 달라진다.

새 Wi-Fi AP의 기본값은 1m에서 `-40dBm`, 실내 경로손실 지수 `3.0`이다. 따라서
장애물이 섞인 일반 사무공간 기준으로 약 10m에서 `-70dBm`, 30m에서 `-84dBm`
수준으로 감소하고 `-95dBm` 아래에서는 관측 목록에서 사라진다. Inspector에서
AP별 기준 RSSI와 감쇠 계수를 조정해 건물 측정값으로 보정할 수 있다.

Debug 위치 어댑터의 예상 정확도는 AP 개수만 세지 않는다. 가장 강한 상위 4개
신호의 평균 RSSI, 전체 유효 신호량, 관측 개수를 함께 사용한다. 같은 6개 AP가
보여도 신호가 약해지면 `sufficient`에서 `limited`, `insufficient`로 내려가고
정확도 반경과 Blue Dot 흔들림이 커진다.
정지 상태에서는 정확도 값을 저역통과 필터로 완만하게 갱신하고 Blue Dot drift를
정확도 반경의 약 4% 이내로 제한한다. 이동 중에는 반응성을 높여 경로 변화와 신호
품질 저하가 더 빠르게 보이도록 한다.

### 입력별 센서 프로토콜

전체 프레임 대신 입력별 프로토콜을 사용할 수도 있다. 아래의 `client`는
`SimulationSessionClient` 인스턴스다.

```swift
let wifiSource: any SimulatedWiFiSignalSource = client
let bluetoothSource: any SimulatedBluetoothSignalSource = client
let motionSource: any SimulatedMotionSource = client
```

운영 코드가 `WiFiSignalSource`, `BluetoothSignalSource`, `MotionSource` 같은 앱 소유
프로토콜에 의존하도록 만들고, Debug iOS Simulator 빌드에서만 위 클라이언트를
adapter로 선택한다. 이 구조에서는 대상 앱의 지도 모델이나 UI에 시뮬레이터가
종속되지 않는다.

별도 프로젝트인 `ShowcaseMap-IndoorAtlas`에는 Debug Simulator 위치 어댑터가
연결되어 있다. 해당 iOS 앱은 이 저장소에 포함되어 있지 않다.
측위 QA에서는 radio quality 기반 오차를 적용하고, 길찾기 QA에서는 정확한 원격
ground truth로 Blue Dot UI를 확인한다.
`INDOOR_POSITION_SOURCE=live` 환경 변수를 지정하면 기존 IndoorAtlas 경로를 사용한다.

### 플랫폼 경계

위도·경도는 `xcrun simctl location`으로 선택한 iOS Simulator에 전달한다.
`CLLocationManager`를 사용하는 앱에서 받을 수 있으며, 이 경로에는 Swift 센서
브리지가 필요하지 않다.

Wi-Fi·BLE·Motion·층·방향 데이터는 Swift 센서 브리지로 전달한다.
iOS Simulator 운영체제의 Wi-Fi 스캔, BLE 스캔, Core Motion 측정값을 직접
바꾸는 방식이 아니므로 대상 앱에서 클라이언트와 입력 어댑터를 연결해야 한다.

IndoorAtlas나 Apple Indoor Positioning 같은 외부 엔진의 내부 센서 융합을
검증하는 용도로는 사용할 수 없다. 이 도구로 앱 기능을 테스트할 때는 Debug
어댑터가 시뮬레이션 위치·층·방향을 앱의 위치 공급자에 전달하도록 구성한다.
자체 측위 엔진은 원시 센서 스트림을 입력으로 연결할 수 있다.

### 개발 중 실행 및 테스트

프로젝트 폴더에서 실행한다.

```sh
swift run IMDFSimulator
```

라이브러리 테스트:

```sh
swift test
```

빌드 캐시에서 `resource fork, Finder information, or similar detritus not allowed`
서명 오류가 발생하면 별도 임시 폴더에서 빌드해 확인할 수 있다.

```sh
swift test --scratch-path /private/tmp/IndoorPositioningSimulator-tests
```

### 현재 제외한 범위

- 실제 iOS Wi-Fi/Bluetooth/Core Motion framework로의 가짜 원시값 주입
- IndoorAtlas 또는 Apple 내부 센서 융합 알고리즘의 Simulator 검증
- 센서 단절·고정값·급격한 drift 같은 고장 주입
- record/replay 및 headless CI assertions

마지막 두 항목은 센서 프레임 계약을 그대로 사용해 후속으로 추가할 수 있다.
