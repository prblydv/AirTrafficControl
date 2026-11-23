import Foundation

@main struct SimulationChecks {
    @MainActor static func until(_ sim:Simulation,seconds:Double=800,_ done:()->Bool)->Bool {
        for _ in 0..<Int(seconds*10) {
            if done() { return true }
            let old=sim.aircraft
            sim.tick(0.1)
            for (a,b) in zip(old,sim.aircraft) {
                precondition(a.position.distance(to:b.position)<6.1,"Aircraft position jumped between frames")
                if !a.airborne && !b.airborne && [.pushback,.taxiing,.landing,.takeoff].contains(a.phase) && (a.phase == b.phase || (a.phase == .pushback && b.phase == .taxiing)) && !a.stopped {
                    let delta=atan2(sin(b.heading-a.heading),cos(b.heading-a.heading))
                    if abs(delta)>=0.20 { print("Nose snap",a.id,a.phase,b.phase,a.position,b.position,a.heading,b.heading,delta,a.route.prefix(3),b.route.prefix(3)) }
                    precondition(abs(delta)<0.20,"Ground aircraft nose snapped during taxi/pushback")
                }
                if a.airborne && b.airborne && a.phase == b.phase && !a.stopped {
                    let delta=atan2(sin(b.heading-a.heading),cos(b.heading-a.heading))
                    precondition(abs(delta)<0.035,"Airborne track changed abruptly")
                }
            }
        }
        return done()
    }
    @MainActor static func depart(_ sim:Simulation,_ id:String,_ runway:Int) {
        sim.selectedID=id
        let before=sim.selected!.position
        sim.clearSelected(to:runway)
        precondition(sim.selected!.position==before && sim.selected!.phase == .pushback)
        let queued=until(sim,seconds:600) { sim.selected?.phase == .queued }
        if !queued { print("Departure stuck",id,sim.selected!.phase,sim.notice) }
        precondition(queued)
        precondition(sim.selected!.position.distance(to:SurfaceLayout.hold(runway))<0.001)
        sim.clearSelected(to:runway)
        precondition(until(sim,seconds:100) { sim.selected?.phase == .climbing })
        let climbStart=sim.selected!
        precondition(climbStart.altitude>=1000 && climbStart.position.x<AirportLayout.width)
        let climbSpeed=climbStart.groundSpeed
        let departed=until(sim,seconds:100) { sim.selected?.phase == .complete }
        if !departed { print("Climb failed",id,sim.selected!.phase,sim.selected!.position,sim.notice) }
        precondition(departed)
        let flown=sim.selected!
        precondition(flown.altitude>climbStart.altitude && flown.groundSpeed>climbSpeed)
        precondition(flown.position.x>AirportLayout.width+100 || flown.position.x < -100 || flown.position.y>AirportLayout.height+100 || flown.position.y < -100)
    }
    @MainActor static func main() {
        setbuf(stdout,nil)
        let seed=Simulation(seed:17),replay=Simulation(seed:17)
        let fleet=seed.aircraft.map(\.modelID)
        precondition(fleet==replay.aircraft.map(\.modelID) && Set(fleet).count==9)
        seed.reset();precondition(seed.aircraft.map(\.modelID) != fleet)
        seed.reset(seed:17);precondition(seed.aircraft.map(\.modelID)==fleet)
        var seen=Set<String>()
        for s in 0..<100 { seen.formUnion(Simulation(seed:UInt64(s)).aircraft.map(\.modelID)) }
        precondition(seen.count==20)
        precondition(SurfaceLayout.gates.count==9 && seed.vehicles.count==24)
        for a in seed.aircraft where a.departure {
            precondition(a.position==SurfaceLayout.gates[a.stand].position && a.readyToDepart)
            precondition(abs(a.heading-SurfaceLayout.gates[a.stand].heading)<0.001)
            var sky=a;sky.altitude=4500
            precondition(abs(a.apparentScale/sky.apparentScale-0.5)<0.001)
        }
        for (r,ends) in SurfaceLayout.runwayEnds.enumerated() {
            let original=AirportLayout.runwayDefinitions[r]
            precondition(ends.0.distance(to:AirportLayout.display(original.2))<0.001)
            precondition(ends.1.distance(to:AirportLayout.display(original.3))<0.001)
        }
        print("PASS: seeded nine-aircraft fleets, all20 designs, nine terminal-facing gates, local tugs and 50% ground scale")

        var roads=RoadGraph()
        roads.addLane([Point(x:0,y:0),Point(x:10,y:0),Point(x:10,y:10)])
        roads.addLane([Point(x:0,y:0),Point(x:0,y:30),Point(x:10,y:10)])
        precondition(abs(FlightCurves.length(from:Point(x:0,y:0),route:roads.shortestPath(from:Point(x:0,y:0),to:Point(x:10,y:10)))-20)<0.001)
        precondition(abs(FlightCurves.length(from:Point(x:3,y:0),route:roads.shortestPath(from:Point(x:3,y:0),to:Point(x:8,y:0)))-5)<0.001)
        for gate in SurfaceLayout.gates { for r in 0..<4 {
            let path=SurfaceLayout.taxiRoute(from:gate.port,to:SurfaceLayout.hold(r))
            precondition(!path.isEmpty && path.last==SurfaceLayout.hold(r))
        } }
        for (a,b) in [(Point(x:1110,y:421),Point(x:1097,y:474)),(Point(x:1097,y:474),Point(x:1076,y:566)),(Point(x:1076,y:566),Point(x:1057,y:647))] {
            precondition(SurfaceLayout.network.edges.contains { edge in
                let x=SurfaceLayout.network.nodes[edge.a],y=SurfaceLayout.network.nodes[edge.b]
                return (x==a && y==b)||(x==b && y==a)
            })
        }
        let block=Simulation(seed:17)
        block.aircraft=[Aircraft(id:"BLOCK",modelID:"02",departure:true,stand:0,position:Simulation.stands[0],phase:.parked)]
        let center=block.aircraft[0].position
        var vehicle=block.vehicles.first { $0.kind == .fuel }!
        let a=Point(x:center.x-50,y:center.y),b=Point(x:center.x+50,y:center.y)
        precondition(block.vehicleBlocked(vehicle,from:a,to:b))
        block.enqueue(.fuel,target:.aircraft("BLOCK"));vehicle.taskID=block.serviceTasks[0].id
        precondition(!block.vehicleBlocked(vehicle,from:a,to:b))
        print("PASS: Dijkstra/same-edge routing, all36 gate/runway paths, eastern taxiway and assigned-service access")

        let hold=Simulation(seed:17);hold.aircraft=[hold.aircraft[0]];hold.aircraft[0].position=SurfaceLayout.fixes[0]
        hold.selectedID=hold.aircraft[0].id
        let position=hold.aircraft[0].position,heading=hold.aircraft[0].heading
        hold.holdSelected()
        precondition(hold.aircraft[0].position==position && hold.aircraft[0].heading==heading)
        let path=hold.aircraft[0].route
        precondition(abs(path.map(\.y).max()!-path.map(\.y).min()!-280)<1)
        precondition(until(hold,seconds:80) { hold.elapsed>=12 })
        precondition(hold.aircraft[0].bankAngle>0.15 && hold.aircraft[0].bankAngle<=0.30,"Turning aircraft must smoothly bank")
        hold.aircraft[0].phase = .inbound
        hold.aircraft[0].route=[SurfaceLayout.offset(hold.aircraft[0].position,heading:hold.aircraft[0].heading,along:200)]
        precondition(until(hold,seconds:5) { hold.elapsed>=16 })
        precondition(abs(hold.aircraft[0].bankAngle)<0.01,"Bank must ease back to level on a straight leg")
        let air=Simulation(seed:17);air.selectedID="DEL204"
        let start=air.selected!.position
        air.clearSelected(to:0);air.clearSelected(to:2)
        precondition(air.selected!.position==start && air.running)
        air.selectedID="DEL718";air.clearSelected(to:2)
        precondition(air.selected!.phase == .approach)
        print("PASS: 280px-wide tangent holding turns, continuous track/position and immediate simultaneous clearances")

        for r in 0..<4 {
            let sim=Simulation(seed:UInt64(r));sim.aircraft=[sim.aircraft[3]]
            let p=sim.aircraft[0].position;sim.selectedID=sim.aircraft[0].id;sim.clearSelected(to:r)
            precondition(sim.aircraft[0].position==p)
            for _ in 0..<20 { sim.tick(0.1) }
            precondition(sim.aircraft[0].position==p,"Wait for tug coupling before pushback")
            precondition(until(sim,seconds:600) { sim.aircraft[0].phase == .queued })
            precondition(sim.effect(.pushback,target:.aircraft(sim.aircraft[0].id)))
        }
        print("PASS: physical coupling, reverse curved pushback, smooth taxi and four runway holding points")

        let service=Simulation(seed:17)
        service.aircraft=[Aircraft(id:"SERVICE",modelID:"07",departure:false,stand:3,position:Simulation.stands[3],phase:.parked)]
        service.selectedID="SERVICE";service.serviceSelected()
        let gatePosition=service.aircraft[0].position
        var unloaded=false,boarded=false,tankerWorking=false,baggageWorking=false
        let serviced=until(service,seconds:600) {
            let f=service.aircraft[0],target=ServiceTarget.aircraft(f.id)
            precondition(f.position==gatePosition)
            if f.passengerUnloadRemaining<f.passengerUnloadDuration { unloaded=true }
            if f.passengerLoadRemaining<f.passengerLoadDuration { precondition(f.passengerUnloadRemaining==0);boarded=true }
            if let fuel=service.serviceTasks.first(where:{ $0.kind == .fuel && $0.target==target }),fuel.remaining<f.refuelDuration {
                precondition(f.passengersHandled,"Refuelling must follow unloading and boarding")
                let unit=service.vehicles.first { $0.taskID==fuel.id }!
                if fuel.state == .working { precondition(unit.position.distance(to:f.position)<25);tankerWorking=true }
            }
            if let belt=service.serviceTasks.first(where:{ $0.kind == .belt && $0.state == .working }),belt.remaining<24 { baggageWorking=true }
            return f.phase == .gateWait
        }
        if !serviced { for t in service.serviceTasks { print(t.kind,t.state,t.remaining,t.prepared,t.effectApplied) } }
        precondition(serviced && unloaded && boarded && tankerWorking && baggageWorking)
        precondition(!service.aircraft[0].readyToDepart && service.aircraft[0].gateWaitRemaining>=11.9 && service.aircraft[0].gateWaitRemaining<=30)
        let f=service.aircraft[0]
        precondition(f.fuelFraction==1 && f.baggageHandled && f.cateringReady && f.waterReady && f.sanitationReady && !f.powerConnected)
        precondition(until(service,seconds:120) { service.aircraft[0].readyToDepart })
        precondition(service.aircraft[0].departure && service.aircraft[0].phase == .parked && service.busyVehicleCount==0)
        precondition(service.resolved==1)
        print("PASS: unload → board → refuel timing, tanker/baggage at aircraft, native services, random gate wait and ready-for-pushback lifecycle")

        let crash=Simulation(seed:17),p=crash.runways[0].start
        crash.aircraft=[Aircraft(id:"A",modelID:"07",departure:false,stand:0,position:p,phase:.holding,altitude:4000,stopped:true),Aircraft(id:"B",modelID:"07",departure:false,stand:1,position:p,phase:.holding,altitude:5000,stopped:true)]
        crash.startLive();crash.tick(0.1)
        precondition(crash.incidents.count==1 && crash.score == -1000 && crash.runways[0].closed)
        let incident=crash.incidents[0]
        crash.reopenRunway(0);precondition(crash.runways[0].closed)
        precondition(until(crash,seconds:400) {
            if let sweep=crash.serviceTasks.first(where:{ $0.kind == .sweeper }),sweep.remaining<ServiceKind.sweeper.duration {
                precondition([ServiceKind.fire,.ambulance,.patrol].allSatisfy { crash.effect($0,target:.incident(incident.id)) })
            }
            return crash.incidentReady(incident)
        })
        crash.reopenRunway(0);precondition(!crash.runways[0].closed)
        crash.reset(seed:17);precondition(crash.incidents.isEmpty && crash.serviceTasks.isEmpty && crash.vehicles.count==24)
        print("PASS: airborne collision, negative score, ordered emergency recovery, reopening and reset")

        let occupied=Simulation(seed:17);occupied.selectedID="DEL204";occupied.clearSelected(to:0)
        let occupiedReady=until(occupied,seconds:900) { occupied.selected?.readyToDepart == true }
        if !occupiedReady { print("Occupied apron stuck",occupied.selected!.phase,occupied.notice);for v in occupied.vehicles where v.taskID != nil { print(v.kind,v.position,v.waitingForAircraft) } }
        precondition(occupiedReady,"Arrival must turn around while the other six gates remain occupied")
        print("PASS: arrival-to-ready turnaround with six neighboring occupied gates")

        for seed in 0..<3 {
            let sim=Simulation(seed:UInt64(seed))
            for id in sim.aircraft.filter({ $0.departure }).map(\.id) { depart(sim,id,0) }
            for (index,id) in ["DEL204","DEL718","DEL092"].enumerated() {
                sim.selectedID=id;sim.clearSelected(to:(index+seed)%4)
                let ready=until(sim,seconds:900) { sim.selected?.readyToDepart == true }
                if !ready { print("Arrival stuck",seed,id,sim.selected!.phase,sim.notice);for v in sim.vehicles where v.taskID != nil { print(v.kind,v.position,v.waitingForAircraft) } }
                precondition(ready)
                depart(sim,id,0)
            }
            precondition(sim.resolved==12 && sim.violations==0 && sim.score==1200)
        }
        print("PASS: three full twelve-movement shifts, including T1 departures, all four arrival runways, gate turnarounds and return departures")
    }
}
