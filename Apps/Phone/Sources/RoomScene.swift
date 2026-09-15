import ARKit
import SceneKit
import SyncProtocol
import UIKit

/// SceneKit content for the room map: reconstructed surfaces colored by what ARKit thinks they are.
/// Everything here is touched from SceneKit's render queue.
enum RoomScene {
    static let surfaceCategory = 1 << 1
    static let markerCategory = 1 << 2
    static let surfaceName = "room.surface"

    /// Colors by `ARMeshClassification` raw value: none, wall, floor, ceiling, table, seat, window, door.
    static let classColors: [UIColor] = [
        UIColor(white: 0.9, alpha: 1),
        UIColor(red: 0.32, green: 0.66, blue: 1.00, alpha: 1),
        UIColor(red: 0.38, green: 0.75, blue: 0.45, alpha: 1),
        UIColor(red: 0.66, green: 0.55, blue: 0.98, alpha: 1),
        UIColor(red: 1.00, green: 0.60, blue: 0.04, alpha: 1),
        UIColor(red: 0.96, green: 0.45, blue: 0.71, alpha: 1),
        UIColor(red: 0.13, green: 0.83, blue: 0.93, alpha: 1),
        UIColor(red: 0.98, green: 0.80, blue: 0.08, alpha: 1),
    ]

    private static let fills = classColors.map { surfaceMaterial($0.withAlphaComponent(0.28), lines: false) }
    private static let wires = classColors.map { surfaceMaterial($0.withAlphaComponent(0.85), lines: true) }
    private static let planes = [
        surfaceMaterial(classColors[2].withAlphaComponent(0.35), lines: false),
        surfaceMaterial(classColors[1].withAlphaComponent(0.35), lines: false),
    ]

    private static func surfaceMaterial(_ color: UIColor, lines: Bool) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.isDoubleSided = true
        material.fillMode = lines ? .lines : .fill
        // Translucent overlay: don't hide the MacBook markers behind walls or desks.
        material.writesToDepthBuffer = false
        return material
    }

    static func planeMaterial(vertical: Bool) -> SCNMaterial {
        planes[vertical ? 1 : 0]
    }

    static func setSurfaceOpacity(_ opacity: CGFloat) {
        for material in fills + wires + planes { material.transparency = opacity }
    }

    /// A filled surface plus, for meshes, a wireframe copy on top.
    static func surfaceNode(geometry: SCNGeometry) -> SCNNode {
        let node = SCNNode(geometry: geometry)
        node.name = surfaceName
        node.categoryBitMask = surfaceCategory
        node.renderingOrder = -1
        if !(geometry is ARSCNPlaneGeometry) {
            let wire = SCNNode(geometry: wireframe(of: geometry))
            wire.categoryBitMask = surfaceCategory
            wire.renderingOrder = -1
            node.addChildNode(wire)
        }
        return node
    }

    static func update(surface node: SCNNode, geometry: SCNGeometry) {
        node.geometry = geometry
        node.childNodes.first?.geometry = wireframe(of: geometry)
    }

    private static func wireframe(of geometry: SCNGeometry) -> SCNGeometry {
        let copy = SCNGeometry(sources: geometry.sources, elements: geometry.elements)
        copy.materials = geometry.materials.compactMap { fill in fills.firstIndex(of: fill).map { wires[$0] } }
        return copy
    }

    /// Copies an ARKit mesh (its buffers are reused between updates) into a geometry with one element per class.
    static func geometry(for mesh: ARMeshGeometry) -> SCNGeometry {
        let vertices = mesh.vertices
        let vertexData = Data(bytes: vertices.buffer.contents().advanced(by: vertices.offset),
                              count: vertices.stride * vertices.count)
        let source = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: vertices.count,
                                       usesFloatComponents: true, componentsPerVector: 3,
                                       bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                       dataStride: vertices.stride)

        let faces = mesh.faces
        guard faces.bytesPerIndex == MemoryLayout<UInt32>.size, faces.indexCountPerPrimitive == 3 else {
            return SCNGeometry(sources: [source], elements: [])
        }
        let indexBase = faces.buffer.contents()
        var byClass: [Int: [UInt32]] = [:]
        let classification = mesh.classification.flatMap { $0.count == faces.count ? $0 : nil }
        for face in 0..<faces.count {
            var kind = 0
            if let classification {
                let raw = classification.buffer.contents()
                    .loadUnaligned(fromByteOffset: classification.offset + face * classification.stride, as: UInt8.self)
                kind = Int(raw) < classColors.count ? Int(raw) : 0
            }
            for corner in 0..<3 {
                byClass[kind, default: []].append(
                    indexBase.loadUnaligned(fromByteOffset: (face * 3 + corner) * 4, as: UInt32.self))
            }
        }

        let kinds = byClass.keys.sorted()
        let elements = kinds.map { kind in
            byClass[kind]!.withUnsafeBytes { bytes in
                SCNGeometryElement(data: Data(bytes), primitiveType: .triangles,
                                   primitiveCount: bytes.count / 12, bytesPerIndex: 4)
            }
        }
        let geometry = SCNGeometry(sources: [source], elements: elements)
        geometry.materials = kinds.map { fills[$0] }
        return geometry
    }
}

