import Foundation

enum RouteLaneKind:String,Codable {case taxiway, serviceRoad, runway, runwayCrossing, standAccess}
enum RouteDirection:String,Codable {case both, forward, reverse}
enum RouteNodeKind:String,Codable {case lane, junction, stand, holdingArea}
enum RouteJunctionMode:String,Codable {case connect, conflictOnly}
struct RouteJunction:Codable,Equatable {var point:Point;var mode:RouteJunctionMode;var edgeIDs:[Int]? = nil}
struct RouteTurn:Codable,Equatable {
    var nodeID:Int? = nil
    var point:Point? = nil
    var fromEdgeID:Int
    var toEdgeID:Int
    var allowed:Bool = true
}
struct OperationalConflict {
    var layer:RouteLayer
    var point:Point
    var sourceEdgeIDs:[Int]
    var radius:Double
    var allowsTurns:Bool
}
struct CompiledOperationalGraph {
    var layers:[RouteLayer:RoadGraph]=[:]
    var conflicts:[OperationalConflict]=[]
    var isolatedSourceNodeIDs:[Int]=[]
    var errors:[String]=[]
    func graph(layer:RouteLayer,role:Int)->RoadGraph {
        guard var graph=layers[layer] else{return RoadGraph()}
        graph.edges=graph.edges.filter{$0.access.isEmpty || $0.access.contains(role)}
        return graph.removingIsolatedNodes()
    }
}

