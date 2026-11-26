import Foundation

enum ServiceKind: Int, CaseIterable, Hashable {
    case patrol = 1, fire, ambulance, followMe, fuel, catering, bus, pushback
    case baggageTractor, baggageCart, belt, stairs, water, lavatory, power, sweeper
    var assetName: String { String(format: "GroundService-%02d", rawValue) }
    var name: String {
        ["Patrol", "Fire engine", "Ambulance", "Follow-me", "Fuel tanker", "Catering", "Passenger bus", "Pushback tug", "Baggage tractor", "Baggage cart", "Belt loader", "Passenger stairs", "Water truck", "Lavatory truck", "Ground power", "Sweeper"][rawValue - 1]
    }
    var duration: Double {
        switch self {
        case .fire: return 16
        case .ambulance: return 18
        case .fuel: return 20
        case .catering: return 12
        case .bus: return 12
        case .stairs, .power: return 3
        case .pushback: return 3
        case .sweeper: return 14
        default: return 8
        }
    }
    var length: Double { (self == .pushback ? 9 : [.patrol, .followMe, .baggageTractor].contains(self) ? 10 : 16) * 0.55 }
    /// Normalized roof position measured in the supplied, nose-up sprite crop.
    var beaconY: Double {
        switch self {
        case .patrol, .ambulance: return 0.24
        case .fire: return 0.30
        case .followMe: return 0.47
        default: return 0.06
        }
    }
}

enum ServiceTarget: Hashable { case aircraft(String), incident(UUID) }
enum ServiceState: String { case queued = "Queued", travelling = "En route", working = "Working", returning = "Returning", done = "Complete", cancelled = "Cancelled" }
struct ServiceTask: Identifiable {
    let id = UUID()
    let kind: ServiceKind
    let target: ServiceTarget
    var state: ServiceState = .queued
    var remaining: Double
    var prepared = false
    var effectApplied = false
}
struct GroundVehicle: Identifiable {
    let kind: ServiceKind
    let id: Int
    let depot: Point
    var position: Point
    var heading = 0.0
    var route: [Point] = []
    var taskID: UUID?
    var waitingForAircraft = false
    var routeUnavailable = false
    var retryAt = 0.0
    var base = 0
    var baggageTractorID:Int?
    init(kind: ServiceKind, depot: Point, position: Point, id: Int? = nil) {
        self.kind = kind; self.depot = depot; self.position = position; self.id = id ?? kind.rawValue
    }
}
struct AirportIncident: Identifiable {
    let id = UUID()
    let position: Point // Fixed-image pixels, shared by effects and service routing.
    let runwayIDs: Set<Int>
    let aircraftIDs: [String]
    let time: Double
    var reopened = false
}

