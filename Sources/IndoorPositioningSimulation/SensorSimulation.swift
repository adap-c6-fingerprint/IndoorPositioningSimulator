import Foundation

/// A single three-axis value. Motion values follow Core Motion's right-handed
/// device coordinate system and use the unit documented by each property.
public struct SimulationVector3: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct SimulationAttitude: Codable, Equatable, Sendable {
    public let roll: Double
    public let pitch: Double
    public let yaw: Double
    public let quaternionX: Double
    public let quaternionY: Double
    public let quaternionZ: Double
    public let quaternionW: Double

    public init(headingDegrees: Double) {
        let yaw = headingDegrees * .pi / 180
        self.roll = 0
        self.pitch = 0
        self.yaw = yaw
        quaternionX = 0
        quaternionY = 0
        quaternionZ = sin(yaw / 2)
        quaternionW = cos(yaw / 2)
    }
}

/// A nearby Wi-Fi observation for positioning engines owned by the consuming app.
/// iOS does not offer a public API that can publish this as an OS Wi-Fi scan.
public struct SimulatedWiFiObservation: Codable, Equatable, Identifiable, Sendable {
    public var id: String { bssid }
    public let bssid: String
    public let ssid: String
    public let rssiDBM: Double
    public let frequencyMHz: Int
    public let channel: Int
    public let observedAt: TimeInterval

    public init(
        bssid: String,
        ssid: String,
        rssiDBM: Double,
        frequencyMHz: Int,
        channel: Int,
        observedAt: TimeInterval
    ) {
        self.bssid = bssid
        self.ssid = ssid
        self.rssiDBM = rssiDBM
        self.frequencyMHz = frequencyMHz
        self.channel = channel
        self.observedAt = observedAt
    }
}

public struct SimulatedIBeaconIdentity: Codable, Equatable, Sendable {
    public let proximityUUID: UUID
    public let major: UInt16
    public let minor: UInt16
    public let measuredPower: Int

    public init(
        proximityUUID: UUID,
        major: UInt16,
        minor: UInt16,
        measuredPower: Int
    ) {
        self.proximityUUID = proximityUUID
        self.major = major
        self.minor = minor
        self.measuredPower = measuredPower
    }
}

/// A BLE advertisement. It contains both generic Core Bluetooth identity and
/// iBeacon fields so a client can adapt it to either kind of positioning input.
public struct SimulatedBluetoothObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let rssiDBM: Double
    public let serviceUUIDs: [UUID]
    public let iBeacon: SimulatedIBeaconIdentity?
    public let observedAt: TimeInterval

    public init(
        id: UUID,
        name: String,
        rssiDBM: Double,
        serviceUUIDs: [UUID],
        iBeacon: SimulatedIBeaconIdentity?,
        observedAt: TimeInterval
    ) {
        self.id = id
        self.name = name
        self.rssiDBM = rssiDBM
        self.serviceUUIDs = serviceUUIDs
        self.iBeacon = iBeacon
        self.observedAt = observedAt
    }
}

public struct SimulatedMotionSample: Codable, Equatable, Sendable {
    /// Seconds since the simulation session started.
    public let timestamp: TimeInterval
    /// Acceleration excluding gravity, in g.
    public let userAccelerationG: SimulationVector3
    /// Gravity vector, in g.
    public let gravityG: SimulationVector3
    /// Rotation rate, in radians per second.
    public let rotationRateRadiansPerSecond: SimulationVector3
    /// Calibrated magnetic field, in microteslas.
    public let magneticFieldMicrotesla: SimulationVector3
    public let attitude: SimulationAttitude
    public let magneticHeadingDegrees: Double

    public init(
        timestamp: TimeInterval,
        userAccelerationG: SimulationVector3,
        gravityG: SimulationVector3,
        rotationRateRadiansPerSecond: SimulationVector3,
        magneticFieldMicrotesla: SimulationVector3,
        attitude: SimulationAttitude,
        magneticHeadingDegrees: Double
    ) {
        self.timestamp = timestamp
        self.userAccelerationG = userAccelerationG
        self.gravityG = gravityG
        self.rotationRateRadiansPerSecond = rotationRateRadiansPerSecond
        self.magneticFieldMicrotesla = magneticFieldMicrotesla
        self.attitude = attitude
        self.magneticHeadingDegrees = magneticHeadingDegrees
    }
}

