import Foundation
import Observation

enum RouteLayer: String, Codable, CaseIterable { case aircraft = "Aircraft taxiways", services = "Vehicle roads" }
struct RouteNode: Codable, Identifiable, Equatable {
    var id:Int;var layer:RouteLayer;var point:Point
    var kind:RouteNodeKind? = nil;var holdingRadius:Double? = nil;var canWait:Bool? = nil
}
struct RouteEdge: Codable, Identifiable, Equatable {
    var id:Int;var a:Int;var b:Int;var access:[Int]
    var kind:RouteLaneKind? = nil;var width:Double? = nil;var direction:RouteDirection? = nil
    var maxWingspan:Double? = nil;var speedLimit:Double? = nil
}
struct RoutePin: Codable, Identifiable, Equatable { var id: String; var point: Point }
struct AirportRouteDocument: Codable, Equatable {
    var version = 1
    var airportID:String? = nil
    var image = "DelhiBoard"
    var width = 1672.0
    var height = 941.0
    var nodes: [RouteNode] = []
    var edges: [RouteEdge] = []
    var pins: [RoutePin] = []
    var boundary = AirportFence.points
    var junctions:[RouteJunction]? = nil
    var turns:[RouteTurn]? = nil
    func graph(layer:RouteLayer,role:Int)->RoadGraph {
        OperationalGraphCompiler.compile(self).graph(layer:layer,role:role)
    }
    func activationProblems()->[String] { problems() }
    func problems() -> [String] {
        var result:[String]=[]
        if ![1,2].contains(version) || image.isEmpty || !width.isFinite || !height.isFinite || width<=0 || height<=0 { result.append("Unsupported graph version or invalid image calibration.") }
        if Set(nodes.map(\.id)).count != nodes.count || Set(edges.map(\.id)).count != edges.count { result.append("Duplicate node or edge IDs.") }
        if nodes.contains(where:{ !$0.point.x.isFinite || !$0.point.y.isFinite || $0.point.x<0 || $0.point.y<0 || $0.point.x>width || $0.point.y>height }) { result.append("A node lies outside the image.") }
        let ids=Set(nodes.map(\.id))
        if edges.contains(where:{ !ids.contains($0.a) || !ids.contains($0.b) || $0.a==$0.b || $0.access.isEmpty || $0.access.contains(where:{ !(0...16).contains($0) }) }) { result.append("An edge has invalid endpoints or no allowed vehicles.") }
        if pins.contains(where:{ !$0.point.x.isFinite || !$0.point.y.isFinite }) || Set(pins.map(\.id)).count != pins.count { result.append("Invalid or duplicate landmark pins.") }
        let indexed=Dictionary(nodes.map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
        for edge in edges {
            if [edge.width,edge.maxWingspan,edge.speedLimit].compactMap({$0}).contains(where:{!$0.isFinite || $0<=0}) {result.append("Invalid width, aircraft limit or speed on edge \(edge.id).")}
            if let a=indexed[edge.a],let b=indexed[edge.b] {
                if a.layer != b.layer {result.append("Edge \(edge.id) joins aircraft and vehicle layers.")}
                if a.point.distance(to:b.point)<0.00001 {result.append("Edge \(edge.id) has zero length.")}
                if (a.layer == .aircraft && edge.access.contains(where:{$0 != 0})) || (a.layer == .services && edge.access.contains(0)) {result.append("Edge \(edge.id) has roles from the wrong layer.")}
                if (edge.kind == .serviceRoad && a.layer != .services) || ([RouteLaneKind.taxiway,.runway].contains(edge.kind ?? .serviceRoad) && a.layer == .services) {result.append("Lane type conflicts with layer on edge \(edge.id).")}
            }
        }
        for n in nodes {if let radius=n.holdingRadius, !radius.isFinite || radius<=0 {result.append("Invalid holding area on node \(n.id).")}}
        let edgeIDs=Set(edges.map(\.id))
        for j in junctions ?? [] {if !j.point.x.isFinite || !j.point.y.isFinite || j.point.x<0 || j.point.y<0 || j.point.x>width || j.point.y>height || !(j.edgeIDs ?? []).allSatisfy({edgeIDs.contains($0)}) {result.append("Invalid junction annotation.")}}
        for turn in turns ?? [] {
            let vertex=turn.nodeID.flatMap{indexed[$0]?.point} ?? turn.point
            guard edgeIDs.contains(turn.fromEdgeID),edgeIDs.contains(turn.toEdgeID),let p=vertex,p.x.isFinite,p.y.isFinite,p.x>=0,p.y>=0,p.x<=width,p.y<=height else{result.append("Invalid turn annotation.");continue}
            for id in [turn.fromEdgeID,turn.toEdgeID] {
                guard let edge=edges.first(where:{$0.id==id}),let a=indexed[edge.a]?.point,let b=indexed[edge.b]?.point else{result.append("Invalid turn edge.");continue}
                let dx=b.x-a.x,dy=b.y-a.y,t=min(1,max(0,((p.x-a.x)*dx+(p.y-a.y)*dy)/max(0.00001,dx*dx+dy*dy)))
                if p.distance(to:Point.interpolate(a,b,fraction:t))>0.1 {result.append("Turn is not on its referenced edges.")}
            }
        }
        return result
    }
}

/// The fence prevents ground response routes from entering the surrounding city.
/// Pavement alignment is authored separately, directly over the image.
enum AirportFence {
    static let points = [Point(x:725,y:193),Point(x:968,y:193),Point(x:972,y:128),Point(x:1150,y:189),Point(x:1215,y:218),Point(x:1262,y:430),Point(x:1110,y:785),Point(x:1010,y:793),Point(x:418,y:666),Point(x:438,y:524),Point(x:553,y:506),Point(x:578,y:332),Point(x:650,y:264),Point(x:677,y:212)]
    static func contains(_ p: Point, polygon:[Point] = points) -> Bool {
        guard polygon.count>=3 else { return false }
        var inside=false,j=polygon.count-1
        for i in polygon.indices {
            let a=polygon[i],b=polygon[j]
            if (a.y>p.y) != (b.y>p.y),p.x<(b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x { inside.toggle() }
            j=i
        }
        return inside
    }
    static func containsSegment(_ a:Point,_ b:Point,polygon:[Point] = points)->Bool {
        let steps=max(1,Int(ceil(a.distance(to:b)/2)))
        return (0...steps).allSatisfy { contains(Point.interpolate(a,b,fraction:Double($0)/Double(steps)),polygon:polygon) }
    }
}

@MainActor enum RoutingOverrides {
    private(set) static var revision=0
    private(set) static var current: AirportRouteDocument? = loadInitial()
    private static func loadInitial()->AirportRouteDocument? {
        let package=AirportPackage.defaultAirport
#if os(macOS) && DEBUG
        if let saved=load("active-routes.json",airportID:package.definition.identity.id),package.acceptsOverride(saved) {return saved}
#endif
        return package.routes
    }
#if os(macOS) && DEBUG
    static var folder: URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("DELControl",isDirectory:true) }
    static func storageFolder(airportID:String)->URL {
        guard airportID != "delhi" else{return folder}
        let safe=airportID.filter{$0.isLetter || $0.isNumber || $0=="-" || $0=="_"}
        return folder.appendingPathComponent("Airports").appendingPathComponent(safe.isEmpty ? "invalid":safe)
    }
    static func load(_ name:String,airportID:String="delhi")->AirportRouteDocument? {
        guard let data=try? Data(contentsOf:storageFolder(airportID:airportID).appendingPathComponent(name)),let value=try? JSONDecoder().decode(AirportRouteDocument.self,from:data),value.problems().isEmpty else { return nil }
        return value
    }
    static func write(_ document:AirportRouteDocument,name:String) throws {
        let destination=storageFolder(airportID:document.airportID ?? "delhi")
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(document).write(to:destination.appendingPathComponent(name),options:.atomic)
    }
    static func activate(_ document:AirportRouteDocument,persist:Bool=true) throws {
        if let problem=document.activationProblems().first { throw CocoaError(.fileReadCorruptFile,userInfo:[NSLocalizedDescriptionKey:problem]) }
        if persist { try write(document,name:"active-routes.json") };current=document;revision+=1
    }
#endif
    static func pin(_ id:String,fallback:Point)->Point { current?.pins.first(where:{ $0.id==id })?.point ?? fallback }
    private static var graphCache:[String:RoadGraph]=[:]
    private static var cachedRevision = -1
    static func graph(_ layer:RouteLayer,role:Int)->RoadGraph? {
        if cachedRevision != revision { graphCache=[:];cachedRevision=revision }
        let key=layer.rawValue+String(role)
        if let cached=graphCache[key] { return cached }
        guard let current,current.nodes.contains(where:{ $0.layer==layer }) else { return nil }
        let graph=current.graph(layer:layer,role:role);graphCache[key]=graph;return graph
    }
}

#if os(macOS) && DEBUG
@MainActor @Observable final class RouteEditorModel {
    var document: AirportRouteDocument
    var layer: RouteLayer = .aircraft
    var selectedNode: Int?
    var selectedEdge: Int?
    var access: Set<Int> = [0]
    var routeStart: Int?
    var preview: [Point] = []
    var message = "Draw: click to place nodes. Click the next node to connect. Click an edge to split it."
    private var undoStack:[AirportRouteDocument]=[]
    private var redoStack:[AirportRouteDocument]=[]
    init(document:AirportRouteDocument? = nil) {
        self.document=document ?? RoutingOverrides.load("draft-routes.json") ?? RoutingOverrides.current ?? Self.builtIn()
    }
    static func builtIn()->AirportRouteDocument {AirportPackage.defaultAirport.routes}
    var canUndo:Bool { !undoStack.isEmpty }
    var canRedo:Bool { !redoStack.isEmpty }
    var visibleNodes:[RouteNode] { document.nodes.filter { $0.layer==layer } }
    var visibleEdges:[RouteEdge] {
        let ids=Set(visibleNodes.map(\.id));return document.edges.filter { ids.contains($0.a) && ids.contains($0.b) }
    }
    func checkpoint() { undoStack.append(document);if undoStack.count>100 { undoStack.removeFirst() };redoStack=[];preview=[] }
    func undo() { guard let previous=undoStack.popLast() else{return};redoStack.append(document);document=previous;selectedNode=nil;selectedEdge=nil;preview=[] }
    func redo() { guard let next=redoStack.popLast() else{return};undoStack.append(document);document=next;selectedNode=nil;selectedEdge=nil;preview=[] }
    func changeLayer(_ value:RouteLayer) { layer=value;access=value == .aircraft ? [0] : Set(1...16);selectedNode=nil;selectedEdge=nil;routeStart=nil;preview=[] }
    func nearestNode(_ p:Point,radius:Double)->Int? { visibleNodes.filter { $0.point.distance(to:p)<=radius }.min { $0.point.distance(to:p)<$1.point.distance(to:p) }?.id }
    func project(_ p:Point,on edge:RouteEdge)->Point? {
        guard let a=document.nodes.first(where:{ $0.id==edge.a })?.point,let b=document.nodes.first(where:{ $0.id==edge.b })?.point else{return nil}
        let dx=b.x-a.x,dy=b.y-a.y,t=min(1,max(0,((p.x-a.x)*dx+(p.y-a.y)*dy)/max(0.001,dx*dx+dy*dy)))
        return Point(x:a.x+t*dx,y:a.y+t*dy)
    }
    func nearestEdge(_ p:Point,radius:Double)->RouteEdge? { visibleEdges.filter { (project(p,on:$0)?.distance(to:p) ?? .infinity)<radius }.min { project(p,on:$0)!.distance(to:p)<project(p,on:$1)!.distance(to:p) } }
    func draw(_ point:Point,snap:Double) {
        checkpoint()
        let prior=selectedNode
        var id=nearestNode(point,radius:snap)
        if id==nil {
            var p=point
            let edge=nearestEdge(p,radius:snap*0.65)
            if let edge { p=project(p,on:edge)! }
            id=(document.nodes.map(\.id).max() ?? -1)+1
            document.nodes.append(RouteNode(id:id!,layer:layer,point:p))
            if let edge {
                let nextID=(document.edges.map(\.id).max() ?? -1)+1
                document.edges.removeAll{$0.id==edge.id}
                var first=edge,second=edge
                first.b=id!;second.a=id!;second.id=nextID
                document.edges += [first,second]
                if let endpoint=document.nodes.first(where:{$0.id==edge.b})?.point {
                    for i in (document.turns ?? []).indices {
                        if document.turns![i].nodeID==edge.b || (document.turns![i].point?.distance(to:endpoint) ?? 99)<0.1 {
                            if document.turns![i].fromEdgeID==edge.id {document.turns![i].fromEdgeID=nextID}
                            if document.turns![i].toEdgeID==edge.id {document.turns![i].toEdgeID=nextID}
                        }
                    }
                }
            }
        }
        if let prior,prior != id { connect(prior,id!,roles:access.sorted()) }
        selectedNode=id;selectedEdge=nil;message="Node \(id!) selected. Continue tracing, or use Break chain."
    }
    private func connect(_ a:Int,_ b:Int,roles:[Int]) {
        if let i=document.edges.firstIndex(where:{ ($0.a==a && $0.b==b)||($0.a==b && $0.b==a) }) {
            document.edges[i].access=Set(document.edges[i].access+roles).sorted();return
        }
        document.edges.append(RouteEdge(id:(document.edges.map(\.id).max() ?? -1)+1,a:a,b:b,access:roles))
    }
    func select(_ p:Point,snap:Double) {
        selectedNode=nearestNode(p,radius:snap);selectedEdge=selectedNode==nil ? nearestEdge(p,radius:snap)?.id : nil
        if let selectedEdge,let edge=document.edges.first(where:{ $0.id==selectedEdge }) { access=Set(edge.access) }
    }
    func deleteSelected() {
        checkpoint()
        if let id=selectedNode { document.nodes.removeAll { $0.id==id };document.edges.removeAll { $0.a==id || $0.b==id } }
        else if let id=selectedEdge { document.edges.removeAll { $0.id==id } }
        selectedNode=nil;selectedEdge=nil
    }
    func clearLayer() { checkpoint();let ids=Set(visibleNodes.map(\.id));document.nodes.removeAll { ids.contains($0.id) };document.edges.removeAll { ids.contains($0.a)||ids.contains($0.b) };selectedNode=nil;selectedEdge=nil }
    func move(_ id:Int,to p:Point) { if let i=document.nodes.firstIndex(where:{ $0.id==id }) { document.nodes[i].point=p };preview=[] }
    func setAccess(_ roles:Set<Int>) { access=roles;if let id=selectedEdge,let i=document.edges.firstIndex(where:{ $0.id==id }) { checkpoint();document.edges[i].access=roles.sorted() } }
    func setPin(_ id:String,point:Point) { checkpoint();document.pins.removeAll { $0.id==id };document.pins.append(RoutePin(id:id,point:point)) }
    func testRoute(_ p:Point,snap:Double,role:Int) {
        guard let id=nearestNode(p,radius:snap) else { message="Choose a node for the route test.";return }
        if let start=routeStart,let a=document.nodes.first(where:{ $0.id==start }),let b=document.nodes.first(where:{ $0.id==id }) {
            let graph=document.graph(layer:layer,role:role)
            let connected=graph.nodes.contains(a.point) && graph.nodes.contains(b.point)
            let path=connected ? graph.shortestPath(from:a.point,to:b.point) : []
            preview=path.isEmpty ? [] : [a.point]+path
            message=preview.isEmpty ? "No connected route for this vehicle." : "Shortest route: \(Int(FlightCurves.length(from:a.point,route:preview))) pixels. Green points show the route."
            routeStart=nil
        } else { routeStart=id;preview=[];message="Start node \(id) chosen. Click the destination node." }
    }
    func saveDraft() { do { try RoutingOverrides.write(document,name:"draft-routes.json");message="Draft saved on this Mac." } catch { message=error.localizedDescription } }
}

#endif
