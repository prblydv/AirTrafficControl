import Foundation

@main struct CoreEngineChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let doc=try JSONDecoder().decode(AirportRouteDocument.self,from:Data(contentsOf:root.appendingPathComponent("AirTrafficControl/airport-routes.json")))
        try RoutingOverrides.activate(doc,persist:false)
        precondition(doc.problems().isEmpty)
        let sim=Simulation(seed:17,continuousTraffic:false)
        precondition(SurfaceLayout.gates.count==19 && sim.aircraft.count==12)
        for f in sim.aircraft {
            precondition(SurfaceLayout.gates[f.stand].accepts(f.model))
            precondition(f.runway != nil && SurfaceLayout.eligible(f.model,runway:f.runway!))
            precondition(!f.origin.isEmpty && !f.destination.isEmpty && f.origin != f.destination)
        }
        precondition(!SurfaceLayout.eligible(AircraftCatalog.model("01"),runway:2))
        precondition(!SurfaceLayout.eligible(AircraftCatalog.model("06"),runway:2))
        precondition(SurfaceLayout.eligible(AircraftCatalog.model("14"),runway:2))
        precondition(sim.vehicles.filter{$0.kind == .fuel}.count==2 && sim.vehicles.filter{$0.kind == .baggageTractor}.count==2)
        print("PASS: approved19stands, compatible12aircraft, origins/destinations, assigned runways and local service fleets")
        for f in sim.aircraft {
            let gate=SurfaceLayout.gates[f.stand]
            if gate.position.x>1000 && !gate.military {precondition(sim.clearanceRunways(for:f).allSatisfy{$0.id==0 || $0.id==2})}
            let r=sim.clearanceRunways(for:f)[0].id
            let entry=SurfaceLayout.departureEntry(for:f.model,runway:r,from:gate.port)
            let path=SurfaceLayout.taxiRoute(from:gate.port,to:entry.hold)
            print("ROUTE",gate.name,r,path.count,entry.hold,entry.lineup)
            precondition(!path.isEmpty,"Disconnected stand/runway")
        }
        print("PASS: departure route access and north-terminal restrictions")
        // Every local service must physically work and return, across both terminals and military apron.
        for stand in [0,12,18] {
            let gate=SurfaceLayout.gates[stand]
            let model=stand==18 ? "17" : stand==0 ? "14" : "07"
            let s=Simulation(seed:17,continuousTraffic:false)
            s.aircraft=[Aircraft(id:"SERVICE",modelID:model,departure:false,stand:stand,position:gate.position,heading:gate.heading,phase:.parked,runway:0)]
            s.selectedID="SERVICE";s.beginTurnaround(0);s.running=true
            for _ in 0..<16000 {
                s.tick(0.1)
                if s.aircraft[0].readyToDepart && s.busyVehicleCount==0 {break}
            }
            if !s.aircraft[0].readyToDepart {
                print("SERVICE STUCK",stand,s.aircraft[0].phase,s.gateStatus(for:s.aircraft[0]))
                for t in s.serviceTasks {print(t.kind,t.state,t.prepared,t.effectApplied,t.remaining)}
                for v in s.vehicles where v.taskID != nil || v.routeUnavailable {print("UNIT",v.kind,v.base,v.position,v.route.count,v.routeUnavailable,v.waitingForAircraft)}
            }
            precondition(s.aircraft[0].readyToDepart && s.busyVehicleCount==0,"Turnaround did not finish")
            for v in s.vehicles {if v.position.distance(to:v.depot)>=0.1 {print("HOMEFAIL",v.kind,v.base,v.position,v.depot)};precondition(v.position.distance(to:v.depot)<0.1,"Vehicle did not return home")}
            precondition(s.aircraft[0].fuelFraction==1 && s.resolved==1)
            print("PASS: full service + home return",gate.name)
        }
        func advance(_ s:Simulation,seconds:Double=1600,until done:()->Bool)->Bool {
            for _ in 0..<Int(seconds*10) {
                if done(){return true}
                if s.selected?.crossingRequest != nil {s.approveCrossing()}
                let old=s.aircraft;s.tick(0.1)
                for (a,b) in zip(old,s.aircraft) {precondition(a.position.distance(to:b.position)<6.5,"Position jumped")}
            }
            return done()
        }
        let live=Simulation(seed:UInt64(CommandLine.arguments.dropFirst().first ?? "17") ?? 17,continuousTraffic:false)
        for i in 0..<3 {live.aircraft[i].stopped=true}
        for id in live.aircraft.filter({$0.departure}).map(\.id) {
            live.selectedID=id
            let options=live.clearanceRunways(for:live.selected!)
            for runway in options {live.clearSelected(to:runway.id);if live.selected!.phase != .parked {break}}
            let reached=advance(live) {live.selected!.phase == .queued}
            if !reached {print("DEPARTURE STUCK",id,live.selected!.phase,live.selected!.position,live.selected!.waitingForTraffic,live.notice,"FLAGS",live.selected!.groundSpeed,live.selected!.crossingRequest as Any,live.selected!.crossingClearances,live.selected!.crossingsEntered,live.selected!.route.prefix(3),live.selected!.stopped,live.running)
                let f=live.selected!,g=SurfaceLayout.gates[f.stand]
                for r in options {
                    let en=SurfaceLayout.departureEntry(for:f.model,runway:r.id,from:g.port);let raw=SurfaceLayout.taxiRoute(from:g.port,to:en.hold)
                    for other in live.aircraft where !other.airborne && other.phase != .complete && other.id != id {
                        let hits=zip([g.port]+raw,raw).filter {live.groundConflict(f,from:$0.0,to:$0.1,other:other,margin:1)}
                        if !hits.isEmpty {print("BLOCKEDBY",other.id,"runway",r.id,"hits",hits.prefix(2))}
                    }
                }}
            precondition(reached,"Departure failed to reach runway")
            live.clearSelected(to:live.selected!.runway!)
            precondition(advance(live,seconds:240){live.selected!.phase == .complete},"Takeoff/climb failed")
            print("PASS: traced pushback/taxi/crossing/takeoff/climb",id)
        }
        for id in live.aircraft.filter({!$0.departure}).map(\.id) {
            live.selectedID=id
            if let i=live.aircraft.firstIndex(where:{$0.id==id}) {live.aircraft[i].stopped=false}
            live.clearSelected(to:live.selected!.runway!)
            let ready=advance(live,seconds:2200) {live.selected!.readyToDepart}
            if !ready {print("ARRIVAL STUCK",id,live.selected!.phase,live.selected!.position,live.notice);for v in live.vehicles where v.taskID != nil || v.routeUnavailable {print("UNIT",v.kind,v.base,v.position,v.routeUnavailable,v.waitingForAircraft)}}
            precondition(ready,"Arrival to ready failed")
            for runway in live.clearanceRunways(for:live.selected!) {live.clearSelected(to:runway.id);if live.selected!.phase != .parked {break}}
            precondition(advance(live){live.selected!.phase == .queued})
            live.clearSelected(to:live.selected!.runway!)
            precondition(advance(live,seconds:240){live.selected!.phase == .complete})
            print("PASS: full assigned arrival/turnaround/return departure",id)
        }
        precondition(live.violations==0 && live.resolved==15)
        print("PASS: complete15movement shift without incidents")
        let parallel=Simulation(seed:17,continuousTraffic:false)
        for i in 0..<3 {parallel.aircraft[i].stopped=true}
        parallel.running=true
        for step in 0..<24000 {
            let work=parallel.aircraft.filter{$0.departure && $0.phase != .complete}
            if work.isEmpty {break}
            for f in work {
                parallel.selectedID=f.id
                if f.phase == .parked && step%50==0 {
                    for r in parallel.clearanceRunways(for:f) {parallel.clearSelected(to:r.id);if parallel.selected!.phase != .parked {break}}
                }
                if f.crossingRequest != nil {
                    let active=parallel.aircraft.contains {a in a.id != f.id && a.runway==f.crossingRequest && ([.takeoff,.landing,.approach].contains(a.phase) || (a.phase == .climbing && a.altitude<500))}
                    if !active {parallel.approveCrossing()}
                }
                if f.phase == .queued {
                    let active=parallel.aircraft.contains {a in a.id != f.id && a.runway==f.runway && ([.takeoff,.landing,.approach].contains(a.phase) || (a.phase == .climbing && a.altitude<500))}
                    if !active {parallel.clearSelected(to:f.runway!)}
                }
            }
            parallel.tick(0.1)
        }
        let unfinished=parallel.aircraft.filter{$0.departure && $0.phase != .complete}
        if !unfinished.isEmpty {for f in unfinished {print("PARALLEL STUCK",f.id,f.phase,f.position,f.waitingForTraffic,f.crossingRequest as Any,"BLOCK",f.blockedBy as Any,f.blockedSince as Any,f.recoveringGround,f.yieldTo as Any,f.lineupRemaining)}}
        precondition(unfinished.isEmpty && parallel.violations==0,"Simultaneous departures did not resolve safely")
        print("PASS: nine simultaneous departure requests, yielding, crossing approvals and safe completion")
        let crossing=Simulation(seed:17,continuousTraffic:false),r=2
        let center=SurfaceLayout.runwayPoint(r,0.5),heading=SurfaceLayout.heading(r)
        let before=SurfaceLayout.offset(center,heading:heading,side:-40),after=SurfaceLayout.offset(center,heading:heading,side:40)
        crossing.aircraft=[Aircraft(id:"CROSS",modelID:"14",departure:true,stand:0,position:before,heading:heading + .pi/2,phase:.taxiing,route:[after],runway:0)]
        crossing.selectedID="CROSS";crossing.running=true
        for _ in 0..<50 {crossing.tick(0.1)}
        precondition(crossing.selected!.crossingRequest==r && crossing.selected!.position==before)
        crossing.approveCrossing()
        for _ in 0..<220 {crossing.tick(0.1)}
        precondition(crossing.selected!.position==after && crossing.selected!.phase == .queued)
        print("PASS: stop before runway crossing, explicit approval and permission lifecycle")
        let ground=Simulation(seed:17,continuousTraffic:false)
        ground.aircraft=[Aircraft(id:"TAXI-A",modelID:"07",departure:true,stand:0,position:Point(x:100,y:100),phase:.taxiing,route:[Point(x:200,y:100)]),Aircraft(id:"TAXI-B",modelID:"07",departure:true,stand:1,position:Point(x:160,y:100),heading:.pi,phase:.taxiing,route:[Point(x:50,y:100)])]
        ground.running=true
        for _ in 0..<100 {ground.tick(0.1)}
        precondition(ground.aircraft.contains{$0.waitingForTraffic} && ground.incidents.isEmpty && ground.score==0)
        let held=ground.aircraft[0].position;ground.aircraft.removeLast()
        for _ in 0..<20 {ground.tick(0.1)}
        precondition(ground.aircraft[0].position.distance(to:held)>0 && !ground.aircraft[0].waitingForTraffic)
        print("PASS: taxi conflict waits safely and resumes when clear")
        let collision=Simulation(seed:17,continuousTraffic:false)
        collision.aircraft=Array(collision.aircraft.prefix(2))
        for i in collision.aircraft.indices {collision.aircraft[i].position=Point(x:150,y:150);collision.aircraft[i].route=[];collision.aircraft[i].phase = .holding;collision.aircraft[i].altitude=4000}
        collision.running=true;collision.tick(0.1)
        precondition(collision.score == -1000 && collision.incidents.count==1)
        print("PASS: airborne collision loss, emergency dispatch and score")
    }
}
