import Foundation

@main struct CrowdedTowRecoveryChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        var doc=AirportRouteDocument()
        doc.nodes=AirportPackage.delhi.routes.nodes.filter{$0.layer == .services}
        let ids=Set(doc.nodes.map(\.id))
        doc.edges=AirportPackage.delhi.routes.edges.filter{ids.contains($0.a) && ids.contains($0.b)}
        let points=[Point(x:100,y:800),Point(x:160,y:800),Point(x:220,y:800),Point(x:220,y:860),Point(x:100,y:880),Point(x:500,y:880),Point(x:500,y:600),Point(x:220,y:600)]
        for (i,p) in points.enumerated() {doc.nodes.append(.init(id:20000+i,layer:.aircraft,point:p))}
        for (i,pair) in [(0,1),(1,2),(2,3),(0,4),(4,5),(5,6),(6,7),(7,2)].enumerated() {
            doc.edges.append(.init(id:20000+i,a:20000+pair.0,b:20000+pair.1,access:[0],width:100))
        }
        let s=Simulation(seed:17,continuousTraffic:false,routes:doc)
        s.followsAssignedGroundRoutes=true
        var tow=Aircraft(id:"RECOVER",modelID:"19",departure:true,stand:0,position:points[0],heading:0,phase:.pushback,route:[points[1],points[2],points[3]],underTow:true,pendingTaxiRoute:[points[3]])
        tow.recoveringGround=true;tow.yieldTo="PRIORITY"
        var other=Aircraft(id:"PRIORITY",modelID:"19",departure:true,stand:1,position:Point(x:190,y:800),heading:.pi,phase:.taxiing,route:[points[0]])
        other.waitsForTugClearance="RECOVER"
        let blocker=Aircraft(id:"THIRD",modelID:"19",departure:true,stand:2,position:points[1],phase:.parked)
        s.aircraft=[tow,other,blocker];s.running=true
        let longer=s.surface.taxiRoute(from:points[0],to:points[3],traffic:[blocker])
        precondition(FlightCurves.length(from:points[0],route:longer)>400,"Long clear bypass was rejected")
        var cleared=false,replanned=false
        for _ in 0..<9000 {
            s.tick(0.1)
            replanned = replanned || s.messages.contains{$0.text.contains("alternative clear route")}
            precondition(s.aircraft[2].position==points[1])
            if !s.aircraft[0].recoveringGround {cleared=true;break}
        }
        precondition(replanned && cleared,"Tow remained deadlocked with third-party traffic")
        print("PASS:third aircraft blocks initial tow; attached tug replans without teleport and reaches another passing area; clear bypass exceeds400units")
        var loop=RoadGraph()
        let start=Point(x:0,y:0),target=Point(x:-20,y:0)
        loop.addLane([start,target]);loop.addLane([start,Point(x:20,y:0),Point(x:20,y:40),Point(x:-20,y:40),target])
        let route=loop.shortestPath(from:start,to:target,initialHeading:0,turnPenalty:35)
        precondition(route.first!.x>0,"Heading-aware routing still chose immediate reversal")
        let offset=loop.shortestPath(from:Point(x:0,y:0.3),to:target,initialHeading:0,turnPenalty:35)
        precondition(offset.first(where:{$0.distance(to:Point(x:0,y:0))>2})!.x>0,"Tiny graph projection spur erased incoming heading")
        print("PASS:forward connected route beats immediate180degree reversal")
    }
}
