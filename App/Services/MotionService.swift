import CoreMotion
import Foundation

/// Reads the accelerometer, gyroscope and compass and reduces them to the few numbers the
/// navigator needs. Assumes the phone is fixed in a mount with the rear camera facing forward.
final class MotionService {
    struct Sample {
        var dt: Double
        var forwardAccel: Double       // m/s^2 along the car's direction of travel
        var yawRate: Double            // deg/s, positive = turning right
        var cameraPitchDown: Double    // radians the rear camera points below the horizon
        var compassHeading: Double?    // degrees from magnetic north the rear camera faces
        var still: Bool                // vibration level looks like a parked or stopped car
    }

    var onSample: ((Sample) -> Void)?
    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    private let manager = CMMotionManager()
    private var lastTimestamp: TimeInterval?
    private var accelWindow: [Double] = []
    private var gyroWindow: [Double] = []
    private let rate = 30.0

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1 / rate
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let frame: CMAttitudeReferenceFrame =
            frames.contains(.xMagneticNorthZVertical) ? .xMagneticNorthZVertical : .xArbitraryZVertical
        let hasCompass = frame == .xMagneticNorthZVertical
        lastTimestamp = nil
        manager.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] motion, _ in
            guard let self = self, let m = motion else { return }
            self.handle(m, hasCompass: hasCompass)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    private func handle(_ m: CMDeviceMotion, hasCompass: Bool) {
        let dt = lastTimestamp.map { m.timestamp - $0 } ?? 1 / rate
        lastTimestamp = m.timestamp
        let g = m.gravity               // unit vector pointing down, device axes
        let a = m.userAcceleration      // in g, gravity removed
        let w = m.rotationRate          // rad/s

        // Car forward = rear camera axis (-Z of the device) flattened onto the horizontal plane.
        let fx = g.z * g.x, fy = g.z * g.y, fz = g.z * g.z - 1
        let norm = max(0.2, (1 - g.z * g.z).squareRoot())
        let forward = 9.80665 * (a.x * fx + a.y * fy + a.z * fz) / norm

        // Rotation about the vertical axis; about "down", positive is clockwise seen from above.
        let yaw = (w.x * g.x + w.y * g.y + w.z * g.z) * 180 / .pi

        // Stand-still detection from one second of vibration.
        accelWindow.append((a.x * a.x + a.y * a.y + a.z * a.z).squareRoot())
        gyroWindow.append((w.x * w.x + w.y * w.y + w.z * w.z).squareRoot())
        let n = Int(rate)
        if accelWindow.count > n { accelWindow.removeFirst(accelWindow.count - n) }
        if gyroWindow.count > n { gyroWindow.removeFirst(gyroWindow.count - n) }
        var still = false
        if accelWindow.count == n {
            let mean = accelWindow.reduce(0, +) / Double(n)
            let variance = accelWindow.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n)
            let gyroMean = gyroWindow.reduce(0, +) / Double(n)
            still = variance.squareRoot() < 0.015 && mean < 0.03 && gyroMean < 0.02
        }

        var compass: Double?
        if hasCompass {
            // The camera axis expressed in the reference frame (X = magnetic north, Y = west, Z = up).
            // CMRotationMatrix conventions are easy to get backwards, so pick the one that
            // reproduces the gravity vector we were given.
            let r = m.attitude.rotationMatrix
            let colErr = abs(-r.m13 - g.x) + abs(-r.m23 - g.y) + abs(-r.m33 - g.z)
            let rowErr = abs(-r.m31 - g.x) + abs(-r.m32 - g.y) + abs(-r.m33 - g.z)
            let north: Double, west: Double
            if colErr <= rowErr {      // matrix maps reference -> device; camera = -(row 3)
                north = -r.m31; west = -r.m32
            } else {                   // matrix maps device -> reference; camera = -(column 3)
                north = -r.m13; west = -r.m23
            }
            if abs(north) + abs(west) > 0.2 {
                compass = Geo.normalize(atan2(-west, north) * 180 / .pi)
            }
        }

        onSample?(Sample(dt: max(0.001, min(0.5, dt)), forwardAccel: forward, yawRate: yaw,
                         cameraPitchDown: asin(max(-1, min(1, -g.z))), compassHeading: compass, still: still))
    }
}
