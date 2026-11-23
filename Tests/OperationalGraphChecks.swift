import Foundation
@main struct OperationalGraphChecks {
    static func document(_ points:[(Int,Point)],_ pairs:[(Int,Int,Int)])->AirportRouteDocument {
        var d=AirportRouteDocument();d.width=600;d.height=600
        d.nodes=points.map{RouteNode(id:$0.0,layer:.aircraft,point:$0.1)}
        d.edges=pairs.map{RouteEdge(id:$0.0,a:$0.1,b:$0.2,access:[0])}
        return d
    }
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let left=Point(x:20,y:50),right=Point(x:80,y:50),junction=Point(x:50,y:50),down=Point(x:50,y:80)
        var t=document([(10,left),(11,right),(40,junction),(41,down),(99,Point(x:90,y:90))],[(100,10,11),(101,40,41)])
        t.nodes[2].kind = .holdingArea;t.nodes[2].holdingRadius=12
        let compiled=OperationalGraphCompiler.compile(t),g=compiled.graph(layer:.aircraft,role:0)
        precondition(!g.shortestPath(from:left,to:down,maximumAccessDistance:0.1).isEmpty)
        precondition(compiled.isolatedSourceNodeIDs.contains(99) && g.nodes.count==4)
        precondition(Set(g.edges.flatMap(\.sourceIDs))==Set([100,101]))
        precondition(Set(g.sourceNodeIDs.values.flatMap{$0})==Set([10,11,40,41]))
        precondition(g.holdingAreas.values.contains(12))
        print("PASS:endpoint junctions connect, isolated nodes disappear, valid stand spurs and source provenance remain")
        var cross=document([(1,left),(2,right),(3,Point(x:50,y:20)),(4,down)],[(10,1,2),(20,3,4)])
        let conflict=OperationalGraphCompiler.compile(cross)
        precondition(conflict.conflicts.count==1 && !conflict.conflicts[0].allowsTurns)
        precondition(conflict.graph(layer:.aircraft,role:0).shortestPath(from:left,to:down,maximumAccessDistance:0.1).isEmpty)
        cross.junctions=[RouteJunction(point:junction,mode:.connect)]
        precondition(!OperationalGraphCompiler.compile(cross).graph(layer:.aircraft,role:0).shortestPath(from:left,to:down,maximumAccessDistance:0.1).isEmpty)
        cross.junctions=[RouteJunction(point:junction,mode:.conflictOnly)]
        precondition(OperationalGraphCompiler.compile(cross).graph(layer:.aircraft,role:0).shortestPath(from:left,to:down,maximumAccessDistance:0.1).isEmpty)
        print("PASS:unlabelled crossings conflict without invented turns; explicit junction annotations control connectivity")
        t.turns=[RouteTurn(nodeID:40,fromEdgeID:100,toEdgeID:101,allowed:false)]
        let restricted=OperationalGraphCompiler.compile(t).graph(layer:.aircraft,role:0)
        precondition(restricted.shortestPath(from:left,to:down,maximumAccessDistance:0.1).isEmpty)
        precondition(!restricted.shortestPath(from:left,to:right,maximumAccessDistance:0.1).isEmpty)
        var flight=Aircraft(id:"A",modelID:"19",departure:true,stand:0,position:left,phase:.taxiing)
        let snapshot=GroundTrafficSnapshot(revision:1,now:0,horizon:180,reservations:[])
        precondition(GroundTrafficPlanner.plan(flight:flight,graph:restricted,target:down,snapshot:snapshot)==nil)
        print("PASS:distance and timed planners both enforce forbidden turns")
        var one=document([(1,left),(2,right)],[(77,1,2)])
        one.edges[0].direction = .forward;one.edges[0].width=30;one.edges[0].speedLimit=2
        let directed=OperationalGraphCompiler.compile(one).graph(layer:.aircraft,role:0)
        let p=Point(x:30,y:50),q=Point(x:70,y:50)
        precondition(!directed.shortestPath(from:p,to:q,maximumAccessDistance:0.1,minimumWidth:13.2).isEmpty)
        precondition(directed.shortestPath(from:q,to:p,maximumAccessDistance:0.1).isEmpty)
        flight.position=q
        precondition(GroundTrafficPlanner.plan(flight:flight,graph:directed,target:p,snapshot:snapshot)==nil)
        precondition(GroundTrafficPlanner.plan(flight:flight,route:[p],snapshot:snapshot,constraints:directed)==nil)
        flight.position=p
        let timed=GroundTrafficPlanner.plan(flight:flight,graph:directed,target:q,snapshot:snapshot)!
        precondition(timed.legs.allSatisfy{$0.cruise<=2})
        var split=directed;split.split(at:p)
        precondition(split.edges.allSatisfy{$0.direction == .forward && $0.width==30 && $0.sourceIDs==[77]})
        one.edges[0].width=5
        let narrow=OperationalGraphCompiler.compile(one).graph(layer:.aircraft,role:0)
        precondition(narrow.shortestPath(from:p,to:q,maximumAccessDistance:0.1,minimumWidth:13.2).isEmpty)
        precondition(narrow.shortestPath(from:Point(x:50,y:52),to:Point(x:50,y:48),maximumAccessDistance:3,minimumWidth:13.2).isEmpty)
        precondition(GroundTrafficPlanner.plan(flight:flight,graph:narrow,target:q,snapshot:snapshot)==nil)
        print("PASS:one-way access survives interior projections/splits; width and speed limits cannot be bypassed")
        let runway=AirportRunwayDefinition(id:0,name:"01",reciprocalName:"19",start:Point(x:100,y:100),end:Point(x:200,y:100),lengthMeters:1000,width:10,hold:Point(x:90,y:80),exit:Point(x:190,y:80),orbitDirection:1,rangeReferenceNM:1)
        let line=document([(1,Point(x:50,y:100)),(2,Point(x:250,y:100)),(3,Point(x:300,y:100))],[(88,1,2),(89,2,3)])
        var taxi=OperationalGraphCompiler.compile(line,runways:[runway]).graph(layer:.aircraft,role:0)
        precondition(taxi.edges.contains{$0.kind == .runway && $0.sourceIDs==[88]})
        taxi.edges=taxi.edges.filter{$0.kind != .runway};taxi=taxi.removingIsolatedNodes()
        precondition(!taxi.shortestPath(from:Point(x:220,y:100),to:Point(x:290,y:100),maximumAccessDistance:0.1).isEmpty)
        precondition(taxi.shortestPath(from:Point(x:60,y:100),to:Point(x:240,y:100),maximumAccessDistance:0.1).isEmpty)
        var service=line
        for i in service.nodes.indices {service.nodes[i].layer = .services}
        for i in service.edges.indices {service.edges[i].access=[8];service.edges[i].kind = .runwayCrossing}
        precondition(service.problems().isEmpty)
        let serviceGraph=OperationalGraphCompiler.compile(service,runways:[runway]).graph(layer:.services,role:8)
        precondition(serviceGraph.edges.contains{$0.kind == .runwayCrossing && $0.runwayIDs.contains(0)})
        precondition(serviceGraph.edges.contains{$0.kind == .serviceRoad && $0.runwayIDs.isEmpty})
        print("PASS:finite runway boundaries split only the actual strip; extension taxi lanes stay connected")
        var invalid=one;invalid.edges[0].width = -1;precondition(!invalid.problems().isEmpty)
        invalid=one;invalid.turns=[RouteTurn(nodeID:999,fromEdgeID:77,toEdgeID:77)];precondition(!invalid.problems().isEmpty)
        let airport=AirportPackage.delhi,surface=AirportSurface(package:airport)
        let full=surface.network,taxiGraph=surface.taxiNetwork
        precondition(taxiGraph.nodes.indices.allSatisfy{id in taxiGraph.edges.contains{$0.a==id || $0.b==id}})
        precondition(Set(full.edges.flatMap(\.sourceIDs))==Set(airport.routes.edges.filter{$0.access.contains(0)}.map(\.id)))
        for gate in surface.gates {
            precondition(taxiGraph.closestPoint(to:gate.port)!.distance(to:gate.port)<2)
        }
        print("PASS:Delhi compiles with all aircraft source-edge IDs, 19 stand accesses, no isolated taxi nodes",full.nodes.count,full.edges.count,"taxi",taxiGraph.nodes.count,taxiGraph.edges.count,"conflicts",surface.operational.conflicts.count)
        let recovery=Simulation(seed:17,continuousTraffic:false,airportPackage:airport)
        recovery.aircraft=[Aircraft(id:"RECOVER",modelID:"07",departure:true,stand:0,position:surface.gates[0].position,recoveringGround:true,phase:.pushback)]
        recovery.vehicles=[]
        var old=ServiceTask(kind:.pushback,target:.aircraft("RECOVER"),remaining:0);old.state = .returning
        recovery.serviceTasks=[old]
        recovery.updateGroundServices(0.1);recovery.updateGroundServices(0.1)
        precondition(recovery.serviceTasks.filter{$0.kind == .pushback && $0.state == .queued}.count==1)
        precondition(recovery.serviceTasks.contains{$0.id==old.id && $0.state == .returning})
        print("PASS:tug recovery keeps exactly one live request while a previous tug returns home")

    }
}