@MainActor
extension Simulation {
    var busyVehicleCount: Int { vehicles.filter { $0.taskID != nil }.count }
    func resetGroundServices() {
        serviceTasks = []; incidents = []
        vehicles=[]
        var inventory:[(Int,AirportServiceBase.Bay)]=[]
        for base in airport.serviceBases {for bay in base.bays {inventory.append((base.id,bay))}}
        inventory.sort {a,b in
            if a.1.role != b.1.role {return a.1.role<b.1.role}
            return a.1.id<b.1.id
        }
        for (base,bay) in inventory {
            let kind=ServiceKind(rawValue:bay.role)!
            var unit=GroundVehicle(kind:kind,depot:bay.position,position:bay.position,id:bay.id)
            unit.base=base;unit.heading=bay.heading;vehicles.append(unit)
        }
        for tractor in vehicles.filter({$0.kind == .baggageTractor}) {attachBaggageCart(to:tractor)}
        for stand in surface.gates.indices {
            let depot=roads.tugBay(stand)
            var unit=GroundVehicle(kind:.pushback,depot:depot,position:depot,id:10000+stand)
            unit.base=100+stand;vehicles.append(unit)
        }
    }
    private func attachBaggageCart(to tractor:GroundVehicle) {
        if let cart=vehicles.firstIndex(where:{$0.kind == .baggageCart && $0.base == tractor.base && $0.baggageTractorID == nil}) {
            vehicles[cart].baggageTractorID=tractor.id
            return
        }
        guard let bay=airport.serviceBases.first(where:{$0.id == tractor.base})?.bays.first(where:{$0.role == ServiceKind.baggageCart.rawValue}) else{return}
        var cart=GroundVehicle(kind:.baggageCart,depot:bay.position,position:bay.position,id:(vehicles.map(\.id).max() ?? 0)+1)
        cart.base=tractor.base;cart.heading=bay.heading;cart.baggageTractorID=tractor.id
        vehicles.append(cart)
    }
    func requiredServices(for flight: Aircraft) -> Set<ServiceKind> {
        Set((airport.serviceProfiles[flight.operatingPurpose.rawValue] ?? []).compactMap(ServiceKind.init(rawValue:)))
    }
    func enqueue(_ kind: ServiceKind, target: ServiceTarget) {
        guard !serviceTasks.contains(where: { $0.kind == kind && $0.target == target && (kind == .pushback ? ![.done,.cancelled,.returning].contains($0.state) : $0.state != .cancelled) }) else { return }
        serviceTasks.append(ServiceTask(kind: kind, target: target, remaining: {
            if case .aircraft(let id)=target,let flight=aircraft.first(where:{ $0.id==id }) {
                if kind == .bus { return flight.passengerUnloadDuration+flight.passengerLoadDuration }
                if kind == .fuel { return flight.refuelDuration }
                if kind == .belt || kind == .baggageCart { return 24 }
            }
            return kind.duration
        }()))
    }
    func effect(_ kind: ServiceKind, target: ServiceTarget) -> Bool {
        serviceTasks.contains { $0.kind == kind && $0.target == target && $0.effectApplied }
    }
    func prepared(_ kind: ServiceKind, target: ServiceTarget) -> Bool {
        serviceTasks.contains { $0.kind == kind && $0.target == target && $0.prepared && $0.state != .cancelled }
    }
    func serviceProgress(for flight: Aircraft) -> (done: Int, total: Int) {
        let required = requiredServices(for: flight)
        return (required.filter { effect($0, target: .aircraft(flight.id)) }.count, required.count)
    }
    func beginTurnaround(_ index: Int) {
        aircraft[index].phase = .servicing
        aircraft[index].readyToDepart=false
        aircraft[index].heading=surface.gates[aircraft[index].stand].heading
        aircraft[index].passengerUnloadRemaining=aircraft[index].passengerUnloadDuration
        aircraft[index].passengerLoadRemaining=aircraft[index].passengerLoadDuration
        aircraft[index].gateWaitRemaining=randomGateDwell()
        aircraft[index].stopped = false
        let target = ServiceTarget.aircraft(aircraft[index].id)
        for kind in requiredServices(for: aircraft[index]).sorted(by: { $0.rawValue < $1.rawValue }) { enqueue(kind, target: target) }
        log("\(aircraft[index].id): at stand. Ground services requested.")
    }
    func cancelStandServices(for flightID:String) {
        for j in serviceTasks.indices where serviceTasks[j].target == .aircraft(flightID) && serviceTasks[j].kind != .pushback && ![.done,.returning,.cancelled].contains(serviceTasks[j].state) {
            serviceTasks[j].state = .cancelled
            for v in vehicles.indices where vehicles[v].taskID==serviceTasks[j].id {
                vehicles[v].route=serviceRoute(from:vehicles[v].position,to:vehicles[v].depot,kind:vehicles[v].kind,taskID:vehicles[v].taskID)
                vehicles[v].routeUnavailable=vehicles[v].route.isEmpty && vehicles[v].position.distance(to:vehicles[v].depot)>1
                vehicles[v].retryAt=0
            }
        }
    }
    func serviceSelected() {
        guard let i = aircraft.firstIndex(where: { $0.id == selectedID }), aircraft[i].phase == .parked else { return }
        guard !serviceTasks.contains(where: { $0.target == .aircraft(aircraft[i].id) && $0.kind != .pushback }) else { return }
        beginTurnaround(i); startLive()
    }
    func incidentReady(_ incident: AirportIncident) -> Bool {
        [.patrol, .fire, .ambulance, .sweeper].allSatisfy { effect($0, target: .incident(incident.id)) }
    }
    func reopenRunway(_ runway: Int) {
        guard runways.indices.contains(runway), runways[runway].closed else { return }
        let relevant = incidents.filter { $0.runwayIDs.contains(runway) && !$0.reopened }
        guard relevant.allSatisfy(incidentReady) else { reject("Emergency crews must finish rescue, firefighting and debris clearance first."); return }
        runways[runway].closed = false
        for i in incidents.indices where incidents[i].runwayIDs.contains(runway) {
            if incidents[i].runwayIDs.allSatisfy({ !runways[$0].closed }) { incidents[i].reopened = true }
        }
        log("\(runways[runway].name): reopened by tower.")
    }
    private func targetPosition(_ target: ServiceTarget, kind: ServiceKind) -> Point? {
        switch target {
        case .aircraft(let id):
            guard let flight = aircraft.first(where: { $0.id == id }), flight.phase != .crashed else { return nil }
            let p = flight.position
            if kind == .pushback {return tugAttachmentPoint(for:flight)}
            if kind == .followMe { return p }
            let size=flight.model.length*flight.apparentScale
            let along:Double,side:Double
            switch kind {
            case .fuel: along = -2;side = size*0.30
            case .baggageTractor,.baggageCart: along = -12;side = -size*0.44
            case .belt: along = -4;side = -size*0.30
            case .stairs,.bus: along = size*0.28;side = -size*0.35
            case .power: along = size*0.30;side = size*0.27
            default: along = -size*0.25;side = size*0.4
            }
            return surface.offset(p,heading:flight.heading,along:along,side:side)
        case .incident(let id):
            guard let p = incidents.first(where: { $0.id == id })?.position else { return nil }
            let graph=roads.graph(for:kind)
            let angle=Double(kind.rawValue)*1.4
            return graph.closestPoint(to:Point(x:p.x+cos(angle)*20,y:p.y+sin(angle)*20))
        }
    }
    func tugAttachmentPoint(for flight:Aircraft)->Point {
        surface.offset(flight.position,heading:flight.heading,along:flight.model.length*flight.apparentScale*0.5+3)
    }
    func serviceRoute(from start:Point,to end:Point,kind:ServiceKind = .fire,taskID:UUID? = nil)->[Point] {
        var base=roads.graph(for:kind)
        base.split(at:start);base.split(at:end)
        let route=base.shortestPath(from:start,to:end,maximumAccessDistance:20,minimumWidth:kind.length*0.65)
        if kind == .pushback && route.isEmpty && start.distance(to:end)>1 {
            // Tugs may use the aircraft taxi lanes to reach a blocked apron
            // aircraft; the short attachment spur stays within nose/bay reach.
            let taxi=surface.taxiNetwork.shortestPath(from:start,to:end,maximumAccessDistance:30,minimumWidth:kind.length*0.65)
            if !taxi.isEmpty {return taxi}
            if let taskID,let task=serviceTasks.first(where:{$0.id==taskID}),case .aircraft(let id)=task.target,
               let flight=aircraft.first(where:{$0.id==id}),end.distance(to:tugAttachmentPoint(for:flight))<0.1 {
                let approach=base.shortestPath(from:start,to:flight.position,maximumAccessDistance:20,minimumWidth:kind.length*0.65)
                if !approach.isEmpty {return approach+[end]}
            }
        }
        return route
    }
    /// Service vehicles have right of way in the simplified game model. They
    /// pass through aircraft footprints and never wait or reroute around them.
    func vehicleBlocked(_ vehicle: GroundVehicle, from start: Point, to end: Point,parkedOnly:Bool=false) -> Bool {
        return false
    }
    private func moveVehicle(_ vehicle: inout GroundVehicle, distance: Double) {
        vehicle.waitingForAircraft=false
        var remaining=distance
        while remaining>0,let target=vehicle.route.first {
            let p=vehicle.position,d=p.distance(to:target)
            let step=min(d,remaining)
            if d<0.001 { vehicle.route.removeFirst();continue }
            let next=Point(x:p.x+(target.x-p.x)*step/d,y:p.y+(target.y-p.y)*step/d)
            vehicle.heading=atan2(target.y-p.y,target.x-p.x);vehicle.position=next;remaining-=step
            if step>=d { vehicle.route.removeFirst() }
        }
    }
    private func workAllowed(_ task: ServiceTask) -> Bool {
        if case .incident = task.target {
            return task.kind != .sweeper || [.patrol, .fire, .ambulance].allSatisfy { effect($0, target: task.target) }
        }
        guard case .aircraft(let id) = task.target, let flight = aircraft.first(where: { $0.id == id }) else { return false }
        let required = requiredServices(for: flight)
        func done(_ kind: ServiceKind) -> Bool { !required.contains(kind) || effect(kind, target: task.target) }
        func ready(_ kind: ServiceKind) -> Bool { !required.contains(kind) || prepared(kind, target: task.target) }
        switch task.kind {
        case .bus: return ready(.stairs)
        case .catering: return ready(.power)
        case .fuel, .water, .lavatory: return done(.bus)
        case .belt: return ready(.baggageCart) && ready(.stairs)
        case .baggageCart: return ready(.belt)
        case .sweeper: return required.subtracting([.power, .sweeper]).allSatisfy(done)
        default: return true
        }
    }
    private func finishWork(_ j: Int, vehicle: inout GroundVehicle) {
        serviceTasks[j].effectApplied = true
        serviceTasks[j].state = .returning
        vehicle.route = serviceRoute(from: vehicle.position, to: vehicle.depot,kind:vehicle.kind,taskID:vehicle.taskID)
        vehicle.routeUnavailable=vehicle.route.isEmpty && vehicle.position.distance(to:vehicle.depot)>1
        if case .aircraft(let id) = serviceTasks[j].target, let i = aircraft.firstIndex(where: { $0.id == id }) {
            switch serviceTasks[j].kind {
            case .fuel: aircraft[i].fuelFraction = 1
            case .bus: aircraft[i].passengersHandled = true
            case .belt: aircraft[i].baggageHandled = true
            case .catering: aircraft[i].cateringReady = true
            case .water: aircraft[i].waterReady = true
            case .lavatory: aircraft[i].sanitationReady = true
            case .power: aircraft[i].powerConnected = false
            default: break
            }
        }
    }
    func updateGroundServices(_ dt: Double) {
        for flight in aircraft where flight.recoveringGround && !flight.underTow && !flight.stopped {
            enqueue(.pushback,target:.aircraft(flight.id))
        }
        for j in serviceTasks.indices where serviceTasks[j].state == .queued {
            if targetPosition(serviceTasks[j].target, kind: serviceTasks[j].kind) == nil { serviceTasks[j].state = .cancelled }
        }
        // Service fleets grow with ready demand. Each extra unit starts at the
        // nearest authored bay for its role, preserving its home base for return.
        let scalable=Set(serviceTasks.indices.filter{serviceTasks[$0].state == .queued && serviceTasks[$0].kind != .pushback && serviceTasks[$0].kind != .baggageCart && workAllowed(serviceTasks[$0])}.map{serviceTasks[$0].kind})
        for kind in scalable {
            let queued=serviceTasks.indices.filter{serviceTasks[$0].kind == kind && serviceTasks[$0].state == .queued && workAllowed(serviceTasks[$0])}.count
            let idle=vehicles.filter{$0.kind == kind && $0.taskID == nil && $0.retryAt<=elapsed}.count
            guard idle<queued else{continue}
            let bases=airport.serviceBases.compactMap{base -> (Int,Point)? in
                guard let bay=base.bays.first(where:{$0.role==kind.rawValue}) else{return nil}
                return(base.id,bay.position)
            }
            guard !bases.isEmpty else{continue}
            for _ in idle..<queued {
                let target=serviceTasks.first(where:{$0.kind == kind && $0.state == .queued && workAllowed($0)}).flatMap{targetPosition($0.target,kind:kind)} ?? bases[0].1
                let home=bases.min{$0.1.distance(to:target)<$1.1.distance(to:target)}!
                let id=(vehicles.map(\.id).max() ?? 0)+1
                var unit=GroundVehicle(kind:kind,depot:home.1,position:home.1,id:id);unit.base=home.0
                vehicles.append(unit)
                if kind == .baggageTractor {attachBaggageCart(to:unit)}
            }
        }
        for i in vehicles.indices where vehicles[i].kind != .baggageCart {
            var unit = vehicles[i]
            if unit.retryAt>elapsed {vehicles[i]=unit;continue}
            if unit.routeUnavailable,let task=unit.taskID,let j=serviceTasks.firstIndex(where:{$0.id==task}),[.returning,.cancelled].contains(serviceTasks[j].state) {
                unit.route=serviceRoute(from:unit.position,to:unit.depot,kind:unit.kind,taskID:task)
                unit.routeUnavailable=unit.route.isEmpty && unit.position.distance(to:unit.depot)>1
                if unit.routeUnavailable {unit.retryAt=elapsed+2;vehicles[i]=unit;continue}
            }
            if unit.kind == .baggageTractor && unit.taskID == nil && vehicles.contains(where:{$0.kind == .baggageCart && $0.baggageTractorID == unit.id && $0.taskID != nil}) {vehicles[i]=unit;continue}
            if unit.taskID == nil {
                let candidates = serviceTasks.indices.filter { serviceTasks[$0].kind == unit.kind && serviceTasks[$0].state == .queued && workAllowed(serviceTasks[$0]) }
                // Tugs claim the nearest queued aircraft; remote tugs do not steal local work.
                let nearestJob = candidates.min { a,b in
                    let pa = targetPosition(serviceTasks[a].target,kind:unit.kind) ?? unit.position
                    let pb = targetPosition(serviceTasks[b].target,kind:unit.kind) ?? unit.position
                    return unit.position.distance(to:pa) < unit.position.distance(to:pb)
                }
                if let j = nearestJob, let target = targetPosition(serviceTasks[j].target, kind: unit.kind) {
                    let route=serviceRoute(from:unit.position,to:target,kind:unit.kind,taskID:serviceTasks[j].id)
                    unit.routeUnavailable=route.isEmpty && unit.position.distance(to:target)>1
                    if unit.routeUnavailable {unit.retryAt=elapsed+2}
                    if !unit.routeUnavailable { unit.taskID=serviceTasks[j].id;unit.route=route;serviceTasks[j].state = .travelling }
                }
            }
            guard let id = unit.taskID, let j = serviceTasks.firstIndex(where: { $0.id == id }) else {
                // Ready vehicles remain in their assigned parking bays.
                vehicles[i] = unit; continue
            }
            if targetPosition(serviceTasks[j].target, kind: unit.kind) == nil && serviceTasks[j].state != .returning {
                serviceTasks[j].state = .cancelled
                unit.route = serviceRoute(from: unit.position, to: unit.depot,kind:unit.kind,taskID:unit.taskID)
                unit.routeUnavailable=unit.route.isEmpty && unit.position.distance(to:unit.depot)>1
            }
            if [.travelling, .returning, .cancelled].contains(serviceTasks[j].state) {
                moveVehicle(&unit, distance: (unit.kind == .ambulance || unit.kind == .fire ? 70 : 45) * dt)
                if unit.route.isEmpty && !unit.routeUnavailable {
                    if serviceTasks[j].state == .travelling { serviceTasks[j].state = .working }
                    else { if serviceTasks[j].state != .cancelled { serviceTasks[j].state = .done }; unit.taskID = nil }
                }
            }
            if serviceTasks[j].state == .working {
                let task = serviceTasks[j]
                if task.kind == .followMe, case .aircraft(let flightID) = task.target, let f = aircraft.firstIndex(where: { $0.id == flightID }) {
                    serviceTasks[j].prepared = true
                    if aircraft[f].phase == .awaitingEscort {
                        guard startArrivalTaxi(f) else {unit.waitingForAircraft=true;vehicles[i]=unit;continue}
                    }
                    let flight = aircraft[f], p = flight.position
                    let ahead = Point(x: flight.position.x + cos(flight.heading)*2, y: flight.position.y + sin(flight.heading)*2)
                    unit.heading = atan2(ahead.y-p.y,ahead.x-p.x)
                    unit.position = ahead
                    if flight.phase != .taxiing && flight.phase != .awaitingEscort { finishWork(j, vehicle: &unit) }
                } else if task.kind == .pushback, case .aircraft(let flightID) = task.target, let f = aircraft.firstIndex(where: { $0.id == flightID }) {
                    serviceTasks[j].remaining -= dt
                    if serviceTasks[j].remaining <= 0 { serviceTasks[j].prepared = true; aircraft[f].underTow = true }
                    let target = tugAttachmentPoint(for:aircraft[f])
                    unit.heading=aircraft[f].heading
                    unit.position = target
                    if aircraft[f].phase != .pushback { aircraft[f].underTow = false; finishWork(j, vehicle: &unit) }
                } else if task.kind == .baggageTractor {
                    serviceTasks[j].prepared = true
                    if effect(.belt, target: task.target) && effect(.baggageCart, target: task.target) { finishWork(j, vehicle: &unit) }
                } else if workAllowed(task) {
                    serviceTasks[j].remaining = max(0, task.remaining - dt)
                    if case .aircraft(let id) = task.target, let f = aircraft.firstIndex(where: { $0.id == id }), task.kind == .fuel {
                        aircraft[f].fuelFraction = min(1, aircraft[f].fuelFraction + dt * 0.55 / aircraft[f].refuelDuration)
                    }
                    if case .aircraft(let id)=task.target,let f=aircraft.firstIndex(where:{ $0.id==id }),task.kind == .bus {
                        if aircraft[f].passengerUnloadRemaining>0 { aircraft[f].passengerUnloadRemaining=max(0,aircraft[f].passengerUnloadRemaining-dt) }
                        else { aircraft[f].passengerLoadRemaining=max(0,aircraft[f].passengerLoadRemaining-dt) }
                    }
                    if serviceTasks[j].remaining <= 0 {
                        serviceTasks[j].prepared = true
                        if task.kind == .power {
                            if case .aircraft(let id) = task.target, let f = aircraft.firstIndex(where: { $0.id == id }) {
                                aircraft[f].powerConnected = true
                                if requiredServices(for: aircraft[f]).subtracting([.power]).allSatisfy({ effect($0, target: task.target) }) { finishWork(j, vehicle: &unit) }
                            }
                        } else if task.kind == .stairs {
                            if effect(.bus, target: task.target) && effect(.catering, target: task.target) { finishWork(j, vehicle: &unit) }
                        } else { finishWork(j, vehicle: &unit) }
                    }
                }
            }
            if !surface.routes.nodes.contains(where:{$0.layer == .services}) && !AirportFence.contains(unit.position,polygon:surface.routes.boundary) { unit.position=vehicles[i].position;unit.routeUnavailable=true }
            vehicles[i] = unit
        }
        updateBaggageCart(dt)
        for i in aircraft.indices where aircraft[i].phase == .servicing {
            let progress = serviceProgress(for: aircraft[i])
            if progress.done == progress.total {
                aircraft[i].phase = .gateWait
                if !aircraft[i].departure && !aircraft[i].arrivalHandled { resolved += 1;aircraft[i].arrivalHandled=true }
                log("\(aircraft[i].id): turnaround complete. Waiting at \(surface.gates[aircraft[i].stand].name).")
            }
        }
    }
    func updateGateReadiness(_ dt: Double) {
        for i in aircraft.indices where aircraft[i].phase == .gateWait {
            aircraft[i].gateWaitRemaining=max(0,aircraft[i].gateWaitRemaining-dt)
            let target=ServiceTarget.aircraft(aircraft[i].id)
            let clear=serviceTasks.filter { $0.target==target }.allSatisfy { [.done,.cancelled].contains($0.state) }
            if aircraft[i].gateWaitRemaining<=0 && clear {
                if !aircraft[i].departure {assignDepartureAirports(i)}
                aircraft[i].departure=true;aircraft[i].phase = .parked;aircraft[i].readyToDepart=true
                log("\(aircraft[i].id): ready for pushback at \(surface.gates[aircraft[i].stand].name).")
            }
        }
    }
    private func updateBaggageCart(_ dt: Double) {
        for c in vehicles.indices where vehicles[c].kind == .baggageCart {
            guard let t=vehicles.firstIndex(where:{$0.kind == .baggageTractor && $0.id == vehicles[c].baggageTractorID}) else{continue}
        var cart = vehicles[c]
        if let tractorID = vehicles[t].taskID, let tj = serviceTasks.firstIndex(where: { $0.id == tractorID }),
           let j = serviceTasks.firstIndex(where: { $0.kind == .baggageCart && $0.target == serviceTasks[tj].target && ![.done, .cancelled].contains($0.state) }) {
            cart.taskID = serviceTasks[j].id
            cart.position = Point(x: vehicles[t].position.x - cos(vehicles[t].heading) * 8, y: vehicles[t].position.y - sin(vehicles[t].heading) * 8)
            cart.heading = vehicles[t].heading
            if serviceTasks[tj].prepared {
                serviceTasks[j].prepared = true
                if !serviceTasks[j].effectApplied && workAllowed(serviceTasks[j]) {
                    serviceTasks[j].state = .working; serviceTasks[j].remaining -= dt
                    if serviceTasks[j].remaining <= 0 { serviceTasks[j].effectApplied = true }
                }
                if serviceTasks[tj].state == .returning { serviceTasks[j].state = .returning }
            } else { serviceTasks[j].state = .travelling }
        } else if let id = cart.taskID, let j = serviceTasks.firstIndex(where: { $0.id == id }) {
            if cart.route.isEmpty {cart.route=serviceRoute(from:cart.position,to:cart.depot,kind:cart.kind,taskID:cart.taskID)}
            cart.routeUnavailable=cart.route.isEmpty && cart.position.distance(to:cart.depot)>0.1
            moveVehicle(&cart,distance:45*dt)
            if cart.position.distance(to:cart.depot)<0.1 {
                if serviceTasks[j].state != .cancelled {serviceTasks[j].state = .done}
                cart.taskID=nil
            }
        }
        vehicles[c] = cart
        }
    }
}

