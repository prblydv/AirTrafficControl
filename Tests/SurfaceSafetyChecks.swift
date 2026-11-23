import Foundation
@main struct SurfaceSafetyChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let document=try JSONDecoder().decode(AirportRouteDocument.self,from:Data(contentsOf:root.appendingPathComponent("AirTrafficControl/airport-routes.json")))
        try RoutingOverrides.activate(document,persist:false)
        let taxi=Simulation(seed:17,continuousTraffic:false)
        taxi.aircraft=[Aircraft(id:"A",modelID:"07",departure:true,stand:0,position:Point(x:500,y:500),phase:.taxiing,route:[Point(x:650,y:500)]),Aircraft(id:"B",modelID:"07",departure:true,stand:1,position:Point(x:560,y:500),heading:.pi,phase:.taxiing,route:[Point(x:400,y:500)])]
        taxi.running=true
        for _ in 0..<70 {taxi.tick(0.1)}
        precondition(taxi.violations==0 && taxi.incidents.isEmpty && taxi.aircraft.contains{$0.waitingForTraffic})
        precondition(taxi.aircraft[0].position.distance(to:taxi.aircraft[1].position)>15)
        let before=taxi.aircraft[0].position;taxi.aircraft.removeLast()
        for _ in 0..<25 {taxi.tick(0.1)}
        precondition(taxi.aircraft[0].position.distance(to:before)>1)
        print("PASS:taxi head-on conflict waits without accident and resumes when clear")
        for phase in [FlightPhase.parked,.taxiing,.landing] {
            let s=Simulation(seed:17,continuousTraffic:false)
            s.aircraft=[Aircraft(id:"A",modelID:"07",departure:false,stand:0,position:Point(x:700,y:470),phase:phase,route:[Point(x:750,y:470)],runway:0),Aircraft(id:"B",modelID:"07",departure:true,stand:1,position:Point(x:700,y:470),phase:.parked)]
            s.running=true;s.tick(0.1)
            precondition(s.incidents.isEmpty && s.score==0,"Off-runway accident occurred")
        }
        print("PASS:apron/taxi/off-runway landing-exit overlap cannot cause accidents")
        let sky=Simulation(seed:17,continuousTraffic:false)
        sky.aircraft=[Aircraft(id:"AIR-A",modelID:"07",departure:false,stand:0,position:Point(x:100,y:100),phase:.holding,route:[Point(x:200,y:100)],altitude:4000),Aircraft(id:"AIR-B",modelID:"07",departure:false,stand:1,position:Point(x:100,y:100),phase:.holding,route:[Point(x:200,y:100)],altitude:4000)]
        sky.running=true;sky.tick(0.1);precondition(sky.incidents.isEmpty)
        print("PASS:only active runway conflicts generate accidents")
        let overhead=Simulation(seed:17,continuousTraffic:false),over=SurfaceLayout.runwayPoint(0,0.4)
        overhead.aircraft=[Aircraft(id:"HIGH",modelID:"07",departure:false,stand:0,position:over,phase:.holding,route:[SurfaceLayout.runwayPoint(0,0.6)],runway:0,altitude:4000),Aircraft(id:"LOW",modelID:"07",departure:false,stand:1,position:over,phase:.landing,route:[SurfaceLayout.runwayPoint(0,0.8)],runway:0)]
        overhead.running=true;overhead.tick(0.1);precondition(overhead.incidents.isEmpty)
        print("PASS:high overflight above an active runway is not a runway occupant")
        for phase in [FlightPhase.takeoff,.landing] {
            let s=Simulation(seed:17,continuousTraffic:false),h=SurfaceLayout.heading(0)
            s.aircraft=[Aircraft(id:"OP",modelID:"07",departure:phase == .takeoff,stand:0,position:SurfaceLayout.runwayPoint(0,0.4),heading:h,phase:phase,route:[SurfaceLayout.runwayPoint(0,0.85)],runway:0,groundSpeed:20),Aircraft(id:"OCCUPANT",modelID:"06",departure:true,stand:1,position:SurfaceLayout.runwayPoint(0,0.44),heading:h,phase:.parked,runway:0)]
            s.running=true
            for _ in 0..<100 {s.tick(0.1);if !s.incidents.isEmpty{break}}
            precondition(s.violations==2 && s.score == -1000 && s.runways[0].closed)
            precondition(s.incidents[0].runwayIDs==[0])
            print("PASS:occupied runway accident remains",phase)
        }
        let command=Simulation(seed:17,continuousTraffic:false),model=AircraftCatalog.model("07")
        let entry=SurfaceLayout.departureEntry(for:model,runway:0,from:SurfaceLayout.gates[12].port)
        command.aircraft=[Aircraft(id:"GO",modelID:"07",departure:true,stand:12,position:entry.hold,phase:.queued,runway:0),Aircraft(id:"BLOCK",modelID:"06",departure:true,stand:1,position:SurfaceLayout.runwayPoint(0,0.45),phase:.parked,runway:0)]
        command.aircraft[0].departureEntry=entry.lineup;command.runways[0].closed=true
        command.selectedID="GO";command.clearSelected(to:0)
        precondition(command.selected!.phase == .lineup,"Tower runway clearance was vetoed")
        print("PASS:tower can still clear takeoff on occupied/marked-closed runway")
        for overlap in [false,true] {
            let real=Simulation(seed:17,continuousTraffic:false),network=SurfaceLayout.taxiNetwork
            let a=network.closestPoint(to:Point(x:1102,y:overlap ? 307:300))!,b=network.closestPoint(to:Point(x:1102,y:330))!
            let north=network.closestPoint(to:Point(x:1105,y:270))!,south=network.closestPoint(to:Point(x:1104,y:365))!
            real.aircraft=[Aircraft(id:"NORTH",modelID:"07",departure:true,stand:12,position:a,heading:1.78,phase:.taxiing,route:SurfaceLayout.taxiRoute(from:a,to:south)),Aircraft(id:"SOUTH",modelID:"07",departure:true,stand:13,position:b,heading:-1.36,phase:.taxiing,route:SurfaceLayout.taxiRoute(from:b,to:north))]
            real.running=true
            for _ in 0..<9000 {
                for f in real.aircraft where f.crossingRequest != nil {real.selectedID=f.id;real.approveCrossing()}
                real.tick(0.1)
                if real.aircraft.allSatisfy({$0.phase == .queued}) {break}
            }
            if !real.aircraft.allSatisfy({$0.phase == .queued}) {for f in real.aircraft {print("JAM",f.id,f.position,f.phase,f.blockedBy as Any,f.recoveringGround,f.yieldTo as Any)}}
            precondition(real.aircraft.allSatisfy{$0.phase == .queued} && real.violations==0)
            print("PASS:real north-terminal pair clears safely",overlap)
        }
    }
}
