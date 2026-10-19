import IndoorPositioningSimulation
import SwiftUI

struct SimulatorCanvas: View {
    @Bindable var model: SimulatorAppModel
    @FocusState private var isFocused: Bool
    @State private var dragTarget: SimulatorAppModel.Selection?
    @State private var zoomScale: CGFloat = 1.55
    @State private var gestureStartZoomScale: CGFloat?

    private let minimumZoomScale: CGFloat = 1
    private let maximumZoomScale: CGFloat = 4

    var body: some View {
        GeometryReader { viewport in
            if let level = model.selectedLevel,
               let scenario = model.scenario,
               let simulator = model.simulator,
               let snapshot = model.snapshot
            {
                let canvasSize = CGSize(
                    width: viewport.size.width * zoomScale,
                    height: viewport.size.height * zoomScale
                )
                let transform = CanvasTransform(
                    bounds: scenario.localBounds,
                    size: canvasSize
                )

                ScrollView([.horizontal, .vertical]) {
                    Canvas { context, _ in
                        drawLevel(
                            level,
                            reference: scenario.coordinateReference,
                            transform: transform,
                            context: &context
                        )
                        drawAnchors(
                            simulator.radioEnvironment.anchors,
                            transform: transform,
                            context: &context
                        )
                        drawPositions(snapshot, transform: transform, context: &context)
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .contentShape(Rectangle())
                    .focusable()
                    .focused($isFocused)
                    .onAppear { isFocused = true }
                    .onTapGesture { isFocused = true }
                    .gesture(dragGesture(
                        simulator: simulator,
                        transform: transform
                    ))
                    .onKeyPress(.upArrow, phases: [.down, .up]) { press in
                        updateMovement(.north, phase: press.phase)
                    }
                    .onKeyPress(.downArrow, phases: [.down, .up]) { press in
                        updateMovement(.south, phase: press.phase)
                    }
                    .onKeyPress(.leftArrow, phases: [.down, .up]) { press in
                        updateMovement(.west, phase: press.phase)
                    }
                    .onKeyPress(.rightArrow, phases: [.down, .up]) { press in
                        updateMovement(.east, phase: press.phase)
                    }
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
                .defaultScrollAnchor(.center)
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            if gestureStartZoomScale == nil {
                                gestureStartZoomScale = zoomScale
                            }
                            let startScale = gestureStartZoomScale ?? zoomScale
                            setZoom(startScale * value.magnification)
                        }
                        .onEnded { _ in
                            gestureStartZoomScale = nil
                        }
                )
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(level.shortName ?? level.name)
                            .font(.headline)
                        Text("핀치 확대·축소 · 두 손가락 스와이프 이동 · 보행 1.125m/s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding()
                }
                .overlay(alignment: .topTrailing) {
                    ZoomControls(
                        zoomScale: zoomScale,
                        zoomOut: { setZoom(zoomScale / 1.25) },
                        fit: { setZoom(minimumZoomScale) },
                        zoomIn: { setZoom(zoomScale * 1.25) }
                    )
                    .padding()
                }
                .overlay(alignment: .bottomTrailing) {
                    DirectionPad(model: model)
                        .padding(18)
                }
            }
        }
    }

    private func setZoom(_ value: CGFloat) {
        zoomScale = min(max(value, minimumZoomScale), maximumZoomScale)
    }

    private func updateMovement(
        _ direction: SimulationMovementDirection,
        phase: KeyPress.Phases
    ) -> KeyPress.Result {
        if phase == .up {
            model.endMoving(direction)
        } else {
            model.beginMoving(direction)
        }
        return .handled
    }