public struct SimulatedDeviceState: Codable, Equatable, Sendable {
    public let position: IndoorCoordinate
    public let headingDegrees: Double
    public let walking: Bool
    public let speedMetersPerSecond: Double

    public init(
        position: IndoorCoordinate,
        headingDegrees: Double,
        walking: Bool,
        speedMetersPerSecond: Double
    ) {
        self.position = position
        self.headingDegrees = headingDegrees
        self.walking = walking
        self.speedMetersPerSecond = speedMetersPerSecond
    }
}

/// A coarse QA diagnostic for whether the current radio observations can
/// plausibly support a two-dimensional indoor fix. The consuming positioning
/// engine remains responsible for the actual position calculation.
public enum SimulationRadioCoverage: String, Codable, Equatable, Sendable {
    case insufficient
    case limited
    case sufficient
}

/// Signal-strength-based QA estimate used by debug adapters. It deliberately
/// reports uncertainty rather than a calculated coordinate.
public struct SimulationRadioQualityAssessment: Equatable, Sendable {
    public let coverage: SimulationRadioCoverage
    public let observationCount: Int
    public let effectiveSignalCount: Double
    public let strongestRSSIDBM: Double?
    public let representativeRSSIDBM: Double?
    public let estimatedHorizontalAccuracyMeters: Double?

    public init(wifiRSSI: [Double], bluetoothRSSI: [Double]) {
        let values = (wifiRSSI + bluetoothRSSI).sorted(by: >)
        observationCount = values.count
        strongestRSSIDBM = values.first

        let representativeValues = Array(values.prefix(4))
        representativeRSSIDBM = representativeValues.isEmpty
            ? nil
            : representativeValues.reduce(0, +) / Double(representativeValues.count)

        effectiveSignalCount = values.reduce(0) { result, rssi in
            result + Self.signalQuality(for: rssi)
        }

        if values.count < 3
            || (values.first ?? -.infinity) < -90
            || effectiveSignalCount < 0.75
        {
            coverage = .insufficient
            estimatedHorizontalAccuracyMeters = nil
        } else {
            coverage = values.count >= 6 && effectiveSignalCount >= 2.4
                ? .sufficient
                : .limited

            let representativeRSSI = representativeRSSIDBM ?? -90
            // Nominal indoor office model: -42dBm at 1m and path-loss
            // exponent 3.0, between open-space (~2) and wall-heavy (~4).
            let dominantRange = pow(10, (-42 - representativeRSSI) / 30)
            let countPenalty = 2.5 + Double(max(0, 6 - values.count)) * 1.5
            let weakSignalPenalty = dominantRange * 0.65
                + max(0, -65 - representativeRSSI) * 0.15
            estimatedHorizontalAccuracyMeters = min(
                50,
                max(2.5, countPenalty + weakSignalPenalty)
            )
        }
    }

    private static func signalQuality(for rssi: Double) -> Double {
        min(max((rssi + 95) / 50, 0), 1)
    }
}

/// Selects whether a consuming app should derive its position from simulated
/// radio observations or use the simulator's exact position for deterministic
/// navigation and UI QA.
public enum SimulationPositioningMode: String, Codable, Equatable, Sendable {
    case radioBased
    case groundTruth
}

