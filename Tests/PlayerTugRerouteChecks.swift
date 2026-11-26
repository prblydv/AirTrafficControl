import Foundation

@main struct PlayerTugRerouteChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let s=Simulation(seed:17,continuousTraffic:false)
        s.followsAssignedGroundRoutes=true
        let graph=s.surface.taxiNetwork
        var dispatched=false
        for edge in graph.edges where !dispatched {
            let a=graph.nodes[edge.a],b=graph.nodes[edge.b],length=a.distance(to:b)
            guard length>75 else{continue}
            let p=Point.interpolate(a,b,fraction:0.35),q=Point.interpolate(a,b,fraction:0.65)
            guard p.distance(to:q)<95 else{continue}
            let heading=atan2(b.y-a.y,b.x-a.x)
            s.aircraft=[
                Aircraft(id:"PLAYER",modelID:"19",departure:true,stand:0,position:p,heading:heading,phase:.taxiing,route:[b]),
                Aircraft(id:"PRIORITY",modelID:"19",departure:true,stand:1,position:q,heading:heading + .pi,phase:.taxiing,route:[a])
            ]
            s.selectedID="PLAYER"
            guard s.groundHeadOnTraffic(for:s.aircraft[0])?.id=="PRIORITY" else{continue}
            let options=s.tugRerouteOptions(for:s.aircraft[0])
            guard options.count>=2 else{continue}
            precondition(Set(options.map(\.id)).count==options.count)
            for option in options {
                s.dispatchSelectedTug(to:option.target)
                if s.aircraft[0].recoveringGround {
                    precondition(!s.aircraft[0].underTow,"Aircraft moved before tug arrived")
                    precondition(s.aircraft[0].position==p && s.aircraft[1].position==q)
                    precondition(s.aircraft[1].route==[a] && !s.aircraft[1].recoveringGround)
                    precondition(s.aircraft[0].pendingTaxiRoute.last?.distance(to:b) ?? 999 < 1)
                    precondition(s.serviceTasks.contains{$0.kind == .pushback && $0.target == .aircraft("PLAYER")})
                    dispatched=true;break
                }
            }
        }
        precondition(dispatched,"No selectable reachable tug alternatives could dispatch")
        let retainedDestination=s.aircraft[0].pendingTaxiRoute.last!
        s.aircraft[0].waitingForTraffic=true;s.aircraft[0].blockedBy="PRIORITY"
        s.aircraft[0].underTow=true
        s.aircraft[1].heading=s.aircraft[0].heading
        let retryOptions=s.tugRerouteOptions(for:s.aircraft[0])
        precondition(!retryOptions.isEmpty,"Blocked recovery lost its tug choices")
        s.dispatchSelectedTug(to:retryOptions.last!.target)
        precondition(s.aircraft[0].underTow && s.aircraft[0].pendingTaxiRoute.last==retainedDestination,"Retry detached tug or lost original destination")
        // Let the original real-service lifecycle check exercise tug arrival.
        s.aircraft[0].underTow=false
        print("PASS:player chooses among multiple connected passing areas; only selected aircraft gets tug; destination preserved; no teleport")
        let airborne=s.aircraft[1]
        var flying=airborne;flying.altitude=4500;flying.phase = .approach
        precondition(s.tugRerouteOptions(for:flying).isEmpty)
        let start=s.aircraft[0].position
        var attached=false,moved=false,cleared=false
        for _ in 0..<6000 {
            for id in s.aircraft.filter({$0.crossingRequest != nil}).map(\.id) {s.selectedID=id;s.approveCrossing()}
            s.tick(0.1)
            if s.aircraft[0].underTow {
                attached=true
                let task=s.serviceTasks.first{$0.kind == .pushback && $0.target == .aircraft("PLAYER") && $0.state == .working}!
                let tug=s.vehicles.first{$0.taskID==task.id}!
                precondition(tug.position.distance(to:s.tugAttachmentPoint(for:s.aircraft[0]))<0.1)
                precondition(tug.position.distance(to:s.aircraft[0].position)>3,"Tug hidden at aircraft centre")
            }
            if s.aircraft[0].position.distance(to:start)>10 {moved=true}
            if moved && !s.aircraft[0].recoveringGround {cleared=true;break}
        }
        if !attached || !moved || !cleared {
            for f in s.aircraft {print("TOW-FAIL",f.id,f.phase,f.position,"underTow",f.underTow,"blockedBy",f.blockedBy as Any,"recovering",f.recoveringGround,"route",f.route.first as Any,f.route.last as Any)}
            print("TOW-FAIL-TASKS",s.serviceTasks.filter{$0.kind == .pushback})
        }
        precondition(attached && moved,"Dispatched tug failed to arrive, attach and move aircraft")
        precondition(cleared,"Tug started moving but never reached the passing area")
        print("PASS:dispatched tug arrives, attaches visibly at nose and actually tows selected aircraft")
    }
}
