import Foundation

@main struct StandAllocationAndRelocationChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let package=AirportPackage.delhi
        for model in AircraftCatalog.models where model.family == .widebody {
            let compatible=package.definition.stands.filter{$0.accepts(model,purpose:.passenger)}
            precondition(Set(compatible.map(\.name)) == Set(["G1","G4","G9","G11"]),"Widebody parking must use only the four requested western stands")
        }
        for seed in [UInt64(1),9,17,42] {
            let s=Simulation(seed:seed,continuousTraffic:false)
            precondition(s.aircraft.count==s.airport.traffic.initial.count,"Stand restrictions silently dropped an initial flight")
            precondition(s.aircraft.filter{$0.model.family == .widebody}.allSatisfy{[0,3,8,10].contains($0.stand) && s.surface.gates[$0.stand].accepts($0.model,purpose:$0.operatingPurpose)})
            precondition(s.aircraft.filter{(11...14).contains($0.stand)}.allSatisfy{[AircraftFamily.regional,.turboprop].contains($0.model.family)},"Northern initial flights should strongly prefer small aircraft")
        }
        let arrivals=Simulation(seed:17,continuousTraffic:true)
        arrivals.aircraft=[];arrivals.startLive()
        for _ in 0..<2500 {
            arrivals.tick(0.1)
            if let flight=arrivals.aircraft.first {
                if flight.model.family == .widebody {precondition([0,3,8,10].contains(flight.stand))}
                if [.regional,.turboprop].contains(flight.model.family) && flight.operatingPurpose == .passenger {precondition((11...14).contains(flight.stand),"Small arrival did not prefer free north apron")}
                arrivals.aircraft=[]
            }
        }
        print("PASS:widebodies use only G1/G4/G9/G11; small aircraft strongly preferred at north stands; full initial fleet retained")
        let s=Simulation(seed:17,continuousTraffic:false)
        s.followsAssignedGroundRoutes=true
        let old=13,gate=s.surface.gates[old]
        s.aircraft=[Aircraft(id:"RELOCATE",modelID:"04",departure:false,stand:old,position:gate.position,heading:gate.heading,phase:.servicing,runway:0)]
        s.selectedID="RELOCATE";s.beginTurnaround(0);s.running=true
        for _ in 0..<10 {s.tick(0.1)}
        let options=s.standRelocationOptions(for:s.aircraft[0])
        precondition(!options.isEmpty,"Servicing aircraft has no tug relocation option")
        let target=options[0],start=s.aircraft[0].position
        s.relocateSelectedByTug(to:target)
        precondition(s.aircraft[0].position==start && s.aircraft[0].towRelocationStand==target && s.aircraft[0].recoveringGround)
        var arrived=false,attached=false
        for _ in 0..<16000 {
            if s.aircraft[0].crossingRequest != nil {s.approveCrossing()}
            let before=s.aircraft[0].position
            s.tick(0.1)
            attached=attached || s.aircraft[0].underTow
            precondition(s.aircraft[0].position.distance(to:before)<1,"Stand relocation teleported aircraft")
            if s.aircraft[0].stand==target && s.aircraft[0].towRelocationStand==nil {arrived=true;break}
        }
        if !arrived {print("RELOCATION FAIL",s.aircraft[0].phase,s.aircraft[0].position,s.aircraft[0].blockedBy as Any,s.serviceTasks.filter{$0.kind == .pushback})}
        precondition(attached && arrived,"Tug failed to relocate servicing widebody")
        print("RELOCATION ARRIVED",s.aircraft[0].stand,s.aircraft[0].phase,s.aircraft[0].position)
        precondition(s.aircraft[0].position.distance(to:s.surface.gates[target].position)<0.1 && s.aircraft[0].phase == .servicing)
        for _ in 0..<6000 {s.tick(0.1);if s.aircraft[0].readyToDepart && s.busyVehicleCount==0 {break}}
        if !s.aircraft[0].readyToDepart || s.busyVehicleCount != 0 {
            print("RELOCATION SERVICES FAIL",s.aircraft[0].phase,s.serviceProgress(for:s.aircraft[0]),s.busyVehicleCount)
            for task in s.serviceTasks {print("RELOCATION TASK",task.kind,task.state,task.prepared,task.effectApplied,task.remaining)}
        }
        precondition(s.aircraft[0].readyToDepart && s.busyVehicleCount==0,"Ground services failed to resume after relocation")
        print("PASS:servicing widebody is towed to compatible stand with crossing authority, no teleport, and completes services afterward")
    }
}
