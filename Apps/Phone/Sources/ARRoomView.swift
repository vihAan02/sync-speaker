import ARKit
import SceneKit
import SwiftUI
import SyncProtocol

/// What the AR layer draws over the camera, derived from the tracker's phase and the leader's render targets.
struct RoomOverlay: Equatable {
    struct Speaker: Equatable {
        var channel: SpeakerRender.Channel
        var delayMs: Double
        var gain: Double
    }

    var phase: RoomTracker.Phase
    /// The speaker a tap on the camera view will place.
    var selected: SpeakerID?
    var showMap = true
    var following = true
    /// Live render targets from the leader, when connected.
    var speakers: [SpeakerID: Speaker] = [:]
}

/// Camera view with the reconstructed room, the MacBook markers and the sound paths to the listener.
struct ARRoomView: UIViewRepresentable {
    enum Tap {
        case surface(SIMD3<Float>)
        case marker(SpeakerID)
        case miss
    }

    let session: ARSession
    let overlay: RoomOverlay
    var onTap: @MainActor (Tap) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator,
                                                         action: #selector(Coordinator.handleTap(_:))))
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.setOverlay(overlay)
        let debug: SCNDebugOptions = overlay.phase == .scanning || overlay.phase == .relocalizing ? [.showFeaturePoints] : []
        if view.debugOptions != debug { view.debugOptions = debug }
    }

    /// Owns the SceneKit content. Node callbacks and `updateAtTime` run on SceneKit's render queue; only the overlay
    /// crosses threads, under a lock.
    final class Coordinator: NSObject, ARSCNViewDelegate, @unchecked Sendable {
        weak var view: ARSCNView?
        var onTap: (@MainActor (Tap) -> Void)?

        private let lock = NSLock()
        private var latest = RoomOverlay(phase: .scanning)
        // Render queue only.
        private var applied: RoomOverlay?
        private var markers: [UUID: SpeakerMarker] = [:]
        private var lastLabelTime: TimeInterval = 0

        func setOverlay(_ overlay: RoomOverlay) {
            lock.withLock { latest = overlay }
        }

        // MARK: Taps (main thread)

        @MainActor @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            let hits = view.hitTest(point, options: [
                .categoryBitMask: RoomScene.surfaceCategory | RoomScene.markerCategory,
                .searchMode: SCNHitTestSearchMode.closest.rawValue,
                .ignoreHiddenNodes: false,
            ])
            if let hit = hits.first {
                if let speaker = SpeakerMarker.speaker(owning: hit.node) {
                    onTap?(.marker(speaker))
                } else {
                    onTap?(.surface(hit.simdWorldCoordinates))
                }
                return
            }
            // No mesh under the finger (e.g. no LiDAR): fall back to ARKit's plane and depth estimates.
            for target in [ARRaycastQuery.Target.existingPlaneGeometry, .estimatedPlane] {
                if let query = view.raycastQuery(from: point, allowing: target, alignment: .any),
                   let result = view.session.raycast(query).first {
                    let t = result.worldTransform.columns.3
                    onTap?(.surface(SIMD3(t.x, t.y, t.z)))
                    return
                }
            }
            onTap?(.miss)
        }

        // MARK: Anchors (render queue)

        func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
            if let speaker = RoomTracker.speaker(for: anchor) {
                let marker = SpeakerMarker(speaker: speaker)
                node.addChildNode(marker.node)
                markers[anchor.identifier] = marker
                marker.appear()
            } else if let mesh = anchor as? ARMeshAnchor {
                node.addChildNode(RoomScene.surfaceNode(geometry: RoomScene.geometry(for: mesh.geometry)))
            } else if let plane = anchor as? ARPlaneAnchor, !RoomTracker.supportsMesh,
                      let device = renderer.device, let geometry = ARSCNPlaneGeometry(device: device) {
                geometry.update(from: plane.geometry)
                geometry.materials = [RoomScene.planeMaterial(vertical: plane.alignment == .vertical)]
                node.addChildNode(RoomScene.surfaceNode(geometry: geometry))
            }
        }

        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let surface = node.childNodes.first(where: { $0.name == RoomScene.surfaceName }) else { return }
            if let mesh = anchor as? ARMeshAnchor {
                RoomScene.update(surface: surface, geometry: RoomScene.geometry(for: mesh.geometry))
            } else if let plane = anchor as? ARPlaneAnchor, let geometry = surface.geometry as? ARSCNPlaneGeometry {
                geometry.update(from: plane.geometry)
            }
        }

        func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
            markers[anchor.identifier] = nil
        }

        // MARK: Per frame (render queue)

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            let overlay = lock.withLock { latest }
            if overlay != applied {
                RoomScene.setSurfaceOpacity(Self.surfaceOpacity(for: overlay))
                applied = overlay
            }
            guard let camera = renderer.pointOfView?.simdWorldPosition else { return }
            let refreshLabels = time - lastLabelTime > 0.15
            if refreshLabels { lastLabelTime = time }
            for marker in markers.values {
                marker.update(overlay: overlay, camera: camera, time: time, refreshLabel: refreshLabels)
            }
        }

        private static func surfaceOpacity(for overlay: RoomOverlay) -> CGFloat {
            switch overlay.phase {
            case .scanning: 0.9
            case .relocalizing: 0.7
            case .choose: 0.35
            case .placing: 0.55
            case .listening: overlay.showMap ? 0.22 : 0
            }
        }
    }
}