/// Timestamped public contract sent by the Mac controller to an iOS Simulator app.
/// This is ground truth plus sensor observations; it deliberately contains no
/// calculated Blue Dot.
public struct SimulationSensorFrame: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var id: UInt64 { sequenceNumber }
    public let schemaVersion: Int
    public let sessionID: UUID
    public let sequenceNumber: UInt64
    public let generatedAt: Date
    public let positioningMode: SimulationPositioningMode
    public let device: SimulatedDeviceState
    public let wifi: [SimulatedWiFiObservation]
    public let bluetooth: [SimulatedBluetoothObservation]
    public let motion: SimulatedMotionSample

    public var radioQuality: SimulationRadioQualityAssessment {
        SimulationRadioQualityAssessment(
            wifiRSSI: wifi.map(\.rssiDBM),
            bluetoothRSSI: bluetooth.map(\.rssiDBM)
        )
    }

    public var radioCoverage: SimulationRadioCoverage {
        radioQuality.coverage
    }

    public init(
        sessionID: UUID,
        sequenceNumber: UInt64,
        generatedAt: Date,
        positioningMode: SimulationPositioningMode = .radioBased,
        device: SimulatedDeviceState,
        wifi: [SimulatedWiFiObservation],
        bluetooth: [SimulatedBluetoothObservation],
        motion: SimulatedMotionSample
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.sessionID = sessionID
        self.sequenceNumber = sequenceNumber
        self.generatedAt = generatedAt
        self.positioningMode = positioningMode
        self.device = device
        self.wifi = wifi
        self.bluetooth = bluetooth
        self.motion = motion
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sessionID
        case sequenceNumber
        case generatedAt
        case positioningMode
        case device
        case wifi
        case bluetooth
        case motion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        sequenceNumber = try container.decode(UInt64.self, forKey: .sequenceNumber)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        positioningMode = try container.decodeIfPresent(
            SimulationPositioningMode.self,
            forKey: .positioningMode
        ) ?? .radioBased
        device = try container.decode(SimulatedDeviceState.self, forKey: .device)
        wifi = try container.decode([SimulatedWiFiObservation].self, forKey: .wifi)
        bluetooth = try container.decode(
            [SimulatedBluetoothObservation].self,
            forKey: .bluetooth
        )
        motion = try container.decode(SimulatedMotionSample.self, forKey: .motion)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(sequenceNumber, forKey: .sequenceNumber)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(positioningMode, forKey: .positioningMode)
        try container.encode(device, forKey: .device)
        try container.encode(wifi, forKey: .wifi)
        try container.encode(bluetooth, forKey: .bluetooth)
        try container.encode(motion, forKey: .motion)
    }
}

public struct SimulationNoiseProfile: Equatable, Sendable {
    public let wifiRSSIStandardDeviationDB: Double
    public let bluetoothRSSIStandardDeviationDB: Double
    public let userAccelerationStandardDeviationG: Double
    public let gravityStandardDeviationG: Double
    public let rotationRateStandardDeviationRadiansPerSecond: Double
    public let magneticFieldStandardDeviationMicrotesla: Double
    public let headingStandardDeviationDegrees: Double

    public var isEnabled: Bool {
        self != .none
    }

    public init(
        wifiRSSIStandardDeviationDB: Double,
        bluetoothRSSIStandardDeviationDB: Double,
        userAccelerationStandardDeviationG: Double,
        gravityStandardDeviationG: Double,
        rotationRateStandardDeviationRadiansPerSecond: Double,
        magneticFieldStandardDeviationMicrotesla: Double,
        headingStandardDeviationDegrees: Double
    ) {
        self.wifiRSSIStandardDeviationDB = wifiRSSIStandardDeviationDB
        self.bluetoothRSSIStandardDeviationDB = bluetoothRSSIStandardDeviationDB
        self.userAccelerationStandardDeviationG = userAccelerationStandardDeviationG
        self.gravityStandardDeviationG = gravityStandardDeviationG
        self.rotationRateStandardDeviationRadiansPerSecond =
            rotationRateStandardDeviationRadiansPerSecond
        self.magneticFieldStandardDeviationMicrotesla =
            magneticFieldStandardDeviationMicrotesla
        self.headingStandardDeviationDegrees = headingStandardDeviationDegrees
    }

    public static let none = Self(
        wifiRSSIStandardDeviationDB: 0,
        bluetoothRSSIStandardDeviationDB: 0,
        userAccelerationStandardDeviationG: 0,
        gravityStandardDeviationG: 0,
        rotationRateStandardDeviationRadiansPerSecond: 0,
        magneticFieldStandardDeviationMicrotesla: 0,
        headingStandardDeviationDegrees: 0
    )

    /// Reproducible indoor QA defaults, not a calibration claim for a specific
    /// iPhone model or building.
    public static let realisticIndoor = Self(
        wifiRSSIStandardDeviationDB: 3,
        bluetoothRSSIStandardDeviationDB: 4,
        userAccelerationStandardDeviationG: 0.008,
        gravityStandardDeviationG: 0.002,
        rotationRateStandardDeviationRadiansPerSecond: 0.005,
        magneticFieldStandardDeviationMicrotesla: 0.8,
        headingStandardDeviationDegrees: 1.5
    )
}