/// Authored, bidirectional service lanes measured on the fixed airport image.
/// Connections and edge lengths form a native weighted graph; no genetic search
/// is needed for this deterministic shortest-path problem.
@MainActor final class AirportServiceRoads {
    let surface:AirportSurface
    var definition:AirportDefinition {surface.definition}
    private var graphCache:[Int:RoadGraph]=[:]
    init(surface:AirportSurface) {self.surface=surface}
    func tugBay(_ stand:Int)->Point {surface.routes.pins.first{$0.id=="tug-\(stand)"}?.point ?? definition.stands[stand].tugBay}
    func parkingBay(_ kind:ServiceKind,base:Int)->Point {definition.serviceBases.first{$0.id==base}!.bays.first{$0.role==kind.rawValue}!.position}
    func depot(for kind:ServiceKind)->Point {kind == .pushback ? tugBay(0):definition.serviceBases.flatMap(\.bays).first{$0.role==kind.rawValue}!.position}
    private func addingBases(to original:RoadGraph)->RoadGraph {
        var graph=original
        for base in definition.serviceBases {
            graph.split(at:base.connection);graph.addLane([base.connection,base.entry])
            for lane in base.accessLanes {graph.addLane(lane)}
        }
        return graph
    }
    var network:RoadGraph {graph(for:.fire)}
    var builtInNetwork:RoadGraph {surface.operational.graph(layer:.services,role:ServiceKind.fire.rawValue)}
    func graph(for kind:ServiceKind)->RoadGraph {
        if let cached=graphCache[kind.rawValue] {return cached}
        let graph=addingBases(to:surface.operational.graph(layer:.services,role:kind.rawValue));graphCache[kind.rawValue]=graph;return graph
    }
}
@MainActor enum ServiceRoads {
    private static var cache:(Int,AirportServiceRoads)?
    private static var legacy:AirportServiceRoads {
        if let c=cache,c.0==RoutingOverrides.revision {return c.1}
        let roads=AirportServiceRoads(surface:SurfaceLayout.legacy);cache=(RoutingOverrides.revision,roads);return roads
    }
    static func tugBay(_ stand:Int)->Point {legacy.tugBay(stand)}
    static func parkingBay(_ kind:ServiceKind,base:Int)->Point {legacy.parkingBay(kind,base:base)}
    static func depot(for kind:ServiceKind)->Point {legacy.depot(for:kind)}
    static var network:RoadGraph {legacy.network}
    static var builtInNetwork:RoadGraph {legacy.builtInNetwork}
    static func graph(for kind:ServiceKind)->RoadGraph {legacy.graph(for:kind)}
}

