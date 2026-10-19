# Indoor Sensor Simulator

실내지도 앱을 현장에 가지 않고 QA하기 위한 macOS 컨트롤러와 범용 Swift 센서
브리지 패키지다. Mac 앱은 가상 디바이스의 위치와 공유기·비콘 배치를 관리하고,
대상 iOS Simulator 앱은 같은 세션에서 위치 또는 원시 센서 프레임을 받는다.

Mac 앱은 Blue Dot을 계산하지 않는다. Blue Dot과 경로 재탐색 같은 기능은 대상
앱 또는 대상 앱이 선택한 측위 엔진의 책임이다.

## 플랫폼 경계

iOS Simulator 운영체제에는 임의의 Wi-Fi 스캔, BLE 스캔, Core Motion 측정값을
주입하는 공개 API가 없다. 따라서 두 가지 전달 경로를 함께 사용한다.

1. `Core Location`: Mac 앱이 `xcrun simctl location`으로 booted iOS
   Simulator에 WGS84 위치를 전달한다. 별도 앱 연동 없이 `CLLocationManager`를
   사용하는 앱에서 확인할 수 있다.
2. `Wi-Fi · BLE · Motion · floor · heading`: 대상 앱이
   `IndoorPositioningSimulation` Swift Package를 추가하고 localhost 센서 세션을
   구독한다. 자체 측위 엔진은 이 원시 스트림으로 위치를 직접 계산한다.

IndoorAtlas와 Apple Indoor Positioning은 내부 센서 융합에 가짜 원시 센서를 넣는
공개 API를 제공하지 않는다. 따라서 이 엔진들을 사용하는 앱은 다음 중 하나를
선택해야 한다.

- 엔진 자체 검증: 실제 디바이스와 실제 현장에서 수행한다.
- 앱 기능 검증: Debug 어댑터가 시뮬레이션 위치·층·방향을 앱의 위치 공급자에
  전달한다.
- 자체 엔진 비교: 아래 원시 센서 스트림을 각 엔진의 입력 프로토콜에 연결한다.

## 구성

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

## 두 가지 테스트 모드

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

## 센서 프레임

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

## 실행 및 사용

개발 중 실행:

```sh
swift run IMDFSimulator
```

앱 번들 생성:

```sh
./Scripts/build-app.sh
open '.build/Indoor Sensor Simulator.app'
```

사용 순서:

1. Xcode에서 테스트할 iOS Simulator와 대상 앱을 실행한다.
2. `Indoor Sensor Simulator.app`에서 IMDF 폴더 또는 ZIP을 연다.
   한 번 연 지도는 다음 실행부터 자동으로 다시 열린다.
3. 오른쪽 `빠른 시작`에서 위치를 전달할 iOS Simulator를 선택한다.
4. 트랙패드 두 손가락 스와이프로 지도를 관성 이동하고 핀치로 확대·축소한다.
   100%보다 확대된 상태에서 상하좌우로 이동할 수 있다. 우측 상단의
   `− / + / 맞춤` 버튼과 `⌘- / ⌘+ / ⌘0` 단축키도 사용할 수 있다. 지도 위
   방향 패드를 길게 누르거나, 지도 영역을 클릭한 뒤 키보드 방향키를 누르는
   동안 가상 디바이스를 이동한다.
5. `Wi-Fi 위치 기반 측위`를 켜서 측위를 검증하거나, 꺼서 위치가 보장된 길찾기를
   검증한다.
6. 보라색 Wi-Fi 또는 주황색 BLE beacon을 드래그해 배치를 바꾼다.
7. Mac inspector에서 센서 브리지에 연결된 앱 개수를 확인한다.
8. 계단·엘리베이터·에스컬레이터 unit 안에서는 위층/아래층 버튼으로 층을 바꾼다.

IMDF의 level 경계, `structure` unit, `fixture` polygon은 충돌 영역으로 처리된다.
따라서 벽과 책상 내부로 이동하거나 통과할 수 없다.

## 대상 앱 연결

Xcode 프로젝트에 이 폴더를 Local Package로 추가하고
`IndoorPositioningSimulation` product를 대상 앱 target에 연결한다.

전체 프레임을 직접 소비하는 예:

```swift
import IndoorPositioningSimulation

let client = try SimulationSessionClient()

Task {
    for await frame in client.frames() {
        if frame.positioningMode == .groundTruth {
            debugLocationProvider.update(
                coordinate: frame.device.position.coordinate,
                levelOrdinal: frame.device.position.levelOrdinal,
                heading: frame.device.headingDegrees
            )
            continue
        }

        // Wi-Fi/BLE는 observedAt이 바뀐 경우에만 새 관측으로 처리한다.
        positioningEngine.consume(
            wifi: frame.wifi,
            bluetooth: frame.bluetooth,
            motion: frame.motion,
            floorHint: frame.device.position.levelOrdinal
        )
    }
}
```

입력별 프로토콜도 제공한다.

```swift
let wifiSource: any SimulatedWiFiSignalSource = client
let bluetoothSource: any SimulatedBluetoothSignalSource = client
let motionSource: any SimulatedMotionSource = client
```

운영 코드가 `WiFiSignalSource`, `BluetoothSignalSource`, `MotionSource` 같은 앱 소유
프로토콜에 의존하도록 만들고, Debug iOS Simulator 빌드에서만 위 클라이언트를
adapter로 선택한다. 이 구조에서는 대상 앱의 지도 모델이나 UI에 시뮬레이터가
종속되지 않는다.

`ShowcaseMap-IndoorAtlas`에는 Debug Simulator 위치 어댑터가 이미 연결되어 있다.
측위 QA에서는 radio quality 기반 오차를 적용하고, 길찾기 QA에서는 정확한 원격
ground truth로 Blue Dot UI를 확인한다.
`INDOOR_POSITION_SOURCE=live` 환경 변수를 지정하면 기존 IndoorAtlas 경로를 사용한다.

## 현재 제외한 범위

- 실제 iOS Wi-Fi/Bluetooth/Core Motion framework로의 가짜 원시값 주입
- IndoorAtlas 또는 Apple 내부 센서 융합 알고리즘의 Simulator 검증
- 센서 단절·고정값·급격한 drift 같은 고장 주입
- record/replay 및 headless CI assertions

마지막 두 항목은 센서 프레임 계약을 그대로 사용해 후속으로 추가할 수 있다.
