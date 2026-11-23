import Foundation
import Observation

struct Point: Equatable, Codable {
    var x: Double
    var y: Double
    func distance(to other: Point) -> Double { hypot(x - other.x, y - other.y) }
    static func interpolate(_ a:Point,_ b:Point,fraction:Double)->Point {Point(x:a.x+(b.x-a.x)*fraction,y:a.y+(b.y-a.y)*fraction)}
}

enum FlightPhase: String {
    case inbound = "Inbound", holding = "Holding", approach = "Descending"
    case parked = "At stand", pushback = "Pushback", taxiing = "Taxiing", queued = "Holding short"
    case lineup = "Lining up", takeoffRoll = "Takeoff roll", climbing = "Climbing out"
    case landingRoll = "Landing roll", runwayExit = "Exiting runway", awaitingEscort = "Awaiting follow-me"
    // Legacy construction compatibility for older developer checks. Live
    // clearances use the explicit phases above.
    case takeoff = "Taking off", landing = "Landing"
    case servicing = "Ground services", gateWait = "Gate wait", complete = "Complete", diverted = "Diverted", crashed = "Crashed"
}
struct Aircraft: Identifiable {
    let id: String
    let modelID: String
    var purpose:AirportPurpose? = nil
    var operatingPurpose:AirportPurpose {purpose ?? model.defaultPurpose}
    var model: AircraftModel { AircraftCatalog.model(modelID) }
    var type: String { model.shortName }
    var departure: Bool
    var stand: Int
    var position: Point
    var heading = 0.0
    var bankAngle = 0.0
    var origin = ""
    var destination = ""
    var automaticArrival=false
    var retryArrivalAt=0.0
    var retiredAt:Double?
    var recoveringGround=false
    var blockedBy:String?
    var blockedSince:Double?
    var nextTaxiPlan=0.0
    var nextYieldAttempt=0.0
    var yieldCandidateCursor=0
    var yieldTo:String?
    var yieldPassPoint:Point?
    var yieldPassHeading=0.0
    var waitingForTraffic=false
    var crossingRequest:Int?
    var crossingClearances:Set<Int> = []
    var crossingsEntered:Set<Int> = []
    var departureEntry:Point?

    var phase: FlightPhase
    var route: [Point] = []
    var runway: Int?
    var emergency = false
    var fuel = 300.0
    var preferredRunway = 0
    var holdingCenter: Point?
    var holdingAltitude = 0.0
    var altitude = 0.0
    var descentStartAltitude = 0.0
    var descentStartDistance = 1.0
    var descentRemainingDistance = 1.0
    var stopped = false
    var underTow = false
    var pendingTaxiRoute: [Point] = []
    var fuelFraction = 0.45
    var passengersHandled = false
    var baggageHandled = false
    var cateringReady = false
    var waterReady = false
    var sanitationReady = false
    var powerConnected = false
    var readyToDepart = false
    var arrivalHandled = false
    var gateWaitRemaining = 0.0
    var passengerUnloadDuration = 16.0
    var passengerLoadDuration = 22.0
    var passengerUnloadRemaining = 16.0
    var passengerLoadRemaining = 22.0
    var refuelDuration = 30.0
    var groundSpeed = 0.0
    var landingRollDistance = 0.0
    var landingRollTotalDistance = 1.0
    var lineupRemaining = 0.0
    var groundPause = 0.0
    var airborne: Bool { altitude > 1 || [.inbound, .holding, .approach].contains(phase) }
    var apparentScale: Double { 0.55 + min(1, max(0, altitude) / 3500) * 0.55 }
}
struct Runway: Identifiable {
    let id: Int
    let name: String
    let start: Point
    let end: Point
    var closed = false
}
struct Message: Identifiable {
    let id = UUID()
    let time: Double
    let text: String
}