/// A virtual MacBook at a placed speaker, with a floating badge, sound waves and a path to the listener.
final class SpeakerMarker {
    let speaker: SpeakerID
    let node = SCNNode()
    private let model = SCNNode()
    private let badge = SCNNode()
    private let waves = SCNNode()
    private let path = SCNNode()
    private let waveMaterial = SCNMaterial()
    private let pathMaterial = SCNMaterial()
    private var label = ""
    private var tint = UIColor.white

    private static let prefix = "marker."

    init(speaker: SpeakerID) {
        self.speaker = speaker
        node.name = Self.prefix + speaker.rawValue
        buildModel()
        buildBadge()
        buildWaves()
        buildPath()
    }

    static func speaker(owning node: SCNNode) -> SpeakerID? {
        var current: SCNNode? = node
        while let candidate = current {
            if let name = candidate.name, name.hasPrefix(prefix) {
                return SpeakerID(rawValue: String(name.dropFirst(prefix.count)))
            }
            current = candidate.parent
        }
        return nil
    }

    func appear() {
        model.scale = SCNVector3(0.01, 0.01, 0.01)
        let grow = SCNAction.scale(to: 1, duration: 0.35)
        grow.timingMode = .easeOut
        model.runAction(grow)
    }

    func update(overlay: RoomOverlay, camera: SIMD3<Float>, time: TimeInterval, refreshLabel: Bool) {
        let here = node.simdWorldPosition
        let distance = simd_distance(SIMD2(here.x, here.z), SIMD2(camera.x, camera.z))
        let render = overlay.speakers[speaker]
        let listening = overlay.phase == .listening

        let newTint: UIColor = switch (overlay.phase, render?.channel) {
        case (.listening, .left?): Self.leftColor
        case (.listening, .right?): Self.rightColor
        case (.placing, _) where overlay.selected == speaker: Self.selectedColor
        default: .white
        }
        if newTint != tint {
            tint = newTint
            waveMaterial.diffuse.contents = tint
            pathMaterial.multiply.contents = tint
        }

        if refreshLabel {
            var chip: String?
            var detail = String(format: "%.2f m away", distance)
            if listening, let render {
                chip = switch render.channel {
                case .left: "Left"
                case .right: "Right"
                case .mono: "Mono"
                }
                let db = 20 * log10(max(render.gain, 0.001))
                detail = String(format: "%.2f m · %.1f ms · %+.1f dB", distance, render.delayMs, db)
            } else if overlay.phase == .placing {
                chip = overlay.selected == speaker ? "Selected" : "Placed"
            }
            let text = [chip ?? "", detail].joined(separator: "|")
            if text != label {
                label = text
                let image = Self.badgeImage(title: "MacBook \(speaker.rawValue)", chip: chip, chipColor: tint, detail: detail)
                badge.geometry?.firstMaterial?.diffuse.contents = image
            }
        }

        // Sound travels from the MacBook toward the listener's chest, just below the phone.
        let listener = camera - SIMD3(0, 0.3, 0)
        waves.isHidden = !listening
        path.isHidden = !(listening && overlay.following) || distance < 0.3
        if listening {
            waves.simdLook(at: listener, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
            waves.opacity = CGFloat(0.35 + 0.65 * (render?.gain ?? 1))
        }
        if !path.isHidden {
            let start = SIMD3<Float>(0, 0.02, 0)
            let end = node.simdConvertPosition(listener, from: nil)
            let span = end - start
            let length = simd_length(span)
            path.simdPosition = (start + end) / 2
            path.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: span / length)
            path.simdScale = SIMD3(1, length, 1)
            // Dashes flow toward the listener, eight per meter.
            var transform = SCNMatrix4Identity
            transform.m22 = length * 8
            transform.m42 = Float(time.truncatingRemainder(dividingBy: 1000) * 1.5)
            pathMaterial.diffuse.contentsTransform = transform
        }
    }

