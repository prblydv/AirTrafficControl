import SpriteKit
import CoreImage
import ImageIO

@MainActor final class AirportScene: SKScene {
    let simulation: Simulation
    private var revision = -1
    static let maximumZoom = 3.0
    private(set) var zoomFactor = 1.0
    private let mapCamera = SKCameraNode()
    private var pinchStart: (zoom: Double, center: CGPoint, anchor: CGPoint)?
    private var dragStart: CGPoint?
    @MainActor private struct PlaneVisual {
        let root:SKNode,body:SKNode,shadow:SKNode,halo:SKNode,title:SKNode,plate:SKNode,type:SKNode,ready:SKNode
        let bank:SKTransformNode,sprite:SKSpriteNode,beacon:SKNode,nav:[SKNode],service:SKLabelNode
        init(_ root:SKNode,asset:String) {
            self.root=root;body=root.childNode(withName:"body")!;shadow=root.childNode(withName:"shadow")!
            bank=body.childNode(withName:"bank") as! SKTransformNode
            sprite=bank.childNode(withName:asset) as! SKSpriteNode
            beacon=bank.childNode(withName:"aircraftBeacon")!
            nav=[bank.childNode(withName:"nav-port")!,bank.childNode(withName:"nav-starboard")!]
            halo=root.childNode(withName:"halo")!;title=root.childNode(withName:"title")!;plate=root.childNode(withName:"plate")!
            type=root.childNode(withName:"type")!;ready=root.childNode(withName:"readyMarker")!
            service=root.childNode(withName:"serviceTimer") as! SKLabelNode
            sprite.color = .black
        }
    }
    private var planeNodes: [String: PlaneVisual] = [:]
    private var vehicleNodes: [Int: SKNode] = [:]
    private var vehicleLights:[Int:[SKNode]]=[:]
    private var incidentNodes: [UUID: SKNode] = [:]
    private var renderedHeading: [String: Double] = [:]
    private var lastSimulationTime = 0.0
    private var lastFrameTime: TimeInterval?
    private var nextRouteWarmAt = -Double.infinity
    private var draggedAircraft:String?
    private var aircraftDragStart:CGPoint?
    private var hits: [(String, CGPoint)] = []
    private let ground = SKNode(), planes = SKNode(), routes = SKNode(), incidentLayer = SKNode(), serviceLayer = SKNode()
    private let aircraftTextures: [String: SKTexture]
    private let serviceTextures: [String: SKTexture]
    private var boardHeight:Double {simulation.airport.image.height}