@MainActor @Observable
final class Simulation {
    static let sharedAirborneAltitude=4500.0
    var aircraft: [Aircraft] = []
    var runways: [Runway] = []
    var vehicles: [GroundVehicle] = []
    var serviceTasks: [ServiceTask] = []
    var incidents: [AirportIncident] = []
    var selectedID: String? = nil
    var elapsed = 0.0
    var running = false
    var resolved = 0
    var violations = 0
    var messages: [Message] = []
    var notice = "Give a clearance to start live traffic. You control separation."
    var finished = false
    var showBriefing = true
    var revision = 0
    // Main-actor commits are atomic: each candidate is validated against the
    // same immutable snapshot used for search, then becomes visible to the next.
    var groundTrafficSearches=0
    var groundTrafficCancellations=0
    var groundTrafficPlans:[String:GroundTrafficPlan]=[:]
    private var groundTrafficEscapes=Set<String>()
    private var groundTrafficRoutes:[String:[Point]]=[:]
    private var groundTrafficHolds:[String:(Point,Double,Bool)]=[:]
    private var groundTrafficRetry:[String:Double]=[:]
    private var groundTrafficRevision = -1
    private var random: ShiftRandom
    let continuousTraffic:Bool
    var nextArrivalAt=45.0
    var trafficSequence=1000
    static var stands:[Point] { SurfaceLayout.gates.map(\.position) }
    let airportPackage:AirportPackage
    var airport:AirportDefinition {airportPackage.definition}
    private(set) var surface:AirportSurface
    private(set) var roads:AirportServiceRoads
    private let usesDeveloperOverrides:Bool
    private var appliedDeveloperRevision:Int
    var routeDocument:AirportRouteDocument {surface.routes}
    var selected: Aircraft? { aircraft.first { $0.id == selectedID } }
    var clock: String { String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60) }
    var score: Int { resolved * 100 - violations * 500 }
    var activeCount: Int { aircraft.filter { ![.complete, .diverted, .crashed].contains($0.phase) }.count }

    init(seed: UInt64? = nil,continuousTraffic:Bool=true,airportPackage:AirportPackage?=nil,routes:AirportRouteDocument?=nil) {
        let package=airportPackage ?? .defaultAirport
        self.airportPackage=package
        usesDeveloperOverrides=airportPackage == nil && routes == nil
        appliedDeveloperRevision=RoutingOverrides.revision
        let override=usesDeveloperOverrides ? RoutingOverrides.current.flatMap{package.acceptsOverride($0) ? $0:nil}:nil
        let surface=AirportSurface(package:package,routes:routes ?? override)
        self.surface=surface;roads=AirportServiceRoads(surface:surface)
        self.continuousTraffic=continuousTraffic
        random = ShiftRandom(seed: seed ?? UInt64.random(in: .min ... .max))
        reset()
    }
    func reset(seed: UInt64? = nil) {
        if usesDeveloperOverrides && appliedDeveloperRevision != RoutingOverrides.revision {
            let override=RoutingOverrides.current.flatMap{airportPackage.acceptsOverride($0) ? $0:nil}
            surface=AirportSurface(package:airportPackage,routes:override);roads=AirportServiceRoads(surface:surface)
            appliedDeveloperRevision=RoutingOverrides.revision
        }
        revision += 1
        invalidateGroundTraffic()
        groundTrafficSearches=0;groundTrafficCancellations=0;groundTrafficEscapes=[]
        nextArrivalAt=airport.traffic.firstArrivalSeconds;trafficSequence=airport.traffic.sequenceStart
        if let seed { random = ShiftRandom(seed: seed) }
        runways=airport.runways.map{let end=$0.activeEnd;return Runway(id:$0.id,name:end.name,start:end.threshold,end:end.oppositeThreshold)}
        var used=Set<Int>();aircraft=[]
        for specification in airport.traffic.initial {
            let pool=specification.modelIDs.map(AircraftCatalog.model)
            let preferred=surface.gates.indices.filter{specification.standIDs.contains(surface.gates[$0].id)}
            let available=pool.filter{model in preferred.contains{!used.contains($0) && surface.gates[$0].accepts(model,purpose:specification.purpose)}}
            guard let model=available.randomElement(using:&random),let stand=preferred.filter({!used.contains($0) && surface.gates[$0].accepts(model,purpose:specification.purpose)}).min(by:{surface.gates[$0].maxSpan<surface.gates[$1].maxSpan}) else{continue}
            used.insert(stand)
            let gate=surface.gates[stand],peer=airport.traffic.peers[Int.random(in:0..<airport.traffic.peers.count,using:&random)]
            guard let runway=runways.indices.filter({surface.eligible(model,runway:$0)}).randomElement(using:&random) else{continue}
            let approach=airport.approaches.first{$0.id==specification.approachID}
            var flight=Aircraft(id:specification.id,modelID:model.id,departure:!specification.arrival,stand:stand,position:approach?.start ?? gate.position,heading:specification.arrival ? 0:gate.heading,origin:specification.arrival ? peer:airport.identity.flightLabel,destination:specification.arrival ? airport.identity.flightLabel:peer,phase:specification.arrival ? .inbound:.parked,runway:runway,preferredRunway:runway,readyToDepart:!specification.arrival)
            flight.purpose=specification.purpose
            aircraft.append(flight)
        }
        for i in aircraft.indices {
            if aircraft[i].departure {
                aircraft[i].fuelFraction=1;aircraft[i].passengersHandled=true;aircraft[i].baggageHandled=true
                aircraft[i].cateringReady=true;aircraft[i].waterReady=true;aircraft[i].sanitationReady=true
            }
            aircraft[i].passengerUnloadDuration = Double(Int.random(in:14...24,using:&random))
            aircraft[i].passengerLoadDuration = Double(Int.random(in:20...32,using:&random))
            aircraft[i].passengerUnloadRemaining = aircraft[i].passengerUnloadDuration
            aircraft[i].passengerLoadRemaining = aircraft[i].passengerLoadDuration
            aircraft[i].refuelDuration = Double(Int.random(in:25...40,using:&random))
            aircraft[i].gateWaitRemaining = Double(Int.random(in:12...30,using:&random))
        }
        for i in aircraft.indices where !aircraft[i].departure {
            if let spec=airport.traffic.initial.first(where:{$0.id==aircraft[i].id}),let approach=airport.approaches.first(where:{$0.id==spec.approachID}) {
                aircraft[i].altitude=approach.altitude;aircraft[i].route=[approach.fix]
                aircraft[i].heading=atan2(approach.fix.y-aircraft[i].position.y,approach.fix.x-aircraft[i].position.x)
            }
        }
        elapsed = 0; running = false; resolved = 0; violations = 0; finished = false
        selectedID = aircraft.first?.id; messages = []
        notice = "Live clearances. You are responsible for aircraft separation."
        resetGroundServices()
        if continuousTraffic {for i in aircraft.indices where !aircraft[i].departure {aircraft[i].automaticArrival=true;assignApproach(i)}}
        log("Tower online. No automatic runway reservations. Instructions act immediately.")
    }
    func assignDepartureAirports(_ index:Int) {
        aircraft[index].origin=airport.identity.flightLabel
        aircraft[index].destination=airport.traffic.peers.randomElement(using:&random)!
    }
    func randomGateDwell() -> Double { Double(Int.random(in:12...30,using:&random)) }
    func log(_ text: String) {
        messages.insert(Message(time: elapsed, text: text), at: 0)
        if messages.count > 40 { messages.removeLast() }
    }
    func reject(_ text: String) { notice = text; log(text) }
    func startLive() { if !finished { running = true } }
    func toggleRunning() { if !finished { running.toggle() } }
    func toggleSelectedGroundHold() {
        guard let i = aircraft.firstIndex(where: { $0.id == selectedID }), [.taxiing, .pushback].contains(aircraft[i].phase) else { return }
        aircraft[i].stopped.toggle()
        aircraft[i].groundSpeed=0
        log("\(aircraft[i].id): \(aircraft[i].stopped ? "hold position" : "continue").")
        startLive()
    }
    func clearSelected(to runwayID: Int) {
        guard !finished, let i = aircraft.firstIndex(where: { $0.id == selectedID }), runways.indices.contains(runwayID) else { return }
        guard clearanceRunways(for:aircraft[i]).contains(where:{$0.id==runwayID}) else { reject("Runway too short for \(aircraft[i].type). Use a longer runway.");return }
        let phase = aircraft[i].phase
        if aircraft[i].departure && phase == .parked {
            let gate=surface.gates[aircraft[i].stand]
            let entry=surface.departureEntry(for:aircraft[i].model,runway:runwayID,from:gate.port)
            var probe=aircraft[i];probe.position=gate.port
            let taxi=plannedTaxiRoute(for:probe,to:entry.hold)
            guard !taxi.isEmpty else { reject("Taxi route is currently unavailable. Try another runway or wait for traffic.");return }
            let target=taxi.first ?? surface.hold(runwayID)
            let taxiHeading=atan2(target.y-gate.port.y,target.x-gate.port.x)
            aircraft[i].departureEntry=entry.lineup
            aircraft[i].runway=runwayID;aircraft[i].phase = .pushback;aircraft[i].stopped=false
            aircraft[i].readyToDepart=false;aircraft[i].groundSpeed=0
            // The tug reverses the aircraft on a curved path. Nose direction is
            // opposite the movement until release; no click changes position.
            aircraft[i].route=surface.pushback(from:aircraft[i].position,noseHeading:aircraft[i].heading,to:gate.port,taxiHeading:taxiHeading,minimumWidth:aircraft[i].model.span*0.55)
            guard !aircraft[i].route.isEmpty else { aircraft[i].phase = .parked;aircraft[i].readyToDepart=true;reject("Pushback is currently unavailable.");return }
            aircraft[i].pendingTaxiRoute=taxi
            if !gate.tugRequired {
                aircraft[i].phase = .taxiing;aircraft[i].route=surface.rounded(gate.access,radius:3)+taxi;aircraft[i].pendingTaxiRoute=[]
            } else { enqueue(.pushback,target:.aircraft(aircraft[i].id)) }
            notice = !gate.tugRequired ? "Taxi clearance sent." : "Pushback tug dispatched; taxi follows automatically after pushback."
        } else if aircraft[i].departure && phase == .queued {
            if aircraft[i].runway != runwayID { rerouteSelected(to: runwayID); return }
            aircraft[i].phase = .lineup; aircraft[i].stopped = false
            aircraft[i].groundSpeed=0
            let lineup=aircraft[i].departureEntry ?? surface.runwayPoint(runwayID,0.06)
            let traced=surface.network.shortestPath(from:aircraft[i].position,to:lineup,maximumAccessDistance:2,minimumWidth:aircraft[i].model.span*0.55)
            let entry=surface.rounded([aircraft[i].position]+traced+[lineup],radius:3)
            guard !entry.isEmpty else { aircraft[i].phase = .queued;reject("Runway entry is currently unavailable.");return }
            aircraft[i].lineupRemaining=FlightCurves.length(from:aircraft[i].position,route:entry)
            aircraft[i].route=entry
            notice = "Line-up clearance sent; takeoff roll follows when aligned. Check the runway yourself."
        } else if !aircraft[i].departure && [.inbound, .holding, .approach].contains(phase) {
            aircraft[i].runway = runwayID; aircraft[i].phase = .approach
            aircraft[i].automaticArrival=false
            assignApproach(i)
            notice = "Landing clearance sent. Watch spacing and crossing traffic."
        } else { reject("\(aircraft[i].id) is \(phase.rawValue.lowercased())."); return }
        log("\(aircraft[i].id): \(aircraft[i].phase.rawValue), \(runways[runwayID].name).")
        startLive()
    }
    func holdSelected() {
        guard let i = aircraft.firstIndex(where: { $0.id == selectedID }), [.inbound, .holding, .approach].contains(aircraft[i].phase) else { return }
        aircraft[i].automaticArrival=false
        aircraft[i].phase = .holding
        aircraft[i].holdingAltitude = max(3000, aircraft[i].altitude)
        aircraft[i].holdingCenter = nil
        setHoldingRoute(i); log("\(aircraft[i].id): hold / go around."); startLive()
    }
    func rerouteSelected(to requested: Int? = nil) {
        guard let i = aircraft.firstIndex(where: { $0.id == selectedID }), aircraft[i].phase == .queued,
              let source = aircraft[i].runway,
              let target = requested ?? runways.indices.first(where: { $0 != source }),
              runways.indices.contains(target) else { return }
        guard surface.eligible(aircraft[i].model,runway:target) else { reject("Runway too short for this aircraft.");return }
        let entry=surface.departureEntry(for:aircraft[i].model,runway:target,from:aircraft[i].position)
        let route=surface.taxiRoute(from:aircraft[i].position,to:entry.hold)
        guard !route.isEmpty else{reject("No connected taxi route to that runway.");return}
        aircraft[i].departureEntry=entry.lineup;aircraft[i].route=route
        aircraft[i].groundSpeed=0
        _ = source
        aircraft[i].runway = target; aircraft[i].phase = .taxiing; aircraft[i].stopped = false
        log("\(aircraft[i].id): reroute to \(runways[target].name)."); startLive()
    }
    private var runwayCostCache:[String:Double]=[:]
    func clearanceRunways(for flight:Aircraft)->[Runway] {
        runways.filter { r in
            guard surface.eligible(flight.model,runway:r.id) else{return false}
            return !flight.departure || surface.gates[flight.stand].departureRunways.contains(r.id)
        }.sorted { a,b in
            if !flight.departure {return a.id==flight.runway && b.id != flight.runway}
            let p=surface.gates[flight.stand].port
            @MainActor func cost(_ r:Int)->Double {
                let key="\(surface.revision)-\(flight.modelID)-\(flight.stand)-\(r)"
                if let cached=runwayCostCache[key] {return cached}
                let entry=surface.departureEntry(for:flight.model,runway:r,from:p)
                let path=surface.taxiRoute(from:p,to:entry.hold)
                let value=path.isEmpty ? Double.infinity : FlightCurves.length(from:p,route:path)
                runwayCostCache[key]=value;return value
            }
            return cost(a.id)<cost(b.id)
        }
    }
    private func assignApproach(_ i:Int) {
        guard let r=aircraft[i].runway else{return}
        if aircraft[i].automaticArrival && !automaticArrivalHasRoom(i,runway:r) {
            aircraft[i].phase = .holding;aircraft[i].holdingAltitude=max(3000,aircraft[i].altitude)
            aircraft[i].retryArrivalAt=elapsed+5;setHoldingRoute(i)
            return
        }
        let h=surface.heading(r),end=runways[r].start
        // Finish with an aligned straight final; never steer toward an off-axis pin.
        let final=surface.offset(end,heading:h,along:-airport.rules.finalApproachDistance)
        aircraft[i].phase = .approach
        aircraft[i].route=FlightCurves.approach(from:aircraft[i].position,heading:aircraft[i].heading,to:final,endHeading:h,radius:surface.turnRadius)+[end]
        aircraft[i].descentStartAltitude=aircraft[i].altitude
        aircraft[i].descentStartDistance=max(1,FlightCurves.length(from:aircraft[i].position,route:aircraft[i].route))
        aircraft[i].descentRemainingDistance=aircraft[i].descentStartDistance
    }
    private func automaticArrivalHasRoom(_ i:Int,runway:Int)->Bool {
        let f=aircraft[i]
        if aircraft.contains(where:{$0.id != f.id && $0.stand==f.stand && ![.complete,.crashed,.diverted].contains($0.phase)}) {return false}
        if aircraft.contains(where:{$0.id != f.id && $0.runway==runway && ([.approach,.landingRoll,.takeoffRoll,.landing,.takeoff].contains($0.phase) || (!$0.airborne && onRunway($0.position,runway)))}) {return false}
        let exit=surface.landingRoute(runway,model:f.model).last ?? surface.exit(runway)
        return !aircraft.contains {other in
            other.id != f.id && !other.airborne && ![.complete,.crashed,.diverted].contains(other.phase) &&
            other.position.distance(to:exit)<(max(f.model.length,f.model.span)+max(other.model.length,other.model.span))*0.275+18
        }
    }
    func startArrivalTaxi(_ i:Int)->Bool {
        let f=aircraft[i],gate=surface.gates[f.stand]
        let route=plannedTaxiRoute(for:f,to:gate.position)
        guard !route.isEmpty else{return false}
        aircraft[i].phase = .taxiing
        aircraft[i].route=route
        aircraft[i].groundSpeed=0
        return true
    }
    private func updateIncomingTraffic() {
        for i in aircraft.indices where aircraft[i].automaticArrival && aircraft[i].phase == .holding && elapsed>=aircraft[i].retryArrivalAt && !aircraft[i].stopped {
            aircraft[i].retryArrivalAt=elapsed+20
            assignApproach(i)
        }
        for i in aircraft.indices where aircraft[i].phase == .awaitingEscort && elapsed>=aircraft[i].nextTaxiPlan {
            aircraft[i].nextTaxiPlan=elapsed+2
            _ = startArrivalTaxi(i)
        }
        if elapsed>=nextArrivalAt {
            nextArrivalAt=elapsed+max(airport.traffic.minimumIntervalSeconds,airport.traffic.baseIntervalSeconds-elapsed/airport.traffic.intervalDecaySeconds)
            let waiting=aircraft.filter{$0.airborne && ![.complete,.crashed,.diverted].contains($0.phase)}.count
            if waiting<airport.traffic.airborneLimit {spawnArrival()}
        }
        let retired=Set(aircraft.filter { f in
            guard f.id != selectedID,let retired=f.retiredAt,elapsed-retired>airport.traffic.retireAfterSeconds else{return false}
            return !serviceTasks.contains{$0.target == .aircraft(f.id) && ![.done,.cancelled].contains($0.state)} && !incidents.contains{$0.aircraftIDs.contains(f.id) && !$0.reopened}
        }.map(\.id))
        if !retired.isEmpty {
            aircraft.removeAll{retired.contains($0.id)}
            serviceTasks.removeAll {if case .aircraft(let id)=$0.target{return retired.contains(id)};return false}
        }
    }
    private func spawnArrival() {
        guard let choice=airport.traffic.continuousModels.randomElement(using:&random) else{return}
        let model=AircraftCatalog.model(choice.modelID)
        let compatible=surface.gates.indices.filter {stand in
            surface.gates[stand].accepts(model,purpose:choice.purpose) && !aircraft.contains{$0.stand==stand && ![.complete,.crashed,.diverted].contains($0.phase)}
        }
        guard let stand=compatible.min(by:{a,b in
            aircraft.filter{$0.stand==a && ![.complete,.crashed,.diverted].contains($0.phase)}.count < aircraft.filter{$0.stand==b && ![.complete,.crashed,.diverted].contains($0.phase)}.count
        }) else{return}
        let eligible=runways.indices.filter{surface.eligible(model,runway:$0)}
        guard let runway=eligible.randomElement(using:&random) else{return}
        let slots=airport.traffic.spawnPoints
        guard let position=slots.first(where:{p in !aircraft.contains{$0.airborne && $0.phase != .complete && $0.position.distance(to:p)<135}}) else{return}
        trafficSequence+=1
        let origin=airport.traffic.continuousPeers.randomElement(using:&random)!
        let heading=atan2(airport.image.height/2-position.y,airport.image.width/2-position.x)
        var flight=Aircraft(id:"\(airport.traffic.callsignPrefix)\(trafficSequence)",modelID:model.id,departure:false,stand:stand,position:position,heading:heading,origin:origin,destination:airport.identity.flightLabel,phase:.inbound,runway:runway,preferredRunway:runway,altitude:4500)
        flight.purpose=choice.purpose;flight.automaticArrival=true
        flight.passengerUnloadDuration=Double(Int.random(in:14...24,using:&random));flight.passengerLoadDuration=Double(Int.random(in:20...32,using:&random));flight.refuelDuration=Double(Int.random(in:25...40,using:&random))
        aircraft.append(flight);assignApproach(aircraft.count-1)
        log("\(flight.id): inbound from \(origin), runway \(runways[runway].name).")
    }
    func onRunway(_ p:Point,_ runway:Int)->Bool {
        let a=runways[runway].start,b=runways[runway].end,dx=b.x-a.x,dy=b.y-a.y,l=a.distance(to:b)
        let along=((p.x-a.x)*dx+(p.y-a.y)*dy)/(l*l),side=abs((p.x-a.x)*dy-(p.y-a.y)*dx)/l
        return along >= -0.01 && along<=1.01 && side<=airport.runways[runway].width/2+airport.rules.runwayMargin
    }
    func activeRunwayOperation(_ f:Aircraft,_ runway:Int)->Bool {
        guard f.runway==runway else{return false}
        return [.landingRoll,.takeoffRoll,.landing,.takeoff].contains(f.phase) || ([.approach,.climbing].contains(f.phase) && f.altitude<120)
    }
    func runwayConflict(_ a:Aircraft,_ b:Aircraft)->Bool {
        guard a.altitude<150,b.altitude<150,!a.airborne || !b.airborne else{return false}
        return runways.indices.contains {r in
            onRunway(a.position,r) && onRunway(b.position,r) && (activeRunwayOperation(a,r) || activeRunwayOperation(b,r))
        }
    }
    private func towerOwnsConflict(_ f:Aircraft,_ other:Aircraft)->Bool {
        for r in runways.indices {
            // Tower authority applies to a real runway conflict. An operation
            // on a strip must not disable separation against off-strip traffic.
            if activeRunwayOperation(f,r) && onRunway(other.position,r) {return true}
            if activeRunwayOperation(other,r) && onRunway(f.position,r) && (f.crossingClearances.contains(r) || activeRunwayOperation(f,r)) {return true}
        };return false
    }
    private func safeTaxiPath(_ f:Aircraft,to end:Point)->[Point] {
        let snapshot=groundTrafficSnapshot(for:f)
        return GroundTrafficPlanner.plan(flight:f,graph:surface.taxiNetwork,target:end,snapshot:snapshot)?.legs.map(\.to) ?? []
    }
    private func taxiMustWait(_ i:Int)->Bool {
        let f=aircraft[i]
        guard !f.airborne,[.taxiing,.pushback,.lineup,.landingRoll,.runwayExit,.landing,.takeoff].contains(f.phase),!f.route.isEmpty else{return false}
        // Once a landing/takeoff operation is on its assigned strip, runway
        // authority and runway-contact rules own the movement. A larger,
        // calibrated taxi stopping envelope must not let an adjacent holding-
        // short footprint veto the roll.
        if let runway=f.runway,[.landingRoll,.takeoffRoll,.landing,.takeoff].contains(f.phase),onRunway(f.position,runway) {return false}
        if !f.recoveringGround,let id=f.yieldTo,let other=aircraft.first(where:{$0.id==id}),!other.airborne,![.queued,.complete].contains(other.phase),
           let point=f.yieldPassPoint,(other.position.x-point.x)*cos(f.yieldPassHeading)+(other.position.y-point.y)*sin(f.yieldPassHeading)<25 {return true}
        if !f.recoveringGround {aircraft[i].yieldTo=nil}
        let motion=GroundMotionModel.profile(for:f)
        var end=f.position,remaining=motion.lookaheadDistance(at:f.groundSpeed,aircraftLength:f.model.length)
        for p in f.route {
            let d=end.distance(to:p)
            if d>remaining {end=Point.interpolate(end,p,fraction:remaining/d);break}
            remaining-=d;end=p;if remaining<=0 {break}
        }
        for other in aircraft where !towerOwnsConflict(f,other) && groundConflict(f,from:f.position,to:end,other:other,margin:1) {
            if end.distance(to:other.position)>f.position.distance(to:other.position)+0.01 {continue}
            aircraft[i].blockedBy=other.id
            if f.phase == .taxiing && !f.recoveringGround && elapsed>=f.nextTaxiPlan,let target=f.route.last {
                aircraft[i].nextTaxiPlan=elapsed+3
                let route=safeTaxiPath(f,to:target)
                if !route.isEmpty {aircraft[i].route=route}
            }
            return true
        };return false
    }
    private func protectTaxiMovement(previous:[Aircraft],plans:[Aircraft]) {
        guard aircraft.count>1 else{return}
        for i in 0..<(aircraft.count-1) {for j in (i+1)..<aircraft.count {
            let a=aircraft[i],b=aircraft[j]
            guard !a.airborne,!b.airborne,!towerOwnsConflict(a,b),!towerOwnsConflict(b,a),
                  !runways.indices.contains(where:{r in
                      (activeRunwayOperation(a,r) && onRunway(a.position,r) && !onRunway(b.position,r)) ||
                      (activeRunwayOperation(b,r) && onRunway(b.position,r) && !onRunway(a.position,r))
                  }),
                  ![.crashed,.complete,.diverted].contains(a.phase),![.crashed,.complete,.diverted].contains(b.phase),
                  a.position.distance(to:b.position)<previous[i].position.distance(to:previous[j].position)-0.001,
                  groundConflict(a,from:a.position,to:a.position,other:b,margin:1) else{continue}
            for k in [i,j] where [.taxiing,.pushback,.lineup,.landingRoll,.runwayExit,.landing,.takeoff].contains(aircraft[k].phase) {
                aircraft[k].position=previous[k].position;aircraft[k].heading=previous[k].heading;aircraft[k].route=plans[k].route
                aircraft[k].lineupRemaining=plans[k].lineupRemaining;aircraft[k].groundSpeed=0;aircraft[k].waitingForTraffic=true
                aircraft[k].blockedBy=aircraft[k==i ? j:i].id
                if aircraft[k].blockedSince == nil {aircraft[k].blockedSince=elapsed}
            }
        }}
    }
    private func resolveTaxiDeadlocks() {
        for i in aircraft.indices where aircraft[i].waitingForTraffic && !aircraft[i].recoveringGround && !aircraft[i].stopped {
            guard let since=aircraft[i].blockedSince,elapsed-since>7,let id=aircraft[i].blockedBy,
                  let j=aircraft.firstIndex(where:{$0.id==id}),aircraft[j].waitingForTraffic,!aircraft[j].recoveringGround,!aircraft[j].stopped,
                  [.taxiing,.pushback].contains(aircraft[i].phase),[.taxiing,.pushback,.queued].contains(aircraft[j].phase) else{continue}
            // One yielding decision per conflict. Arrivals clearing the airfield win;
            // otherwise a stable callsign order prevents both choosing to reverse.
            let loser:Int,winner:Int
            if aircraft[i].departure != aircraft[j].departure {loser=aircraft[i].departure ? i:j;winner=loser==i ? j:i}
            else {loser=aircraft[i].id>aircraft[j].id ? i:j;winner=loser==i ? j:i}
            guard !towerOwnsConflict(aircraft[loser],aircraft[winner]),!towerOwnsConflict(aircraft[winner],aircraft[loser]),elapsed>=aircraft[loser].nextYieldAttempt else{continue}
            aircraft[loser].nextYieldAttempt=elapsed+5
            if beginGroundYield(loser,to:winner) {return}
            // Stable priority is a preference, not permission to dispatch an
            // impossible retreat. The other aircraft may have the clear spur.
            aircraft[winner].nextYieldAttempt=elapsed+5
            if beginGroundYield(winner,to:loser) {return}
        }
    }
    private func beginGroundYield(_ loser:Int,to winner:Int)->Bool {
        let f=aircraft[loser],other=aircraft[winner]
        guard let destination=(f.phase == .pushback ? f.pendingTaxiRoute.last : f.route.last) else{return false}
        var graph=surface.taxiNetwork;graph.split(at:f.position)
        graph.edges=graph.edges.filter {e in
            !aircraft.contains {other in
                let a=graph.nodes[e.a],b=graph.nodes[e.b]
                guard groundConflict(f,from:a,to:b,other:other,margin:1) else{return false}
                if a.distance(to:f.position)<0.02 && b.distance(to:other.position)>f.position.distance(to:other.position)+1 {return false}
                if b.distance(to:f.position)<0.02 && a.distance(to:other.position)>f.position.distance(to:other.position)+1 {return false}
                return true
            }
        }
        func distanceToRoute(_ p:Point)->Double {
            var prior=other.position,best=Double.infinity
            for q in other.route {
                let dx=q.x-prior.x,dy=q.y-prior.y,t=min(1,max(0,((p.x-prior.x)*dx+(p.y-prior.y)*dy)/max(0.001,dx*dx+dy*dy)))
                best=min(best,p.distance(to:Point(x:prior.x+t*dx,y:prior.y+t*dy)));prior=q
            };return best
        }
        let clearance=(f.model.span+other.model.span)*0.275+8
        let candidates=graph.nodes.filter{$0.distance(to:f.position)>20 && $0.distance(to:f.position)<220 && distanceToRoute($0)>clearance}.sorted{$0.distance(to:f.position)<$1.distance(to:f.position)}
        guard !candidates.isEmpty else{return false}
        let offset=aircraft[loser].yieldCandidateCursor % candidates.count
        let ordered=Array(candidates.dropFirst(offset))+Array(candidates.prefix(offset))
        var feasibilityChecks=0
        for (index,target) in ordered.enumerated() {
            // Continue across attempts rather than freezing a simulation update
            // or permanently discarding candidates after a dense initial group.
            if feasibilityChecks>=2 {return false}
            aircraft[loser].yieldCandidateCursor=(offset+index+1) % candidates.count
            if aircraft.contains(where:{$0.id != f.id && $0.recoveringGround && ($0.route.last?.distance(to:target) ?? 999)<clearance}) {continue}
            let path=graph.shortestPath(from:f.position,to:target,maximumAccessDistance:2,minimumWidth:f.model.span*0.55)
            guard !path.isEmpty,FlightCurves.length(from:f.position,route:path)<400 else{continue}
            let resume=surface.taxiRoute(from:target,to:destination,minimumWidth:f.model.span*0.55)
            guard !resume.isEmpty else{continue}
            // A passing place is useful only if the loser can still leave it
            // after the winner reaches its holding point. Check with the same
            // planner instead of dispatching a tug into a terminal dead end.
            if !groundTrafficEscapes.contains(f.id),let endpoint=(other.phase == .pushback ? other.pendingTaxiRoute.last : other.route.last) {
                var probe=f;probe.position=target;probe.phase = .taxiing
                let finalRoute=[other.position]+other.route
                let before=finalRoute.dropLast().last ?? other.position
                let heading=atan2(endpoint.y-before.y,endpoint.x-before.x)
                let base=groundTrafficSnapshot(for:probe)
                let future=GroundTrafficReservation(owner:other.id,start:elapsed,end:base.horizon,polygon:GroundTrafficPlanner.body(other,at:endpoint,heading:heading))
                let snapshot=GroundTrafficSnapshot(revision:base.revision,now:base.now,horizon:base.horizon,reservations:base.reservations.filter{$0.owner != other.id}+[future])
                feasibilityChecks+=1
                guard GroundTrafficPlanner.plan(flight:probe,graph:surface.taxiNetwork,target:destination,snapshot:snapshot,expansionLimit:3000) != nil else{continue}
            }
            aircraft[loser].recoveringGround=true;aircraft[loser].blockedSince=nil;aircraft[loser].blockedBy=nil
            aircraft[loser].phase = .pushback;aircraft[loser].underTow=false;aircraft[loser].groundSpeed=0
            aircraft[loser].route=surface.rounded([f.position]+path,radius:2);aircraft[loser].pendingTaxiRoute=resume
            // Hold in the passing place until the winning aircraft has passed.
            aircraft[loser].yieldTo=other.id
            var closest=Double.infinity,prior=other.position
            for q in other.route {
                let dx=q.x-prior.x,dy=q.y-prior.y,t=min(1,max(0,((target.x-prior.x)*dx+(target.y-prior.y)*dy)/max(0.001,dx*dx+dy*dy)))
                let projection=Point(x:prior.x+t*dx,y:prior.y+t*dy)
                if projection.distance(to:target)<closest {closest=projection.distance(to:target);aircraft[loser].yieldPassPoint=projection;aircraft[loser].yieldPassHeading=atan2(dy,dx)}
                prior=q
            }
            enqueue(.pushback,target:.aircraft(f.id));log("\(f.id): ground crew moving aircraft to a passing place.")
            return true
        }
        return false
    }

    func groundConflict(_ flight:Aircraft,from start:Point,to end:Point,other:Aircraft,margin:Double=1)->Bool {
        guard other.id != flight.id,!other.airborne,![.crashed,.diverted].contains(other.phase),!(other.departure && other.phase == .complete) else{return false}
        let p=other.position,dx=end.x-start.x,dy=end.y-start.y
        let t=min(1,max(0,((p.x-start.x)*dx+(p.y-start.y)*dy)/max(0.0001,dx*dx+dy*dy)))
        let q=Point(x:start.x+dx*t,y:start.y+dy*t)
        let radius=(max(flight.model.length,flight.model.span)+max(other.model.length,other.model.span))*0.275+margin*2
        guard q.distance(to:p)<radius else{return false}
        let profile:[(Double,Double)]=[(0.5,0),(0.46,-0.045),(0.18,-0.065),(0.08,-0.15),(-0.08,-0.5),(-0.20,-0.49),(-0.15,-0.085),(-0.36,-0.07),(-0.42,-0.23),(-0.49,-0.23),(-0.45,-0.055),(-0.5,0),(-0.45,0.055),(-0.49,0.23),(-0.42,0.23),(-0.36,0.07),(-0.15,0.085),(-0.20,0.49),(-0.08,0.5),(0.08,0.15),(0.18,0.065),(0.46,0.045)]
        func body(_ f:Aircraft,_ position:Point,_ heading:Double)->[Point] {
            let l=f.model.length*0.55+margin*2,w=f.model.span*0.55+margin*2,c=cos(heading),s=sin(heading)
            return profile.map { a,b in Point(x:position.x+a*l*c-b*w*s,y:position.y+a*l*s+b*w*c) }
        }
        let heading=start.distance(to:end)>0.1 ? atan2(dy,dx)+(flight.phase == .pushback ? .pi : 0) : flight.heading
        let one=body(flight,q,heading),two=body(other,p,other.heading)
        if one.contains(where:{AirportFence.contains($0,polygon:two)}) || two.contains(where:{AirportFence.contains($0,polygon:one)}) {return true}
        func cross(_ a:Point,_ b:Point,_ c:Point)->Double {(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)}
        for i in one.indices {for j in two.indices {
            let a=one[i],b=one[(i+1)%one.count],c=two[j],d=two[(j+1)%two.count]
            if cross(a,b,c)*cross(a,b,d)<0 && cross(c,d,a)*cross(c,d,b)<0 {return true}
        }}
        return false
    }

    func plannedTaxiRoute(for flight:Aircraft,to target:Point)->[Point] {
        // Route proposals use the same time-aware search as committed movement.
        // A temporarily unavailable time slot must not reject a taxi clearance:
        // retain the connected geometry and schedule it when the tug is ready.
        let snapshot=groundTrafficSnapshot(for:flight)
        if let plan=GroundTrafficPlanner.plan(flight:flight,graph:surface.taxiNetwork,target:target,snapshot:snapshot) {return plan.legs.map(\.to)}
        return surface.taxiRoute(from:flight.position,to:target,minimumWidth:flight.model.span*0.55)
    }
    private func invalidateGroundTraffic() {
        groundTrafficPlans=[:];groundTrafficRoutes=[:];groundTrafficHolds=[:];groundTrafficRetry=[:]
        groundTrafficRevision=surface.revision
    }
    private func trafficManaged(_ f:Aircraft)->Bool {
        // Existing physical tug recovery remains a guarded local fallback.
        // Its actual position is held in snapshots until normal taxi resumes;
        // speculative recovery completion must never reserve a false departure.
        guard !f.airborne,!f.recoveringGround,!groundTrafficEscapes.contains(f.id) else{return false}
        if [.taxiing,.pushback,.lineup,.runwayExit].contains(f.phase) {return true}
        if let r=f.runway, !onRunway(f.position,r) {
            return f.phase == .landing || (f.phase == .takeoff && f.lineupRemaining>0)
        }
        return false
    }
    private func trafficReady(_ f:Aircraft)->Bool {
        if !f.recoveringGround,let id=f.yieldTo,let other=aircraft.first(where:{$0.id==id}),!other.airborne,![.queued,.complete].contains(other.phase),
           let point=f.yieldPassPoint,(other.position.x-point.x)*cos(f.yieldPassHeading)+(other.position.y-point.y)*sin(f.yieldPassHeading)<25 {return false}
        return trafficManaged(f) && !f.stopped && f.crossingRequest == nil && f.groundPause<=0 &&
            (f.phase != .pushback || f.underTow) && !f.route.isEmpty
    }
    private func groundTrafficSnapshot(for flight:Aircraft)->GroundTrafficSnapshot {
        let horizon=elapsed+240
        var reservations:[GroundTrafficReservation]=[]
        for other in aircraft where other.id != flight.id && !other.airborne &&
            ![.crashed,.diverted].contains(other.phase) && !(other.departure && other.phase == .complete) &&
            !towerOwnsConflict(flight,other) && !towerOwnsConflict(other,flight) {
            if let plan=groundTrafficPlans[other.id],trafficReady(other) {
                reservations += GroundTrafficPlanner.reservations(for:plan,flight:other,now:elapsed,horizon:horizon)
            } else {
                // No speculative departure time for stopped, unapproved or
                // tug-blocked aircraft: their current footprint stays occupied.
                reservations.append(.init(owner:other.id,start:elapsed,end:horizon,polygon:GroundTrafficPlanner.body(other,at:other.position,heading:other.heading)))
            }
        }
        return .init(revision:surface.revision,now:elapsed,horizon:horizon,reservations:reservations)
    }
    private func prepareGroundTraffic(_ step:Double) {
        if groundTrafficRevision != surface.revision {invalidateGroundTraffic()}
        for i in aircraft.indices {
            if let id=aircraft[i].yieldTo,let winner=aircraft.first(where:{$0.id==id}),[.queued,.complete].contains(winner.phase) {
                // The winner has finished this taxi movement. Its actual held
                // footprint, rather than an obsolete pass-point projection,
                // now decides whether the common planner can resume the loser.
                aircraft[i].yieldTo=nil
            }
        }
        let grounded=Set(aircraft.filter{!$0.airborne && ![.crashed,.diverted].contains($0.phase) && !($0.departure && $0.phase == .complete)}.map(\.id))
        let tracked=Set(groundTrafficPlans.keys).union(groundTrafficHolds.keys)
        // SIPP requires a safe starting configuration. Preserve the existing
        // guarded separation path for invalid, already-overlapping starts until
        // that taxi movement ends. Other plans see only their actual footprint.
        groundTrafficEscapes=groundTrafficEscapes.filter {id in aircraft.contains{$0.id==id && [.taxiing,.pushback].contains($0.phase)}}
        let fresh=grounded.subtracting(tracked)
        for f in aircraft where fresh.contains(f.id) && [.taxiing,.pushback].contains(f.phase) {
            for other in aircraft where !towerOwnsConflict(f,other) && !towerOwnsConflict(other,f) {
                if groundConflict(f,from:f.position,to:f.position,other:other,margin:1) {groundTrafficEscapes.insert(f.id);groundTrafficEscapes.insert(other.id)}
            }
        }
        var changed=grounded != tracked
        func cancel(_ id:String) {
            groundTrafficCancellations+=1
            groundTrafficPlans.removeValue(forKey:id);groundTrafficRoutes.removeValue(forKey:id);groundTrafficRetry.removeValue(forKey:id)
        }
        for (id,plan) in groundTrafficPlans {
            guard let f=aircraft.first(where:{$0.id==id}),trafficReady(f),f.phase==plan.phase,
                  f.position.distance(to:plan.position(at:elapsed-step))<0.05,
                  abs(atan2(sin(f.heading-plan.heading(at:elapsed-step)),cos(f.heading-plan.heading(at:elapsed-step))))<0.001,
                  f.route==groundTrafficRoutes[id],elapsed<plan.horizon-1 else{cancel(id);changed=true;continue}
        }
        for (id,hold) in groundTrafficHolds {
            guard let f=aircraft.first(where:{$0.id==id}),f.position.distance(to:hold.0)<0.01,abs(atan2(sin(f.heading-hold.1),cos(f.heading-hold.1)))<0.001,trafficReady(f)==hold.2 else{changed=true;continue}
        }
        // Cancel dependent plans to a fixed point against actual held positions.
        // An unrelated runway roll must not repeatedly restart the entire apron.
        if changed {
            var removed=true
            while removed {
                removed=false
                for (id,plan) in groundTrafficPlans {
                    guard let f=aircraft.first(where:{$0.id==id}) else{cancel(id);removed=true;continue}
                    if !GroundTrafficPlanner.validated(plan,flight:f,against:groundTrafficSnapshot(for:f)) {cancel(id);removed=true}
                }
            }
        }
        for i in aircraft.indices where trafficManaged(aircraft[i]) {
            if aircraft[i].phase == .taxiing && checkCrossing(i) {
                if groundTrafficPlans[aircraft[i].id] != nil {
                    cancel(aircraft[i].id)
                    // A crossing is an indefinite ATC hold. Withdraw trajectories
                    // relying on it moving; independent traffic keeps its slots.
                    var removed=true
                    while removed {
                        removed=false
                        for (id,plan) in groundTrafficPlans {
                            if let f=aircraft.first(where:{$0.id==id}),!GroundTrafficPlanner.validated(plan,flight:f,against:groundTrafficSnapshot(for:f)) {cancel(id);removed=true}
                        }
                    }
                }
                aircraft[i].groundSpeed=0
            }
        }
        // Existing committed trajectories keep their slots. New plans are
        // admitted one by one, never from independently stale traffic copies.
        for i in aircraft.indices where trafficReady(aircraft[i]) && groundTrafficPlans[aircraft[i].id]==nil {
            let f=aircraft[i]
            if elapsed<(groundTrafficRetry[f.id] ?? 0) {continue}
            groundTrafficRetry[f.id]=elapsed+2
            let snapshot=groundTrafficSnapshot(for:f)
            groundTrafficSearches+=1
            var candidate:GroundTrafficPlan?
            if f.phase == .taxiing && !f.recoveringGround && f.yieldTo == nil {
                // The final stand access is already part of the dedicated graph.
                candidate=GroundTrafficPlanner.plan(flight:f,graph:surface.taxiNetwork,target:f.route.last!,snapshot:snapshot)
            } else {
                let path=f.phase == .takeoff ? Array(f.route.dropLast()) : f.route
                candidate=GroundTrafficPlanner.plan(flight:f,route:path,snapshot:snapshot,constraints:surface.network)
            }
            // Geometric shortcuts/rounding are never applied AFTER reservation.
            // Fixed authored routes remain usable when an access point is not
            // represented in the generic taxi graph.
            if candidate == nil && !(f.phase == .taxiing && surface.taxiNetwork.hasRestrictions) {candidate=GroundTrafficPlanner.plan(flight:f,route:f.phase == .takeoff ? Array(f.route.dropLast()) : f.route,snapshot:snapshot,constraints:surface.network)}
            if let plan=candidate,GroundTrafficPlanner.validated(plan,flight:f,against:snapshot) {
                groundTrafficPlans[f.id]=plan
                aircraft[i].route=plan.legs.map(\.to)+(f.phase == .takeoff ? Array(f.route.suffix(1)) : [])
                groundTrafficRoutes[f.id]=aircraft[i].route
            }
        }
        groundTrafficHolds=Dictionary(uniqueKeysWithValues:aircraft.filter{!$0.airborne && groundTrafficPlans[$0.id]==nil && ![.crashed,.diverted].contains($0.phase) && !($0.departure && $0.phase == .complete)}.map{($0.id,($0.position,$0.heading,trafficReady($0)))})
    }
    private func moveOnGroundSchedule(_ i:Int,step:Double)->Bool {
        guard trafficManaged(aircraft[i]) else{return false}
        let f=aircraft[i]
        guard let plan=groundTrafficPlans[f.id] else {
            _ = taxiMustWait(i) // retain physical blocker metadata for tug recovery
            if aircraft[i].blockedBy == nil {
                // A temporal plan can fail before the short emergency lookahead
                // reaches the blocker. Recovery still needs that dependency.
                var prior=f.position,walked=0.0
                for p in f.route {
                    let h=atan2(p.y-prior.y,p.x-prior.x)+(f.phase == .pushback ? .pi : 0)
                    let shape=GroundTrafficReservation(owner:f.id,start:0,end:0,polygon:GroundTrafficPlanner.swept(f,from:prior,to:p,heading:h))
                    if let other=aircraft.first(where:{other in
                        guard other.id != f.id,!other.airborne,![.complete,.crashed,.diverted].contains(other.phase),!towerOwnsConflict(f,other),!towerOwnsConflict(other,f) else{return false}
                        return shape.intersects(.init(owner:other.id,start:0,end:0,polygon:GroundTrafficPlanner.body(other,at:other.position,heading:other.heading)))
                    }) {aircraft[i].blockedBy=other.id;break}
                    walked+=prior.distance(to:p);prior=p;if walked>240 {break}
                }
            }
            aircraft[i].waitingForTraffic=true;aircraft[i].groundSpeed=0
            if aircraft[i].blockedSince == nil {aircraft[i].blockedSince=elapsed}
            return true
        }
        let p=plan.position(at:elapsed),distance=f.position.distance(to:p)
        aircraft[i].position=p;aircraft[i].heading=plan.heading(at:elapsed)
        aircraft[i].groundSpeed=plan.speed(at:elapsed)
        aircraft[i].waitingForTraffic=plan.waiting(at:elapsed)
        aircraft[i].route=plan.remainingRoute(at:elapsed)+(f.phase == .takeoff ? Array(f.route.suffix(1)) : [])
        groundTrafficRoutes[f.id]=aircraft[i].route
        if f.phase == .takeoff {aircraft[i].lineupRemaining=max(0,f.lineupRemaining-distance)}
        // A scheduled wait has a known release time, rather than a mutual-wait
        // dependency for the legacy recovery fallback.
        aircraft[i].blockedBy=nil;aircraft[i].blockedSince=nil
        return true
    }
    func approveCrossing() {
        guard let i=aircraft.firstIndex(where:{$0.id==selectedID}),let r=aircraft[i].crossingRequest else{return}
        aircraft[i].crossingClearances.insert(r);aircraft[i].crossingRequest=nil
        log("\(aircraft[i].id): cross \(runways[r].name), clearance issued by tower.");startLive()
    }
    private func checkCrossing(_ i:Int)->Bool {
        let p=aircraft[i].position
        for r in runways.indices {
            let a=runways[r].start,b=runways[r].end,dx=b.x-a.x,dy=b.y-a.y,l=a.distance(to:b)
            func coordinates(_ q:Point)->(Double,Double){(((q.x-a.x)*dx+(q.y-a.y)*dy)/(l*l),abs((q.x-a.x)*dy-(q.y-a.y)*dx)/l)}
            let here=coordinates(p)
            if aircraft[i].crossingClearances.contains(r) {
                if here.1<15 {aircraft[i].crossingsEntered.insert(r)}
                if aircraft[i].crossingsEntered.contains(r) && here.1>25 {aircraft[i].crossingClearances.remove(r);aircraft[i].crossingsEntered.remove(r)}
                continue
            }
            var remaining=aircraft[i].model.length*0.55/2+23,previous=p
            for target in aircraft[i].route {
                let distance=previous.distance(to:target)
                let q=distance>remaining ? Point.interpolate(previous,target,fraction:remaining/max(0.001,distance)) : target
                let from=coordinates(previous),next=coordinates(q)
                let s0=((previous.x-a.x)*dy-(previous.y-a.y)*dx)/l,s1=((q.x-a.x)*dy-(q.y-a.y)*dx)/l
                let onLength=(min(from.0,next.0)<1 && max(from.0,next.0)>0)
                if onLength && (next.1<13 || s0*s1<0) {
                    if aircraft[i].crossingRequest != r {aircraft[i].crossingRequest=r;log("\(aircraft[i].id): requesting crossing \(runways[r].name). Holding position.")}
                    return true
                }
                remaining-=distance;if remaining<=0 {break};previous=q
            }
        }
        aircraft[i].crossingRequest=nil;return false
    }
    /// Positions, paths, hit targets and collisions all share fixed-image pixels.
    func displayPosition(for flight: Aircraft) -> Point { flight.position }
    func rangeNM(for flight: Aircraft) -> Double {
        let r=flight.runway ?? flight.preferredRunway
        let scale=runways[r].start.distance(to:runways[r].end)/airport.runways[r].rangeReferenceNM
        return flight.position.distance(to:runways[r].start)/scale
    }
    func tick(_ dt: Double) {
        guard running, !finished, dt > 0 else { return }
        let step = min(dt, 0.1)
        elapsed += step
        if continuousTraffic {updateIncomingTraffic()}
        resolveTaxiDeadlocks()
        let previous = aircraft
        prepareGroundTraffic(step)
        var movementPlans=aircraft
        for i in aircraft.indices {
            guard ![.complete, .crashed, .diverted, .servicing, .gateWait, .parked, .awaitingEscort].contains(aircraft[i].phase), !aircraft[i].stopped else { continue }
            if aircraft[i].phase == .pushback && !aircraft[i].underTow { continue }
            aircraft[i].waitingForTraffic=false
            if aircraft[i].phase == .taxiing,checkCrossing(i) {aircraft[i].groundSpeed=0;continue}
            if aircraft[i].groundPause>0 {aircraft[i].groundPause=max(0,aircraft[i].groundPause-step);continue}
            if trafficManaged(aircraft[i]) {
                movementPlans[i]=aircraft[i]
                _ = moveOnGroundSchedule(i,step:step)
                continue
            }
            aircraft[i].waitingForTraffic=taxiMustWait(i)
            if aircraft[i].waitingForTraffic {
                if aircraft[i].blockedSince == nil {aircraft[i].blockedSince=elapsed}
                aircraft[i].groundSpeed=0;continue
            }
            let phase = aircraft[i].phase
            if phase == .holding && aircraft[i].altitude < aircraft[i].holdingAltitude {
                aircraft[i].altitude = min(aircraft[i].holdingAltitude, aircraft[i].altitude + 300 * step)
            }
            if aircraft[i].groundPause>0 { aircraft[i].groundPause=max(0,aircraft[i].groundPause-step);continue }
            var desired=aircraft[i].model.speed(for:phase)
            let groundMotion = aircraft[i].airborne ? nil : GroundMotionModel.profile(for:aircraft[i])
            if let groundMotion {desired=groundMotion.cruiseSpeed}
            if phase == .approach {
                // Keep the straight final faster, then smoothly bleed speed over
                // the last 160 simulation metres before touchdown.
                let remaining=max(0,aircraft[i].descentRemainingDistance)
                let slowdown=min(1,max(0,(160-remaining)/160))
                let landingSpeed=aircraft[i].model.speed(for:.landingRoll)
                desired=landingSpeed+(desired-landingSpeed)*(1-slowdown)
            }
            if phase == .landing,let target=aircraft[i].route.first,aircraft[i].position.distance(to:target)<100 { desired=6 }
            let speed: Double
            if phase == .taxiing { desired=min(desired,surface.cornerSpeed(from:aircraft[i].position,route:aircraft[i].route)) }
            if phase == .climbing {
                aircraft[i].groundSpeed=min(desired,aircraft[i].groundSpeed+step*1.5);speed=aircraft[i].groundSpeed
            } else if aircraft[i].airborne { speed=desired }
            else if phase == .landingRoll {
                let target=aircraft[i].model.speed(for:.runwayExit)
                let progress=min(1,max(0,aircraft[i].landingRollDistance/aircraft[i].landingRollTotalDistance))
                let rolloutSpeed=aircraft[i].model.speed(for:.landingRoll)
                speed=rolloutSpeed+(target-rolloutSpeed)*progress
                aircraft[i].groundSpeed=speed
            }
            else {
                let motion=groundMotion!
                let old=aircraft[i].groundSpeed
                aircraft[i].groundSpeed=old>desired ? max(desired,old-step*motion.deceleration) : min(desired,old+step*motion.acceleration)
                speed=aircraft[i].groundSpeed
            }
            movementPlans[i]=aircraft[i]
            move(i, distance: speed * step)
            if phase == .landingRoll {aircraft[i].landingRollDistance += speed*step}
            if phase == .lineup || phase == .takeoff { aircraft[i].lineupRemaining=max(0,aircraft[i].lineupRemaining-speed*step) }
            if phase == .approach, aircraft[i].runway != nil {
                aircraft[i].descentRemainingDistance = max(0,aircraft[i].descentRemainingDistance-speed*step)
                aircraft[i].altitude = aircraft[i].descentStartAltitude * min(1,aircraft[i].descentRemainingDistance/aircraft[i].descentStartDistance)
            } else if phase == .climbing {
                aircraft[i].altitude=min(6000,aircraft[i].altitude+step*220)
            } else if [.takeoffRoll,.takeoff].contains(phase), let r = aircraft[i].runway {
                let runway = runways[r], dx = runway.end.x - runway.start.x, dy = runway.end.y - runway.start.y
                let t = ((aircraft[i].position.x-runway.start.x)*dx + (aircraft[i].position.y-runway.start.y)*dy) / (dx*dx+dy*dy)
                let entry=aircraft[i].departureEntry ?? runway.start
                let et=((entry.x-runway.start.x)*dx+(entry.y-runway.start.y)*dy)/(dx*dx+dy*dy)
                let lift=et+(1-et)*aircraft[i].model.takeoffRollFraction
                aircraft[i].altitude = max(0,(t-lift)/max(0.01,1-lift))*1200
            }
        }
        // All non-landing airborne traffic shares one flight level. Aircraft
        // on approach may descend; touchdown/ground phases remain at zero.
        for i in aircraft.indices where aircraft[i].airborne && aircraft[i].phase != .approach {
            aircraft[i].altitude=Self.sharedAirborneAltitude
        }
        for i in aircraft.indices {
            let turn=atan2(sin(aircraft[i].heading-previous[i].heading),cos(aircraft[i].heading-previous[i].heading))/step
            let lift=min(1,max(0,aircraft[i].altitude)/350)
            let target=aircraft[i].airborne && !aircraft[i].stopped ? min(0.30,max(-0.30,turn*2.7))*lift : 0
            aircraft[i].bankAngle += (target-aircraft[i].bankAngle)*(1-exp(-step/0.65))
        }
        protectTaxiMovement(previous:previous,plans:movementPlans)
        for i in aircraft.indices {
            if aircraft[i].position.distance(to:previous[i].position)>0.01 {aircraft[i].blockedSince=nil;aircraft[i].blockedBy=nil}
            if aircraft[i].route.isEmpty && !aircraft[i].stopped && [.inbound,.holding,.approach,.landingRoll,.runwayExit,.lineup,.takeoffRoll,.landing,.taxiing,.pushback,.takeoff,.climbing].contains(aircraft[i].phase) {reachedRouteEnd(i)}
        }
        detectCollisions(previous: previous)
        updateGroundServices(step)
        updateGateReadiness(step)
        if !continuousTraffic && activeCount == 0 && busyVehicleCount == 0 && incidents.allSatisfy(incidentReady) {
            finished = true; running = false
            notice = "Shift complete: \(resolved) handled, \(violations) aircraft lost. Score \(score)."
        }
    }
    private func move(_ i: Int, distance: Double) {
        var remaining = distance
        while remaining > 0, let target = aircraft[i].route.first {
            let p = aircraft[i].position, d = p.distance(to: target)
            if d > 0.001 { aircraft[i].heading = atan2(target.y - p.y, target.x - p.x) + (aircraft[i].phase == .pushback ? .pi : 0) }
            if d <= remaining { aircraft[i].position = target; aircraft[i].route.removeFirst(); remaining -= d }
            else { aircraft[i].position = Point(x: p.x+(target.x-p.x)*remaining/d, y: p.y+(target.y-p.y)*remaining/d); remaining = 0 }
        }
    }
    private func setHoldingRoute(_ i: Int) {
        let p=aircraft[i].position,h=aircraft[i].heading,r=surface.turnRadius
        let preferred=surface.orbitDirections[aircraft[i].preferredRunway]
        // Fly a straight entry when needed to fit the full, large orbit on the
        // terrain. Both turn directions preserve the current position/track.
        for distance in stride(from:0.0,through:450.0,by:10) {
            let entry=surface.offset(p,heading:h,along:distance)
            for direction in [preferred,-preferred] {
                let center=surface.offset(entry,heading:h,side:direction*r)
                if center.x-r>=55 && center.x+r<=airport.image.width-55 && center.y-r>=55 && center.y+r<=airport.image.height-55 {
                    aircraft[i].route=(distance>0 ? [entry] : [])+FlightCurves.arc(from:entry,heading:h,angle:2 * .pi,direction:direction,radius:r)
                    return
                }
            }
        }
        aircraft[i].route=FlightCurves.arc(from:p,heading:h,angle:2 * .pi,direction:preferred,radius:r)
    }
    private func reachedRouteEnd(_ i: Int) {
        switch aircraft[i].phase {
        case .inbound:
            aircraft[i].phase = .holding; aircraft[i].holdingCenter = nil; setHoldingRoute(i)
        case .holding: setHoldingRoute(i)
        case .pushback:
            aircraft[i].recoveringGround=false
            aircraft[i].underTow = false; aircraft[i].groundSpeed=0;aircraft[i].groundPause=2; aircraft[i].phase = .taxiing; aircraft[i].route = aircraft[i].pendingTaxiRoute; aircraft[i].pendingTaxiRoute = []
        case .taxiing:
            if aircraft[i].departure { aircraft[i].phase = .queued; log("\(aircraft[i].id): holding short. Awaiting your takeoff clearance.") }
            else { beginTurnaround(i) }
        case .approach:
            aircraft[i].altitude = 0; aircraft[i].phase = .landingRoll; aircraft[i].groundSpeed=aircraft[i].model.speed(for:.landingRoll);aircraft[i].landingRollDistance=0
            let full=surface.landingRoute(aircraft[i].runway!,model:aircraft[i].model)
            if let r=aircraft[i].runway,let firstOff=full.firstIndex(where:{!onRunway($0,r)}) {
                aircraft[i].route=Array(full[..<firstOff]);aircraft[i].pendingTaxiRoute=Array(full[firstOff...])
            } else {aircraft[i].route=full;aircraft[i].pendingTaxiRoute=[]}
            aircraft[i].landingRollTotalDistance=max(1,FlightCurves.length(from:aircraft[i].position,route:aircraft[i].route))
            log("\(aircraft[i].id): touchdown.")
        case .landingRoll:
            aircraft[i].phase = .runwayExit
            aircraft[i].route=aircraft[i].pendingTaxiRoute;aircraft[i].pendingTaxiRoute=[]
            if aircraft[i].route.isEmpty,let r=aircraft[i].runway {aircraft[i].route=[surface.exit(r)]}
            log("\(aircraft[i].id): landing roll complete; exiting runway.")
        case .runwayExit, .landing:
            aircraft[i].phase = .awaitingEscort; enqueue(.followMe, target: .aircraft(aircraft[i].id))
            _ = startArrivalTaxi(i)
            log("\(aircraft[i].id): taxiing to stand; follow-me assistance dispatched.")
        case .lineup:
            aircraft[i].phase = .takeoffRoll;aircraft[i].groundSpeed=0;aircraft[i].lineupRemaining=0
            aircraft[i].route=[runways[aircraft[i].runway!].end]
            log("\(aircraft[i].id): aligned; takeoff roll.")
        case .takeoffRoll, .takeoff:
            aircraft[i].phase = .climbing
            aircraft[i].route=[surface.departureExit(from:aircraft[i].position,heading:aircraft[i].heading)]
            log("\(aircraft[i].id): airborne, climbing out.")
        case .climbing: aircraft[i].phase = .complete;aircraft[i].retiredAt=elapsed; resolved += 1; log("\(aircraft[i].id): departed the airspace.")
        default: break
        }
    }
    private func detectCollisions(previous: [Aircraft]) {
        guard aircraft.count > 1 else { return }
        func active(_ f: Aircraft) -> Bool { f.phase != .crashed && f.phase != .diverted && !(f.departure && f.phase == .complete) }
        for i in 0..<(aircraft.count-1) where active(aircraft[i]) {
            for j in (i+1)..<aircraft.count where active(aircraft[i]) && active(aircraft[j]) {
                let a0 = displayPosition(for: previous[i]), b0 = displayPosition(for: previous[j])
                let a1 = displayPosition(for: aircraft[i]), b1 = displayPosition(for: aircraft[j])
                let x = a0.x-b0.x, y = a0.y-b0.y, vx = (a1.x-b1.x)-x, vy = (a1.y-b1.y)-y
                let denominator = vx*vx+vy*vy
                let t = denominator > 0.0001 ? min(1,max(0,-(x*vx+y*vy)/denominator)) : 0
                let distance = hypot(x+vx*t,y+vy*t)
                let altitudeA = previous[i].altitude + (aircraft[i].altitude-previous[i].altitude)*t
                let altitudeB = previous[j].altitude + (aircraft[j].altitude-previous[j].altitude)*t
                let radius = (aircraft[i].model.length*aircraft[i].apparentScale + aircraft[j].model.length*aircraft[j].apparentScale) * 0.27
                // Contacts only become accidents on an active landing/takeoff runway.
                let airbornePair = previous[i].airborne && previous[j].airborne
                let bothGround = !aircraft[i].airborne && !aircraft[j].airborne
                let contact:Bool
                if bothGround {
                    var moving=aircraft[i];moving.position=Point(x:a0.x+(a1.x-a0.x)*t,y:a0.y+(a1.y-a0.y)*t)
                    var obstacle=aircraft[j];obstacle.position=Point(x:b0.x+(b1.x-b0.x)*t,y:b0.y+(b1.y-b0.y)*t)
                    contact=groundConflict(moving,from:moving.position,to:moving.position,other:obstacle,margin:0)
                } else {
                    let separation=airbornePair ? max(radius,40) : radius
                    contact=distance<separation && (airbornePair || abs(altitudeA-altitudeB)<300)
                }
                var collisionA=aircraft[i],collisionB=aircraft[j]
                collisionA.altitude=altitudeA;collisionB.altitude=altitudeB
                collisionA.position=Point(x:a0.x+(a1.x-a0.x)*t,y:a0.y+(a1.y-a0.y)*t)
                collisionB.position=Point(x:b0.x+(b1.x-b0.x)*t,y:b0.y+(b1.y-b0.y)*t)
                if contact && (airbornePair || runwayConflict(collisionA,collisionB)) {
                    let p = Point(x: (a1.x+b1.x)/2, y: (a1.y+b1.y)/2)
                    collide(i, j, at: p)
                }
            }
        }
    }
    private func collide(_ i: Int, _ j: Int, at position: Point) {
        let affected=Set(runways.indices.filter{onRunway(position,$0)})
        let incident = AirportIncident(position: position, runwayIDs: affected, aircraftIDs: [aircraft[i].id, aircraft[j].id], time: elapsed)
        incidents.append(incident)
        for f in [i,j] {
            if aircraft[f].phase == .complete { resolved = max(0,resolved-1) }
            aircraft[f].phase = .crashed; aircraft[f].route = []; aircraft[f].stopped = false; aircraft[f].underTow = false
        }
        violations += 2
        for r in affected { runways[r].closed = true }
        for kind in [ServiceKind.patrol, .fire, .ambulance, .sweeper] { enqueue(kind, target: .incident(incident.id)) }
        notice = "COLLISION: \(incident.aircraftIDs.joined(separator: " / ")). Runway closed; emergency crews dispatched. −1000 points."
        log(notice)
    }
}
/// Geographic runway endpoints from OurAirports, checked against DIAL runway names.
/// Taxi routes and scenario stand locations come from the mapped OSM network.
enum DelhiLayout {
    // Spherical Mercator, the same projection used by MapKit. One world unit is
    // ten projected metres. Both axes share the same scale: headings stay aligned.
    static let radius = 6_378_137.0
    private static let radians = Double.pi / 180
    private static let originX = radius * 77.045 * radians
    private static let originY = radius * log(tan(.pi / 4 + 28.59 * radians / 2))
    static func point(_ latitude: Double, _ longitude: Double) -> Point {
        Point(x: (radius * longitude * radians - originX) / 10,
              y: (originY - radius * log(tan(.pi / 4 + latitude * radians / 2))) / 10)
    }
    static func latitude(_ p: Point) -> Double {
        (2 * atan(exp((originY - p.y * 10) / radius)) - .pi / 2) / radians
    }
    static func longitude(_ p: Point) -> Double { (originX + p.x * 10) / radius / radians }
    static let northStart = point(28.5672, 77.084801)
    static let northEnd = point(28.5585, 77.122498)
    static let southStart = point(28.547171, 77.065491)
    static let southEnd = point(28.537729, 77.109528)
    static let visualRunways: [(String, String, Point, Point)] = [
        ("09", "27", point(28.570499, 77.087997), point(28.569799, 77.116997)),
        ("10", "28", northStart, northEnd),
        ("11L", "29R", point(28.550125, 77.068176), point(28.540747, 77.111877)),
        ("11R", "29L", southStart, southEnd)
    ]
    static let terminals: [(String, Point)] = [
        ("TERMINAL 1", point(28.5658, 77.1201)),
        ("TERMINAL 2", point(28.5589, 77.0875)),
        ("TERMINAL 3", point(28.55525, 77.0848))
    ]
    static let stands = DelhiGroundData.stands
    static let standNames = ["Bay 41", "Bay 42", "Bay 43"]
    static func extended(_ start: Point, _ end: Point, fraction: Double) -> Point {
        Point(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
    }
    static func distanceToRunway(_ p: Point, start: Point, end: Point) -> Double {
        abs((end.y - start.y) * p.x - (end.x - start.x) * p.y + end.x * start.y - end.y * start.x) / start.distance(to: end)
    }
}

extension DelhiLayout {
    static func crossings(_ route: [Point]) -> Set<Int> {
        let lines = AirportLayout.runwayDefinitions.map { ($0.2, $0.3) }
        var result = Set<Int>()
        for (r, line) in lines.enumerated() {
            let (c, d) = line
            let vx = d.x - c.x, vy = d.y - c.y
            let length = c.distance(to: d)
            func side(_ p: Point) -> Double { (vx * (p.y - c.y) - vy * (p.x - c.x)) / length }
            func along(_ p: Point) -> Double { ((p.x - c.x) * vx + (p.y - c.y) * vy) / (length * length) }
            for (a, b) in zip(route, route.dropFirst()) {
                let sa = side(a), sb = side(b)
                if abs(sa) < AirportLayout.runwayWidth / 2 + 4 && (0...1).contains(along(a)) || abs(sb) < AirportLayout.runwayWidth / 2 + 4 && (0...1).contains(along(b)) { result.insert(r) }
                if sa * sb < 0 {
                    let f = sa / (sa - sb)
                    let intersection = extended(a, b, fraction: f)
                    if (0...1).contains(along(intersection)) { result.insert(r) }
                }
            }
        }
        return result
    }
}

extension DelhiLayout {
    static func nauticalMiles(_ a: Point, _ b: Point) -> Double {
        let p1 = latitude(a) * .pi / 180, p2 = latitude(b) * .pi / 180
        let dl = (longitude(b) - longitude(a)) * .pi / 180
        let h = pow(sin((p2 - p1) / 2), 2) + cos(p1) * cos(p2) * pow(sin(dl / 2), 2)
        return 6_371_008.8 * 2 * asin(min(1, sqrt(h))) / 1852
    }
    static func arrivalPoint(runway: Int, nauticalMiles distance: Double) -> Point {
        let ends = [(northStart, northEnd), (southStart, southEnd), (visualRunways[0].2, visualRunways[0].3), (visualRunways[2].2, visualRunways[2].3)]
        let (start, end) = ends[runway]
        let lat = latitude(start) * .pi / 180, lon = longitude(start) * .pi / 180
        let endLat = latitude(end) * .pi / 180
        let dl = (longitude(end) - longitude(start)) * .pi / 180
        let bearing = atan2(sin(dl) * cos(endLat), cos(lat) * sin(endLat) - sin(lat) * cos(endLat) * cos(dl)) + .pi
        let arc = distance * 1852 / 6_371_008.8
        let outLat = asin(sin(lat) * cos(arc) + cos(lat) * sin(arc) * cos(bearing))
        let outLon = lon + atan2(sin(bearing) * sin(arc) * cos(lat), cos(arc) - sin(lat) * sin(outLat))
        return point(outLat * 180 / .pi, outLon * 180 / .pi)
    }
}

/// Tangent circular turns joined by a straight leg. Evaluate the four feasible
/// left/right combinations and choose the shortest; every turn has the authored
/// radius. Sampling changes position AND track, rather than only easing a sprite.
enum FlightCurves {
    static func wrap(_ a: Double) -> Double { let t=a.truncatingRemainder(dividingBy:2 * .pi);return t<0 ? t+2 * .pi : t }
    static func length(from p: Point, route: [Point]) -> Double { zip([p]+route,route).reduce(0) { $0+$1.0.distance(to:$1.1) } }
    static func arc(from p: Point, heading: Double, angle: Double, direction: Double, radius: Double) -> [Point] {
        let count=max(1,Int(ceil(angle/0.012)))
        return (1...count).map { i in
            let h=heading+direction*angle*Double(i)/Double(count)
            return Point(x:p.x+radius/direction*(sin(h)-sin(heading)),y:p.y+radius/direction*(cos(heading)-cos(h)))
        }
    }
    static func circle(from p: Point, heading: Double, radius: Double) -> [Point] {
        arc(from:p,heading:heading,angle:2 * .pi,direction:1,radius:radius)
    }
    static func approach(from p: Point, heading h: Double, to q: Point, endHeading e: Double, radius r: Double) -> [Point] {
        var best:[Point]=[],bestLength=Double.infinity
        for s in [-1.0,1.0] { for t in [-1.0,1.0] {
            let c=Point(x:p.x-s*r*sin(h),y:p.y+s*r*cos(h))
            let d=Point(x:q.x-t*r*sin(e),y:q.y+t*r*cos(e))
            let separation=c.distance(to:d),offset=(t-s)*r
            guard separation>0.00001,abs(offset)<=separation else { continue }
            let phi=atan2(d.y-c.y,d.x-c.x)-asin(offset/separation)
            let first=wrap(s*(phi-h)),last=wrap(t*(e-phi))
            let straight=sqrt(max(0,separation*separation-offset*offset))
            let cost=(first+last)*r+straight
            if cost>=bestLength { continue }
            var points=arc(from:p,heading:h,angle:first,direction:s,radius:r)
            let a=points.last ?? p
            let b=Point(x:a.x+cos(phi)*straight,y:a.y+sin(phi)*straight)
            if straight>0.001 { points.append(b) }
            points += arc(from:b,heading:phi,angle:last,direction:t,radius:r)
            if let final=points.last,final.distance(to:q)<0.01 {
                points[points.count-1]=q;best=points;bestLength=cost
            }
        } }
        precondition(!best.isEmpty,"No tangent approach path")
        return best
    }
}
