import Foundation

@main struct BaggageServiceChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let s=Simulation(seed:17,continuousTraffic:false)
        let stands=[11,12,13]
        s.aircraft=stands.enumerated().map {number,stand in
            Aircraft(id:"BAGS-\(number)",modelID:"07",departure:false,stand:stand,position:s.surface.gates[stand].position,phase:.parked)
        }
        let originalTractors=s.vehicles.filter{$0.kind == .baggageTractor}.count
        for i in s.aircraft.indices {s.beginTurnaround(i)}
        s.running=true
        for _ in 0..<6000 {
            s.tick(0.1)
            let carts=s.vehicles.filter{$0.kind == .baggageCart}
            let tractors=s.vehicles.filter{$0.kind == .baggageTractor}
            precondition(Set(carts.compactMap(\.baggageTractorID)).count == tractors.count,"Each tractor needs its own cart")
            for cart in carts {
                if let taskID=cart.taskID,let task=s.serviceTasks.first(where:{$0.id == taskID}),![.returning,.done,.cancelled].contains(task.state),
                   let tractor=tractors.first(where:{$0.id == cart.baggageTractorID}),let tractorTask=tractor.taskID.flatMap({id in s.serviceTasks.first{$0.id == id}}) {
                    precondition(task.target == tractorTask.target,"Cart followed another aircraft's tractor")
                }
            }
            if s.aircraft.allSatisfy(\.readyToDepart) && s.busyVehicleCount == 0 {break}
        }
        for flight in s.aircraft {
            precondition(flight.baggageHandled && flight.readyToDepart,"Concurrent baggage service never finished for \(flight.id)")
        }
        precondition(s.vehicles.filter{$0.kind == .baggageTractor}.count>originalTractors,"Fixture did not exercise extra baggage tractors")
        precondition(s.busyVehicleCount == 0 && s.vehicles.allSatisfy{$0.position.distance(to:$0.depot)<0.1},"Baggage crew failed to return and release")
        print("PASS:simultaneous northern-stand turnarounds scale paired baggage trains, complete baggage and return all crews")
        // Returned trains must remain reusable, without stealing another cart.
        s.aircraft=[Aircraft(id:"BAGS-REUSE",modelID:"07",departure:false,stand:12,position:s.surface.gates[12].position,phase:.parked)]
        s.beginTurnaround(0)
        for _ in 0..<6000 {
            s.tick(0.1)
            if s.aircraft[0].readyToDepart && s.busyVehicleCount == 0 {break}
        }
        precondition(s.aircraft[0].baggageHandled && s.aircraft[0].readyToDepart && s.busyVehicleCount == 0)
        print("PASS:paired baggage crews complete another turnaround after returning home")
    }
}