enum OperationalGraphCompiler {
    private struct Lane {let source:RouteEdge;let layer:RouteLayer;let a:Point;let b:Point}
    private struct Cut {let t:Double;let point:Point}
    static func compile(_ document:AirportRouteDocument,runways:[AirportRunwayDefinition]=[],defaultWidth:Double=10)->CompiledOperationalGraph {
        var result=CompiledOperationalGraph()
        let indexed=Dictionary(document.nodes.map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
        let lanes=document.edges.compactMap {edge->Lane? in
            guard let a=indexed[edge.a],let b=indexed[edge.b],a.layer==b.layer,a.point.distance(to:b.point)>0.00001 else{return nil}
            return Lane(source:edge,layer:a.layer,a:a.point,b:b.point)
        }
        var cuts=lanes.map{[Cut(t:0,point:$0.a),Cut(t:1,point:$0.b)]}
        func add(_ index:Int,_ t:Double) {
            guard t>0.000001 && t<0.999999 else{return}
            let p=Point.interpolate(lanes[index].a,lanes[index].b,fraction:t)
            if !cuts[index].contains(where:{$0.point.distance(to:p)<0.001}) {cuts[index].append(.init(t:t,point:p))}
        }
        func mode(_ p:Point,_ a:Int,_ b:Int,endpoint:Bool)->RouteJunctionMode {
            if let annotation=document.junctions?.first(where:{$0.point.distance(to:p)<0.1 && ($0.edgeIDs==nil || ($0.edgeIDs!.contains(a) && $0.edgeIDs!.contains(b)))}) {return annotation.mode}
            return endpoint ? .connect:.conflictOnly
        }
        // Exact endpoint-on-edge T joins are safe to connect. Unlabelled proper
        // crossings get a conflict resource, not invented turning permissions.
        if lanes.count>1 {for i in 0..<(lanes.count-1) {for j in (i+1)..<lanes.count {
            let a=lanes[i],b=lanes[j]
            guard a.layer==b.layer,max(a.a.x,a.b.x)+0.01>=min(b.a.x,b.b.x),max(b.a.x,b.b.x)+0.01>=min(a.a.x,a.b.x),max(a.a.y,a.b.y)+0.01>=min(b.a.y,b.b.y),max(b.a.y,b.b.y)+0.01>=min(a.a.y,a.b.y) else{continue}
            let ux=a.b.x-a.a.x,uy=a.b.y-a.a.y,vx=b.b.x-b.a.x,vy=b.b.y-b.a.y,den=ux*vy-uy*vx
            if abs(den)<0.0000001 {continue}
            let dx=b.a.x-a.a.x,dy=b.a.y-a.a.y,t=(dx*vy-dy*vx)/den,u=(dx*uy-dy*ux)/den
            guard t >= -0.000001,t<=1.000001,u >= -0.000001,u<=1.000001 else{continue}
            let point=Point.interpolate(a.a,a.b,fraction:min(1,max(0,t)))
            let endpoint=t<0.000001 || t>0.999999 || u<0.000001 || u>0.999999
            let policy=mode(point,a.source.id,b.source.id,endpoint:endpoint)
            if policy == .connect {add(i,t);add(j,u)}
            if !endpoint || policy == .conflictOnly {
                result.conflicts.append(.init(layer:a.layer,point:point,sourceEdgeIDs:[a.source.id,b.source.id],radius:max(a.source.width ?? defaultWidth,b.source.width ?? defaultWidth)/2,allowsTurns:policy == .connect))
            }
        }}}
        // Split at the finite strip rectangle, so only the portion actually on
        // a runway is excluded from taxi routing, never its infinite extension.
        for (i,lane) in lanes.enumerated() {
            for runway in runways {
                let dx=runway.end.x-runway.start.x,dy=runway.end.y-runway.start.y,length=runway.start.distance(to:runway.end)
                guard length>0 else{continue}
                func local(_ p:Point)->Point {Point(x:((p.x-runway.start.x)*dx+(p.y-runway.start.y)*dy)/length,y:((p.x-runway.start.x)*(-dy)+(p.y-runway.start.y)*dx)/length)}
                let a=local(lane.a),b=local(lane.b),half=runway.width/2+0.5
                for x in [0.0,length] where abs(b.x-a.x)>0.000001 {let t=(x-a.x)/(b.x-a.x),y=a.y+(b.y-a.y)*t;if abs(y)<=half+0.000001 {add(i,t)}}
                for y in [-half,half] where abs(b.y-a.y)>0.000001 {let t=(y-a.y)/(b.y-a.y),x=a.x+(b.x-a.x)*t;if x>=0 && x<=length {add(i,t)}}
            }
        }
        for layer in RouteLayer.allCases {
            var graph=RoadGraph();graph.turnRules=document.turns ?? [];graph.junctionRules=document.junctions ?? []
            var nodeGroups:[Int:Int]=[:]
            func node(_ p:Point,edge:Int)->Int {
                var group=0
                if let conflict=result.conflicts.first(where:{!$0.allowsTurns && $0.sourceEdgeIDs.contains(edge) && $0.point.distance(to:p)<0.001}) {
                    let sources=lanes.filter{conflict.sourceEdgeIDs.contains($0.source.id)}
                    if sources.count==2 && Set([sources[0].source.a,sources[0].source.b]).isDisjoint(with:[sources[1].source.a,sources[1].source.b]) {group=edge+1}
                }
                if let id=graph.nodes.indices.first(where:{graph.nodes[$0].distance(to:p)<0.001 && nodeGroups[$0]==group}) {return id}
                let id=graph.nodes.count;graph.nodes.append(p);nodeGroups[id]=group;return id
            }
            for (i,lane) in lanes.enumerated() where lane.layer==layer {
                let points=cuts[i].sorted{$0.t<$1.t}
                for (a,b) in zip(points,points.dropFirst()) where a.point.distance(to:b.point)>0.001 {
                    let ai=node(a.point,edge:lane.source.id),bi=node(b.point,edge:lane.source.id),middle=Point.interpolate(a.point,b.point,fraction:0.5)
                    var kind=lane.source.kind ?? (layer == .aircraft ? .taxiway:.serviceRoad)
                    var strips=Set<Int>()
                    if !runways.isEmpty && (kind == .runway || kind == .runwayCrossing) {kind = layer == .aircraft ? .taxiway:.serviceRoad}
                    for runway in runways {
                        let dx=runway.end.x-runway.start.x,dy=runway.end.y-runway.start.y,l=runway.start.distance(to:runway.end)
                        let along=((middle.x-runway.start.x)*dx+(middle.y-runway.start.y)*dy)/(l*l),side=abs((middle.x-runway.start.x)*dy-(middle.y-runway.start.y)*dx)/l
                        if along >= -0.000001 && along<=1.000001 && side<=runway.width/2+0.500001 {
                            strips.insert(runway.id)
                            let parallel=abs((b.point.x-a.point.x)*dx+(b.point.y-a.point.y)*dy)/(a.point.distance(to:b.point)*l)
                            if layer == .aircraft && parallel>0.75 {kind = .runway} else if kind != .runway {kind = .runwayCrossing}
                        }
                    }
                    if a.t<0.000001 && !(graph.sourceNodeIDs[ai] ?? []).contains(lane.source.a) {graph.sourceNodeIDs[ai,default:[]].append(lane.source.a)}
                    if b.t>0.999999 && !(graph.sourceNodeIDs[bi] ?? []).contains(lane.source.b) {graph.sourceNodeIDs[bi,default:[]].append(lane.source.b)}
                    var edge=RoadGraph.Edge(a:ai,b:bi)
                    edge.sourceIDs=[lane.source.id];edge.kind=kind;edge.width=lane.source.width;edge.maxWingspan=lane.source.maxWingspan
                    edge.direction=lane.source.direction ?? .both;edge.access=lane.source.access;edge.speedLimit=lane.source.speedLimit;edge.runwayIDs=strips
                    if document.turns?.isEmpty != false,let duplicate=graph.edges.firstIndex(where:{e in
                        ((e.a==edge.a && e.b==edge.b) || (e.direction == .both && edge.direction == .both && e.a==edge.b && e.b==edge.a)) && e.kind==edge.kind && e.direction==edge.direction && e.width==edge.width && e.maxWingspan==edge.maxWingspan && e.speedLimit==edge.speedLimit && e.access==edge.access
                    }) {graph.edges[duplicate].sourceIDs += edge.sourceIDs}
                    else {graph.edges.append(edge)}
                }
            }
            for source in document.nodes where source.layer==layer {
                let locations=graph.nodes.indices.filter{(graph.sourceNodeIDs[$0] ?? []).contains(source.id)}
                if locations.isEmpty {result.isolatedSourceNodeIDs.append(source.id)}
                for id in locations {
                    if let allowed=source.canWait {graph.waitPermissions[id]=allowed}
                    if source.kind == .holdingArea {graph.holdingAreas[id]=source.holdingRadius ?? defaultWidth/2}
                }
            }
            for i in graph.nodes.indices where graph.waitPermissions[i]==nil {
                let p=graph.nodes[i]
                graph.waitPermissions[i] = !runways.contains {r in
                    let dx=r.end.x-r.start.x,dy=r.end.y-r.start.y,l=r.start.distance(to:r.end)
                    let t=((p.x-r.start.x)*dx+(p.y-r.start.y)*dy)/(l*l)
                    return t>=0 && t<=1 && abs((p.x-r.start.x)*dy-(p.y-r.start.y)*dx)/l<=r.width/2
                }
            }
            graph.conflicts=result.conflicts.filter{$0.layer==layer}
            result.layers[layer]=graph
        }
        return result
    }
}
