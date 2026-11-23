import AppKit
import SpriteKit

@main struct RenderingChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let assets=root.appendingPathComponent("AirTrafficControl/Assets.xcassets")
        func texture(_ name:String) throws -> SKTexture {
            let file=assets.appendingPathComponent(name+".imageset/"+name.lowercased()+".png")
            let data=try Data(contentsOf:file), bitmap=NSBitmapImageRep(data:data)!
            precondition(bitmap.hasAlpha && bitmap.pixelsWide>100 && bitmap.pixelsHigh>100)
            return SKTexture(image:NSImage(data:data)!)
        }
        var aircraftTextures:[String:SKTexture]=[:], serviceTextures:[String:SKTexture]=[:]
        for a in AircraftCatalog.models { aircraftTextures[a.assetName]=try texture(a.assetName) }
        for v in ServiceKind.allCases { serviceTextures[v.assetName]=try texture(v.assetName) }
        let bg=SKTexture(image:NSImage(contentsOf:assets.appendingPathComponent("DelhiBoard.imageset/delhi-board-expanded.png"))!)
        let sim=Simulation(seed:17)
        let scene=AirportScene(simulation:sim,artworkTexture:bg,aircraftTextures:aircraftTextures,serviceTextures:serviceTextures)
        let view=SKView(frame:CGRect(x:0,y:0,width:AirportLayout.width,height:AirportLayout.height));view.presentScene(scene)
        func verify(_ time:Double) {
            scene.update(time)
            precondition(scene.size==CGSize(width:AirportLayout.width,height:AirportLayout.height))
            let layer=scene.childNode(withName:"//aircraftLayer")!
            precondition(layer.children.count==sim.aircraft.count)
            for a in sim.aircraft {
                let node=layer.childNode(withName:"flight-"+a.id)!
                precondition(node.childNode(withName:"body/bank/"+a.model.assetName) is SKSpriteNode)
                if a.airborne { precondition(node.position.x>=0 && node.position.x<=AirportLayout.width && node.position.y>=0 && node.position.y<=AirportLayout.height) }
                precondition(abs(node.childNode(withName:"body")!.xScale-a.apparentScale)<0.001)
                precondition(abs((node.childNode(withName:"body/bank") as! SKTransformNode).xRotation-a.bankAngle)<0.001)
            }
            precondition(scene.childNode(withName:"//groundServicesLayer")!.children.count==24)
            var paint=0
            scene.enumerateChildNodes(withName:"//runway-paint") { node,_ in
                precondition((node as! SKLabelNode).fontSize<=8);paint+=1
            }
            precondition(paint==8)
            var gates=0
            for gate in SurfaceLayout.gates { if scene.childNode(withName:"//gate-"+gate.name) != nil { gates+=1 } }
            precondition(gates==9)
            for a in sim.aircraft {
                let marker=scene.childNode(withName:"//flight-"+a.id+"/readyMarker")!
                precondition(marker.isHidden == !(a.readyToDepart && a.phase == .parked))
            }
            let units=scene.childNode(withName:"//groundServicesLayer")!.children
            precondition(units.allSatisfy { $0.childNode(withName:"beacon-0") != nil })
        }
        verify(1)
        let anchor=Point(x:0.7,y:0.4)
        let point=CGPoint(x:view.bounds.width*anchor.x,y:view.bounds.height*(1-anchor.y))
        let beforeZoom=scene.convertPoint(fromView:point)
        scene.pinch(magnification:100,anchor:anchor);scene.endPinch()
        precondition(scene.zoomFactor==3 && abs(scene.camera!.xScale-1.0/3)<0.001)
        let afterZoom=scene.convertPoint(fromView:point)
        precondition(hypot(beforeZoom.x-afterZoom.x,beforeZoom.y-afterZoom.y)<0.01,"Pinch must keep its focus point fixed")
        scene.dragMap(translation:Point(x:100000,y:-100000));scene.endDrag()
        precondition(scene.camera!.position.x>=scene.size.width/6-0.001 && scene.camera!.position.y<=scene.size.height*5/6+0.001)
        scene.pinch(magnification:0.001,anchor:Point(x:0.5,y:0.5));scene.endPinch()
        precondition(scene.zoomFactor==1 && scene.camera!.position==CGPoint(x:scene.size.width/2,y:scene.size.height/2))
        print("PASS: anchored1–3xpinch zoom, bounded drag, reset and bank transform")
        sim.reset();verify(2);sim.reset(seed:17);verify(3)
        let initial=NSBitmapImageRep(cgImage:view.texture(from:scene)!.cgImage())
        try initial.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("art/live-traffic-preview.png"))
        sim.selectedID="DEL204";sim.clearSelected(to:0)
        for _ in 0..<200 { sim.tick(0.05) };verify(4)
        sim.holdSelected()
        var prior=scene.childNode(withName:"//flight-DEL204/body")!.zRotation
        for step in 0..<150 {
            sim.tick(0.05);scene.update(5+Double(step)*0.05)
            let heading=scene.childNode(withName:"//flight-DEL204/body")!.zRotation
            precondition(abs(atan2(sin(heading-prior),cos(heading-prior)))<0.04,"Airborne sprite rotation must remain smooth")
            prior=heading
        }
        let banking=scene.childNode(withName:"//flight-DEL204/body/bank") as! SKTransformNode
        precondition(abs(banking.xRotation-sim.aircraft[0].bankAngle)<0.001 && abs(banking.xRotation)>0.1)
        precondition((scene.childNode(withName:"//flight-DEL204/body/bank/"+sim.aircraft[0].model.assetName) as! SKSpriteNode).colorBlendFactor>0.01)
        let a=sim.aircraft[0],b=sim.aircraft[1],p=DelhiLayout.extended(sim.runways[0].start,sim.runways[0].end,fraction:0.4)
        sim.aircraft=[Aircraft(id:a.id,modelID:a.modelID,departure:false,stand:0,position:p,phase:.queued,runway:0),Aircraft(id:b.id,modelID:b.modelID,departure:false,stand:1,position:p,phase:.queued,runway:0)]
        // Replace fixture nodes just as a new shift would.
        sim.revision+=1;sim.tick(0.05);verify(5)
        precondition(scene.childNode(withName:"//incidentsLayer")!.children.count==1)
        let incident=NSBitmapImageRep(cgImage:view.texture(from:scene)!.cgImage())
        try incident.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("art/incident-response-preview.png"))
        sim.reset();verify(6)
        sim.aircraft=[Aircraft(id:"SERVICE",modelID:"07",departure:false,stand:3,position:Simulation.stands[3],heading:SurfaceLayout.gates[3].heading,phase:.parked)]
        sim.revision+=1;sim.selectedID="SERVICE";sim.serviceSelected()
        var savedFuel=false
        for step in 0..<6000 {
            sim.tick(0.1)
            if step%10==0 { scene.update(10+Double(step)*0.1) }
            if !savedFuel && sim.serviceTasks.contains(where:{ $0.kind == .fuel && $0.state == .working && $0.remaining<sim.aircraft[0].refuelDuration }) {
                scene.update(10+Double(step)*0.1)
                let picture=NSBitmapImageRep(cgImage:view.texture(from:scene)!.cgImage())
                try picture.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("art/gate-service-preview.png"));savedFuel=true
            }
            if sim.aircraft[0].readyToDepart { break }
        }
        precondition(savedFuel && sim.aircraft[0].readyToDepart)
        verify(610)
        let marker=scene.childNode(withName:"//flight-SERVICE/readyMarker")!
        let before=marker.position
        sim.tick(0.1);scene.update(611)
        precondition(marker.position != before,"Ready arrow must animate")
        let ready=NSBitmapImageRep(cgImage:view.texture(from:scene)!.cgImage())
        try ready.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("art/gate-ready-preview.png"))
        sim.reset();verify(612)
        precondition(scene.childNode(withName:"//incidentsLayer")!.children.isEmpty)
        sim.reset(seed:17);sim.aircraft=[sim.aircraft[3]];sim.revision+=1;sim.selectedID=sim.aircraft[0].id
        sim.clearSelected(to:0)
        for _ in 0..<6000 { sim.tick(0.1);scene.update(sim.elapsed);if sim.aircraft[0].phase == .queued { break } }
        precondition(sim.aircraft[0].phase == .queued)
        sim.clearSelected(to:0)
        for _ in 0..<1000 { sim.tick(0.1);scene.update(sim.elapsed);if sim.aircraft[0].phase == .climbing { break } }
        precondition(sim.aircraft[0].phase == .climbing)
        for _ in 0..<80 { sim.tick(0.1);scene.update(sim.elapsed) }
        let outbound=scene.childNode(withName:"//flight-"+sim.aircraft[0].id)!
        precondition(sim.aircraft[0].phase == .climbing && !outbound.isHidden,"Departure must remain visible in climb-out")
        let climb=NSBitmapImageRep(cgImage:view.texture(from:scene)!.cgImage())
        try climb.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("art/climbout-preview.png"))
        for _ in 0..<1000 { sim.tick(0.1);scene.update(sim.elapsed);if sim.aircraft[0].phase == .complete { break } }
        precondition(sim.aircraft[0].phase == .complete && outbound.isHidden && sim.aircraft[0].position.x>AirportLayout.width+100)
        print("PASS: departure stays visible while climbing, then completes beyond map edge")
        // Review actual simulation snapshots over time, rather than testing
        // rotation easing alone. Air: broad semicircle. Ground: reverse tug arc.
        let sheet=NSImage(size:CGSize(width:1600,height:470))
        sheet.lockFocus();NSColor.black.setFill();NSBezierPath(rect:CGRect(x:0,y:0,width:1600,height:470)).fill();sheet.unlockFocus()
        for row in 0..<2 {
            sim.reset(seed:17)
            let chosen=sim.aircraft[row==0 ? 0 : 3]
            sim.aircraft=[chosen];sim.revision+=1;sim.selectedID=chosen.id
            if row==0 { sim.aircraft[0].position=SurfaceLayout.fixes[0];sim.holdSelected() }
            else { sim.clearSelected(to:0) }
            scene.update(700+Double(row)*100)
            for frame in 0..<8 {
                if frame>0 { for step in 0..<120 { sim.tick(0.05);if step%2==0 { scene.update(sim.elapsed) } } }
                scene.update(sim.elapsed)
                let cg=view.texture(from:scene)!.cgImage(),scale=Double(cg.width)/AirportLayout.width
                let area=row==0 ? CGRect(x:45,y:75,width:365,height:365) : CGRect(x:570,y:465,width:240,height:180)
                let crop=cg.cropping(to:CGRect(x:area.minX*scale,y:area.minY*scale,width:area.width*scale,height:area.height*scale))!
                let picture=NSImage(cgImage:crop,size:area.size)
                sheet.lockFocus()
                let y=row==0 ? 250.0 : 20.0
                picture.draw(in:CGRect(x:Double(frame)*200,y:y,width:198,height:198),from:.zero,operation:.sourceOver,fraction:1)
                let label="\(row==0 ? "HOLD" : "PUSHBACK") \(frame*6)s"
                (label as NSString).draw(at:CGPoint(x:Double(frame)*200+8,y:y+201),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:10,weight:.medium),.foregroundColor:NSColor.white])
                sheet.unlockFocus()
            }
        }
        let sheetBitmap=NSBitmapImageRep(data:sheet.tiffRepresentation!)!
        try sheetBitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("art/motion-review.png"))
        print("PASS: 20 aircraft + 16 service textures / 24 units, full-map arrivals, painted numbers, altitude scaling, incident effects and clean restart")
    }
}
