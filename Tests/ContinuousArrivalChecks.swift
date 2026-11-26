import Foundation

@main struct ContinuousArrivalChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let s=Simulation(seed:17,continuousTraffic:true)
        s.followsAssignedGroundRoutes=true
        s.aircraft=s.surface.gates.indices.map { i in
            Aircraft(id:"PARKED-\(i)",modelID:"07",departure:true,stand:i,position:s.surface.gates[i].position,phase:.parked)
        }
        let count=s.aircraft.count
        s.elapsed=s.nextArrivalAt;s.running=true;s.tick(0.1)
        precondition(s.aircraft.count==count+1,"Occupied stands stopped incoming traffic")
        let arrival=s.aircraft.last!
        precondition(arrival.runway != nil && arrival.phase == .approach)
        let first=s.arrivalInterval
        s.elapsed+=300
        precondition(s.arrivalInterval<first,"Arrival pace failed to increase")
        s.elapsed=100000
        precondition(s.arrivalInterval==s.airport.traffic.minimumIntervalSeconds)
        for _ in 0..<3 {
            s.aircraft.removeAll{$0.airborne}
            s.elapsed=s.nextArrivalAt;s.tick(0.1)
            precondition(s.aircraft.contains{$0.phase == .approach && $0.runway != nil},"Continuous arrival stream stopped")
        }
        print("PASS:occupied stands allow continuous arrivals; interval decreases to configured floor; every arrival has an approach")
    }
}
