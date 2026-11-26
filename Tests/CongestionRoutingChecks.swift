import Foundation

@main struct CongestionRoutingChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let s=Simulation(seed:17,continuousTraffic:false),surface=s.surface
        var alternatives=0
        for runway in surface.definition.runways.indices {
            for t in [0.08,0.92] {
                let middle=surface.runwayPoint(runway,t),heading=surface.heading(runway)
                guard let start=surface.taxiNetwork.closestPoint(to:surface.offset(middle,heading:heading,side:30)),
                      let target=surface.taxiNetwork.closestPoint(to:surface.offset(middle,heading:heading,side:-30)) else{continue}
                let normal=surface.taxiRoute(from:start,to:target)
                guard normal.count>3 else{continue}
                let blocker=Aircraft(id:"QUEUE",modelID:"07",departure:true,stand:0,position:normal[normal.count/2],phase:.queued)
                let alternative=surface.taxiRoute(from:start,to:target,traffic:[blocker])
                guard !alternative.isEmpty,alternative != normal else{continue}
                func cost(_ route:[Point])->Double {
                    var previous=start,total=0.0
                    for point in route {total+=previous.distance(to:point)+surface.taxiTrafficCost(from:previous,to:point,traffic:[blocker],clearance:0);previous=point}
                    return total
                }
                if cost(alternative)<cost(normal) {
                    alternatives+=1
                    print("PASS:runway",runway,"end",t,"uses lower-congestion connected alternative")
                }
            }
        }
        precondition(alternatives>0,"Traffic costs never selected a connected alternative around a blocked route")
        print("PASS:congestion-aware initial routes use traced alternatives near runway ends")
    }
}
