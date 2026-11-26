import SwiftUI
import SpriteKit

/// Keep the native display loop independent of SwiftUI's dashboard updates.
/// Always draw one initial frame, then pause only after SpriteKit presents it.
@MainActor struct GameSceneView {
    let scene:AirportScene
    let isRunning:Bool
    let presentationRevision:Int
    let selectedID:String?
    private func configure(_ view:SKView) {
        view.preferredFramesPerSecond=60
        if view.scene !== scene {scene.resetDisplayClock();view.presentScene(scene)}
        if view.isPaused {view.isPaused=false}
    }
}
#if os(macOS)
@MainActor final class GameSKView:SKView {
    private var gestureMagnification=1.0
    override func magnify(with event:NSEvent) {
        applyMagnification(Double(event.magnification),phase:event.phase,location:convert(event.locationInWindow,from:nil))
    }
    func applyMagnification(_ delta:Double,phase:NSEvent.Phase,location:CGPoint) {
        guard let scene=scene as? AirportScene,bounds.width>0,bounds.height>0 else{return}
        if phase.contains(.began) {gestureMagnification=1;scene.endPinch()}
        gestureMagnification=max(0.01,gestureMagnification+delta)
        let y=Double(location.y/bounds.height)
        scene.pinch(magnification:gestureMagnification,anchor:Point(x:Double(location.x/bounds.width),y:isFlipped ? y:1-y))
        if phase.contains(.ended) || phase.contains(.cancelled) {scene.endPinch();gestureMagnification=1}
    }
}
extension GameSceneView:NSViewRepresentable {
    func makeNSView(context:Context)->SKView {let view=GameSKView();configure(view);return view}
    func updateNSView(_ view:SKView,context:Context) {configure(view)}
    static func dismantleNSView(_ view:SKView,coordinator:()) {view.isPaused=true;view.presentScene(nil)}
}
#else
extension GameSceneView:UIViewRepresentable {
    func makeUIView(context:Context)->SKView {let view=SKView();configure(view);return view}
    func updateUIView(_ view:SKView,context:Context) {configure(view)}
    static func dismantleUIView(_ view:SKView,coordinator:()) {view.isPaused=true;view.presentScene(nil)}
}
#endif

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var simulation: Simulation
    @State private var scene: AirportScene
    @State private var showRestart = false
#if os(macOS) && DEBUG
    @State private var showRouteEditor = false
#endif
    private let mint=Color(red:0.62,green:0.77,blue:0.69)
    private let panel=Color(red:0.075,green:0.12,blue:0.14)
    init() {
        let sim=Simulation(plansGroundTrafficInBackground:true)
        sim.followsAssignedGroundRoutes=true
#if os(macOS) && DEBUG
        let edit=ProcessInfo.processInfo.arguments.contains("--route-editor")
        if edit { sim.showBriefing=false }
        _showRouteEditor=State(initialValue:edit)
#endif
        _simulation=State(initialValue:sim); _scene=State(initialValue:AirportScene(simulation:sim))
    }
    var body: some View {
        let _=simulation.presentationRevision
        GeometryReader { geometry in
            VStack(spacing:0) {
                header
                if geometry.size.width>900 {
                    HStack(alignment:.top,spacing:0) {
                        airport
                        ScrollView { desk.padding(14) }.frame(width:330)
                    }
                } else {
                    VStack(spacing:0) {
                        airport.frame(height:min(geometry.size.height*0.62,geometry.size.width*simulation.airport.image.height/simulation.airport.image.width))
                        ScrollView { desk.padding(12) }
                    }
                }
            }.background(Color(red:0.045,green:0.075,blue:0.09))
        }
        .preferredColorScheme(.dark)
#if os(macOS) && DEBUG
        .sheet(isPresented:$showRouteEditor) { RouteEditorView(backgroundImage:Image(nsImage:NSImage(contentsOf:simulation.airportPackage.backgroundURL)!),document:RoutingOverrides.load("draft-routes.json",airportID:simulation.airport.identity.id) ?? simulation.surface.routes,surface:simulation.surface,onApply:{ simulation.reset();simulation.startLive() }) }
#endif
        .sheet(isPresented:$simulation.showBriefing) { briefing }
        .onChange(of:simulation.showBriefing) { _,shown in if shown { simulation.running=false } else { simulation.startLive() } }
        .onChange(of:scenePhase) { _,phase in if phase != .active { simulation.running=false } }
        .confirmationDialog("Restart with a new fleet?",isPresented:$showRestart) {
            Button("Restart shift",role:.destructive) { simulation.reset(); simulation.startLive() }
        }
    }
    private var header: some View {
        HStack(spacing:14) {
            VStack(alignment:.leading,spacing:3) {
                Text(simulation.airport.identity.title).font(.system(size:20,weight:.heavy,design:.monospaced)).tracking(2)
                Text(simulation.airport.identity.subtitle).font(.system(size:9,weight:.semibold,design:.monospaced)).foregroundStyle(mint)
            }
            Spacer(minLength:0)
            Text(simulation.clock).font(.system(size:24,weight:.light,design:.monospaced))
            Button { simulation.toggleRunning() } label: { Image(systemName:simulation.running ? "pause.fill" : "play.fill") }.buttonStyle(.plain).accessibilityLabel(simulation.running ? "Pause simulation" : "Resume simulation")
#if os(macOS) && DEBUG
            Button("Dev routes") { simulation.running=false;showRouteEditor=true }.buttonStyle(.bordered).accessibilityLabel("Open development route editor")
#endif
            Button { simulation.showBriefing=true } label: { Image(systemName:"questionmark.circle") }.buttonStyle(.plain).accessibilityLabel("Instructions")
            Button { showRestart=true } label: { Image(systemName:"arrow.counterclockwise") }.buttonStyle(.plain).accessibilityLabel("New shift")
        }.padding(16).background(panel)
    }
    private var airport: some View {
        ZStack(alignment:.bottomLeading) {
            GameSceneView(scene:scene,isRunning:simulation.running,presentationRevision:simulation.presentationRevision,selectedID:simulation.selectedID)
                .frame(maxWidth:.infinity,maxHeight:.infinity)
#if !os(macOS)
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    scene.pinch(magnification:Double(value.magnification),anchor:Point(x:value.startAnchor.x,y:value.startAnchor.y))
                }.onEnded { _ in scene.endPinch() })
