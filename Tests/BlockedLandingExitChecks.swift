import Foundation

@main struct BlockedLandingExitChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        var changed=false
        for runway in [0,3] where !changed {
            let s=Simulation(seed:17,continuousTraffic:false),model=AircraftCatalog.model("07")
            s.followsAssignedGroundRoutes=true
            let stand=12,destination=s.surface.gates[stand].position
            let full=s.surface.landingRoute(runway,model:model,destination:destination)
            guard let firstOff=full.firstIndex(where:{!s.onRunway($0,runway)}),let oldExit=full.last else{continue}
            let start=s.surface.runwayPoint(runway,0.3)
            var flight=Aircraft(id:"LAND",modelID:model.id,departure:false,stand:stand,position:start,heading:s.surface.heading(runway),phase:.landingRoll,route:Array(full[..<firstOff]),runway:runway,pendingTaxiRoute:Array(full[firstOff...]),groundSpeed:15)
            flight.landingRollTotalDistance=FlightCurves.length(from:start,route:flight.route)
            let blocker=Aircraft(id:"BLOCKED-EXIT",modelID:model.id,departure:true,stand:0,position:oldExit,phase:.parked)
            s.aircraft=[flight,blocker];s.running=true
            s.tick(0.01)
            if let next=s.aircraft[0].pendingTaxiRoute.last,next.distance(to:oldExit)>10 {
                changed=true
                precondition(s.aircraft[0].position.distance(to:start)<1,"Changing exit teleported landing aircraft")
                let a=s.surface.threshold(runway),b=s.surface.runwayEnds[runway].1,p=s.aircraft[0].route.first!
                let along=((p.x-a.x)*(b.x-a.x)+(p.y-a.y)*(b.y-a.y))/pow(a.distance(to:b),2)
                precondition(along>0.3,"Landing exit reroute sent aircraft backwards")
            }
        }
        precondition(changed,"Landing aircraft never switched from blocked exit to an available later exit")
        print("PASS:landing roll switches away from occupied exit without reversing or teleporting")
    }
}