    private func dragGesture(
        simulator: WiFiIndoorPositioningSimulator,
        transform: CanvasTransform
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                isFocused = true
                if dragTarget == nil {
                    dragTarget = hitTarget(
                        at: value.startLocation,
                        simulator: simulator,
                        transform: transform
                    )
                    model.selection = dragTarget ?? .user
                }
                let point = transform.meterPoint(from: value.location)
                switch dragTarget ?? .user {
                case .user:
                    model.moveUser(to: point)
                case .anchor(let id):
                    model.moveAnchor(id: id, to: point)
                }
            }
            .onEnded { _ in dragTarget = nil }
    }

    private func hitTarget(
        at location: CGPoint,
        simulator: WiFiIndoorPositioningSimulator,
        transform: CanvasTransform
    ) -> SimulatorAppModel.Selection {
        let nearest = simulator.radioEnvironment.anchors
            .map { anchor in
                (anchor.id, distance(transform.point(for: anchor.position), location))
            }
            .min { $0.1 < $1.1 }
        if let nearest, nearest.1 <= 22 { return .anchor(nearest.0) }
        return .user
    }

    private func drawLevel(
        _ level: IMDFMapLevel,
        reference: LocalCoordinateReference,
        transform: CanvasTransform,
        context: inout GraphicsContext
    ) {
        for polygon in level.polygons {
            let path = path(for: polygon, reference: reference, transform: transform)
            context.fill(path, with: .color(.gray.opacity(0.12)))
            context.stroke(path, with: .color(.secondary.opacity(0.7)), lineWidth: 2)
        }

        for unit in level.units {
            for polygon in unit.polygons {
                let path = path(for: polygon, reference: reference, transform: transform)
                let tint: Color = unit.category == "walkway"
                    ? .blue.opacity(0.06)
                    : .primary.opacity(0.04)
                context.fill(path, with: .color(tint))
                context.stroke(path, with: .color(.secondary.opacity(0.22)), lineWidth: 0.7)
            }
        }


        for fixture in level.fixtures {
            for polygon in fixture.polygons {
                let path = path(for: polygon, reference: reference, transform: transform)
                context.fill(path, with: .color(.brown.opacity(0.28)))
                context.stroke(path, with: .color(.brown.opacity(0.65)), lineWidth: 0.8)
            }
        }
    }

    private func drawAnchors(
        _ anchors: [RadioAnchor],
        transform: CanvasTransform,
        context: inout GraphicsContext
    ) {
        for anchor in anchors {
            let center = transform.point(for: anchor.position)
            let selected = model.selection == .anchor(anchor.id)
            let color: Color = anchor.kind == .wifi ? .purple : .orange
            if selected {
                context.stroke(
                    Path(ellipseIn: CGRect(x: center.x - 15, y: center.y - 15, width: 30, height: 30)),
                    with: .color(color.opacity(0.35)),
                    lineWidth: 4
                )
            }
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)),
                with: .color(color)
            )
            context.stroke(
                Path(ellipseIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)),
                with: .color(.white),
                lineWidth: 2
            )
            context.draw(
                Text(anchor.id).font(.caption2.monospaced()).foregroundStyle(.primary),
                at: CGPoint(x: center.x, y: center.y + 18),
                anchor: .top
            )
        }
    }

    private func drawPositions(
        _ snapshot: SimulationSnapshot,
        transform: CanvasTransform,
        context: inout GraphicsContext
    ) {
        let actual = transform.point(for: snapshot.actualPosition)
        let headingRadians = (snapshot.heading - 90) * .pi / 180
        var fieldOfView = Path()
        fieldOfView.move(to: actual)
        fieldOfView.addArc(
            center: actual,
            radius: 34,
            startAngle: .radians(headingRadians - .pi / 6),
            endAngle: .radians(headingRadians + .pi / 6),
            clockwise: false
        )
        fieldOfView.closeSubpath()
        context.fill(fieldOfView, with: .color(.green.opacity(0.18)))
        context.stroke(
            Path(ellipseIn: CGRect(x: actual.x - 7, y: actual.y - 7, width: 14, height: 14)),
            with: .color(.green),
            lineWidth: model.selection == .user ? 4 : 2
        )

    }

    private func path(
        for polygon: IMDFPolygon,
        reference: LocalCoordinateReference,
        transform: CanvasTransform
    ) -> Path {
        var result = Path()
        for ring in polygon.rings {
            guard let first = ring.first else { continue }
            result.move(to: transform.point(for: reference.project(first)))
            for coordinate in ring.dropFirst() {
                result.addLine(to: transform.point(for: reference.project(coordinate)))
            }
            result.closeSubpath()
        }
        return result
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> Double {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}

private struct ZoomControls: View {
    let zoomScale: CGFloat
    let zoomOut: () -> Void
    let fit: () -> Void
    let zoomIn: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: zoomOut) {
                Image(systemName: "minus")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("-", modifiers: .command)
            .accessibilityLabel("지도 축소")

            Button(action: fit) {
                Text("\(Int((zoomScale * 100).rounded()))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 48, minHeight: 26)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("0", modifiers: .command)
            .help("지도 전체 맞춤")

            Button(action: zoomIn) {
                Image(systemName: "plus")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("+", modifiers: .command)
            .accessibilityLabel("지도 확대")
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.1), radius: 7, y: 3)
    }
}

private struct DirectionPad: View {
    @Bindable var model: SimulatorAppModel

    var body: some View {
        VStack(spacing: 6) {
            MovementButton(
                direction: .north,
                systemImage: "arrow.up",
                label: "위로 이동",
                model: model
            )
            HStack(spacing: 6) {
                MovementButton(
                    direction: .west,
                    systemImage: "arrow.left",
                    label: "왼쪽으로 이동",
                    model: model
                )
                Image(systemName: "figure.walk")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .frame(width: 48, height: 48)
                MovementButton(
                    direction: .east,
                    systemImage: "arrow.right",
                    label: "오른쪽으로 이동",
                    model: model
                )
            }
            MovementButton(
                direction: .south,
                systemImage: "arrow.down",
                label: "아래로 이동",
                model: model
            )
            Text("길게 눌러 이동")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

private struct MovementButton: View {
    let direction: SimulationMovementDirection
    let systemImage: String
    let label: String
    @Bindable var model: SimulatorAppModel

    @State private var isPressed = false
    @State private var pressedAt: Date?

    var body: some View {
        Image(systemName: systemImage)
            .font(.title3.bold())
            .frame(width: 48, height: 48)
            .foregroundStyle(isPressed ? .white : .primary)
            .background(
                isPressed ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        pressedAt = Date()
                        model.beginMoving(direction)
                    }
                    .onEnded { _ in
                        model.endMoving(direction)
                        if let pressedAt,
                           Date().timeIntervalSince(pressedAt) < 0.12
                        {
                            model.nudge(direction)
                        }
                        isPressed = false
                        pressedAt = nil
                    }
            )
            .accessibilityLabel(label)
            .onDisappear {
                if isPressed {
                    model.endMoving(direction)
                }
            }
    }
}

private struct CanvasTransform {
    let bounds: SimulationBounds
    let size: CGSize
    let scale: Double
    private let originX: Double
    private let originY: Double

    init(bounds: SimulationBounds, size: CGSize) {
        self.bounds = bounds
        self.size = size
        let padding = 48.0
        let width = max(bounds.maximumEast - bounds.minimumEast, 1)
        let height = max(bounds.maximumNorth - bounds.minimumNorth, 1)
        scale = max(0.01, min(
            (size.width - padding * 2) / width,
            (size.height - padding * 2) / height
        ))
        let contentWidth = width * scale
        let contentHeight = height * scale
        originX = (size.width - contentWidth) / 2
        originY = (size.height - contentHeight) / 2
    }

    func point(for meterPoint: MeterPoint) -> CGPoint {
        CGPoint(
            x: originX + (meterPoint.east - bounds.minimumEast) * scale,
            y: size.height - originY - (meterPoint.north - bounds.minimumNorth) * scale
        )
    }

    func meterPoint(from point: CGPoint) -> MeterPoint {
        bounds.clamped(MeterPoint(
            east: bounds.minimumEast + (point.x - originX) / scale,
            north: bounds.minimumNorth + (size.height - originY - point.y) / scale
        ))
    }
}
