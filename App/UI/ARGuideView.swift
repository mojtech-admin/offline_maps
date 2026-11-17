import AVFoundation
import SwiftUI
import UIKit

/// Live camera picture.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        // The app is locked to landscape-right, the sensor's native orientation.
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }
    }
}

/// Camera view with the route painted onto the road ahead.
///
/// The ribbon is drawn by projecting points of the route (known in metres ahead / to the side of
/// the car) through a pinhole camera model using the mount height and the phone's measured pitch.
struct ARGuideView: View {
    @ObservedObject var engine: NavigationEngine

    var body: some View {
        ZStack {
            CameraPreview(session: engine.camera.session)
            Canvas { context, size in
                guard let route = engine.route, let car = engine.position else { return }
                drawRibbon(context: context, size: size, route: route, car: car)
            }
            if engine.route == nil {
                Text("Choose a destination to see directions on the road")
                    .font(.headline).padding(10)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundColor(.white)
            }
        }
        .ignoresSafeArea()
    }

    private func drawRibbon(context: GraphicsContext, size: CGSize, route: Route, car: Coord) {
        let cam = engine.camera
        let frame = cam.frameSize
        guard frame.width > 0, frame.height > 0 else { return }
        let scale = max(size.width / frame.width, size.height / frame.height)   // aspect fill
        let f = cam.focalPixels * Double(scale)
        let h = cam.mountHeight, pitch = cam.pitchDown
        let heading = engine.heading * .pi / 180
        let halfWidth = 1.3

        func project(forward: Double, right: Double) -> CGPoint? {
            let z = forward * cos(pitch) + h * sin(pitch)
            let y = -forward * sin(pitch) + h * cos(pitch)
            guard z > 1.5 else { return nil }
            return CGPoint(x: Double(size.width) / 2 + f * right / z, y: Double(size.height) / 2 + f * y / z)
        }

        var left: [CGPoint] = [], rightEdge: [CGPoint] = [], centre: [(CGPoint, Double)] = []
        var previous: (fwd: Double, right: Double)?
        for d in stride(from: 4.0, through: 160.0, by: 4.0) {
            let along = engine.routeDistance + d
            if along > route.length { break }
            let p = Geo.toLocal(route.coord(at: along), origin: car)
            let fwd = p.x * sin(heading) + p.y * cos(heading)
            let right = p.x * cos(heading) - p.y * sin(heading)
            defer { previous = (fwd, right) }
            // direction of the path here, to offset the two edges sideways
            var nx = 1.0, ny = 0.0
            if let q = previous {
                let dx = right - q.right, dy = fwd - q.fwd
                let len = (dx * dx + dy * dy).squareRoot()
                if len > 0.1 { nx = dy / len; ny = -dx / len }
            }
            guard let l = project(forward: fwd - ny * halfWidth, right: right - nx * halfWidth),
                  let r = project(forward: fwd + ny * halfWidth, right: right + nx * halfWidth),
                  let c = project(forward: fwd, right: right) else { continue }
            left.append(l); rightEdge.append(r); centre.append((c, d))
        }
        guard left.count > 2 else { return }

        var ribbon = Path()
        ribbon.move(to: left[0])
        for p in left.dropFirst() { ribbon.addLine(to: p) }
        for p in rightEdge.reversed() { ribbon.addLine(to: p) }
        ribbon.closeSubpath()
        context.fill(ribbon, with: .color(Color(red: 0.2, green: 0.55, blue: 1.0).opacity(0.45)))
        context.stroke(ribbon, with: .color(.white.opacity(0.7)), lineWidth: 1.5)

        // chevrons every 12 m, shrinking with distance
        for (i, item) in centre.enumerated() where i % 3 == 1 && i + 1 < centre.count {
            let p = item.0, q = centre[i + 1].0
            let w = CGFloat(max(4, f * 0.8 / max(4, item.1)))
            let dx = q.x - p.x, dy = q.y - p.y
            let len = max(1, hypot(dx, dy))
            let ux = dx / len, uy = dy / len
            var chevron = Path()
            chevron.move(to: CGPoint(x: p.x - uy * w, y: p.y + ux * w))
            chevron.addLine(to: CGPoint(x: p.x + ux * w * 0.8, y: p.y + uy * w * 0.8))
            chevron.addLine(to: CGPoint(x: p.x + uy * w, y: p.y - ux * w))
            context.stroke(chevron, with: .color(.white), style: StrokeStyle(lineWidth: max(2, w / 4), lineCap: .round, lineJoin: .round))
        }
    }
}
