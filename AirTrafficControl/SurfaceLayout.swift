import Foundation

/// Geometry and caches belong to one simulation/airport, never the last airport
/// loaded by another window. All operational coordinates come from its package.
@MainActor final class AirportSurface {
    typealias Gate=AirportStand
    let definition:AirportDefinition
    let routes:AirportRouteDocument
    let revision:Int
    private static var nextRevision=0
    init(package:AirportPackage,routes:AirportRouteDocument?=nil) {
        definition=package.definition;self.routes=routes ?? package.routes
        Self.nextRevision+=1;revision=Self.nextRevision
    }
    var approvedGates:[Gate] {definition.stands}
    var gates:[Gate] {definition.stands}
    var runwayEnds:[(Point,Point)] {definition.runways.map{($0.activeEnd.threshold,$0.activeEnd.oppositeThreshold)}}
    var runwayLengths:[Double] {definition.runways.map{$0.activeEnd.usableLengthMeters}}
    var turnRadius:Double {definition.rules.turnRadius}
    var starts:[Point] {definition.approaches.map(\.start)}
    var fixes:[Point] {definition.approaches.map(\.fix)}
    var orbitDirections:[Double] {definition.runways.map(\.orbitDirection)}
    lazy var operational:CompiledOperationalGraph=OperationalGraphCompiler.compile(routes,runways:definition.runways,defaultWidth:definition.rules.taxiwayWidth)
    private lazy var aircraftNetwork=operational.graph(layer:.aircraft,role:0)
    var network:RoadGraph {aircraftNetwork}
    var builtInNetwork:RoadGraph {network}
    func threshold(_ r: Int) -> Point { runwayEnds[r].0 }
    func heading(_ r: Int) -> Double { let (a,b)=runwayEnds[r];return atan2(b.y-a.y,b.x-a.x) }
    func runwayPoint(_ r: Int,_ t: Double) -> Point { Point.interpolate(runwayEnds[r].0,runwayEnds[r].1,fraction:t) }
    func offset(_ p: Point, heading: Double, along: Double = 0, side: Double = 0) -> Point {
        Point(x:p.x+cos(heading)*along-sin(heading)*side,y:p.y+sin(heading)*along+cos(heading)*side)
    }
    func hold(_ r: Int) -> Point { definition.runways[r].activeEnd.hold }
    func exit(_ r: Int) -> Point { definition.runways[r].activeEnd.exit }
    func eligible(_ model:AircraftModel,runway:Int)->Bool { runwayLengths.indices.contains(runway) && runwayLengths[runway]>=model.minimumRunwayMeters }

