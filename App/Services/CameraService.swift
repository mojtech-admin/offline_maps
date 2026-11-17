import AVFoundation
import CoreVideo
import Foundation
import Vision

/// Runs the rear camera and derives two things from it without any network:
///  * ground speed, from optical flow of the road surface (needs mount height and camera pitch)
///  * text on road signs, via on-device OCR
/// The app is locked to landscape-right, which is the sensor's native orientation, so frames
/// arrive upright with no rotation.
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()

    /// Called on the main queue about ten times a second. `speed` is m/s or nil when the road
    /// texture could not be tracked; `still` is true when nothing in view is moving.
    var onSpeed: ((_ speed: Double?, _ still: Bool) -> Void)?
    /// Called on the main queue with the text found in a frame.
    var onText: (([SeenText]) -> Void)?

    // Geometry shared with the AR overlay. Written from the main queue.
    var mountHeight = 1.2                 // metres from road to camera
    var pitchDown = 0.0                   // radians, from MotionService
    var roadBandBottom = 0.15             // fraction of frame height hidden by dashboard/bonnet
    private(set) var focalPixels = 1000.0 // focal length in pixels of the delivered frames
    private(set) var frameSize = CGSize(width: 1280, height: 720)
    private(set) var isRunning = false

    private let sessionQueue = DispatchQueue(label: "offroute.camera.session")
    private let videoQueue = DispatchQueue(label: "offroute.camera.video")
    private let ocrQueue = DispatchQueue(label: "offroute.camera.ocr")
    private var configured = false
    private var previous: CVPixelBuffer?
    private var previousTime = 0.0
    private var frameIndex = 0
    private var ocrBusy = false
    private var lastOCR = 0.0

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self = self else { return }
            self.sessionQueue.async {
                if !self.configured { self.configure() }
                if self.configured, !self.session.isRunning { self.session.startRunning() }
                self.isRunning = self.session.isRunning
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.isRunning = false
            self.videoQueue.async { self.previous = nil }
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        guard session.canAddInput(input) else { session.commitConfiguration(); return }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); return }
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }
        session.commitConfiguration()

        // Focus far away and keep exposure short so the road stays sharp.
        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .far }
            device.unlockForConfiguration()
        }
        let fov = Double(device.activeFormat.videoFieldOfView)      // horizontal, degrees
        if fov > 10 { focalPixels = 640 / tan(fov * .pi / 360) }
        configured = true
    }

    // MARK: frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        if CGFloat(width) != frameSize.width {
            focalPixels *= Double(width) / Double(frameSize.width)
            frameSize = CGSize(width: width, height: height)
        }
        frameIndex += 1

        // Flow between two consecutive frames, sampled on every third frame (~10 Hz).
        if frameIndex % 3 == 0, let prev = previous {
            let dt = time - previousTime
            if dt > 0.005, dt < 0.07 {
                let result = measureSpeed(current: buffer, previous: prev, dt: dt)
                DispatchQueue.main.async { self.onSpeed?(result.speed, result.still) }
            }
        }
        previous = buffer
        previousTime = time

        if time - lastOCR > 0.7, !ocrBusy {
            ocrBusy = true
            lastOCR = time
            ocrQueue.async {
                let items = self.readText(buffer)
                self.videoQueue.async { self.ocrBusy = false }
                if !items.isEmpty { DispatchQueue.main.async { self.onText?(items) } }
            }
        }
    }

    // MARK: speed from optical flow

    /// For a camera at height h looking ahead, a point on a flat road seen at an angle β below the
    /// horizon moves down the image at  dy/dt = f (1 + (y/f)²) · v · sin²β / h   pixels per second,
    /// where y is the pixel offset below the image centre. Solving for v at many pixels and taking
    /// the median gives the ground speed.
    private func measureSpeed(current: CVPixelBuffer, previous: CVPixelBuffer, dt: Double)
        -> (speed: Double?, still: Bool) {
        let roi = CGRect(x: 0.25, y: roadBandBottom, width: 0.5, height: 0.3)   // origin bottom-left
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: previous, options: [:])
        request.computationAccuracy = .low
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        request.regionOfInterest = roi
        let handler = VNImageRequestHandler(cvPixelBuffer: current, options: [:])
        guard (try? handler.perform([request])) != nil,
              let flow = (request.results?.first as? VNPixelBufferObservation)?.pixelBuffer else {
            return (nil, false)
        }
        CVPixelBufferLockBaseAddress(flow, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(flow, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(flow) else { return (nil, false) }
        let fw = CVPixelBufferGetWidth(flow), fh = CVPixelBufferGetHeight(flow)
        let rowBytes = CVPixelBufferGetBytesPerRow(flow)
        guard fw > 8, fh > 8 else { return (nil, false) }

        let imageH = Double(frameSize.height)
        let f = focalPixels, h = mountHeight, pitch = pitchDown
        let roiTop = imageH * (1 - Double(roi.maxY))              // rows are counted from the top
        let rowScale = imageH * Double(roi.height) / Double(fh)   // image pixels per flow pixel

        var speeds: [Double] = []
        var usable = 0, moving = 0, signSum = 0.0
        speeds.reserveCapacity(fw * fh / 36)
        for row in stride(from: 2, to: fh - 2, by: 6) {
            let y = roiTop + (Double(row) + 0.5) * rowScale - imageH / 2
            let beta = pitch + atan(y / f)
            if beta < 0.045 { continue }                            // too close to the horizon
            let k = f * (1 + (y / f) * (y / f)) * sin(beta) * sin(beta) / h
            let line = (base + row * rowBytes).assumingMemoryBound(to: Float32.self)
            for col in stride(from: 2, to: fw - 2, by: 6) {
                let dx = Double(line[2 * col]) * rowScale
                let dy = Double(line[2 * col + 1]) * rowScale
                guard dx.isFinite, dy.isFinite else { continue }
                usable += 1
                if abs(dy) < 0.2 || abs(dx) > abs(dy) + 1.5 { continue }
                moving += 1
                signSum += dy > 0 ? 1 : -1
                speeds.append(abs(dy) / dt / k)
            }
        }
        guard usable > 60 else { return (nil, false) }
        if moving * 8 < usable { return (nil, true) }                // almost nothing moves
        // the road must flow consistently one way, and estimates must agree with each other
        guard moving * 3 > usable, abs(signSum) > 0.7 * Double(moving) else { return (nil, false) }
        speeds.sort()
        let median = speeds[speeds.count / 2]
        let spread = speeds[speeds.count * 3 / 4] - speeds[speeds.count / 4]
        guard median.isFinite, median < 70, spread < 0.8 * median + 1 else { return (nil, false) }
        return (median, false)
    }

    // MARK: sign text

    private func readText(_ buffer: CVPixelBuffer) -> [SeenText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.02
        request.regionOfInterest = CGRect(x: 0, y: 0.3, width: 1, height: 0.7)   // skip the dashboard
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return [] }
        var items: [SeenText] = []
        for obs in results {
            guard let top = obs.topCandidates(1).first, top.confidence > 0.4 else { continue }
            let box = obs.boundingBox
            items.append(SeenText(text: top.string, x: Double(box.midX), y: Double(box.midY),
                                  height: Double(box.height)))
        }
        return items
    }
}