    init(simulation: Simulation, artworkTexture: SKTexture? = nil, aircraftTextures: [String: SKTexture] = [:], serviceTextures: [String: SKTexture] = [:]) {
        self.simulation = simulation; self.aircraftTextures = aircraftTextures; self.serviceTextures = serviceTextures
        super.init(size: CGSize(width:simulation.airport.image.width,height:simulation.airport.image.height))
        scaleMode = .aspectFit; backgroundColor = color(0x14201E)
        addChild(ground);addChild(mapCamera);camera=mapCamera;resetZoom()
        let image = SKSpriteNode(texture: artworkTexture ?? Self.backgroundTexture(simulation.airportPackage.backgroundURL))
        image.size = size; image.position = CGPoint(x: size.width/2, y: size.height/2); ground.addChild(image)
        ground.addChild(routes); ground.addChild(serviceLayer); ground.addChild(planes); ground.addChild(incidentLayer)
        planes.name = "aircraftLayer"; serviceLayer.name = "groundServicesLayer"; incidentLayer.name = "incidentsLayer"
        routes.zPosition = 10; serviceLayer.zPosition = 15; planes.zPosition = 20; incidentLayer.zPosition = 25
        paintRunwayNumbers();paintGates();resetZoom()
    }
    private static func backgroundTexture(_ url:URL)->SKTexture {
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else{preconditionFailure("Airport background is unavailable: \(url.lastPathComponent)")}
        return SKTexture(cgImage:image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func didMove(to view:SKView) {
        simulation.surface.prewarmDepartureEntries(for:simulation.aircraft)
        simulation.surface.prewarmLandingExits()
    }
    func resetDisplayClock() {lastFrameTime=nil}
    private func requestDisplay() {if let view,view.isPaused {view.isPaused=false}}
    override func didFinishUpdate() {
        // Pausing after a completed frame avoids the blank first-frame failure
        // of constructing SwiftUI's SpriteView in an already-paused state.
        if !simulation.running {view?.isPaused=true}
    }
    func resetZoom() {
        requestDisplay()
        zoomFactor=1;pinchStart=nil;dragStart=nil
        mapCamera.position=CGPoint(x:size.width/2,y:size.height/2);mapCamera.setScale(1)
    }
    private func clampCamera() {
        let x=size.width/(2*zoomFactor),y=size.height/(2*zoomFactor)
        mapCamera.position=CGPoint(x:min(size.width-x,max(x,mapCamera.position.x)),y:min(size.height-y,max(y,mapCamera.position.y)))
    }
    func pinch(magnification: Double, anchor: Point) {
        requestDisplay()
        guard magnification.isFinite,magnification>0 else { return }
        if pinchStart == nil {
            var point=CGPoint(x:anchor.x*size.width,y:(1-anchor.y)*size.height)
            if let view {
#if os(macOS)
                point=convertPoint(fromView:CGPoint(x:anchor.x*view.bounds.width,y:(1-anchor.y)*view.bounds.height))
#else
                point=convertPoint(fromView:CGPoint(x:anchor.x*view.bounds.width,y:anchor.y*view.bounds.height))
#endif
            }
            pinchStart=(zoomFactor,mapCamera.position,point);dragStart=nil
        }
        let start=pinchStart!
        zoomFactor=min(Self.maximumZoom,max(1,start.zoom*magnification))
        let ratio=start.zoom/zoomFactor
        mapCamera.setScale(1/zoomFactor)
        mapCamera.position=CGPoint(x:start.anchor.x-(start.anchor.x-start.center.x)*ratio,y:start.anchor.y-(start.anchor.y-start.center.y)*ratio)
        clampCamera()
    }
    func endPinch() { pinchStart=nil }
    func dragMap(translation: Point) {
        requestDisplay()
        guard draggedAircraft == nil else {return}
        guard zoomFactor>1,pinchStart == nil else { return }
        if dragStart == nil { dragStart=mapCamera.position }
        let fit=view.map { min($0.bounds.width/size.width,$0.bounds.height/size.height) } ?? 1
        let scale=max(0.001,fit*zoomFactor),start=dragStart!
        mapCamera.position=CGPoint(x:start.x-translation.x/scale,y:start.y+translation.y/scale)
        clampCamera()
    }
    func endDrag() { dragStart=nil }
    private func pixel(_ p: Point) -> CGPoint { CGPoint(x: p.x, y: boardHeight-p.y) }
    private func color(_ hex: UInt32, alpha: CGFloat = 1) -> SKColor {
        SKColor(red: CGFloat((hex >> 16)&255)/255, green: CGFloat((hex >> 8)&255)/255, blue: CGFloat(hex&255)/255, alpha: alpha)
    }
    private func text(_ value: String, at point: CGPoint, size: CGFloat, hex: UInt32, parent: SKNode) -> SKLabelNode {
        let label = SKLabelNode(fontNamed: "Menlo-Bold"); label.text = value; label.fontSize = size; label.fontColor = color(hex); label.position = point; parent.addChild(label); return label
    }
    private func paintRunwayNumbers() {
        for r in simulation.airport.runways {
            let a=pixel(r.start), b=pixel(r.end), length=hypot(b.x-a.x,b.y-a.y)
            let paint=SKNode(); paint.position=a; paint.zRotation=atan2(b.y-a.y,b.x-a.x); paint.zPosition=3; ground.addChild(paint)
            for (number,x,rotation) in [(r.name,22.0,-Double.pi/2),(r.reciprocalName,length-22,Double.pi/2)] {
                let label=text(number,at:CGPoint(x:x,y:0),size:number.count>2 ? 6 : 8,hex:0xD4D2C5,parent:paint)
                label.verticalAlignmentMode = .center; label.zRotation=rotation; label.alpha=0.82; label.name="runway-paint"
            }
        }
    }
    private func paintGates() {
        for gate in simulation.surface.gates {
            let path=CGMutablePath()
            path.move(to:pixel(simulation.surface.offset(gate.position,heading:gate.heading,along:-18)))
            path.addLine(to:pixel(simulation.surface.offset(gate.position,heading:gate.heading,along:14)))
            let line=SKShapeNode(path:path);line.name="gate-"+gate.name;line.strokeColor=color(0xD8C579,alpha:0.65);line.lineWidth=0.9;line.zPosition=4;ground.addChild(line)
            let stop=simulation.surface.offset(gate.position,heading:gate.heading,along:9)
            let bar=CGMutablePath();bar.move(to:pixel(simulation.surface.offset(stop,heading:gate.heading,side:-5)));bar.addLine(to:pixel(simulation.surface.offset(stop,heading:gate.heading,side:5)))
            let mark=SKShapeNode(path:bar);mark.strokeColor=line.strokeColor;mark.lineWidth=0.9;mark.zPosition=4;ground.addChild(mark)
            let label=text(gate.name,at:pixel(Point(x:gate.position.x-15,y:gate.position.y+14)),size:7,hex:0xE0CE86,parent:ground);label.zPosition=5
        }
    }
    private func makePlane(_ a: Aircraft) -> SKNode {
        let root = SKNode()
        root.name = "flight-" + a.id
        let length = CGFloat(a.model.length)
        let span = CGFloat(a.model.span)
        let body = SKNode(); body.name = "body"; root.addChild(body)
        let texture = aircraftTextures[a.model.assetName] ?? SKTexture(imageNamed: a.model.assetName)
        texture.filteringMode = .linear
        let size = texture.size()
        let fit = min(span / max(1, size.width), length / max(1, size.height))
        let imageSize = CGSize(width: size.width * fit, height: size.height * fit)
        let shadow = SKSpriteNode(texture: texture, color: .black, size: imageSize)
        shadow.colorBlendFactor = 1; shadow.alpha = 1; shadow.zRotation = -.pi / 2
        shadow.name="shadowShape"
        // A tinted copy batches with sprites instead of requiring an offscreen
        // Gaussian-blur render pass for every aircraft on every frame.
        let softShadow=SKNode();softShadow.name="shadow"
        softShadow.addChild(shadow);root.addChild(softShadow)
        let bank=SKTransformNode();bank.name="bank";bank.zPosition=1;body.addChild(bank)
        let sprite = SKSpriteNode(texture: texture)
        sprite.name = a.model.assetName
        sprite.size = imageSize; sprite.zRotation = -.pi / 2
        bank.addChild(sprite)
        // Sprite-local forward is +X. Port is +Y, starboard is -Y.
        for (name,tip,tint) in [("nav-port",AircraftCatalog.wingLights[a.modelID]!.0,UInt32(0xFF3B30)),("nav-starboard",AircraftCatalog.wingLights[a.modelID]!.1,UInt32(0x42E87B))] {
            let light=SKShapeNode(circleOfRadius:0.75);light.name=name
            light.fillColor=color(tint);light.strokeColor = .clear;light.glowWidth=0.6
            light.position=CGPoint(x:(0.5-tip.y)*Double(imageSize.height),y:(0.5-tip.x)*Double(imageSize.width));light.zPosition=3;bank.addChild(light)
        }
        let beacon=SKShapeNode(circleOfRadius:0.65);beacon.name="aircraftBeacon";beacon.fillColor=color(0xFF4433);beacon.strokeColor = .clear;beacon.glowWidth=0.5;bank.addChild(beacon)
        let halo = SKShapeNode(circleOfRadius: span / 2 + 7); halo.name = "halo"; halo.strokeColor = color(0xB8D8C7, alpha: 0.8); halo.lineWidth = 1.5; halo.fillColor = .clear; root.addChild(halo)
        let plate = SKShapeNode(rectOf: CGSize(width: max(44, CGFloat(a.type.count * 6 + 10)), height: 14), cornerRadius: 3); plate.name = "plate"; plate.fillColor = color(0x15201F, alpha: 0.84); plate.strokeColor = .clear; plate.position = CGPoint(x: 0, y: -span / 2 - 17); root.addChild(plate)
        let type = text(a.type, at: CGPoint(x: 0, y: -span / 2 - 22), size: 10, hex: 0xF5F3E9, parent: root); type.name = "type"
        let title = text(a.id, at: CGPoint(x: 0, y: span / 2 + 15), size: 10, hex: 0xF4F1DF, parent: root); title.name = "title"
        let ready=SKNode();ready.name="readyMarker";root.addChild(ready)
        _=text("↓",at:CGPoint(x:0,y:0),size:23,hex:0x93D9B3,parent:ready)
        _=text("READY",at:CGPoint(x:0,y:18),size:8,hex:0x93D9B3,parent:ready)
        let service=text("",at:.zero,size:8,hex:0xE7D09A,parent:root);service.name="serviceTimer"
        return root
    }

    override func update(_ currentTime: TimeInterval) {
        let frameDelta=lastFrameTime.map { currentTime-$0 < 0.25 ? max(0,min(currentTime-$0,1.0/15.0)) : 0 } ?? 0
        lastFrameTime=currentTime
        // One display clock: avoid an independent sleep loop drifting against
        // SpriteKit and displaying duplicate positions followed by jumps.
        simulation.tick(frameDelta)
        if revision != simulation.revision || simulation.elapsed>=nextRouteWarmAt {
            simulation.surface.prewarmDepartureEntries(for:simulation.aircraft)
            nextRouteWarmAt=simulation.elapsed+1
        }
        if revision != simulation.revision {
            planes.removeAllChildren(); planeNodes.removeAll(); serviceLayer.removeAllChildren(); vehicleNodes.removeAll();vehicleLights.removeAll()
            incidentLayer.removeAllChildren(); incidentNodes.removeAll(); renderedHeading.removeAll(); lastSimulationTime=simulation.elapsed; revision=simulation.revision;resetZoom()
        }
        let dt=max(0,min(0.2,simulation.elapsed-lastSimulationTime));lastSimulationTime=simulation.elapsed
        let visible=simulation.aircraft.filter{![.crashed,.diverted].contains($0.phase) && !($0.departure && $0.phase == .complete)}
        let live=Set(visible.map(\.id))
        for id in Array(planeNodes.keys) where !live.contains(id) {planeNodes.removeValue(forKey:id)?.root.removeFromParent();renderedHeading.removeValue(forKey:id)}
        hits.removeAll(keepingCapacity:true)
        for a in visible {
            if planeNodes[a.id] == nil { let node=makePlane(a); planes.addChild(node); planeNodes[a.id]=PlaneVisual(node,asset:a.model.assetName) }
            let visual=planeNodes[a.id]!,node=visual.root, location=pixel(simulation.displayPosition(for:a))
            node.position=location; node.isHidden=[.crashed,.diverted].contains(a.phase) || (a.departure && a.phase == .complete)
            // Explicit depth prevents creation order from putting a taxiing
            // aircraft over an arrival or departure passing above it.
            node.zPosition=a.airborne ? 10+max(0,a.altitude)/100 : ([.takeoffRoll,.landingRoll].contains(a.phase) ? 5 : 0)
            let body=visual.body
            // Simulation headings use map coordinates (positive Y is south),
            // while SpriteKit's scene has positive Y north. Convert the track
            // directly, without estimating it from a separately transformed point.
            let desired = -a.heading
            let prior=renderedHeading[a.id] ?? desired
            let delta=atan2(sin(desired-prior),cos(desired-prior))
            // Circular exponential moving average avoids jitter at short curve
            // vertices and correctly crosses the -pi/pi heading boundary.
            let heading=prior+delta*(1-exp(-dt/(a.airborne ? 0.16:0.22)))
            renderedHeading[a.id]=heading
            body.zRotation=heading; body.setScale(a.apparentScale)
            visual.bank.xRotation=a.bankAngle
            visual.sprite.colorBlendFactor=abs(a.bankAngle)*0.12
            let motion = !a.airborne && !a.stopped && !a.waitingForTraffic && a.groundSpeed>0.5 && [.taxiing,.pushback,.lineup,.takeoffRoll,.landingRoll,.runwayExit,.takeoff,.landing].contains(a.phase)
            let vibration=motion ? min(0.22,a.groundSpeed*0.012)*sin(simulation.elapsed*37+Double(a.stand)*2) : 0
            body.position=CGPoint(x:0,y:vibration)
            let shadow=visual.shadow
            do {
                let altitude=min(1,max(0,a.altitude)/6000)
                shadow.position=CGPoint(x:1+altitude*28,y:-1-altitude*19)
                shadow.zRotation=heading;shadow.setScale(0.55*(1+altitude*0.12))
                shadow.alpha=0.24-altitude*0.17
            }
            let blink=a.airborne || [.takeoffRoll,.landingRoll,.takeoff,.landing].contains(a.phase)
            let pulse=simulation.elapsed.truncatingRemainder(dividingBy:1.2)<0.25
            for light in visual.nav {let alpha:CGFloat=blink ? (pulse ? 1 : 0.12) : 1;if light.alpha != alpha {light.alpha=alpha}}
            visual.beacon.alpha = blink ? (pulse ? 1 : 0.08) : 0.2
            visual.halo.isHidden=a.id != simulation.selectedID
            visual.halo.setScale(a.apparentScale)
            visual.title.isHidden=a.id != simulation.selectedID
            visual.plate.isHidden=a.id != simulation.selectedID
            visual.type.isHidden=a.id != simulation.selectedID
            let span=CGFloat(a.model.span*a.apparentScale)
            visual.plate.position=CGPoint(x:0,y:-span/2-12)
            visual.type.position=CGPoint(x:0,y:-span/2-15)
            visual.title.position=CGPoint(x:0,y:span/2+29)
            let ready=visual.ready
            ready.isHidden = !a.readyToDepart || a.phase != .parked
            ready.position=CGPoint(x:0,y:span/2+8+sin(simulation.elapsed*2.5)*4)
            ready.alpha=0.75+0.25*sin(simulation.elapsed*2.5)
            let service=visual.service
            service.isHidden = ![.servicing,.gateWait].contains(a.phase) && a.crossingRequest == nil && !a.waitingForTraffic
            if !service.isHidden {
                let value=a.crossingRequest != nil ? "CROSSING REQUEST" : a.waitingForTraffic ? "WAITING" : simulation.gateStatus(for:a)
                if service.text != value { service.text=value }
            }
            service.position=CGPoint(x:0,y:span/2+12)
            if !node.isHidden { hits.append((a.id,location)) }
        }
        let underTow=Set(simulation.aircraft.filter(\.underTow).map(\.id))
        var attachedTugs=Set<UUID>(),incidentEffects:[UUID:Set<ServiceKind>]=[:]
        for task in simulation.serviceTasks {
            if task.kind == .pushback,task.state == .working,case .aircraft(let id)=task.target,underTow.contains(id) {attachedTugs.insert(task.id)}
            if task.effectApplied,case .incident(let id)=task.target {incidentEffects[id,default:[]].insert(task.kind)}
        }
        renderServices(attachedTugs:attachedTugs); renderIncidents(effects:incidentEffects)
    }
    private func renderServices(attachedTugs:Set<UUID>) {
        let live=Set(simulation.vehicles.map(\.id))
        for id in Array(vehicleNodes.keys) where !live.contains(id) {vehicleNodes.removeValue(forKey:id)?.removeFromParent();vehicleLights.removeValue(forKey:id)}
        for unit in simulation.vehicles {
            if vehicleNodes[unit.id] == nil {
                let texture=serviceTextures[unit.kind.assetName] ?? SKTexture(imageNamed:unit.kind.assetName)
                let node=SKSpriteNode(texture:texture), original=texture.size()
                let fit=unit.kind.length/max(1,original.height)
                node.size=CGSize(width:original.width*fit,height:original.height*fit); node.name=unit.kind.assetName
                serviceLayer.addChild(node); vehicleNodes[unit.id]=node
                let roofY=node.size.height*(0.5-unit.kind.beaconY)
                let emergency=[ServiceKind.patrol,.fire,.ambulance].contains(unit.kind)
                var lights:[SKNode]=[]
                for index in 0..<(emergency ? 2 : 1) {
                    let light=SKShapeNode(circleOfRadius:0.4)
                    light.name="beacon-\(index)";light.strokeColor = .clear
                    light.fillColor=emergency ? (index==0 ? .red : .cyan) : .yellow
                    light.position=CGPoint(x:emergency ? Double(index*2-1)*1.1 : 0,y:roofY)
                    light.glowWidth=0.45;light.zPosition=2;node.addChild(light)
                    lights.append(light)
                }
                vehicleLights[unit.id]=lights
            }
            let node=vehicleNodes[unit.id]!
            let towing=unit.kind == .pushback && unit.taskID.map{attachedTugs.contains($0)} == true
            node.zPosition=towing ? 10:0
            node.position=pixel(unit.position); node.zRotation = -unit.heading - .pi/2; node.alpha=1
            for (index,light) in (vehicleLights[unit.id] ?? []).enumerated() {
                let phase=(simulation.elapsed*2.8+Double(unit.id)*0.17+Double(index)*0.5).truncatingRemainder(dividingBy:1)
                let alpha:CGFloat=phase<0.22 ? 1 : 0.12
                if light.alpha != alpha {light.alpha=alpha}
            }
        }
    }
    private func renderIncidents(effects:[UUID:Set<ServiceKind>]) {
        for incident in simulation.incidents {
            if incidentNodes[incident.id] == nil {
                let root=SKNode(); root.name="incident-"+incident.id.uuidString; root.position=pixel(incident.position)
                let wreck=SKShapeNode(ellipseOf:CGSize(width:40,height:24)); wreck.fillColor=color(0x292923); wreck.strokeColor = .clear; root.addChild(wreck)
                for i in 0..<20 {
                    let burst=SKShapeNode(circleOfRadius:CGFloat(4+i%4)); burst.fillColor=i%2 == 0 ? .orange : .yellow; burst.strokeColor = .clear; root.addChild(burst)
                    let angle=Double(i)/20*2*Double.pi
                    burst.run(.sequence([.group([.moveBy(x:cos(angle)*70,y:sin(angle)*70,duration:0.9),.fadeOut(withDuration:1),.scale(to:0.1,duration:1)]),.removeFromParent()]))
                }
                let fire=SKNode(); fire.name="fire"
                for i in 0..<5 {
                    let flame=SKShapeNode(circleOfRadius:CGFloat(6+i%3)); flame.fillColor=color(i%2 == 0 ? 0xEF782D : 0xF7C560,alpha:0.8); flame.strokeColor = .clear
                    flame.position=CGPoint(x:Double(i-2)*7,y:Double(i%2)*5); fire.addChild(flame)
                    flame.run(.repeatForever(.sequence([.scale(to:1.4,duration:0.3),.scale(to:0.7,duration:0.4)])))
                }
                root.addChild(fire); incidentLayer.addChild(root); incidentNodes[incident.id]=root
            }
            let completed=effects[incident.id] ?? []
            let suppressed=completed.contains(.fire)
            if let fire=incidentNodes[incident.id]?.childNode(withName:"fire") {
                fire.isHidden=suppressed
                if suppressed && !fire.isPaused {fire.isPaused=true;for flame in fire.children {flame.removeAllActions()}}
            }
            incidentNodes[incident.id]?.alpha=[ServiceKind.patrol,.fire,.ambulance,.sweeper].allSatisfy{completed.contains($0)} ? 0.2 : 1
        }
    }
    private func select(at p: CGPoint) {
        requestDisplay()
        if let hit=hits.min(by:{hypot($0.1.x-p.x,$0.1.y-p.y)<hypot($1.1.x-p.x,$1.1.y-p.y)}),hypot(hit.1.x-p.x,hit.1.y-p.y)<max(14,50/zoomFactor) { simulation.selectedID=hit.0 }
    }
    private func beginAircraftDrag(at point:CGPoint) {
        select(at:point)
        guard let selected=simulation.selected,selected.airborne,!selected.departure,
              let hit=hits.first(where:{$0.0==selected.id}),
              hypot(hit.1.x-point.x,hit.1.y-point.y)<max(14,50/zoomFactor) else{return}
        draggedAircraft=selected.id;aircraftDragStart=point
    }
    private func finishAircraftDrag(at point:CGPoint) {
        defer {draggedAircraft=nil;aircraftDragStart=nil}
        guard let id=draggedAircraft,let start=aircraftDragStart,hypot(point.x-start.x,point.y-start.y)>12,
              let flight=simulation.aircraft.first(where:{$0.id==id}),flight.airborne else{return}
        let destination=Point(x:point.x,y:boardHeight-point.y)
        guard let runway=simulation.clearanceRunways(for:flight).min(by:{
            $0.start.distance(to:destination)<$1.start.distance(to:destination)
        }) else{return}
        simulation.selectedID=id;simulation.clearSelected(to:runway.id)
    }
#if os(macOS)
    override func mouseDown(with event: NSEvent) { beginAircraftDrag(at:event.location(in:self)) }
    override func mouseUp(with event: NSEvent) { finishAircraftDrag(at:event.location(in:self)) }
#else
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { if let t=touches.first { beginAircraftDrag(at:t.location(in:self)) } }
    override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent?) {if let t=touches.first {finishAircraftDrag(at:t.location(in:self))}}
    override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent?) {draggedAircraft=nil;aircraftDragStart=nil}
#endif
}