    private var taxiCache:(Int,RoadGraph)?
    var taxiNetwork:RoadGraph {
        if let cache=taxiCache,cache.0==revision{return cache.1}
        var graph=network
        graph.edges=graph.edges.filter{$0.kind != .runway}
        graph=graph.removingIsolatedNodes()
        taxiCache=(revision,graph);return graph
    }
    private var entryCache:[String:(Point,Point)]=[:]
    func departureEntry(for model:AircraftModel,runway:Int,from start:Point)->(hold:Point,lineup:Point) {
        let key="\(revision)-\(model.minimumRunwayMeters)-\(runway)-\(Int(start.x))-\(Int(start.y))"
        if let cached=entryCache[key] {return(cached.0,cached.1)}
        let a=threshold(runway),b=runwayEnds[runway].1,dx=b.x-a.x,dy=b.y-a.y,l=a.distance(to:b)
        var best:(Double,Point,Point)?
        let graph=network,taxi=taxiNetwork
        // A traced runway access branch may be used only if enough runway remains.
        for p in graph.nodes {
            let t=((p.x-a.x)*dx+(p.y-a.y)*dy)/(l*l),side=abs((p.x-a.x)*dy-(p.y-a.y)*dx)/l
            guard t>0.025,t<0.52,side<5,(1-t)*runwayLengths[runway]>=model.minimumRunwayMeters else{continue}
            let choices=taxi.nodes.filter { q in
                let s=abs((q.x-a.x)*dy-(q.y-a.y)*dx)/l
                return s>18 && s<35 && q.distance(to:p)<65
            }.sorted{$0.distance(to:p)<$1.distance(to:p)}.prefix(3)
            for hold in choices {
                let entry=graph.shortestPath(from:hold,to:p,maximumAccessDistance:2)
                guard !entry.isEmpty,FlightCurves.length(from:hold,route:entry)<80 else{continue}
                let route=taxi.shortestPath(from:start,to:hold,maximumAccessDistance:2)
                guard !route.isEmpty else{continue}
                let cost=FlightCurves.length(from:start,route:route)+FlightCurves.length(from:hold,route:entry)
                if best == nil || cost<best!.0 {best=(cost,hold,p)}
            }
        }
        if let best{entryCache[key]=(best.1,best.2);return(best.1,best.2)}
        return (hold(runway),runwayPoint(runway,0.06))
    }
    /// Quadratic corner fillets keep each path continuous and tangent. Never
    /// change aircraft coordinates when starting/replacing a route.
    func rounded(_ input: [Point], radius: Double = 10) -> [Point] {
        var points:[Point]=[]
        for p in input where p.distance(to:points.last ?? Point(x:-99999,y:-99999))>0.01 { points.append(p) }
        guard points.count>2 else { return Array(points.dropFirst()) }
        var out:[Point]=[]
        for i in 1..<(points.count-1) {
            let a=points[i-1],b=points[i],c=points[i+1]
            let trim=min(radius,min(a.distance(to:b),b.distance(to:c))*0.35)
            let p=Point.interpolate(b,a,fraction:trim/b.distance(to:a))
            let q=Point.interpolate(b,c,fraction:trim/b.distance(to:c))
            out.append(p)
            let steps=max(32,Int(ceil(trim*8)))
            for j in 1...steps {
                let t=Double(j)/Double(steps),u=1-t
                out.append(Point(x:u*u*p.x+2*u*t*b.x+t*t*q.x,y:u*u*p.y+2*u*t*b.y+t*t*q.y))
            }
        }
        out.append(points.last!);return out
    }
    func pushback(from start: Point, noseHeading: Double, to port: Point, taxiHeading: Double,minimumWidth:Double=0) -> [Point] {
        if network.hasRestrictions {
            let path=network.shortestPath(from:start,to:port,maximumAccessDistance:2,minimumWidth:minimumWidth)
            return path.isEmpty ? []:rounded([start]+path,radius:3)
        }
        if let gate=gates.first(where:{$0.position.distance(to:start)<1}),!gate.access.isEmpty { return rounded(gate.access,radius:3) }
        return taxiRoute(from:start,to:port)
    }
    func landingRoute(_ runway:Int,model:AircraftModel?=nil)->[Point] {
        let a=threshold(runway),b=runwayEnds[runway].1,dx=b.x-a.x,dy=b.y-a.y,l=a.distance(to:b)
        let minimum=max(0.50,(model?.takeoffRollFraction ?? 0.64)+0.04)
        let graph=network
        // Use the left-hand exit in the direction of landing. This keeps the
        // rollout on its intended taxiway instead of steering across the strip.
        let preferredSide=1.0
        let candidates=graph.nodes.compactMap { p -> (Point,Double)? in
            let t=((p.x-a.x)*dx+(p.y-a.y)*dy)/(l*l),side=abs((p.x-a.x)*dy-(p.y-a.y)*dx)/l
            return t>=minimum && t<0.99 && side<5 ? (p,t) : nil
        }.sorted{$0.1<$1.1}
        for (join,t) in candidates {
            let targets=graph.nodes.filter {p in
                let signed=((p.x-a.x)*dy-(p.y-a.y)*dx)/l,side=abs(signed)
                return side>22 && side<50 && p.distance(to:join)<90 && signed*preferredSide>0
            }.sorted{$0.distance(to:join)<$1.distance(to:join)}
            for target in targets.prefix(20) {
                let path=graph.shortestPath(from:join,to:target,maximumAccessDistance:2)
                guard !path.isEmpty else{continue}
                var exitPath:[Point]=[],valid=true
                for p in path {
                    let along=((p.x-a.x)*dx+(p.y-a.y)*dy)/(l*l),side=abs((p.x-a.x)*dy-(p.y-a.y)*dx)/l
                    if side<12 && along<t-0.035 {valid=false;break}
                    exitPath.append(p)
                    if side>22 {break}
                }
                guard valid,let last=exitPath.last,abs((last.x-a.x)*dy-(last.y-a.y)*dx)/l>22,FlightCurves.length(from:join,route:exitPath)<110 else{continue}
                let rollout=runwayPoint(runway,t)
                return [rollout]+rounded([rollout,join]+exitPath,radius:3)
            }
        }
        // Remain on the centreline if a traced exit is unavailable; never skid
        // toward a nearby parallel taxiway pin.
        return [runwayPoint(runway,0.92)]
    }
    func departureExit(from p: Point, heading: Double) -> Point {
        let dx=cos(heading),dy=sin(heading)
        var distance=Double.infinity
        if dx>0.0001 { distance=min(distance,(definition.image.width+140-p.x)/dx) }
        if dx < -0.0001 { distance=min(distance,(-140-p.x)/dx) }
        if dy>0.0001 { distance=min(distance,(definition.image.height+140-p.y)/dy) }
        if dy < -0.0001 { distance=min(distance,(-140-p.y)/dy) }
        return offset(p,heading:heading,along:max(1,distance))
    }
    /// Faster straights, slower bends: cap taxi turn rate before each corner.
    func cornerSpeed(from p: Point,route: [Point]) -> Double {
        var points=[p],distance=0.0
        for q in route {
            distance += q.distance(to:points.last!);points.append(q)
            if distance>24 { break }
        }
        var curvature=0.0
        if points.count>2 { for i in 1..<(points.count-1) {
            let a=points[i-1],b=points[i],c=points[i+1],ab=a.distance(to:b),bc=b.distance(to:c)
            if min(ab,bc)<0.001 { continue }
            let turn=atan2(sin(atan2(c.y-b.y,c.x-b.x)-atan2(b.y-a.y,b.x-a.x)),cos(atan2(c.y-b.y,c.x-b.x)-atan2(b.y-a.y,b.x-a.x)))
            curvature=max(curvature,abs(turn)/max(0.1,(ab+bc)/2))
        } }
        return curvature>0.001 ? max(2,0.8/curvature) : 30
    }
    func taxiRoute(from start: Point,to end: Point,minimumWidth:Double=0) -> [Point] {
        let path=taxiNetwork.shortestPath(from:start,to:end,maximumAccessDistance:2,minimumWidth:minimumWidth)
        return path.isEmpty ? [] : rounded([start]+path,radius:3)
    }
    func arrivalRoute(runway: Int, stand: Int, from start: Point) -> [Point] {
        let gate=gates[stand]
        if !gate.access.isEmpty {
            let path=taxiRoute(from:start,to:gate.port)
            guard !path.isEmpty else{return []}
            return path+rounded(Array(gate.access.reversed()),radius:3)
        }
        var path=taxiRoute(from:start,to:gate.port)
        let prior=path.count>1 ? path[path.count-2] : start
        let h=atan2(gate.port.y-prior.y,gate.port.x-prior.x)
        path += FlightCurves.approach(from:gate.port,heading:h,to:gate.position,endHeading:gate.heading,radius:8)
        return path
    }
}

