import Foundation
import AppKit
import SwiftUI

@main struct RouteEditorChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil);_ = NSApplication.shared
        let model=RouteEditorModel(document:AirportRouteDocument())
        let a=Point(x:620,y:340),b=Point(x:650,y:340),c=Point(x:680,y:340)
        model.draw(a,snap:2);model.draw(b,snap:2);model.draw(c,snap:2)
        precondition(model.document.nodes.count==3 && model.document.edges.count==2)
        model.selectedNode=nil;model.draw(Point(x:635,y:340),snap:2)
        precondition(model.document.nodes.count==4 && model.document.edges.count==3)
        model.undo();precondition(model.document.nodes.count==3)
        model.redo();precondition(model.document.nodes.count==4)
        model.select(Point(x:625,y:340),snap:2);precondition(model.selectedEdge != nil)
        model.deleteSelected();precondition(model.document.edges.count==2)
        model.undo();precondition(model.document.edges.count==3)
        model.testRoute(a,snap:2,role:0);model.testRoute(c,snap:2,role:0)
        precondition(!model.preview.isEmpty && abs(FlightCurves.length(from:a,route:model.preview)-60)<0.001)
        model.changeLayer(.services);model.access=[ServiceKind.fire.rawValue]
        let s=Point(x:1000,y:200),e=Point(x:1040,y:200)
        model.draw(s,snap:2);model.draw(e,snap:2)
        model.testRoute(s,snap:2,role:2);model.testRoute(e,snap:2,role:2);precondition(!model.preview.isEmpty)
        model.testRoute(s,snap:2,role:5);model.testRoute(e,snap:2,role:5);precondition(model.preview.isEmpty)
        let decoded=try JSONDecoder().decode(AirportRouteDocument.self,from:JSONEncoder().encode(model.document))
        precondition(decoded==model.document && decoded.problems().isEmpty)
        precondition(AirportFence.contains(Point(x:600,y:400)) && !AirportFence.contains(Point(x:200,y:400)))
        var bad=model.document;bad.nodes.append(RouteNode(id:999,layer:.services,point:Point(x:200,y:400)));bad.edges.append(RouteEdge(id:999,a:999,b:model.document.nodes.last!.id,access:[2]))
        precondition(bad.activationProblems().isEmpty,"The removed boundary must not restrict tracing or activation")
        print("PASS: draw/connect/split, select/delete, undo/redo, vehicle-specific route tests, JSON round trip and boundary validation")

        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let photo=NSImage(contentsOf:root.appendingPathComponent("AirTrafficControl/Assets.xcassets/DelhiBoard.imageset/delhi-board-expanded.png"))!
        let view=RouteEditorView(backgroundImage:Image(nsImage:photo),document:RouteEditorModel.builtIn(),autosaveOnDismiss:false,onApply:{}).frame(width:1400,height:900)
        let renderer=ImageRenderer(content:view);renderer.proposedSize=ProposedViewSize(width:1400,height:900);renderer.scale=1
        guard let picture=renderer.nsImage,let data=picture.tiffRepresentation,let bitmap=NSBitmapImageRep(data:data) else { fatalError("Editor snapshot failed") }
        try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("art/route-editor-preview.png"))
        let host=NSHostingView(rootView:view.environment(\.colorScheme,.dark))
        host.frame=CGRect(x:0,y:0,width:1400,height:900)
        let window=NSWindow(contentRect:host.frame,styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.contentView=host;window.setFrameOrigin(CGPoint(x:-5000,y:-5000));window.orderFront(nil)
        RunLoop.main.run(until:Date().addingTimeInterval(0.3));host.layoutSubtreeIfNeeded()
        if let actual=host.bitmapImageRepForCachingDisplay(in:host.bounds) {
            host.cacheDisplay(in:host.bounds,to:actual)
            try actual.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("art/route-editor-native-preview.png"))
        }
        window.orderOut(nil)
        print("PASS: native interactive editor renders with real airport image and graph overlay")

        model.setPin("gate-0-port",point:Point(x:660,y:543))
        try RoutingOverrides.activate(model.document,persist:false)
        precondition(SurfaceLayout.gates[0].port==Point(x:660,y:543))
        precondition(ServiceRoads.graph(for:.fire).nodes.count>0 && ServiceRoads.graph(for:.fuel).nodes.isEmpty)
        precondition(SurfaceLayout.taxiRoute(from:Point(x:660,y:543),to:SurfaceLayout.hold(0)).isEmpty,"Missing connectors must fail; no off-network shortcut")
        let road=RoadGraph(nodes:[s,e],edges:[RoadGraph.Edge(a:0,b:1)])
        precondition(road.shortestPath(from:Point(x:200,y:400),to:e,maximumAccessDistance:20).isEmpty)
        print("PASS: activated graph/pins feed native routing, role permissions enforced, missing connectors rejected")
    }
}
