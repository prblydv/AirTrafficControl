import Foundation

@main struct GroundTrafficPlannerChecks {
    static func flight(_ id:String,_ p:Point,_ phase:FlightPhase = .taxiing)->Aircraft {
        Aircraft(id:id,modelID:"19",departure:true,stand:15,position:p,phase:phase)
    }
    static func snapshot(_ reservations:[GroundTrafficReservation]=[],now:Double=0,revision:Int=1)->GroundTrafficSnapshot {
        .init(revision:revision,now:now,horizon:180,reservations:reservations)
    }
    static func obstacle(_ id:String,_ a:Point,_ b:Point,_ start:Double,_ end:Double)->GroundTrafficReservation {
        let f=flight(id,a),h=atan2(b.y-a.y,b.x-a.x)
        return .init(owner:id,start:start,end:end,polygon:GroundTrafficPlanner.swept(f,from:a,to:b,heading:h))
    }
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        setbuf(stderr,nil)
        var graph=RoadGraph();graph.addLane([Point(x:0,y:0),Point(x:60,y:0),Point(x:120,y:0)])
        let a=flight("A",Point(x:0,y:0)),target=Point(x:120,y:0)
        let clear=GroundTrafficPlanner.plan(flight:a,graph:graph,target:target,snapshot:snapshot())!
        var dense=RoadGraph();dense.addLane((0...10).map{Point(x:Double($0)*12,y:0)})
        let densePlan=GroundTrafficPlanner.plan(flight:a,graph:dense,target:target,snapshot:snapshot())!
        precondition(abs(clear.finish-densePlan.finish)<0.001,"straight-route ETA changed with edge density: \(clear.finish) vs \(densePlan.finish)")
        
        var bend=RoadGraph();bend.addLane([Point(x:0,y:0),Point(x:60,y:0),Point(x:60,y:60)])
        let bent=GroundTrafficPlanner.plan(flight:a,graph:bend,target:Point(x:60,y:60),snapshot:snapshot())!
        precondition(clear.legs.count>=2 && clear.position(at:clear.finish)==target, "clear path geometry")
        let taxiMotion=GroundMotionModel.profile(for:a)
        