#endif
                .simultaneousGesture(DragGesture(minimumDistance:8).onChanged { value in
                    scene.dragMap(translation:Point(x:value.translation.width,y:value.translation.height))
                }.onEnded { _ in scene.endDrag() })
            Text("\(simulation.running ? "LIVE" : simulation.finished ? "SHIFT COMPLETE" : "PAUSED") · \(simulation.resolved) HANDLED · SCORE \(simulation.score) · \(simulation.incidents.count) INCIDENTS")
                .font(.system(size:9,weight:.medium,design:.monospaced)).padding(8).background(panel.opacity(0.85),in:RoundedRectangle(cornerRadius:5)).padding(10)
        }.overlay(alignment:.topTrailing) {
            Button { scene.resetZoom() } label: { Image(systemName:"arrow.up.left.and.arrow.down.right").padding(9) }
                .buttonStyle(.plain).background(panel.opacity(0.8),in:RoundedRectangle(cornerRadius:6)).padding(10).accessibilityLabel("Fit airport")
        }.clipped().background(panel)
    }
    private var desk: some View { VStack(spacing:12) { controls; runways; flights; services; radio } }
    private var controls: some View {
        VStack(alignment:.leading,spacing:11) {
            section("CLEARANCES")
            if let a=simulation.selected {
                HStack {
                    Image(a.model.assetName).resizable().scaledToFit().frame(width:95,height:85)
                    VStack(alignment:.leading,spacing:5) {
                        Text(a.id).font(.system(size:20,weight:.bold,design:.monospaced))
                        Text(a.model.displayName).font(.caption)
                        Text(a.stopped ? "Holding position" : a.phase.rawValue).font(.caption).foregroundStyle(mint)
                    }
                }
                Text("\(a.origin) → \(a.destination)").font(.caption).foregroundStyle(.secondary)
                if let r=a.runway { Text("Assigned runway · \(simulation.runways[r].name)").font(.caption).foregroundStyle(mint) }
                if let r=a.crossingRequest {
                    Button("Approve crossing · \(simulation.runways[r].name)") {simulation.approveCrossing()}.buttonStyle(.borderedProminent).tint(.orange)
                    Text("Holding short. Check landing and departing traffic before approving.").font(.caption2)
                }
                if a.airborne {
                    Text(String(format:"%.1f NM · %.0f ft",simulation.rangeNM(for:a),a.altitude))
                        .font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary)
                }
                if let waiting=a.groundWaitingState {
                    let queue=a.departureQueuePosition.map{" · Queue \($0)"} ?? ""
                    Text(waiting.rawValue+queue).font(.caption).foregroundStyle(.orange)
                    if a.waitingForTraffic,let blocker=a.blockedBy {Text("Traffic ahead · \(blocker)").font(.caption2).foregroundStyle(.orange)}
                }
                if a.readyToDepart { Text("↑ READY FOR PUSHBACK · \(simulation.surface.gates[a.stand].name)").font(.caption).foregroundStyle(mint) }
                if [.parked,.servicing,.gateWait].contains(a.phase) || a.towRelocationStand != nil {
                    let stands=simulation.standRelocationOptions(for:a)
                    ForEach(stands,id:\.self) { stand in
                        Button("Tug relocate → \(simulation.surface.gates[stand].name)") {simulation.relocateSelectedByTug(to:stand)}.buttonStyle(.bordered).tint(.orange)
                    }
                    if stands.isEmpty {Text("No compatible free stand for tug relocation.").font(.caption2).foregroundStyle(.secondary)}
                }
                if a.recoveringGround {
                    Text(a.underTow ? (a.waitingForTraffic ? "TUG ATTACHED · Blocked by \(a.blockedBy ?? "traffic")" : "TUG TOWING · Moving to passing area") : "TUG REQUESTED · Awaiting ground crew").font(.caption).foregroundStyle(.orange)
                }
                if let other=simulation.groundHeadOnTraffic(for:a) {
                    Text("GROUND CONFLICT · \(other.id)").font(.caption).foregroundStyle(.orange)
                    Text("Choose a passing area for this aircraft. A tug moves it aside, then it resumes its destination.").font(.caption2)
                    let options=simulation.tugRerouteOptions(for:a)
                    ForEach(options) { option in
                        Button("Send tug · Passing area \(option.id+1)") {simulation.dispatchSelectedTug(to:option.target)}.buttonStyle(.bordered).tint(.orange)
                    }
                    if options.isEmpty {Text("No clear passing area for this aircraft. Select the opposing aircraft to see its options.").font(.caption2).foregroundStyle(.orange)}
                }
                let canClear=a.phase == .parked || a.phase == .queued || (!a.departure && [.inbound,.holding,.approach].contains(a.phase))
                ForEach(simulation.clearanceRunways(for:a)) { r in
                    Button { simulation.clearSelected(to:r.id) } label: {
                        HStack {
                            Text(a.phase == .parked ? "\(!simulation.surface.gates[a.stand].tugRequired ? "Taxi" : "Pushback + taxi") → \(r.name)" : a.departure ? (a.runway == r.id ? "Line up + takeoff · \(r.name)" : "Reroute → \(r.name)") : "Land · \(r.name)")
                            Spacer(); if r.closed { Image(systemName:"xmark.octagon") }
                        }.frame(minHeight:28)
                    }.buttonStyle(.bordered).tint(mint).disabled(!canClear || simulation.finished)
                }
                HStack {
                    if a.airborne {
                        Button("Hold / go around") { simulation.holdSelected() }.disabled(![.inbound,.holding,.approach].contains(a.phase))
                    } else {
                        Button(a.stopped ? "Continue taxi" : "Hold position") { simulation.toggleSelectedGroundHold() }.disabled(![.taxiing,.pushback].contains(a.phase))
                    }
                }.buttonStyle(.bordered).font(.caption)
                if a.phase == .servicing || a.phase == .gateWait {
                    let progress=simulation.serviceProgress(for:a)
                    ProgressView(value:Double(progress.done),total:Double(progress.total)).tint(mint)
                    Text(simulation.gateStatus(for:a)).font(.caption).foregroundStyle(mint)
                    Text("Turnaround \(progress.done)/\(progress.total) · Fuel \(Int(a.fuelFraction*100))%")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(simulation.notice).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(15).background(panel,in:RoundedRectangle(cornerRadius:10))
    }
    private var runways: some View {
        VStack(alignment:.leading,spacing:8) {
            section("RUNWAY STATUS")
            ForEach(simulation.runways) { r in
                HStack {
                    Text(r.name).font(.system(size:11,weight:.bold,design:.monospaced))
                    Spacer()
                    Text(r.closed ? "Closed" : "Open").font(.caption).foregroundStyle(r.closed ? Color.orange : mint)
                    if r.closed {
                        Button("Reopen") { simulation.reopenRunway(r.id) }.font(.caption).buttonStyle(.bordered)
                    }
                }.padding(.vertical,3)
            }
            Text("Clearances do not block other aircraft. Maintain separation yourself.").font(.caption2).foregroundStyle(.secondary)
        }.padding(15).background(panel,in:RoundedRectangle(cornerRadius:10))
    }
    private var flights: some View {
        VStack(alignment:.leading,spacing:7) {
            section("FLIGHT STRIPS")
            ForEach(simulation.aircraft) { a in
                Button { simulation.selectedID=a.id } label: {
                    HStack {
                        Image(a.model.assetName).resizable().scaledToFit().frame(width:25,height:30)
                        VStack(alignment:.leading,spacing:3) {
                            Text(a.id).font(.system(size:12,weight:.bold,design:.monospaced))
                            let queue=a.departureQueuePosition.map{" · Q\($0)"} ?? ""
                            Text(a.type+" · "+(a.crossingRequest != nil ? "Crossing requested" : a.groundWaitingState?.rawValue ?? a.phase.rawValue)+queue).font(.system(size:10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName:a.phase == .crashed ? "flame.fill" : a.departure ? "arrow.up.right" : "arrow.down.right").foregroundStyle(a.phase == .crashed ? Color.orange : mint)
                    }.padding(8).background(a.id == simulation.selectedID ? mint.opacity(0.10) : .white.opacity(0.025),in:RoundedRectangle(cornerRadius:5))
                }.buttonStyle(.plain)
            }
        }.padding(15).background(panel,in:RoundedRectangle(cornerRadius:10))
    }
    private var services: some View {
        VStack(alignment:.leading,spacing:7) {
            section("GROUND OPERATIONS · \(simulation.busyVehicleCount) ACTIVE")
            if simulation.busyVehicleCount==0 {Text("Ground crews ready").font(.caption).foregroundStyle(.secondary)}
            ForEach(simulation.vehicles.filter { $0.taskID != nil }) { vehicle in
                let task=simulation.serviceTasks.first { $0.id == vehicle.taskID }
                HStack(spacing:9) {
                    Image(vehicle.kind.assetName).resizable().scaledToFit().frame(width:20,height:25)
                    Text(vehicle.kind.name).font(.system(size:10))
                    Spacer()
                    Text(vehicle.routeUnavailable ? "Waiting for access" : vehicle.waitingForAircraft ? "Waiting for aircraft" : task?.state.rawValue ?? "Parked").font(.system(size:9)).foregroundStyle(task == nil ? .secondary : mint)
                }
            }
        }.padding(15).background(panel,in:RoundedRectangle(cornerRadius:10))
    }
    private var radio: some View {
        VStack(alignment:.leading,spacing:8) {
            section("TOWER LOG")
            ForEach(simulation.messages.prefix(6)) { m in
                Text(String(format:"%02d:%02d ",Int(m.time)/60,Int(m.time)%60)+m.text).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
            }
        }.padding(15).background(panel,in:RoundedRectangle(cornerRadius:10))
    }
    private func section(_ title:String) -> some View { Text(title).font(.system(size:9,weight:.bold,design:.monospaced)).tracking(1).foregroundStyle(mint) }
    private var briefing: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                Text("LIVE TOWER").font(.system(size:30,weight:.heavy,design:.monospaced)).foregroundStyle(mint)
                Text("Your instructions take effect immediately.").font(.title3)
                Text("Select an aircraft on the airport or a flight strip. Continuous arrivals follow assigned runway approaches automatically and build up over time. Hold or reroute them to manage spacing. They shrink as they descend.\n\nGive landing, pushback, taxi and takeoff clearances directly, including on occupied runways. Multiple aircraft can receive the same runway clearance. You must keep them separated; use hold, go-around and hold-position commands.\n\nEach aircraft lost in a runway accident costs 500 points; each flight handled earns 100. Taxiway traffic waits or reroutes safely. Accidents happen when landing or takeoff traffic meets another aircraft occupying that runway. Aircraft that collide explode. Affected runways close, and patrol, fire, ambulance and cleanup crews respond. You can reopen the runway after they finish.\n\nA tug performs departure pushback. Follow-me vehicles escort landed aircraft to the apron. Ground crews automatically perform the services required by each flight and return to their own local bases. Watch their work in Ground Operations.\n\nYou can pause from the top bar. Taxiway aircraft wait and reroute for traffic. Your landing, takeoff and approved crossing instructions still proceed on occupied runways. Runway crossings require your approval. Aircraft and stand restrictions determine which runways are available. Wing lights and altitude-dependent shadows remain visible. There are no scripted engine failures in this version.")
                    .font(.system(size:14)).lineSpacing(3)
                Button("Take control →") { simulation.showBriefing=false }.buttonStyle(.borderedProminent).tint(mint).foregroundStyle(.black).controlSize(.large)
            }.padding(28)
        }.frame(idealWidth:560,idealHeight:680).background(panel)
    }
}