/// Generates repeatable, temporally correlated noisy signals for a phone held
/// steadily with its screen facing upward.
public struct SimulatedSensorGenerator: Sendable {
    public static let defaultMotionFrequencyHertz = 50.0
    public static let defaultWiFiFrequencyHertz = 1.0
    public static let defaultBluetoothFrequencyHertz = 10.0
    public static let defaultWalkingSpeedMetersPerSecond = 1.125

    public let sessionID: UUID
    public private(set) var sequenceNumber: UInt64 = 0
    public private(set) var elapsedTime: TimeInterval = 0
    public private(set) var noiseProfile: SimulationNoiseProfile
    private var previousHeadingDegrees: Double
    private var lastWiFiObservationTime = -Double.infinity
    private var lastBluetoothObservationTime = -Double.infinity
    private var cachedWiFi: [SimulatedWiFiObservation] = []
    private var cachedBluetooth: [SimulatedBluetoothObservation] = []
    private var wifiNoiseByAnchorID: [String: Double] = [:]
    private var bluetoothNoiseByAnchorID: [String: Double] = [:]
    private var headingNoiseDegrees = 0.0
    private var randomState: UInt64

    public init(
        sessionID: UUID = UUID(),
        initialHeadingDegrees: Double = 0,
        noiseProfile: SimulationNoiseProfile = .realisticIndoor,
        noiseSeed: UInt64? = nil
    ) {
        self.sessionID = sessionID
        self.noiseProfile = noiseProfile
        previousHeadingDegrees = initialHeadingDegrees
        randomState = noiseSeed ?? Self.stableHash(sessionID.uuidString)
    }

    public mutating func setNoiseProfile(_ profile: SimulationNoiseProfile) {
        noiseProfile = profile
        wifiNoiseByAnchorID.removeAll(keepingCapacity: true)
        bluetoothNoiseByAnchorID.removeAll(keepingCapacity: true)
        headingNoiseDegrees = 0
        invalidateRadioObservations()
    }

    public mutating func invalidateRadioObservations() {
        lastWiFiObservationTime = -Double.infinity
        lastBluetoothObservationTime = -Double.infinity
    }