        precondition(taxiMotion.cruiseSpeed==a.model.speed(for:.taxiing), "cruise")
        precondition(taxiMotion.stoppingDistance(at:11)>24,"Fallback lookahead is shorter than reaction plus braking distance")
        precondition(taxiMotion.turnSpeed(from:0,to:.pi/2,over:10)<taxiMotion.cruiseSpeed)
        precondition(bent.legs[0].exitSpeed < taxiMotion.cruiseSpeed,"bend speed limit")
        for leg in clear.legs where leg.distance>0.001 {
            precondition(abs(leg.travelled(at:leg.end)-leg.distance)<0.0001, "leg endpoint integration: \(leg.travelled(at:leg.end)) / \(leg.distance)")
            precondition(abs(leg.speed(at:leg.start)-leg.entrySpeed)<0.001 && abs(leg.speed(at:leg.end)-leg.exitSpeed)<0.001)
            let dt=0.001
            var prior=leg.speed(at:leg.start),maximumAcceleration=0.0,maximumBraking=0.0,time=leg.start+dt
            while time<=leg.end+0.000001 {
                let current=leg.speed(at:min(time,leg.end)),change=(current-prior)/dt
                maximumAcceleration=max(maximumAcceleration,change);maximumBraking=max(maximumBraking,-change)
                prior=current;time+=dt
            }
            precondition(maximumAcceleration<=leg.acceleration+0.001 && maximumBraking<=leg.deceleration+0.001)
        }
        print("PASS:shared calibrated cruise, turning, reaction, acceleration and braking integrate to the exact endpoint")
        let crossed=obstacle("CROSS",Point(x:60,y:-50),Point(x:60,y:50),0,18)
        let crossing=GroundTrafficPlanner.plan(flight:a,graph:graph,target:target,snapshot:snapshot([crossed]))!
        precondition(crossing.legs.contains{$0.start>=18} && crossing.finish>clear.finish+5)
        precondition(GroundTrafficPlanner.validated(crossing,flight:a,against:snapshot([crossed])))
        print("PASS:unjoined geometric junction conflict produces an explicit scheduled wait")
        let first=GroundTrafficPlanner.plan(flight:a,graph:graph,target:target,snapshot:snapshot())!
        var b=flight("B",target);b.heading = .pi
        let reserved=GroundTrafficPlanner.reservations(for:first,flight:a,now:0,horizon:180)
        let opposing=GroundTrafficPlanner.plan(flight:b,graph:graph,target:a.position,snapshot:snapshot(reserved))
        precondition(opposing==nil,"Opposing aircraft admitted into a corridor with no clear exit")
        var alternate=graph;alternate.addLane([target,Point(x:120,y:40),Point(x:0,y:40),a.position])
        // A's terminal occupies B's destination: use a clear off-corridor exit.
        alternate.addLane([Point(x:0,y:40),Point(x:-50,y:40)])
        // The independent exit is already aligned north; the calibrated turn
        // rate correctly prevents an instantaneous 90-degree escape at t=0.
        var detourFlight=b;detourFlight.heading = .pi/2
        let detour=GroundTrafficPlanner.plan(flight:detourFlight,graph:alternate,target:Point(x:-50,y:40),snapshot:snapshot(reserved))
        precondition(detour != nil && detour!.legs.contains{$0.to.y==40})
        print("PASS:opposing entry is refused without an exit; connected independent detour remains usable")
        let parked=obstacle("PARKED",Point(x:60,y:0),Point(x:60,y:0),0,180)
        precondition(GroundTrafficPlanner.plan(flight:a,graph:graph,target:target,snapshot:snapshot([parked]))==nil)
        let resumed=GroundTrafficPlanner.plan(flight:a,graph:graph,target:target,snapshot:snapshot(now:20))!
        precondition(resumed.legs.first!.start>=20)
        precondition(!GroundTrafficPlanner.validated(first,flight:a,against:snapshot(revision:2)))
        precondition(!GroundTrafficPlanner.validated(first,flight:a,against:snapshot([parked])))
        print("PASS:stopped aircraft do not disappear; changed traffic/graph rejects stale commits; removal permits replanning")
        var turn=RoadGraph();turn.addLane([Point(x:0,y:0),Point(x:60,y:0),Point(x:60,y:60)])
        let later=obstacle("LATER",Point(x:60,y:0),Point(x:60,y:0),5,14)
        let interval=GroundTrafficPlanner.plan(flight:a,graph:turn,target:Point(x:60,y:60),snapshot:snapshot([later]))!
        precondition(interval.legs.contains{$0.to==Point(x:60,y:0) && $0.end>14})
        print("PASS:search reaches a later safe interval instead of keeping one distance label per node")
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let document=try JSONDecoder().decode(AirportRouteDocument.self,from:Data(contentsOf:root.appendingPathComponent("AirTrafficControl/airport-routes.json")))
        try RoutingOverrides.activate(document,persist:false)
        let s=Simulation(seed:9,continuousTraffic:false)
        s.aircraft=[Aircraft(id:"HOLD",modelID:"19",departure:true,stand:15,position:SurfaceLayout.gates[15].port,phase:.taxiing,route:SurfaceLayout.taxiRoute(from:SurfaceLayout.gates[15].port,to:SurfaceLayout.hold(0)))]
        s.running=true
        for _ in 0..<30 {s.tick(0.1)}
        let before=s.aircraft[0].position
        s.selectedID="HOLD";s.toggleSelectedGroundHold()
        for _ in 0..<30 {s.tick(0.1)}
        precondition(s.aircraft[0].position==before && s.groundTrafficPlans.isEmpty)
        s.toggleSelectedGroundHold()
        for _ in 0..<50 {s.tick(0.1)}
        precondition(s.aircraft[0].position.distance(to:before)>1)
        s.reset(seed:9);precondition(s.groundTrafficPlans.isEmpty)
        print("PASS:manual hold freezes position, cancels schedules, resumes from actual position; reset clears plans")
        let independent=Simulation(seed:9,continuousTraffic:false)
        independent.aircraft=[flight("ONE",Point(x:100,y:100)),flight("TWO",Point(x:400,y:100))]
        independent.aircraft[0].route=[Point(x:100,y:200)]
        independent.aircraft[1].route=[Point(x:500,y:100)]
        independent.running=true
        for _ in 0..<20 {independent.tick(0.1)}
        let originalFinish=independent.groundTrafficPlans["TWO"]!.finish
        independent.selectedID="ONE";independent.toggleSelectedGroundHold()
        independent.tick(0.1)
        precondition(independent.groundTrafficPlans["TWO"]?.finish==originalFinish,"Unrelated hold restarted another trajectory")
        independent.aircraft[0].position=Point(x:450,y:100)
        let blockedPosition=independent.aircraft[1].position
        independent.tick(0.1)
        precondition(independent.groundTrafficPlans["TWO"]==nil && independent.aircraft[1].position==blockedPosition,"Changed hold failed to withdraw a dependent trajectory")
        independent.aircraft.removeFirst()
        for _ in 0..<50 {independent.tick(0.1)}
        precondition(independent.aircraft[0].position.distance(to:blockedPosition)>1)
        print("PASS:unrelated schedules keep their slots; changed held footprints cancel dependent plans; removed blockers release traffic")
        let rotated=Simulation(seed:9,continuousTraffic:false)
        rotated.aircraft=[flight("PARKED",Point(x:450,y:116.0),.parked),flight("MOVING",Point(x:400,y:100))]
        rotated.aircraft[1].route=[Point(x:500,y:100)]
        rotated.running=true
        for _ in 0..<20 {rotated.tick(0.1)}
        precondition(rotated.groundTrafficPlans["MOVING"] != nil)
        let rotationStop=rotated.aircraft[1].position
        rotated.aircraft[0].heading = .pi/2
        rotated.tick(0.1)
        precondition(rotated.groundTrafficPlans["MOVING"]==nil && rotated.aircraft[1].position==rotationStop,"Rotated stationary footprint failed to withdraw a dependent plan")
        print("PASS:stationary heading changes invalidate affected footprint reservations")


    }
}
