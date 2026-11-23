import Foundation
@main struct TrafficFlowChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let document=try JSONDecoder().decode(AirportRouteDocument.self,from:Data(contentsOf:root.appendingPathComponent("AirTrafficControl/airport-routes.json")))
        try RoutingOverrides.activate(document,persist:false)
        for r in 0..<4 {
            let route=SurfaceLayout.landingRoute(r,model:AircraftCatalog.model("06"))
            let a=SurfaceLayout.threshold(r),b=SurfaceLayout.runwayEnds[r].1,dx=b.x-a.x,dy=b.y-a.y,l=a.distance(to:b),roll=route[0]
            let lateral=abs((roll.x-a.x)*dy-(roll.y-a.y)*dx)/l
            print("LAND ROUTE",r,route.count,lateral,route.prefix(3))
            precondition(lateral<0.001 && route.count>2,"Rollout is not centreline-aligned / exit missing")
            let s=Simulation(seed:17,continuousTraffic:false)
            s.aircraft=[Aircraft(id:"LAND",modelID:"06",departure:false,stand:0,position:a,heading:SurfaceLayout.heading(r),phase:.landing,route:route,runway:r,groundSpeed:22)]
            s.running=true
            for _ in 0..<1200 {
                if s.aircraft[0].route.first != roll {break}
                s.tick(0.1)
                let p=s.aircraft[0].position
                if s.aircraft[0].route.first != roll {break}
                precondition(abs((p.x-a.x)*dy-(p.y-a.y)*dx)/l<0.001,"Aircraft skidded off centreline during rollout")
            }
            print("PASS: runway",r,"centreline rollout and traced exit",route.count)
        }
        let bases=Simulation(seed:17,continuousTraffic:false)
        precondition(bases.vehicles.count==49)
        for base in 0...1 {
            let units=bases.vehicles.filter{$0.kind != .pushback && $0.base==base}
            precondition(units.count==15)
            for (i,u) in units.enumerated() {
                let expected=ServiceRoads.parkingBay(u.kind,base:base)
                precondition(u.position==expected && u.depot==expected)
                for v in units.dropFirst(i+1) {precondition(u.position.distance(to:v.position)>8.5)}
                let path=ServiceRoads.graph(for:u.kind).shortestPath(from:u.position,to:ServiceRoads.parkingBay(u.kind,base:1-base),maximumAccessDistance:2)
                precondition(!path.isEmpty,"Base bay disconnected")
            }
        }
        print("PASS:15distinct reachable bays at each base; local terminal tugs retained")
        var fixture=AirportRouteDocument()
        let points=[Point(x:500,y:500),Point(x:550,y:500),Point(x:600,y:500),Point(x:650,y:500),Point(x:600,y:550)]
        for layer in [RouteLayer.aircraft,.services] {
            let offset=fixture.nodes.count
            fixture.nodes += points.enumerated().map {RouteNode(id:offset+$0.offset,layer:layer,point:$0.element)}
            for (a,b) in [(0,1),(1,2),(2,3),(2,4)] {fixture.edges.append(RouteEdge(id:fixture.edges.count,a:offset+a,b:offset+b,access:layer == .aircraft ? [0]:Array(1...16)))}
        }
        try RoutingOverrides.activate(fixture,persist:false)
        let jam=Simulation(seed:17,continuousTraffic:false)
        jam.aircraft=[Aircraft(id:"A",modelID:"07",departure:true,stand:0,position:Point(x:535,y:500),heading:0,phase:.taxiing,route:[Point(x:650,y:500)]),Aircraft(id:"B",modelID:"07",departure:true,stand:1,position:Point(x:565,y:500),heading:.pi,phase:.taxiing,route:[Point(x:500,y:500)])]
        jam.vehicles=[GroundVehicle(kind:.pushback,depot:Point(x:600,y:550),position:Point(x:565,y:500),id:800)]
        jam.running=true;var recovery=false
        for _ in 0..<5000 {
            let old=jam.aircraft;jam.tick(0.1)
            recovery = recovery || jam.aircraft.contains{$0.recoveringGround}
            for (a,b) in zip(old,jam.aircraft) {precondition(a.position.distance(to:b.position)<2,"Deadlock recovery teleported")}
            if jam.aircraft.allSatisfy({$0.phase == .queued}) {break}
        }
        if !jam.aircraft.allSatisfy({$0.phase == .queued}) {
            for f in jam.aircraft {print("JAM",f.id,f.position,f.phase,f.blockedBy as Any,f.recoveringGround,f.yieldTo as Any,f.route.prefix(2))}
            for t in jam.serviceTasks {print("TASK",t.kind,t.state,t.remaining)}
        }
        precondition(recovery && jam.aircraft.allSatisfy{$0.phase == .queued} && jam.violations==0,"Opposing aircraft deadlocked")
        print("PASS: opposing-aircraft deadlock resolved with physical tug/passing-bay movement")
        let cycle=Simulation(seed:17,continuousTraffic:false)
        cycle.aircraft=[Aircraft(id:"A",modelID:"07",departure:true,stand:0,position:Point(x:535,y:500),phase:.pushback,route:[Point(x:650,y:500)],underTow:true),Aircraft(id:"B",modelID:"07",departure:true,stand:1,position:Point(x:565,y:500),heading:.pi,phase:.pushback,route:[Point(x:600,y:500)],underTow:true)]
        cycle.aircraft[0].blockedBy="B";cycle.aircraft[0].blockedSince=0;cycle.aircraft[0].waitingForTraffic=true
        cycle.aircraft[1].awaitingGroundRelease=true;cycle.aircraft[1].groundDispatchOrder=2
        cycle.vehicles=[];cycle.running=true
        let start=cycle.aircraft[1].position
        for _ in 0..<25 {cycle.tick(0.1)}
        precondition(!cycle.aircraft[1].awaitingGroundRelease && cycle.aircraft[1].position.distance(to:start)>1,"Gate admission produced a circular wait")
        print("PASS:admitted aircraft blocked by waiting gate aircraft releases that gate aircraft")
        try RoutingOverrides.activate(document,persist:false)
        for overlap in [false,true] {
            let real=Simulation(seed:17,continuousTraffic:false)
            let network=SurfaceLayout.taxiNetwork
            let a=network.closestPoint(to:Point(x:1102,y:overlap ? 307:300))!,b=network.closestPoint(to:Point(x:1102,y:330))!
            let north=network.closestPoint(to:Point(x:1105,y:270))!,south=network.closestPoint(to:Point(x:1104,y:365))!
            real.aircraft=[Aircraft(id:"NORTH",modelID:"07",departure:true,stand:12,position:a,heading:1.78,phase:.taxiing,route:SurfaceLayout.taxiRoute(from:a,to:south)),Aircraft(id:"SOUTH",modelID:"07",departure:true,stand:13,position:b,heading:-1.36,phase:.taxiing,route:SurfaceLayout.taxiRoute(from:b,to:north))]
            real.running=true
            for _ in 0..<9000 {
                for f in real.aircraft where f.crossingRequest != nil {real.selectedID=f.id;real.approveCrossing()}
                real.tick(0.1)
                if real.aircraft.allSatisfy({$0.phase == .queued}) {break}
            }
            if !real.aircraft.allSatisfy({$0.phase == .queued}) {
                for f in real.aircraft {print("REAL JAM",overlap,f.id,f.position,f.phase,f.blockedBy as Any,f.recoveringGround,f.yieldTo as Any)}
                for v in real.vehicles where v.taskID != nil {print("VEHICLE",v.kind,v.position,v.routeUnavailable,v.waitingForAircraft)}
            }
            precondition(real.aircraft.allSatisfy{$0.phase == .queued},"Real north-terminal opposing aircraft failed to clear")
            print("PASS:real north-terminal head-on pair clears",overlap)
        }
        let flow=Simulation(seed:42)
        flow.running=true;var seen=Set(flow.aircraft.map(\.id));var automaticLanding=false
        for _ in 0..<7500 {
            flow.tick(0.1)
            for f in flow.aircraft where !f.departure && ![.complete,.crashed,.diverted].contains(f.phase) {
                precondition(f.runway != nil && SurfaceLayout.eligible(f.model,runway:f.runway!))
                if f.phase == .landing || f.phase == .awaitingEscort || f.phase == .servicing {automaticLanding=true}
            }
            seen.formUnion(flow.aircraft.map(\.id))
        }
        precondition(flow.trafficSequence>=1010 && seen.count>20 && !flow.finished && automaticLanding,"Continuous assigned arrivals did not build up/land")
        precondition(flow.aircraft.filter{$0.airborne && ![.complete,.crashed,.diverted].contains($0.phase)}.count<=19)
        print("PASS:750seconds continuous assigned traffic,automatic approaches/landings,bounded buildup",seen.count,flow.resolved)
        let safe=Simulation(seed:17,continuousTraffic:false)
        let p=SurfaceLayout.runwayPoint(0,0.5)
        safe.aircraft=[Aircraft(id:"ONE",modelID:"06",departure:false,stand:0,position:p,phase:.landing,runway:0),Aircraft(id:"TWO",modelID:"07",departure:true,stand:1,position:p,phase:.taxiing,runway:0)]
        safe.running=true;safe.tick(0.1)
        precondition(safe.incidents.isEmpty && safe.violations==0)
        print("PASS:ground/runway contacts cannot generate aircraft-loss explosions or penalties")
    }
}