    public mutating func makeFrame(
        position: IndoorCoordinate,
        localPosition: MeterPoint,
        headingDegrees: Double,
        walking: Bool,
        positioningMode: SimulationPositioningMode = .radioBased,
        speedMetersPerSecond: Double = Self.defaultWalkingSpeedMetersPerSecond,
        radioEnvironment: SimulatedRadioEnvironment,
        deltaTime: TimeInterval = 1 / Self.defaultMotionFrequencyHertz,
        date: Date = Date()
    ) -> SimulationSensorFrame {
        let safeDeltaTime = max(deltaTime, 0.001)
        elapsedTime += safeDeltaTime
        sequenceNumber &+= 1
        let activeNoiseProfile = positioningMode == .radioBased
            ? noiseProfile
            : .none

        let normalizedHeading = Self.normalizedHeading(headingDegrees)
        let headingDelta = Self.shortestAngle(
            from: previousHeadingDegrees,
            to: normalizedHeading
        )
        previousHeadingDegrees = normalizedHeading

        let walkingPhase = elapsedTime * 2 * .pi * 1.8
        let forwardAcceleration = walking ? 0.045 * sin(walkingPhase) : 0
        let verticalAcceleration = walking ? 0.11 * sin(walkingPhase * 2) : 0
        headingNoiseDegrees = correlatedNoise(
            previous: headingNoiseDegrees,
            standardDeviation: activeNoiseProfile.headingStandardDeviationDegrees
                * (walking ? 1 : 0.35),
            correlation: walking ? 0.96 : 0.985
        )
        let sensedHeading = Self.normalizedHeading(normalizedHeading + headingNoiseDegrees)
        let headingRadians = sensedHeading * .pi / 180
        let magneticStrength = 48.0

        if elapsedTime - lastWiFiObservationTime
            >= 1 / Self.defaultWiFiFrequencyHertz
        {
            lastWiFiObservationTime = elapsedTime
            var observations: [SimulatedWiFiObservation] = []
            for anchor in radioEnvironment.anchors where anchor.kind == .wifi {
                let rssi = anchor.rssi(at: localPosition) + wifiNoise(
                    for: anchor.id,
                    walking: walking,
                    profile: activeNoiseProfile
                )
                guard rssi >= radioEnvironment.minimumVisibleRSSI else { continue }
                let channel = 1 + Int(Self.stableHash(anchor.id) % 11)
                observations.append(SimulatedWiFiObservation(
                    bssid: Self.bssid(for: anchor.id),
                    ssid: anchor.id,
                    rssiDBM: rssi,
                    frequencyMHz: 2_407 + channel * 5,
                    channel: channel,
                    observedAt: elapsedTime
                ))
            }
            cachedWiFi = observations.sorted { $0.rssiDBM > $1.rssiDBM }
        }

        if elapsedTime - lastBluetoothObservationTime
            >= 1 / Self.defaultBluetoothFrequencyHertz
        {
            lastBluetoothObservationTime = elapsedTime
            var observations: [SimulatedBluetoothObservation] = []
            for anchor in radioEnvironment.anchors where anchor.kind == .beacon {
                let rssi = anchor.rssi(at: localPosition) + bluetoothNoise(
                    for: anchor.id,
                    walking: walking,
                    profile: activeNoiseProfile
                )
                guard rssi >= radioEnvironment.minimumVisibleRSSI else { continue }
                let hash = Self.stableHash(anchor.id)
                observations.append(SimulatedBluetoothObservation(
                    id: Self.uuid(for: anchor.id),
                    name: anchor.id,
                    rssiDBM: rssi,
                    serviceUUIDs: [],
                    iBeacon: SimulatedIBeaconIdentity(
                        proximityUUID: Self.beaconNamespace,
                        major: UInt16((hash >> 16) & 0xffff),
                        minor: UInt16(hash & 0xffff),
                        measuredPower: Int(anchor.referenceRSSI.rounded())
                    ),
                    observedAt: elapsedTime
                ))
            }
            cachedBluetooth = observations.sorted { $0.rssiDBM > $1.rssiDBM }
        }

        let motion = SimulatedMotionSample(
            timestamp: elapsedTime,
            userAccelerationG: SimulationVector3(
                x: forwardAcceleration + gaussianNoise(
                    standardDeviation: activeNoiseProfile.userAccelerationStandardDeviationG
                ),
                y: gaussianNoise(
                    standardDeviation: activeNoiseProfile.userAccelerationStandardDeviationG
                ),
                z: verticalAcceleration + gaussianNoise(
                    standardDeviation: activeNoiseProfile.userAccelerationStandardDeviationG
                )
            ),
            gravityG: SimulationVector3(
                x: gaussianNoise(
                    standardDeviation: activeNoiseProfile.gravityStandardDeviationG
                ),
                y: gaussianNoise(
                    standardDeviation: activeNoiseProfile.gravityStandardDeviationG
                ),
                z: -1 + gaussianNoise(
                    standardDeviation: activeNoiseProfile.gravityStandardDeviationG
                )
            ),
            rotationRateRadiansPerSecond: SimulationVector3(
                x: gaussianNoise(
                    standardDeviation: activeNoiseProfile
                        .rotationRateStandardDeviationRadiansPerSecond
                ),
                y: gaussianNoise(
                    standardDeviation: activeNoiseProfile
                        .rotationRateStandardDeviationRadiansPerSecond
                ),
                z: headingDelta * .pi / 180 / safeDeltaTime + gaussianNoise(
                    standardDeviation: activeNoiseProfile
                        .rotationRateStandardDeviationRadiansPerSecond
                )
            ),
            magneticFieldMicrotesla: SimulationVector3(
                x: magneticStrength * sin(headingRadians) + gaussianNoise(
                    standardDeviation: activeNoiseProfile
                        .magneticFieldStandardDeviationMicrotesla
                ),
                y: magneticStrength * cos(headingRadians) + gaussianNoise(
                    standardDeviation: activeNoiseProfile
                        .magneticFieldStandardDeviationMicrotesla
                ),
                z: gaussianNoise(
                    standardDeviation: activeNoiseProfile
                        .magneticFieldStandardDeviationMicrotesla
                )
            ),
            attitude: SimulationAttitude(headingDegrees: sensedHeading),
            magneticHeadingDegrees: sensedHeading
        )

        return SimulationSensorFrame(
            sessionID: sessionID,
            sequenceNumber: sequenceNumber,
            generatedAt: date,
            positioningMode: positioningMode,
            device: SimulatedDeviceState(
                position: position,
                headingDegrees: normalizedHeading,
                walking: walking,
                speedMetersPerSecond: walking ? speedMetersPerSecond : 0
            ),
            wifi: cachedWiFi,
            bluetooth: cachedBluetooth,
            motion: motion
        )
    }