    // MARK: Building

    static let leftColor = UIColor(red: 0.32, green: 0.66, blue: 1.00, alpha: 1)
    static let rightColor = UIColor(red: 1.00, green: 0.60, blue: 0.04, alpha: 1)
    static let selectedColor = UIColor(red: 0.38, green: 0.75, blue: 0.45, alpha: 1)

    private func buildModel() {
        let aluminium = SCNMaterial()
        aluminium.lightingModel = .physicallyBased
        aluminium.diffuse.contents = UIColor(white: 0.84, alpha: 1)
        aluminium.metalness.contents = 0.75
        aluminium.roughness.contents = 0.35
        aluminium.transparency = 0.85
        let dark = SCNMaterial()
        dark.lightingModel = .physicallyBased
        dark.diffuse.contents = UIColor(white: 0.12, alpha: 1)
        dark.roughness.contents = 0.6

        // MacBook Air proportions, in meters. The screen faces +Z, toward the person who placed it.
        let base = SCNNode(geometry: SCNBox(width: 0.304, height: 0.012, length: 0.215, chamferRadius: 0.004))
        base.geometry?.firstMaterial = aluminium
        base.position = SCNVector3(0, 0.006, 0)
        let keyboard = SCNNode(geometry: SCNBox(width: 0.27, height: 0.001, length: 0.095, chamferRadius: 0.002))
        keyboard.geometry?.firstMaterial = dark
        keyboard.position = SCNVector3(0, 0.0125, -0.03)
        let trackpad = SCNNode(geometry: SCNBox(width: 0.125, height: 0.001, length: 0.075, chamferRadius: 0.003))
        trackpad.geometry?.firstMaterial = dark
        trackpad.opacity = 0.5
        trackpad.position = SCNVector3(0, 0.0125, 0.06)

        let hinge = SCNNode()
        hinge.position = SCNVector3(0, 0.012, -0.105)
        hinge.eulerAngles.x = -0.3
        let lid = SCNNode(geometry: SCNBox(width: 0.304, height: 0.205, length: 0.006, chamferRadius: 0.003))
        lid.geometry?.firstMaterial = aluminium
        lid.position = SCNVector3(0, 0.1025, 0)
        let screen = SCNNode(geometry: SCNPlane(width: 0.28, height: 0.18))
        let screenMaterial = SCNMaterial()
        screenMaterial.lightingModel = .constant
        screenMaterial.diffuse.contents = Self.screenImage(speaker: speaker)
        screen.geometry?.firstMaterial = screenMaterial
        screen.position = SCNVector3(0, 0.1025, 0.0035)
        hinge.addChildNode(lid)
        hinge.addChildNode(screen)

        // Invisible, slightly larger box so the marker is easy to tap.
        let hitBox = SCNNode(geometry: SCNBox(width: 0.36, height: 0.26, length: 0.28, chamferRadius: 0))
        let invisible = SCNMaterial()
        invisible.colorBufferWriteMask = []
        invisible.writesToDepthBuffer = false
        hitBox.geometry?.firstMaterial = invisible
        hitBox.position = SCNVector3(0, 0.12, 0)

        for part in [base, keyboard, trackpad, hinge, lid, screen, hitBox] {
            part.categoryBitMask = RoomScene.markerCategory
        }
        [base, keyboard, trackpad, hinge, hitBox].forEach(model.addChildNode)
        node.addChildNode(model)
    }

    private func buildBadge() {
        let plane = SCNPlane(width: 0.34, height: 0.34 * 200 / 560)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        plane.firstMaterial = material
        badge.geometry = plane
        badge.position = SCNVector3(0, 0.36, 0)
        badge.renderingOrder = 10
        badge.constraints = [SCNBillboardConstraint()]
        node.addChildNode(badge)
    }

