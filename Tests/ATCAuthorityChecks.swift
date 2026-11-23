import Foundation
@main struct ATCAuthorityChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let document=try JSONDecoder().decode(AirportRouteDocument.self,from:Data(contentsOf:root.appendingPathComponent("AirTrafficControl/airport-routes.json")))
        try RoutingOverrides.activate(document,persist:false)
        let takeoff=Simulation(seed:17,continuousTraffic:false),model=AircraftCatalog.model("07")
        let gate=SurfaceLayout.gates[12],entry=SurfaceLayout.departureEntry(for:model,runway:0,from:gate.port)
        takeoff.aircraft=[Aircraft(id:"GO",modelID:"07",departure:true,stand:12,position:entry.hold,phase:.queued,runway:0),Aircraft(id:"BLOCK",modelID:"06",departure:true,stand:1,position:SurfaceLayout.runwayPoint(0,0.45),heading:SurfaceLayout.heading(0),phase:.parked,runway:0)]
        takeoff.aircraft[0].departureEntry=entry.lineup
        takeoff.runways[0].closed=true;takeoff.selectedID="GO";takeoff.clearSelected(to:0)
        precondition(takeoff.selected!.phase == .lineup,"ATC line-up/takeoff clearance was vetoed by occupied/closed runway")
        for _ in 0..<1800 {takeoff.tick(0.1);if takeoff.incidents.count>0{break}}
        precondition(takeoff.violations==2 && takeoff.score == -1000 && takeoff.selected!.phase == .crashed,"Unsafe takeoff did not cause accident")
        print("PASS:occupied/marked-closed runway takeoff accepted; conflicting aircraft collide with penalty")
        let landing=Simulation(seed:17,continuousTraffic:false)
        let threshold=SurfaceLayout.threshold(0),h=SurfaceLayout.heading(0)
        landing.aircraft=[Aircraft(id:"LAND",modelID:"07",departure:false,stand:0,position:SurfaceLayout.offset(threshold,heading:h,along:-50),heading:h,phase:.inbound,runway:0,altitude:100),Aircraft(id:"BLOCK",modelID:"06",departure:true,stand:0,position:SurfaceLayout.runwayPoint(0,0.5),phase:.parked,runway:0)]
        landing.selectedID="LAND";landing.clearSelected(to:0)
        precondition(landing.selected!.phase == .approach)
        // Short aligned final fixture isolates the touchdown decision from the broad approach arc.
        landing.aircraft[0].route=[threshold];landing.aircraft[0].descentStartDistance=50;landing.aircraft[0].descentRemainingDistance=50
        for _ in 0..<80 {landing.tick(0.1);if landing.selected!.phase == .landingRoll {break}}
        precondition(landing.selected!.phase == .landingRoll,"Occupied runway triggered an unauthorized go-around")
        print("PASS:landing follows tower clearance despite occupied runway/gate; no automatic go-around")
        let headon=Simulation(seed:17,continuousTraffic:false)
        headon.aircraft=[Aircraft(id:"A",modelID:"07",departure:true,stand:0,position:Point(x:500,y:500),phase:.taxiing,route:[Point(x:650,y:500)]),Aircraft(id:"B",modelID:"07",departure:true,stand:1,position:Point(x:560,y:500),heading:.pi,phase:.taxiing,route:[Point(x:400,y:500)])]
        headon.running=true
        for _ in 0..<100 {headon.tick(0.1)}
        precondition(headon.aircraft.contains{$0.waitingForTraffic} && headon.incidents.isEmpty && headon.score==0)
        print("PASS:head-on taxi traffic waits safely without collision")
        let crossing=Simulation(seed:17,continuousTraffic:false),center=SurfaceLayout.runwayPoint(2,0.5),heading=SurfaceLayout.heading(2)
        let before=SurfaceLayout.offset(center,heading:heading,side:-40),after=SurfaceLayout.offset(center,heading:heading,side:40)
        crossing.aircraft=[Aircraft(id:"CROSS",modelID:"14",departure:true,stand:0,position:before,heading:heading + .pi/2,phase:.taxiing,route:[after],runway:0)]
        crossing.selectedID="CROSS";crossing.running=true
        for _ in 0..<40 {crossing.tick(0.1)}
        precondition(crossing.selected!.position==before && crossing.selected!.crossingRequest==2)
        crossing.runways[2].closed=true;crossing.approveCrossing()
        for _ in 0..<160 {crossing.tick(0.1)}
        precondition(crossing.selected!.position==after,"Approved crossing was vetoed")
        print("PASS:crossing requires ATC approval, then proceeds without occupancy/closure veto")
        let burst=Simulation(seed:17,continuousTraffic:false)
        for i in 0..<3 {burst.aircraft[i].stopped=true}
        let starts=Dictionary(uniqueKeysWithValues:burst.aircraft.map{($0.id,$0.position)})
        for f in burst.aircraft.filter({$0.departure}) {
            burst.selectedID=f.id;burst.clearSelected(to:burst.clearanceRunways(for:f)[0].id)
            precondition([.pushback,.taxiing].contains(burst.selected!.phase))
        }
        for _ in 0..<400 {burst.tick(0.1)}
        precondition(burst.aircraft.filter{$0.departure}.contains{ $0.position.distance(to:starts[$0.id]!)>10 })
        precondition(burst.incidents.isEmpty && burst.violations==0)
        print("PASS:all departure clearances accepted together; taxi traffic remains safe")
        for r in 0..<4 {
            let route=SurfaceLayout.landingRoute(r,model:model),a=SurfaceLayout.threshold(r),b=SurfaceLayout.runwayEnds[r].1,l=a.distance(to:b),p=route[0]
            precondition(route.count>2 && abs((p.x-a.x)*(b.y-a.y)-(p.y-a.y)*(b.x-a.x))/l<0.001)
        }
        print("PASS:all four centreline rollout fixes retained")
        let services=Simulation(seed:17,continuousTraffic:false)
        services.aircraft=[Aircraft(id:"SERVICE",modelID:"07",departure:false,stand:12,position:SurfaceLayout.gates[12].position,heading:SurfaceLayout.gates[12].heading,phase:.parked,runway:0)]
        services.beginTurnaround(0);services.running=true
        for _ in 0..<15000 {services.tick(0.1);if services.aircraft[0].readyToDepart && services.busyVehicleCount==0 {break}}
        precondition(services.aircraft[0].readyToDepart && services.vehicles.allSatisfy{$0.position.distance(to:$0.depot)<0.1})
        print("PASS:automatic turnaround and two-base crew home returns retained")
    }
}
