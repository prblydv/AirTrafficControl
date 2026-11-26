import AppKit
import SwiftUI
import SpriteKit

@main struct LiveRenderingChecks {
    @MainActor static func main() throws {
        let app=NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:800),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.contentView=NSHostingView(rootView:ContentView())
        window.makeKeyAndOrderFront(nil)
        func pump(_ seconds:Double) { RunLoop.main.run(until:Date().addingTimeInterval(seconds)) }
        func find(_ node:NSView)->SKView? {
            if let view=node as? SKView { return view }
            return node.subviews.lazy.compactMap { find($0) }.first
        }
        pump(2)
        let view=find(window.contentView!)!
        let scene=view.scene as! AirportScene
        precondition(view.isPaused,"Briefing must draw once and stop its display loop")
        let native=view as! GameSKView
        let anchor=CGPoint(x:view.bounds.midX,y:view.bounds.midY)
        native.applyMagnification(0.4,phase:.began,location:anchor)
        pump(0.1)
        precondition(scene.zoomFactor>1.3,"Native trackpad pinch did not zoom while paused")
        native.applyMagnification(0,phase:.ended,location:anchor)
        scene.resetZoom();pump(0.1)
        scene.simulation.showBriefing=false
        scene.simulation.startLive()
        pump(2)
        precondition(scene.simulation.elapsed>0.5,"Hosted game display clock did not start")
        precondition(scene.childNode(withName:"//aircraftLayer")!.children.count>0,"No aircraft rendered")
        precondition(view.texture(from:scene) != nil,"No rendered scene texture")
        scene.simulation.running=false
        let paused=scene.simulation.elapsed
        pump(0.3)
        precondition(scene.simulation.elapsed==paused)
        precondition(view.isPaused,"Paused game kept its display loop running")
        scene.simulation.startLive()
        pump(0.5)
        precondition(scene.simulation.elapsed>paused,"Hosted game failed to resume")
        precondition(!view.isPaused)
        native.applyMagnification(0.4,phase:.began,location:anchor)
        pump(0.1)
        precondition(scene.zoomFactor>1.3,"Native trackpad pinch did not zoom during play")
        native.applyMagnification(0,phase:.ended,location:anchor)
        print("PASS:real SwiftUI window renders aircraft, advances display-clock simulation, pauses and resumes")
        window.orderOut(nil)
    }
}