    private mutating func wifiNoise(
        for anchorID: String,
        walking: Bool,
        profile: SimulationNoiseProfile
    ) -> Double {
        let previous = wifiNoiseByAnchorID[anchorID] ?? 0
        let value = correlatedNoise(
            previous: previous,
            standardDeviation: profile.wifiRSSIStandardDeviationDB
                * (walking ? 1 : 0.25),
            correlation: walking ? 0.82 : 0.96
        )
        wifiNoiseByAnchorID[anchorID] = value
        return value
    }

    private mutating func bluetoothNoise(
        for anchorID: String,
        walking: Bool,
        profile: SimulationNoiseProfile
    ) -> Double {
        let previous = bluetoothNoiseByAnchorID[anchorID] ?? 0
        let value = correlatedNoise(
            previous: previous,
            standardDeviation: profile.bluetoothRSSIStandardDeviationDB
                * (walking ? 1 : 0.3),
            correlation: walking ? 0.88 : 0.97
        )
        bluetoothNoiseByAnchorID[anchorID] = value
        return value
    }

    private mutating func correlatedNoise(
        previous: Double,
        standardDeviation: Double,
        correlation: Double
    ) -> Double {
        guard standardDeviation > 0 else { return 0 }
        let innovationScale = sqrt(max(0, 1 - correlation * correlation))
        return correlation * previous
            + innovationScale * gaussianNoise(standardDeviation: standardDeviation)
    }

    private mutating func gaussianNoise(standardDeviation: Double) -> Double {
        guard standardDeviation > 0 else { return 0 }
        let first = max(nextUniform(), Double.leastNonzeroMagnitude)
        let second = nextUniform()
        let standardNormal = sqrt(-2 * log(first)) * cos(2 * .pi * second)
        return standardNormal * standardDeviation
    }

    private mutating func nextUniform() -> Double {
        randomState &+= 0x9E37_79B9_7F4A_7C15
        var value = randomState
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    private static let beaconNamespace = UUID(
        uuidString: "D18A2C50-41B0-4A39-A971-4D8E27EF8C11"
    )!

    private static func normalizedHeading(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 360)
        return remainder >= 0 ? remainder : remainder + 360
    }

    private static func shortestAngle(from: Double, to: Double) -> Double {
        var delta = normalizedHeading(to) - normalizedHeading(from)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private static func bssid(for value: String) -> String {
        let hash = stableHash(value)
        let bytes = (0..<6).map { offset in
            UInt8(truncatingIfNeeded: hash >> UInt64(offset * 8))
        }
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private static func uuid(for value: String) -> UUID {
        let first = stableHash(value)
        let second = stableHash("indoor-simulator:\(value)")
        let text = String(
            format: "%08X-%04X-%04X-%04X-%012llX",
            UInt32(truncatingIfNeeded: first >> 32),
            UInt16(truncatingIfNeeded: first >> 16),
            UInt16(truncatingIfNeeded: first),
            UInt16(truncatingIfNeeded: second >> 48),
            second & 0x0000_ffff_ffff_ffff
        )
        return UUID(uuidString: text)!
    }
}

/// App-owned positioning engines should depend on these sources instead of
/// directly depending on unavailable Simulator hardware.
public protocol SimulatedWiFiSignalSource: Sendable {
    func observations() -> AsyncStream<[SimulatedWiFiObservation]>
}

public protocol SimulatedBluetoothSignalSource: Sendable {
    func observations() -> AsyncStream<[SimulatedBluetoothObservation]>
}

public protocol SimulatedMotionSource: Sendable {
    func samples() -> AsyncStream<SimulatedMotionSample>
}
