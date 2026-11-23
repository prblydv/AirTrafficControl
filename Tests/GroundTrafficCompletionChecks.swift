import Foundation
@main struct GroundTrafficCompletionChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let d=try JSONDecoder().decode(AirportRouteDocument.self,from:Data(contentsOf:root.appendingPathComponent("AirTrafficControl/airport-routes.json")))
        try RoutingOverrides.activate(d,persist:false)
        let seeds:[UInt64]=ProcessInfo.processInfo.environment["ATC_CHECK_SEED"].flatMap(UInt64.init).map{[$0]} ?? [17,9,42]
        for seed in seeds {
            let s=Simulation(seed:seed,continuousTraffic:false)
            for i in 0..<3 {s.aircraft[i].stopped=true}
            let ids=s.aircraft.filter{$0.departure}.map(\.id)
            var lastProgress=Dictionary(uniqueKeysWithValues:ids.map{($0,0.0)}),last=Dictionary(uniqueKeysWithValues:s.aircraft.map{($0.id,$0.position)})
            for id in ids {s.selectedID=id;let f=s.selected!;s.clearSelected(to:s.clearanceRunways(for:f)[0].id)}
            s.running=true
            for frame in 0..<12000 {
                if frame % 1000 == 0 {print("PROGRESS",seed,Int(s.elapsed),s.aircraft.filter{ids.contains($0.id) && $0.phase == .complete}.count,"plans",s.groundTrafficPlans.count,"searches",s.groundTrafficSearches,"cancels",s.groundTrafficCancellations)
                    if frame % 1000 == 0 {for f in s.aircraft where ids.contains(f.id) {print("STATE",f.id,f.phase,f.position,f.waitingForTraffic,f.blockedBy as Any,f.recoveringGround,f.underTow,f.route.count)}}
                }
                for f in s.aircraft.filter({ids.contains($0.id)}) {
                    s.selectedID=f.id
                    if let r=f.crossingRequest {
                        let busy=s.aircraft.contains {a in
                            a.id != f.id && a.runway==r && (([.lineup,.takeoffRoll,.landingRoll,.takeoff,.landing].contains(a.phase) && !a.waitingForTraffic) || (a.phase == .climbing && a.altitude<300))
                        }
                        if !busy {s.approveCrossing()}
                    }
                    if f.phase == .queued,let r=f.runway {
                        let busy=s.aircraft.contains {a in a.id != f.id && ((s.onRunway(a.position,r) && !a.airborne && ![.complete,.crashed].contains(a.phase)) || (a.runway==r && [.lineup,.takeoffRoll,.landingRoll,.takeoff,.landing].contains(a.phase)))}
                        if !busy {s.clearSelected(to:r)}
                    }
                }
                let before=s.aircraft
                s.tick(0.1)
                for (old,new) in zip(before,s.aircraft) {precondition(old.position.distance(to:new.position)<6.5,"Position jumped")}
                for f in s.aircraft where ids.contains(f.id) {
                    if f.position.distance(to:last[f.id]!)>1 {lastProgress[f.id]=s.elapsed;last[f.id]=f.position}
                }
                if s.aircraft.filter({ids.contains($0.id)}).allSatisfy({[.complete,.crashed].contains($0.phase)}) {break}
            }
            let departures=s.aircraft.filter{ids.contains($0.id)}
            print("SEED",seed,"TIME",Int(s.elapsed),"COMPLETE",departures.filter{$0.phase == .complete}.count,"LOSSES",s.violations)
            for f in departures where f.phase != .complete {
                print("PENDING",f.id,SurfaceLayout.gates[f.stand].name,f.phase.rawValue,"idle",Int(s.elapsed-(lastProgress[f.id] ?? 0)),"block",f.blockedBy ?? "none","cross",f.crossingRequest.map(String.init) ?? "none","recovery",f.recoveringGround,"pos",Int(f.position.x),Int(f.position.y),"lineupRemaining",f.lineupRemaining,"onAssignedStrip",f.runway.map{s.onRunway(f.position,$0)} ?? false,"underTow",f.underTow)
            }
            precondition(departures.allSatisfy{$0.phase == .complete} && s.violations==0,"Fleet did not finish safely")
            for v in s.vehicles where v.taskID != nil {
                if let task=s.serviceTasks.first(where:{$0.id==v.taskID}) {print("CREW",v.kind,task.target,task.state,"missingRoute",v.routeUnavailable,"aircraftBlock",v.waitingForAircraft,"pos",v.position,"remaining",v.route.count)}
            }
        }
    }
}