    private func buildWaves() {
        waveMaterial.lightingModel = .constant
        waveMaterial.diffuse.contents = tint
        waveMaterial.writesToDepthBuffer = false
        waves.position = SCNVector3(0, 0.11, 0)
        let travel = 1.6
        for index in 0..<3 {
            let torus = SCNTorus(ringRadius: 0.1, pipeRadius: 0.003)
            torus.firstMaterial = waveMaterial
            let ring = SCNNode(geometry: torus)
            ring.eulerAngles.x = .pi / 2 // face the listener along the parent's -Z
            ring.opacity = 0
            let pulse = SCNAction.sequence([
                .run { ring in
                    ring.opacity = 0.9
                    ring.scale = SCNVector3(0.4, 0.4, 0.4)
                    ring.position = SCNVector3Zero
                },
                .group([
                    .scale(to: 2.2, duration: travel),
                    .fadeOut(duration: travel),
                    .move(to: SCNVector3(0, 0, -0.9), duration: travel),
                ]),
            ])
            ring.runAction(.sequence([.wait(duration: Double(index) * travel / 3), .repeatForever(pulse)]))
            waves.addChildNode(ring)
        }
        waves.isHidden = true
        node.addChildNode(waves)
    }

    private func buildPath() {
        let cylinder = SCNCylinder(radius: 0.0035, height: 1)
        pathMaterial.lightingModel = .constant
        pathMaterial.diffuse.contents = Self.dashImage
        pathMaterial.diffuse.wrapT = .repeat
        pathMaterial.diffuse.wrapS = .repeat
        pathMaterial.multiply.contents = tint
        pathMaterial.writesToDepthBuffer = false
        cylinder.firstMaterial = pathMaterial
        path.geometry = cylinder
        path.isHidden = true
        node.addChildNode(path)
    }

    // MARK: Images

    private static let dashImage: UIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 32), format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 4, height: 18))
        }
    }()

    private static func screenImage(speaker: SpeakerID) -> UIImage {
        let size = CGSize(width: 560, height: 360)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(red: 0.05, green: 0.08, blue: 0.16, alpha: 1).cgColor,
                          UIColor(red: 0.10, green: 0.20, blue: 0.36, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height),
                                                     options: [])
            }
            let letter = NSAttributedString(string: speaker.rawValue, attributes: [
                .font: UIFont.systemFont(ofSize: 220, weight: .bold),
                .foregroundColor: UIColor.white,
            ])
            let letterSize = letter.size()
            letter.draw(at: CGPoint(x: (size.width - letterSize.width) / 2, y: (size.height - letterSize.height) / 2 - 16))
            let caption = NSAttributedString(string: "SyncSpeaker", attributes: [
                .font: UIFont.systemFont(ofSize: 30, weight: .medium),
                .foregroundColor: UIColor(white: 1, alpha: 0.6),
            ])
            caption.draw(at: CGPoint(x: (size.width - caption.size().width) / 2, y: size.height - 64))
        }
    }

    private static func badgeImage(title: String, chip: String?, chipColor: UIColor, detail: String) -> UIImage {
        let size = CGSize(width: 560, height: 200)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor(white: 0.04, alpha: 0.8).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4), cornerRadius: 40).fill()
            NSAttributedString(string: title, attributes: [
                .font: UIFont.systemFont(ofSize: 58, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]).draw(at: CGPoint(x: 36, y: 26))
            if let chip {
                let text = NSAttributedString(string: chip, attributes: [
                    .font: UIFont.systemFont(ofSize: 38, weight: .bold),
                    .foregroundColor: UIColor.black,
                ])
                let textSize = text.size()
                let rect = CGRect(x: size.width - 36 - textSize.width - 40, y: 34, width: textSize.width + 40, height: 64)
                chipColor.setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: 32).fill()
                text.draw(at: CGPoint(x: rect.minX + 20, y: rect.midY - textSize.height / 2))
            }
            NSAttributedString(string: detail, attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 40, weight: .medium),
                .foregroundColor: UIColor(white: 1, alpha: 0.78),
            ]).draw(at: CGPoint(x: 36, y: 120))
        }
    }
}
