import AppKit
import NS2Kit
import SceneKit
import simd

/// Live 3D view for the Motion tab: a simple controller model that turns with the real one.
///
/// SceneKit's axes match SDL's sensor frame (+X right, +Y up, +Z toward the viewer), so the orientation
/// from `OrientationFilter` applies directly. Arrows on the controller: X red, Y green, Z blue; the yellow
/// arrow is the gravity the accelerometer measures, drawn in the controller's frame, so when the readings
/// are right it points straight up in the view whatever the controller's position.
@MainActor
final class MotionScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private let controller = SCNNode()
    private let gravity = SCNNode()

    init() {
        scene.background.contents = NSColor.clear

        let cam = SCNCamera()
        cam.fieldOfView = 38
        cam.zNear = 0.01                 // the model is ~0.15 units wide; the default near plane (1) would clip it
        cam.zFar = 10
        camera.camera = cam
        camera.simdPosition = SIMD3(0, 0.22, 0.38)
        camera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camera)

        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .directional
        light.light?.intensity = 900
        light.simdEulerAngles = SIMD3(-0.9, 0.4, 0)
        scene.rootNode.addChildNode(light)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        scene.rootNode.addChildNode(ambient)

        buildController()
        scene.rootNode.addChildNode(controller)

        // World reference: a faint floor ring.
        let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.13, pipeRadius: 0.0015))
        ring.geometry?.firstMaterial?.diffuse.contents = NSColor.secondaryLabelColor.withAlphaComponent(0.35)
        ring.simdPosition = SIMD3(0, -0.06, 0)
        scene.rootNode.addChildNode(ring)
    }

    func update(orientation: simd_quatd, accel: SIMD3<Double>?) {
        controller.simdOrientation = simd_quatf(ix: Float(orientation.imag.x), iy: Float(orientation.imag.y),
                                                iz: Float(orientation.imag.z), r: Float(orientation.real))
        if let a = accel, simd_length(a) > 0.2 {
            gravity.isHidden = false
            let dir = simd_normalize(SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z)))
            gravity.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: dir)
            gravity.simdScale = SIMD3(1, Float(min(2, simd_length(a))), 1)
        } else {
            gravity.isHidden = true
        }
    }

    // MARK: Model

    private func material(_ c: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = c
        m.roughness.contents = 0.6
        return m
    }

    private func buildController() {
        let shell = NSColor(white: 0.22, alpha: 1)
        // Body lies flat in the X–Z plane; its face (+Y) points up. The top edge (shoulders) is at −Z.
        let body = SCNNode(geometry: SCNBox(width: 0.15, height: 0.026, length: 0.075, chamferRadius: 0.018))
        body.geometry?.materials = [material(shell)]
        controller.addChildNode(body)
        for x: Float in [-0.052, 0.052] {                 // grips reaching toward the player and down
            let grip = SCNNode(geometry: SCNCapsule(capRadius: 0.019, height: 0.075))
            grip.geometry?.materials = [material(shell)]
            grip.simdPosition = SIMD3(x, -0.008, 0.042)
            grip.simdEulerAngles = SIMD3(.pi / 2 - 0.35, 0, x < 0 ? -0.18 : 0.18)
            controller.addChildNode(grip)
        }
        for (x, z) in [(Float(-0.035), Float(-0.008)), (0.025, 0.018)] {   // sticks
            let stick = SCNNode(geometry: SCNCylinder(radius: 0.009, height: 0.012))
            stick.geometry?.materials = [material(NSColor(white: 0.45, alpha: 1))]
            stick.simdPosition = SIMD3(x, 0.018, z)
            controller.addChildNode(stick)
        }
        let face = SCNNode(geometry: SCNSphere(radius: 0.006))           // face buttons, right side
        face.geometry?.materials = [material(.systemGreen)]
        face.simdPosition = SIMD3(0.045, 0.015, -0.01)
        controller.addChildNode(face)
        let top = SCNNode(geometry: SCNBox(width: 0.12, height: 0.012, length: 0.012, chamferRadius: 0.005))
        top.geometry?.materials = [material(.systemOrange)]              // shoulders = top edge
        top.simdPosition = SIMD3(0, 0.004, -0.04)
        controller.addChildNode(top)

        controller.addChildNode(arrow(SIMD3(1, 0, 0), .systemRed, length: 0.1))
        controller.addChildNode(arrow(SIMD3(0, 1, 0), .systemGreen, length: 0.1))
        controller.addChildNode(arrow(SIMD3(0, 0, 1), .systemBlue, length: 0.1))

        let g = arrow(SIMD3(0, 1, 0), .systemYellow, length: 0.08, radius: 0.0035)
        gravity.addChildNode(g)
        controller.addChildNode(gravity)
    }

    /// An arrow from the origin along `dir`.
    private func arrow(_ dir: SIMD3<Float>, _ color: NSColor, length: Float, radius: Float = 0.0022) -> SCNNode {
        let node = SCNNode()
        let shaft = SCNNode(geometry: SCNCylinder(radius: CGFloat(radius), height: CGFloat(length)))
        shaft.geometry?.materials = [material(color)]
        shaft.simdPosition = SIMD3(0, length / 2, 0)
        let head = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: CGFloat(radius * 3), height: CGFloat(radius * 6)))
        head.geometry?.materials = [material(color)]
        head.simdPosition = SIMD3(0, length + radius * 3, 0)
        node.addChildNode(shaft)
        node.addChildNode(head)
        node.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: simd_normalize(dir))
        return node
    }
}