struct RoadGraph {
    struct Edge {
        var a:Int;var b:Int
        var sourceIDs:[Int]=[]
        var kind:RouteLaneKind = .taxiway
        var direction:RouteDirection = .both
        var access:[Int]=[]
        var width:Double? = nil
        var maxWingspan:Double? = nil
        var speedLimit:Double? = nil
        var runwayIDs=Set<Int>()
        func permits(from node:Int)->Bool {direction == .both || (direction == .forward && node==a) || (direction == .reverse && node==b)}
        func fits(_ span:Double)->Bool {(width == nil || span<=width!+0.001) && (maxWingspan == nil || span<=maxWingspan!+0.001)}
    }
    var nodes:[Point]=[]
    var edges:[Edge]=[]
    var sourceNodeIDs:[Int:[Int]]=[:]
    var turnRules:[RouteTurn]=[]
    var junctionRules:[RouteJunction]=[]
    var waitPermissions:[Int:Bool]=[:]
    var holdingAreas:[Int:Double]=[:]
    var conflicts:[OperationalConflict]=[]
    var hasRestrictions:Bool {!turnRules.isEmpty || junctionRules.contains{$0.mode == .conflictOnly} || edges.contains{$0.direction != .both || $0.width != nil || $0.maxWingspan != nil}}
    func canWait(at node:Int)->Bool {waitPermissions[node] ?? true}
    func canTurn(incoming:Int,outgoing:Int,at node:Int)->Bool {
        guard incoming>=0 else{return true}
        let one=edges[incoming],two=edges[outgoing]
        let ids=sourceNodeIDs[node] ?? []
        let rules=turnRules.filter{r in ((r.nodeID.map{ids.contains($0)} ?? false) || (r.point.map{$0.distance(to:nodes[node])<0.01} ?? false)) && one.sourceIDs.contains(r.fromEdgeID)}
        if rules.contains(where:{!$0.allowed && two.sourceIDs.contains($0.toEdgeID)}) {return false}
        let allowed=rules.filter(\.allowed)
        if !allowed.isEmpty && !allowed.contains(where:{two.sourceIDs.contains($0.toEdgeID)}) {return false}
        if let rule=junctionRules.first(where:{$0.mode == .conflictOnly && $0.point.distance(to:nodes[node])<0.01 && ($0.edgeIDs==nil || (!Set(one.sourceIDs).isDisjoint(with:$0.edgeIDs!) && !Set(two.sourceIDs).isDisjoint(with:$0.edgeIDs!)))}) {
            _ = rule
            let from=nodes[one.a==node ? one.b:one.a],to=nodes[two.a==node ? two.b:two.a],p=nodes[node]
            let dot=(p.x-from.x)*(to.x-p.x)+(p.y-from.y)*(to.y-p.y)
            if dot/max(0.00001,from.distance(to:p)*p.distance(to:to))<0.999 {return false}
        }
        return true
    }
    func removingIsolatedNodes()->RoadGraph {
        var graph=self
        let used=Set(edges.flatMap{[$0.a,$0.b]}),order=nodes.indices.filter{used.contains($0)}
        let remap=Dictionary(uniqueKeysWithValues:order.enumerated().map{($0.element,$0.offset)})
        graph.nodes=order.map{nodes[$0]}
        graph.edges=edges.map{e in var v=e;v.a=remap[e.a]!;v.b=remap[e.b]!;return v}
        graph.sourceNodeIDs=Dictionary(uniqueKeysWithValues:sourceNodeIDs.compactMap{k,v in remap[k].map{($0,v)}})
        graph.waitPermissions=Dictionary(uniqueKeysWithValues:waitPermissions.compactMap{k,v in remap[k].map{($0,v)}})
        graph.holdingAreas=Dictionary(uniqueKeysWithValues:holdingAreas.compactMap{k,v in remap[k].map{($0,v)}})
        return graph
    }
    mutating func addLane(_ points:[Point]) {
        let ids=points.map{p->Int in if let i=nodes.firstIndex(where:{$0.distance(to:p)<0.01}) {return i};nodes.append(p);return nodes.count-1}
        for (a,b) in zip(ids,ids.dropFirst()) where a != b {
            if !edges.contains(where:{($0.a==a && $0.b==b)||($0.a==b && $0.b==a)}) {edges.append(.init(a:a,b:b))}
        }
    }
    @discardableResult mutating func split(at p:Point)->Int? {
        guard let e=closestEdge(to:p),projection(p,onto:edges[e]).distance(to:p)<2.1 else{return nil}
        return splitEdge(e,at:projection(p,onto:edges[e]))
    }
    private mutating func splitEdge(_ index:Int,at point:Point)->Int {
        let edge=edges[index]
        if nodes[edge.a].distance(to:point)<0.001 {return edge.a}
        if nodes[edge.b].distance(to:point)<0.001 {return edge.b}
        let id=nodes.count;nodes.append(point)
        var first=edge,second=edge;first.b=id;second.a=id
        edges[index]=first;edges.append(second)
        waitPermissions[id] = edge.kind != .runway && edge.kind != .runwayCrossing && !conflicts.contains{$0.point.distance(to:point)<0.01}
        return id
    }
    mutating func attach(_ p:Point,maximumAccessDistance:Double)->Int? {
        guard let e=closestEdge(to:p) else{return nil}
        let inherited=edges[e]
        let q=projection(p,onto:inherited);guard q.distance(to:p)<=maximumAccessDistance else{return nil}
        let id=splitEdge(e,at:q)
        if q.distance(to:p)<0.000001 {return id}
        let access=nodes.count;nodes.append(p)
        var spur=inherited;spur.a=access;spur.b=id;spur.direction = .both;spur.kind = .standAccess
        edges.append(spur);return access
    }
    func projection(_ p:Point,onto edge:Edge)->Point {
        let a=nodes[edge.a],b=nodes[edge.b],dx=b.x-a.x,dy=b.y-a.y
        let t=min(1,max(0,((p.x-a.x)*dx+(p.y-a.y)*dy)/max(0.0001,dx*dx+dy*dy)))
        return Point(x:a.x+t*dx,y:a.y+t*dy)
    }
    func closestEdge(to p:Point)->Int? {
        var best:Int?,distance=Double.infinity
        for i in edges.indices {
            let next=projection(p,onto:edges[i]).distance(to:p)
            if next<distance {best=i;distance=next}
        }
        return best
    }
    func closestPoint(to p:Point)->Point? {guard let i=closestEdge(to:p) else{return nil};return projection(p,onto:edges[i])}
    func shortestPath(from start:Point,to end:Point,maximumAccessDistance:Double = .infinity,minimumWidth:Double=0,edgeDelay:((Point,Point,Double)->Double)?=nil,initialHeading:Double?=nil,turnPenalty:Double=0)->[Point] {
        var graph=self
        graph.edges=graph.edges.filter{$0.fits(minimumWidth)}
        guard let si=graph.attach(start,maximumAccessDistance:maximumAccessDistance),let ei=graph.attach(end,maximumAccessDistance:maximumAccessDistance) else{return []}
        struct Key:Hashable {let node:Int;let edge:Int}
        struct Label {let key:Key;let parent:Int?;let cost:Double}
        var adjacency=Array(repeating:[(Int,Int,Double)](),count:graph.nodes.count)
        for (i,e) in graph.edges.enumerated() where e.fits(minimumWidth) {
            let d=graph.nodes[e.a].distance(to:graph.nodes[e.b])
            if e.permits(from:e.a) {adjacency[e.a].append((e.b,i,d))}
            if e.permits(from:e.b) {adjacency[e.b].append((e.a,i,d))}
        }
        var labels=[Label(key:Key(node:si,edge:-1),parent:nil,cost:0)],best=[Key(node:si,edge:-1):0.0],heap:[(Int,Double)]=[(0,0)]
        func push(_ item:(Int,Double)) {heap.append(item);var i=heap.count-1;while i>0 {let p=(i-1)/2;if heap[p].1<=heap[i].1 {break};heap.swapAt(i,p);i=p}}
        func pop()->(Int,Double)? {
            guard !heap.isEmpty else{return nil};if heap.count==1 {return heap.removeLast()}
            let top=heap[0];heap[0]=heap.removeLast();var i=0
            while i*2+1<heap.count {var c=i*2+1;if c+1<heap.count && heap[c+1].1<heap[c].1 {c+=1};if heap[i].1<=heap[c].1 {break};heap.swapAt(i,c);i=c};return top
        }
        while let (index,cost)=pop() {
            let label=labels[index],u=label.key.node
            if cost>(best[label.key] ?? .infinity) {continue}
            if u==ei {
                var result:[Point]=[],cursor:Int?=index
                while let i=cursor {result.append(graph.nodes[labels[i].key.node]);cursor=labels[i].parent}
                var route:[Point]=[]
                for p in result.reversed() where p.distance(to:route.last ?? start)>0.01 {route.append(p)}
                return route
            }
            for (v,edge,d) in adjacency[u] where graph.canTurn(incoming:label.key.edge,outgoing:edge,at:u) {
                var turning=0.0
                let outgoing=atan2(graph.nodes[v].y-graph.nodes[u].y,graph.nodes[v].x-graph.nodes[u].x)
                let incoming:Double?
                if let parent=label.parent {
                    let prior=graph.nodes[labels[parent].key.node]
                    // A tiny projection spur from a rounded exit is not the
                    // aircraft's incoming direction along the taxiway.
                    if graph.nodes[u].distance(to:prior)<2 && labels[parent].parent==nil {incoming=initialHeading}
                    else {incoming=atan2(graph.nodes[u].y-prior.y,graph.nodes[u].x-prior.x)}
                } else {incoming=initialHeading}
                if let incoming,turnPenalty>0 {
                    let angle=abs(atan2(sin(outgoing-incoming),cos(outgoing-incoming)))
                    turning=angle*turnPenalty+(angle>2.1 ? turnPenalty*12:0)
                }
                let next=cost+d+turning+max(0,edgeDelay?(graph.nodes[u],graph.nodes[v],cost) ?? 0),key=Key(node:v,edge:edge)
                if next<(best[key] ?? .infinity) {best[key]=next;labels.append(.init(key:key,parent:index,cost:next));push((labels.count-1,next))}
            }
        }
        return []
    }
}

@MainActor extension Simulation {
    func gateStatus(for flight: Aircraft) -> String {
        if flight.phase == .gateWait { return flight.gateWaitRemaining>0 ? "GATE WAIT · \(Int(ceil(flight.gateWaitRemaining)))s" : "Waiting for crews to clear" }
        let target=ServiceTarget.aircraft(flight.id)
        if !effect(.bus,target:target) && requiredServices(for:flight).contains(.bus) {
            let active=serviceTasks.contains { $0.target==target && $0.kind == .bus && $0.state == .working }
            if !active { return "Passengers · waiting for stairs / bus" }
            if flight.passengerUnloadRemaining>0 { return "UNLOADING · \(Int(ceil(flight.passengerUnloadRemaining)))s" }
            return "BOARDING · \(Int(ceil(flight.passengerLoadRemaining)))s"
        }
        if let fuel=serviceTasks.first(where:{ $0.target==target && $0.kind == .fuel && !$0.effectApplied }) {
            return "REFUELLING · \(Int(ceil(fuel.remaining)))s · \(Int(flight.fuelFraction*100))%"
        }
        if !effect(.belt,target:target) && requiredServices(for:flight).contains(.belt) { return "Baggage handling" }
        return "Final ground checks"
    }
}
