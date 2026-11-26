import Foundation

@main struct RunwayFootprintCollisionChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        for phase in [FlightPhase.landingRoll,.takeoffRoll] {
            let s=Simulation(seed:17,continuousTraffic:false)
            s.followsAssignedGroundRoutes=true
            let center=s.surface.runwayPoint(0,0.6),heading=s.surface.heading(0)
            let beside=s.surface.offset(center,heading:heading,side:18)
            s.aircraft=[
                Aircraft(id:"ROLL",modelID:"05",departure:phase == .takeoffRoll,stand:0,position:center,heading:heading,phase:phase,route:[s.runways[0].end],runway:0,groundSpeed:20),
                Aircraft(id:"OCCUPANT",modelID:"05",departure:true,stand:1,position:beside,heading:heading,phase:.parked)
            ]
            precondition(!s.onRunway(beside,0) && s.occupiesRunway(s.aircraft[1],0),"Fixture must have off-strip centre and on-strip wings")
            s.running=true;s.tick(0.1)
            precondition(s.aircraft.allSatisfy{$0.phase == .crashed} && s.violations==2 && s.runways[0].closed,"Runway roll passed through occupying aircraft without accident")
        }
        let apron=Simulation(seed:17,continuousTraffic:false)
        apron.aircraft=[Aircraft(id:"TAXI",modelID:"05",departure:true,stand:0,position:Point(x:700,y:470),phase:.taxiing,route:[Point(x:750,y:470)]),Aircraft(id:"PARK",modelID:"05",departure:true,stand:1,position:Point(x:700,y:470),phase:.parked)]
        apron.running=true;apron.tick(0.1)
        precondition(apron.incidents.isEmpty,"Apron contact generated runway accident")
        print("PASS:landing/takeoff contact with on-strip footprint crashes both and closes runway; apron contact does not generate accident")
    }
}
