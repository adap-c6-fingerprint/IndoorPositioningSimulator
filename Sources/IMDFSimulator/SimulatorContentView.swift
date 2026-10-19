import IndoorPositioningSimulation
import SwiftUI

struct SimulatorContentView: View {
    @Bindable var model: SimulatorAppModel

    var body: some View {
        NavigationSplitView {
            SimulatorSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            if model.selectedLevel != nil,
               model.scenario != nil,
               model.simulator != nil
            {
                VStack(spacing: 0) {
                    SimulatorStatusBar(model: model)
                    Divider()
                    HSplitView {
                        SimulatorCanvas(model: model)
                            .frame(minWidth: 600)
                        SimulatorInspector(model: model)
                            .frame(minWidth: 280, idealWidth: 310, maxWidth: 360)
                    }
                }
            } else {
                VStack(spacing: 24) {
                    Image(systemName: "map.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(.blue)
                    VStack(spacing: 8) {
                        Text("1분 만에 테스트 시작")
                            .font(.largeTitle.bold())
                        Text("지도를 한 번 열면 다음 실행부터 자동으로 다시 열립니다.")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        startStep(1, "IMDF 지도 열기", "폴더 또는 ZIP을 선택하세요.")
                        startStep(2, "iOS Simulator 실행", "Xcode에서 테스트할 앱을 실행하세요.")
                        startStep(3, "방향키로 이동", "화면 방향 버튼으로도 움직일 수 있습니다.")
                    }
                    Button("1단계 · IMDF 지도 열기…", systemImage: "folder.badge.plus") {
                        model.chooseIMDF()
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
                .padding(40)
            }
        }
        .alert(
            "시뮬레이터 오류",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("확인") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "알 수 없는 오류")
        }
    }

    private func startStep(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 30, height: 30)
                .background(.blue, in: Circle())
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SimulatorStatusBar: View {
    @Bindable var model: SimulatorAppModel

    var body: some View {
        HStack(spacing: 12) {
            status(
                "지도",
                value: model.selectedLevel?.shortName ?? "준비",
                systemImage: "map.fill",
                color: .blue
            )
            status(
                "위치 대상",
                value: model.selectedSimulator?.name ?? "선택 필요",
                systemImage: "iphone",
                color: model.selectedSimulator == nil ? .orange : .green
            )
            status(
                "센서 브리지",
                value: "\(model.connectedClientCount)개 앱",
                systemImage: "dot.radiowaves.left.and.right",
                color: model.connectedClientCount == 0 ? .secondary : .green
            )
            status(
                "테스트 모드",
                value: model.usesRadioPositioning ? "Wi‑Fi 측위" : "길찾기 QA",
                systemImage: model.usesRadioPositioning ? "wifi" : "point.topleft.down.to.point.bottomright.curvepath",
                color: model.usesRadioPositioning ? .orange : .blue
            )
            Spacer()
            Label("방향키 또는 화면 버튼으로 이동", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func status(
        _ title: String,
        value: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SimulatorSidebar: View {
    @Bindable var model: SimulatorAppModel

    var body: some View {
        List {
            Section {
                Button("IMDF 열기…", systemImage: "folder") {
                    model.chooseIMDF()
                }
                Button("시나리오 열기…", systemImage: "doc") {
                    model.chooseScenario()
                }
                Button("시나리오 저장…", systemImage: "square.and.arrow.down") {
                    model.saveScenario()
                }
                .disabled(model.scenario == nil)
            }

            if let map = model.map {
                Section("Venue") {
                    LabeledContent("이름", value: map.venueName)
                    if let version = map.manifestVersion {
                        LabeledContent("IMDF", value: version)
                    }
                }

                Section("층") {
                    ForEach(map.levels) { level in
                        Button {
                            model.selectLevel(level)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(level.shortName ?? level.name)
                                    Text("ordinal \(level.ordinal) · unit \(level.units.count)개")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.selectedLevel?.id == level.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let anchors = model.simulator?.radioEnvironment.anchors {
                Section("신호원") {
                    ForEach(anchors) { anchor in
                        Button {
                            model.selection = .anchor(anchor.id)
                        } label: {
                            HStack {
                                Image(systemName: anchor.kind == .wifi
                                    ? "wifi"
                                    : "antenna.radiowaves.left.and.right")
                                    .foregroundStyle(anchor.kind == .wifi ? .purple : .orange)
                                Text(anchor.id)
                                Spacer()
                                if model.selection == .anchor(anchor.id) {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    HStack {
                        Button("Wi‑Fi", systemImage: "plus") {
                            model.addAnchor(kind: .wifi)
                        }
                        Button("Beacon", systemImage: "plus") {
                            model.addAnchor(kind: .beacon)
                        }
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
        }
        .navigationTitle("Indoor Sensor Simulator")
    }
}

private struct SimulatorInspector: View {
    @Bindable var model: SimulatorAppModel

    var body: some View {
        Form {
            if let snapshot = model.snapshot {
                Section("빠른 시작") {
                    Label("지도 준비 완료", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)

                    if model.bootedSimulators.isEmpty {
                        Label("iOS Simulator를 먼저 실행하세요", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Picker("위치 보낼 기기", selection: $model.selectedSimulatorID) {
                            ForEach(model.bootedSimulators) { simulator in
                                Text(simulator.displayName)
                                    .tag(Optional(simulator.id))
                            }
                        }
                    }

                    HStack {
                        Label(
                            model.connectedClientCount == 0
                                ? "센서 앱 연결 대기"
                                : "센서 앱 \(model.connectedClientCount)개 연결됨",
                            systemImage: model.connectedClientCount == 0
                                ? "hourglass"
                                : "checkmark.circle.fill"
                        )
                        .foregroundStyle(
                            model.connectedClientCount == 0
                                ? Color.secondary
                                : Color.green
                        )
                        Spacer()
                        Button("새로고침", systemImage: "arrow.clockwise") {
                            Task { await model.refreshBootedSimulators() }
                        }
                        .labelStyle(.iconOnly)
                    }

                    Text("이제 지도 위 방향 버튼을 누르거나 키보드 방향키를 누르세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("가상 디바이스") {
                    LabeledContent("위치", value: meters(snapshot.actualPosition))
                    LabeledContent("방향", value: "\(Int(snapshot.heading))°")
                    LabeledContent("보행", value: model.isWalking ? "1.125 m/s" : "정지")
                    Button("사용자 선택", systemImage: "figure.walk") {
                        model.selection = .user
                    }
                }

                Section("테스트 모드") {
                    Toggle("Wi‑Fi 위치 기반 측위", isOn: $model.usesRadioPositioning)
                    if model.usesRadioPositioning {
                        Label(
                            "측위 QA · 신호 세기와 개수에 따라 위치 오차가 달라집니다.",
                            systemImage: "wifi"
                        )
                        .foregroundStyle(.orange)
                    } else {
                        Label(
                            "길찾기 QA · 입력 위치를 오차 없이 그대로 전달합니다.",
                            systemImage: "location.fill"
                        )
                        .foregroundStyle(.blue)
                    }
                }

                Section("센서 출력") {
                    Toggle("현실적 센서 노이즈", isOn: $model.appliesSensorNoise)
                        .disabled(!model.usesRadioPositioning)
                    Text(
                        model.usesRadioPositioning
                            ? "정지 Wi‑Fi ±0.75dB · BLE ±1.2dB · 보행 중 노이즈 증가"
                            : "외부 노이즈와 Wi‑Fi 간섭을 적용하지 않습니다."
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let frame = model.latestFrame {
                        LabeledContent("전송 주기", value: "50 Hz")
                        LabeledContent("Wi‑Fi", value: "\(frame.wifi.count)개")
                        LabeledContent("Bluetooth", value: "\(frame.bluetooth.count)개")
                        if frame.positioningMode == .groundTruth {
                            LabeledContent("Blue Dot", value: "입력 위치와 동일")
                            Label(
                                "정확한 위치 보장 · 길찾기 기능을 독립적으로 테스트합니다.",
                                systemImage: "checkmark.circle.fill"
                            )
                            .foregroundStyle(.green)
                        } else if let accuracy = frame.radioQuality.estimatedHorizontalAccuracyMeters {
                            LabeledContent(
                                "예상 Blue Dot 정확도",
                                value: "±" + accuracy.formatted(
                                    .number.precision(.fractionLength(1))
                                ) + "m"
                            )
                        }
                        if frame.positioningMode == .groundTruth {
                            EmptyView()
                        } else if frame.radioCoverage == .insufficient {
                            Label("측위 불가 · 신호가 너무 적거나 약합니다", systemImage: "location.slash.fill")
                                .foregroundStyle(.red)
                        } else if frame.radioCoverage == .limited {
                            Label("제한된 측위 · Blue Dot 오차가 큽니다", systemImage: "location.circle")
                                .foregroundStyle(.orange)
                        } else {
                            Label("측위 가능 · 실제와 같은 오차를 포함합니다", systemImage: "location.fill")
                                .foregroundStyle(.green)
                        }
                        LabeledContent(
                            "Motion timestamp",
                            value: frame.motion.timestamp.formatted(
                                .number.precision(.fractionLength(2))
                            ) + "s"
                        )
                        if frame.wifi.isEmpty && frame.bluetooth.isEmpty {
                            Text("수신 가능한 신호가 없습니다.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(frame.wifi) { observation in
                            LabeledContent(
                                observation.ssid,
                                value: observation.rssiDBM.formatted(
                                    .number.precision(.fractionLength(1))
                                ) + " dBm"
                            )
                        }
                        ForEach(frame.bluetooth) { observation in
                            LabeledContent(
                                observation.name,
                                value: observation.rssiDBM.formatted(
                                    .number.precision(.fractionLength(1))
                                ) + " dBm"
                            )
                        }
                    }
                }
            }

            Section("iOS Simulator 연결") {
                Toggle("Core Location도 주입", isOn: $model.injectsCoreLocation)
                Text(model.coreLocationStatus)
                    .foregroundStyle(.secondary)
                Text("Core Location은 위에서 선택한 기기로 전달합니다. Wi‑Fi·Bluetooth·Motion은 연결된 앱의 Swift 센서 브리지로 전달합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("층 이동") {
                HStack {
                    Button("아래층", systemImage: "arrow.down") {
                        model.transitionFloor(by: -1)
                    }
                    Button("위층", systemImage: "arrow.up") {
                        model.transitionFloor(by: 1)
                    }
                }
                Text(model.currentVerticalConnectorName.map {
                    "현재 \($0) 영역입니다."
                } ?? "계단·엘리베이터·에스컬레이터 안에서 층을 이동하세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let anchor = model.selectedAnchor {
                Section("선택한 신호원") {
                    LabeledContent("ID", value: anchor.id)
                    LabeledContent("종류", value: anchor.kind == .wifi ? "Wi‑Fi" : "Beacon")
                    LabeledContent("위치", value: meters(anchor.position))

                    VStack(alignment: .leading) {
                        Text("1m 기준 RSSI: \(Int(anchor.referenceRSSI)) dBm")
                        Slider(
                            value: Binding(
                                get: { model.selectedAnchor?.referenceRSSI ?? anchor.referenceRSSI },
                                set: { model.updateSelectedAnchor(referenceRSSI: $0) }
                            ),
                            in: -90 ... -20,
                            step: 1
                        )
                    }

                    VStack(alignment: .leading) {
                        Text(
                            "감쇠 계수: "
                            + anchor.pathLossExponent.formatted(
                                .number.precision(.fractionLength(1))
                            )
                        )
                        Slider(
                            value: Binding(
                                get: {
                                    model.selectedAnchor?.pathLossExponent
                                        ?? anchor.pathLossExponent
                                },
                                set: { model.updateSelectedAnchor(pathLossExponent: $0) }
                            ),
                            in: 1 ... 5,
                            step: 0.1
                        )
                    }

                    Button("선택한 신호원 삭제", role: .destructive) {
                        model.removeSelectedAnchor()
                    }
                    .disabled((model.simulator?.radioEnvironment.anchors.count ?? 0) <= 1)
                }
            }

            Section("조작") {
                Text("방향키 누르기: 1.125m/s 연속 보행")
                Text("트랙패드 두 손가락 스와이프: 관성 지도 이동")
                Text("트랙패드 핀치 또는 −/+ 버튼: 지도 확대·축소")
                Text("지도 드래그: 사용자 또는 신호원 이동")
                Text("초록 점과 부채꼴: 위치와 디바이스 방향")
            }
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func meters(_ point: MeterPoint) -> String {
        "E \(format(point.east)) · N \(format(point.north))"
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + "m"
    }
}
