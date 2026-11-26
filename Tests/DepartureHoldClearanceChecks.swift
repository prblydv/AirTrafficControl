import Foundation

@main struct DepartureHoldClearanceChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let s=Simulation(seed:17,continuousTraffic:false),surface=s.surface
        var checked=0
        for id in ["05","07","19"] {
            let model=AircraftCatalog.model(id)
            for runway in surface.definition.runways.indices where surface.eligible(model,runway:runway) {
                guard let gate=surface.gates.first(where:{$0.accepts(model,purpose:model.defaultPurpose) && $0.departureRunways.contains(runway)}) else{continue}
                let entry=surface.departureEntry(for:model,runway:runway,from:gate.port)
                precondition(!surface.taxiRoute(from:gate.port,to:entry.hold,minimumWidth:model.span*0.55).isEmpty,"Safe holding point disconnected from taxiway")
                precondition(!surface.network.shortestPath(from:entry.hold,to:entry.lineup,maximumAccessDistance:2,minimumWidth:model.span*0.55).isEmpty,"Holding point cannot reach runway after clearance")
                for angle in stride(from:0.0,to:Double.pi*2,by:Double.pi/8) {
                    let held=Aircraft(id:"HOLD",modelID:id,departure:true,stand:0,position:entry.hold,heading:angle,phase:.queued,runway:runway)
                    precondition(!s.occupiesRunway(held,runway),"Queued \(id) footprint intrudes on runway \(runway)")
                    let a=surface.threshold(runway),b=surface.runwayEnds[runway].1,l=a.distance(to:b)
                    let t=min(1,max(0,((entry.hold.x-a.x)*(b.x-a.x)+(entry.hold.y-a.y)*(b.y-a.y))/(l*l)))
                    let rolling=Aircraft(id:"ROLL",modelID:"05",departure:false,stand:1,position:surface.runwayPoint(runway,t),heading:surface.heading(runway),phase:.landingRoll,runway:runway)
                    precondition(!s.groundConflict(rolling,from:rolling.position,to:rolling.position,other:held,margin:1),"Landing wing intersects queued aircraft")
                }
                checked+=1
            }
        }
        precondition(checked>=4)
        print("PASS:\(checked) model/runway departure holds remain fully outside runway at16headings, clear landing wings, and connect to taxi/lineup paths")
    }
}
