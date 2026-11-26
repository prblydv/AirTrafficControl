import Foundation

@main struct DepartureHeadingChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        for (modelID,stand) in [("03",11),("09",0),("09",6)] {
        let s=Simulation(seed:17,continuousTraffic:false)
        s.followsAssignedGroundRoutes=true
        let gate=s.surface.gates[stand]
        s.aircraft=[Aircraft(id:"HEADING",modelID:modelID,departure:true,stand:stand,position:gate.position,heading:gate.heading,phase:.parked,readyToDepart:true)]
        s.selectedID="HEADING"
        let runway=s.clearanceRunways(for:s.aircraft[0])[0].id
        s.clearSelected(to:runway)
        print("START",runway,gate.heading,s.aircraft[0].route.prefix(3))
        for _ in 0..<14000 {
            if s.aircraft[0].crossingRequest != nil {s.approveCrossing()}
            s.tick(0.1)
            if s.aircraft[0].phase == .queued {break}
        }
        precondition(s.aircraft[0].phase == .queued)
        print("QUEUED",s.aircraft[0].position,s.aircraft[0].heading,"entry",s.aircraft[0].departureEntry!)
        s.clearSelected(to:runway)
        let held=s.aircraft[0]
        let next=held.route.first(where:{$0.distance(to:held.position)>1})!
        let entryHeading=atan2(next.y-held.position.y,next.x-held.position.x)
        precondition(cos(entryHeading-held.heading) >= -0.5,"Holding position faces away from runway entry")
        print("LINEUP",s.aircraft[0].route.prefix(5),s.aircraft[0].route.suffix(5))
        var turn=0.0,rolled=false
        for _ in 0..<4000 {
            let old=s.aircraft[0]
            s.tick(0.1)
            let next=s.aircraft[0],delta=atan2(sin(next.heading-old.heading),cos(next.heading-old.heading))
            turn+=abs(delta)
            if abs(delta)>1 {print("TURN",old.phase,next.phase,old.position,next.position,old.heading,next.heading)}
            if next.phase == .takeoffRoll {print("ROLL",next.heading,"expected",s.surface.heading(runway),"totalTurn",turn);rolled=true;break}
        }
        precondition(rolled && turn<Double.pi*1.5,"Runway entry made an unnecessary near-full rotation")
        print("PASS:departure",modelID,"stand",stand,"holds toward its entry and lines up without a full turn")
        }
    }
}
