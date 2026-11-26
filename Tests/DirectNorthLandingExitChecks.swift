import Foundation

@main struct DirectNorthLandingExitChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let package=AirportPackage.delhi
        let s=Simulation(seed:17,continuousTraffic:false)
        s.followsAssignedGroundRoutes=true
        let runway=3,surface=s.surface,a=surface.threshold(3),b=surface.runwayEnds[3].1,l=a.distance(to:b),dx=b.x-a.x,dy=b.y-a.y
        func side(_ p:Point)->Double {((p.x-a.x)*dy-(p.y-a.y)*dx)/l}
        let stand=surface.gates.indices.min{surface.gates[$0].position.y<surface.gates[$1].position.y}!
        let destination=surface.gates[stand].position
        for id in ["02","03","05"] {
            let model=AircraftCatalog.model(id),path=surface.landingRoute(runway,model:model,destination:destination)
            precondition(path.count>1 && path.map(side).min()! > -1,"North-terminal widebody exit still detours south of runway")
            precondition(side(path.last!)>22)
        }
        let model=AircraftCatalog.model("05"),full=surface.landingRoute(runway,model:model,destination:destination)
        let split=full.firstIndex{!s.onRunway($0,runway)}!
        var flight=Aircraft(id:"WB-SILV",modelID:model.id,departure:false,stand:stand,position:surface.runwayPoint(runway,0.85),heading:surface.heading(runway),phase:.landingRoll,route:Array(full[..<split]),runway:runway,pendingTaxiRoute:Array(full[split...]),groundSpeed:20)
        flight.landingRollTotalDistance=FlightCurves.length(from:flight.position,route:flight.route)
        s.aircraft=[flight];s.running=true
        var taxied=false
        for _ in 0..<2000 {
            let before=s.aircraft[0].position
            s.tick(0.1)
            precondition(side(s.aircraft[0].position) > -1,"Actual rollout/exit moved south before north turn")
            precondition(s.aircraft[0].position.distance(to:before)<4,"Landing exit jumped")
            if s.aircraft[0].phase == .taxiing {taxied=true;break}
        }
        precondition(taxied)
        precondition(package.definition.runways[3].activeEnd.landingExits?.isEmpty==false)
        print("PASS:WB-NAVY/WB-TRI/WB-SILV use north-side exit; actual WB-SILV rollout to taxi never detours south or teleports")
    }
}