/// Compatibility for Delhi developer tools and older check fixtures. Live
/// simulation/rendering use their own AirportSurface instance instead.
@MainActor enum SurfaceLayout {
    typealias Gate=AirportStand
    private static var cache:(Int,AirportSurface)?
    static var legacy:AirportSurface {
        if let c=cache,c.0==RoutingOverrides.revision {return c.1}
        let package=AirportPackage.delhi
        let override=RoutingOverrides.current.flatMap{package.acceptsOverride($0) ? $0:nil}
        let surface=AirportSurface(package:package,routes:override)
        cache=(RoutingOverrides.revision,surface);return surface
    }
    static var approvedGates:[Gate] {legacy.approvedGates}
    static var gates:[Gate] {legacy.gates}
    static var runwayEnds:[(Point,Point)] {legacy.runwayEnds}
    static var runwayLengths:[Double] {legacy.runwayLengths}
    static var turnRadius:Double {legacy.turnRadius}
    static var starts:[Point] {legacy.starts}
    static var fixes:[Point] {legacy.fixes}
    static var orbitDirections:[Double] {legacy.orbitDirections}
    static var network:RoadGraph {legacy.network}
    static var builtInNetwork:RoadGraph {legacy.builtInNetwork}
    static var taxiNetwork:RoadGraph {legacy.taxiNetwork}
    static func threshold(_ r:Int)->Point {legacy.threshold(r)}
    static func heading(_ r:Int)->Double {legacy.heading(r)}
    static func runwayPoint(_ r:Int,_ t:Double)->Point {legacy.runwayPoint(r,t)}
    static func offset(_ p:Point,heading:Double,along:Double=0,side:Double=0)->Point {legacy.offset(p,heading:heading,along:along,side:side)}
    static func hold(_ r:Int)->Point {legacy.hold(r)}
    static func exit(_ r:Int)->Point {legacy.exit(r)}
    static func eligible(_ model:AircraftModel,runway:Int)->Bool {legacy.eligible(model,runway:runway)}
    static func departureEntry(for model:AircraftModel,runway:Int,from start:Point)->(hold:Point,lineup:Point) {legacy.departureEntry(for:model,runway:runway,from:start)}
    static func rounded(_ points:[Point],radius:Double=10)->[Point] {legacy.rounded(points,radius:radius)}
    static func pushback(from start:Point,noseHeading:Double,to port:Point,taxiHeading:Double)->[Point] {legacy.pushback(from:start,noseHeading:noseHeading,to:port,taxiHeading:taxiHeading)}
    static func landingRoute(_ runway:Int,model:AircraftModel?=nil)->[Point] {legacy.landingRoute(runway,model:model)}
    static func departureExit(from p:Point,heading:Double)->Point {legacy.departureExit(from:p,heading:heading)}
    static func cornerSpeed(from p:Point,route:[Point])->Double {legacy.cornerSpeed(from:p,route:route)}
    static func taxiRoute(from start:Point,to end:Point)->[Point] {legacy.taxiRoute(from:start,to:end)}
    static func arrivalRoute(runway:Int,stand:Int,from start:Point)->[Point] {legacy.arrivalRoute(runway:runway,stand:stand,from:start)}
}
