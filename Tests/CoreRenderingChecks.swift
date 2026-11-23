import AppKit
import SpriteKit
@main struct CoreRenderingChecks {
    @MainActor static func main() throws {
        _=NSApplication.shared
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let doc=try JSONDecoder().decode(AirportRouteDocument.self,from:Data(contentsOf:root.appendingPathComponent("AirTrafficControl/airport-routes.json")))
        try RoutingOverrides.activate(doc,persist:false)
        let assets=root.appendingPathComponent("AirTrafficControl/Assets.xcassets")
        func texture(_ name:String)->SKTexture {SKTexture(image:NSImage(contentsOf:assets.appendingPathComponent(name+".imageset/"+name.lowercased()+".png"))!)}
        let aircraft=Dictionary(uniqueKeysWithValues:AircraftCatalog.models.map{($0.assetName,texture($0.assetName))})
        let vehicles=Dictionary(uniqueKeysWithValues:ServiceKind.allCases.map{($0.assetName,texture($0.assetName))})
        let background=SKTexture(image:NSImage(contentsOf:assets.appendingPathComponent("DelhiBoard.imageset/delhi-board-expanded.png"))!)
        let sim=Simulation(seed:17,continuousTraffic:false)
        let scene=AirportScene(simulation:sim,artworkTexture:background,aircraftTextures:aircraft,serviceTextures:vehicles)
        let view=SKView(frame:NSRect(x:0,y:0,width:1672,height:941));view.presentScene(scene);scene.update(1)
        precondition(scene.childNode(withName:"//groundServicesLayer")!.children.count==49)
        precondition(scene.childNode(withName:"//aircraftLayer")!.children.count==12)
        for f in sim.aircraft {
            let node=scene.childNode(withName:"//flight-"+f.id)!
            precondition(node.childNode(withName:"plate")!.isHidden == (f.id != sim.selectedID))
            precondition(node.childNode(withName:"type")!.isHidden == (f.id != sim.selectedID))
            let bank=node.childNode(withName:"body/bank")!
            let red=bank.childNode(withName:"nav-port") as! SKShapeNode,green=bank.childNode(withName:"nav-starboard") as! SKShapeNode
            precondition(red.position.y>0 && green.position.y<0 && red.fillColor != green.fillColor)
            precondition(!red.isHidden && !green.isHidden && node.childNode(withName:"shadow") != nil)
            precondition(bank.childNode(withName:"aircraftBeacon") != nil)
        }
        for g in SurfaceLayout.gates {precondition(scene.childNode(withName:"//gate-"+g.name) != nil)}
        let sky=sim.aircraft[0].id
        sim.elapsed=0.1;scene.update(1.1)
        let nav=scene.childNode(withName:"//flight-"+sky+"/body/bank/nav-port")!
        let bright=nav.alpha;sim.elapsed=0.5;scene.update(1.5);precondition(nav.alpha<bright)
        let grounded=sim.aircraft.first(where:{$0.departure})!.id
        let groundNav=scene.childNode(withName:"//flight-"+grounded+"/body/bank/nav-port")!
        precondition(groundNav.alpha==1)
        let removed=sim.aircraft.last!.id;sim.aircraft.removeLast();scene.update(1.6)
        precondition(scene.childNode(withName:"//flight-"+removed)==nil)
        sim.reset(seed:17);scene.update(1.7)
        let index=sim.aircraft.firstIndex{$0.departure}!,id=sim.aircraft[index].id
        let node=scene.childNode(withName:"//flight-"+id)!,shadow=node.childNode(withName:"shadow")!
        let groundOffset=hypot(shadow.position.x,shadow.position.y),groundAlpha=shadow.alpha,groundScale=shadow.xScale
        sim.aircraft[index].altitude=5000;sim.aircraft[index].phase = .holding;scene.update(2)
        precondition(hypot(shadow.position.x,shadow.position.y)>groundOffset && shadow.alpha<groundAlpha && shadow.xScale>groundScale)
        sim.aircraft[index].altitude=0;sim.aircraft[index].phase = .taxiing;sim.aircraft[index].groundSpeed=10
        let position=sim.aircraft[index].position;sim.elapsed=1.03;scene.update(3)
        let first=node.childNode(withName:"body")!.position
        sim.elapsed=1.09;scene.update(4)
        precondition(first != node.childNode(withName:"body")!.position && sim.aircraft[index].position==position)
        sim.reset(seed:17);scene.update(5)
        let snapshot=NSBitmapImageRep(cgImage:view.texture(from:scene)!.cgImage())
        try snapshot.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("art/core-gameplay-preview.png"))
        scene.pinch(magnification:100,anchor:Point(x:0.5,y:0.5));scene.endPinch();precondition(scene.zoomFactor==3)
        print("PASS:19gate rendering,12aircraft,49vehicles,red/green wing lights,altitude shadows,visual-only vibration,zoom and shift reset")
    }
}
