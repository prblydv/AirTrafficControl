import Foundation

@main struct LocalTrafficFollowingChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        func scenario(blocker:Point)->Simulation {
            let s=Simulation(seed:17,continuousTraffic:false)
            s.followsAssignedGroundRoutes=true
            s.aircraft=[
                Aircraft(id:"FOLLOWER",modelID:"07",departure:false,stand:0,position:Point(x:700,y:470),heading:0,phase:.taxiing,route:[Point(x:950,y:470)]),
                Aircraft(id:"BLOCKER",modelID:"07",departure:false,stand:1,position:blocker,phase:.parked)
            ]
            s.running=true
            return s
        }
        let distant=scenario(blocker:Point(x:950,y:470))
        for _ in 0..<20 { distant.tick(0.1) }
        precondition(distant.aircraft[0].position.x>701,"Distant occupied destination stranded follower")
        precondition(distant.aircraft[0].route==[Point(x:950,y:470)],"Assigned route changed for distant traffic")
        let behind=scenario(blocker:Point(x:650,y:470))
        for _ in 0..<20 { behind.tick(0.1) }
        precondition(behind.aircraft[0].position.x>701,"Traffic behind blocked forward movement")
        let nearby=scenario(blocker:Point(x:735,y:470))
        for _ in 0..<50 { nearby.tick(0.1) }
        precondition(nearby.aircraft[0].waitingForTraffic,"Follower failed to stop for nearby aircraft")
        precondition(nearby.aircraft[0].position.distance(to:nearby.aircraft[1].position)>20,"Follower overlapped nearby aircraft")
        precondition(nearby.aircraft[0].route==[Point(x:950,y:470)],"Same-direction queue rerouted follower")
        nearby.aircraft.removeLast()
        let before=nearby.aircraft[0].position
        for _ in 0..<30 { nearby.tick(0.1) }
        precondition(nearby.aircraft[0].position.distance(to:before)>1,"Follower failed to resume after blocker cleared")
        print("PASS:distant occupied destination permits progress; nearby blocker stops follower; clearing resumes movement")
        for phase in [FlightPhase.parked,.servicing,.crashed,.diverted,.complete] {
            let stale=scenario(blocker:Point(x:650,y:300))
            stale.aircraft[1].phase=phase
            stale.aircraft[0].yieldTo="BLOCKER"
            stale.aircraft[0].yieldPassPoint=Point(x:900,y:470)
            stale.aircraft[0].yieldPassHeading=0
            stale.aircraft[0].waitingForTraffic=true
            stale.aircraft[0].blockedBy="BLOCKER"
            for _ in 0..<20 {stale.tick(0.1)}
            precondition(stale.aircraft[0].position.x>701 && !stale.aircraft[0].waitingForTraffic,"Stale yield stopped flight after opponent \(phase)")
            precondition(stale.aircraft[0].yieldTo==nil && stale.aircraft[0].blockedBy==nil)
        }
        let remoteTow=scenario(blocker:Point(x:100,y:100))
        remoteTow.aircraft[1].phase = .pushback
        remoteTow.aircraft[1].recoveringGround=true
        remoteTow.aircraft[0].waitsForTugClearance="BLOCKER"
        for _ in 0..<20 {remoteTow.tick(0.1)}
        precondition(remoteTow.aircraft[0].position.x>701 && remoteTow.aircraft[0].waitsForTugClearance==nil,"Remote unfinished tow kept clear aircraft waiting")
        print("PASS:parked/servicing/crashed/retired opponents and remote unfinished tows cannot leave stale traffic holds")
        for phase in [FlightPhase.servicing,.parked,.gateWait,.queued,.pushback] {
            let inactive=scenario(blocker:Point(x:100,y:100))
            inactive.aircraft[0].phase=phase
            inactive.aircraft[0].waitingForTraffic=true
            inactive.aircraft[0].blockedBy="OLD-BLOCKER"
            inactive.tick(0.1)
            precondition(!inactive.aircraft[0].waitingForTraffic && inactive.aircraft[0].blockedBy==nil,"Inactive phase retained stale traffic label")
        }
        print("PASS:services, parked, queued and awaiting-tug states clear obsolete traffic labels")
        let stoppedTow=scenario(blocker:Point(x:740,y:430))
        stoppedTow.aircraft[1].phase = .pushback
        stoppedTow.aircraft[1].heading = .pi/2
        stoppedTow.aircraft[1].route=[Point(x:740,y:500)]
        stoppedTow.aircraft[1].recoveringGround=true
        stoppedTow.aircraft[1].underTow=true
        stoppedTow.aircraft[1].stopped=true
        stoppedTow.aircraft[1].waitingForTraffic=true
        for _ in 0..<20 {stoppedTow.tick(0.1)}
        precondition(stoppedTow.aircraft[0].position.x>701,"Stopped tow reserved an empty future crossing")
        print("PASS:stopped tow cannot reserve an empty future corridor")
    }
}
