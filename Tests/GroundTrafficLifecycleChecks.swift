import Foundation

@main struct GroundTrafficLifecycleChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let document=try JSONDecoder().decode(AirportRouteDocument.self,from:Data(contentsOf:root.appendingPathComponent("AirTrafficControl/airport-routes.json")))
        try RoutingOverrides.activate(document,persist:false)
        let s=Simulation(seed:17,continuousTraffic:false),model=AircraftCatalog.model("07")
        let landing=SurfaceLayout.landingRoute(0,model:model),firstOff=landing.firstIndex(where:{!s.onRunway($0,0)}) ?? landing.endIndex
        var cycle=Aircraft(id:"CYCLE",modelID:model.id,departure:false,stand:12,position:SurfaceLayout.threshold(0),heading:SurfaceLayout.heading(0),phase:.landingRoll,route:Array(landing[..<firstOff]),runway:0,groundSpeed:model.speed(for:.landingRoll))
        if firstOff<landing.endIndex {cycle.pendingTaxiRoute=Array(landing[firstOff...])}
        s.aircraft=[cycle]
        s.selectedID="CYCLE";s.running=true
        var usedSchedule=false,usedRunwayExit=false,usedLineup=false,usedTakeoffRoll=false
        func step() {
            if s.aircraft[0].crossingRequest != nil {s.approveCrossing()}
            let before=s.aircraft[0].position
            s.tick(0.1)
            usedSchedule = usedSchedule || s.groundTrafficPlans["CYCLE"] != nil
            usedRunwayExit = usedRunwayExit || s.aircraft[0].phase == .runwayExit
            usedLineup = usedLineup || s.aircraft[0].phase == .lineup
            usedTakeoffRoll = usedTakeoffRoll || s.aircraft[0].phase == .takeoffRoll
            precondition(before.distance(to:s.aircraft[0].position)<6.5,"Lifecycle movement jumped")
        }
        for _ in 0..<18000 {
            step()
            if s.aircraft[0].readyToDepart && s.busyVehicleCount==0 {break}
        }
        let arrival=s.aircraft[0]
        if !arrival.readyToDepart {print("PENDING ARRIVAL",s.elapsed,arrival.phase,arrival.position,arrival.blockedBy as Any,arrival.crossingRequest as Any)}
        precondition(usedSchedule && usedRunwayExit && arrival.readyToDepart && arrival.fuelFraction==1 && arrival.passengersHandled && arrival.baggageHandled)
        precondition(s.busyVehicleCount==0 && s.vehicles.allSatisfy{$0.position.distance(to:$0.depot)<0.1})
        precondition(s.resolved==1 && s.violations==0)
        print("PASS:centreline landing, scheduled taxi, automatic turnaround, ready state and all crews home",Int(s.elapsed))
        s.clearSelected(to:s.clearanceRunways(for:s.aircraft[0])[0].id)
        precondition([.pushback,.taxiing].contains(s.aircraft[0].phase))
        for _ in 0..<18000 {
            if s.aircraft[0].phase == .queued {s.clearSelected(to:s.aircraft[0].runway!)}
            step()
            if s.finished {break}
        }
        if !s.finished {print("PENDING DEPARTURE",s.elapsed,s.aircraft[0].phase,s.aircraft[0].position,s.aircraft[0].blockedBy as Any)}
        precondition(usedLineup && usedTakeoffRoll && s.finished && s.aircraft[0].phase == .complete && s.resolved==2 && s.score==200 && s.incidents.isEmpty)
        precondition(s.vehicles.allSatisfy{$0.position.distance(to:$0.depot)<0.1})
        print("PASS:serviced arrival departs through tug, scheduled taxi and tower takeoff; full lifecycle finishes",Int(s.elapsed))
    }
}
