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
    func departureHoldClearance(for model:AircraftModel,runway:Int)->Double {
        let trafficSpan=AircraftCatalog.models.filter{eligible($0,runway:runway)}.map{$0.span*0.275}.max() ?? 0
        let strip=definition.runways[runway].width/2+definition.rules.runwayMargin
        return max(strip,trafficSpan)+hypot(model.length,model.span)*0.275+6
    }
    func departureEntry(for model:AircraftModel,runway:Int,from start:Point)->(hold:Point,lineup:Point) {
        let key="\(revision)-\(model.id)-\(runway)-\(start.x)-\(start.y)"
        if let cached=entryCache[key] {return(cached.0,cached.1)}
        let result: (Point,Point)
        if let cached=routeGeometry.entry(key) {result=cached}
        else {result=departureInput(model,runway:runway,start:start).build();routeGeometry.saveEntry(result,for:key)}
        if entryCache.count>=256 {entryCache.removeAll(keepingCapacity:true)}
        entryCache[key]=result
        return result
    }
    private func departureInput(_ model:AircraftModel,runway:Int,start:Point)->AirportRouteGeometry.DepartureInput {
        .init(graph:network,taxi:taxiNetwork,a:threshold(runway),b:runwayEnds[runway].1,start:start,original:hold(runway),fallbackLineup:runwayPoint(runway,0.06),runwayLength:runwayLengths[runway],minimumRunway:model.minimumRunwayMeters,span:model.span*0.55,clearance:departureHoldClearance(for:model,runway:runway),initialHeading:gates.first(where:{$0.port.distance(to:start)<0.01})?.heading)
    }
    func prewarmDepartureEntries(for flights:[Aircraft]) {
        for flight in flights {
            let start=gates[flight.stand].port
            for runway in gates[flight.stand].departureRunways where eligible(flight.model,runway:runway) {
                let key="\(revision)-\(flight.modelID)-\(runway)-\(start.x)-\(start.y)"
                if entryCache[key] != nil || routeGeometry.hasEntryOrPending(key) {continue}
                routeGeometry.submitEntry(key,input:departureInput(flight.model,runway:runway,start:start))
            }
        }
    }
    /// Quadratic corner fillets keep each path continuous and tangent. Never
    /// change aircraft coordinates when starting/replacing a route.
    func rounded(_ input: [Point], radius: Double = 10) -> [Point] {
        Self.roundedPath(input,radius:radius)
    }
    nonisolated static func roundedPath(_ input:[Point],radius:Double)->[Point] {
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
    private var landingRouteCache:[String:[Point]]=[:]
    private let routeGeometry=AirportRouteGeometry.Store()
    deinit {routeGeometry.cancel()}
    func prewarmLandingExits() {
        let ids=Set(definition.traffic.initial.filter(\.arrival).flatMap(\.modelIDs)+definition.traffic.continuousModels.map(\.modelID))
        for runway in definition.runways.indices {
            for id in ids.sorted() {
                let model=AircraftCatalog.model(id)
                guard eligible(model,runway:runway) else{continue}
                let key=AirportRouteGeometry.Key(runway:runway,span:model.span*0.55,minimum:max(0.50,model.takeoffRollFraction+0.04),bothSides:true)
                routeGeometry.submit(key,graph:network,a:threshold(runway),b:runwayEnds[runway].1,authored:definition.runways[runway].activeEnd.landingExits ?? [])
            }
        }
    }
    func landingRoute(_ runway:Int,model:AircraftModel?=nil,destination:Point?=nil,traffic:[Aircraft]=[],minimumProgress:Double=0)->[Point] {
        let cacheKey="\(runway)-\(model?.id ?? "default")-\(String(describing:destination))-\(minimumProgress)"
        if traffic.isEmpty,let cached=landingRouteCache[cacheKey] {return cached}
        let a=threshold(runway),b=runwayEnds[runway].1,dx=b.x-a.x,dy=b.y-a.y,l=a.distance(to:b)
        let minimum=max(minimumProgress,max(0.50,(model?.takeoffRollFraction ?? 0.64)+0.04))
        var bestRoute:[Point]?,bestScore=Double.infinity
        var onwardCache:[String:[Point]]=[:]
        let footprints=trafficFootprints(traffic,clearance:(model?.span ?? 0)*0.275)
        func consider(_ landing:[Point],rollout:Point,t:Double) {
            guard let destination,let last=landing.last else{return}
            let prior=landing.dropLast().last ?? rollout
            let exitHeading=atan2(last.y-prior.y,last.x-prior.x)
            let key="\(last.x)-\(last.y)-\(exitHeading)"
            let onward:[Point]
            if let cached=onwardCache[key] {onward=cached}
            else {onward=taxiRoute(from:last,to:destination,minimumWidth:(model?.span ?? 0)*0.55,traffic:traffic,heading:exitHeading);onwardCache[key]=onward}
            guard !onward.isEmpty else{return}
            let crossings=runwayCrossingCount(from:last,route:onward)
            let next=onward.first(where:{$0.distance(to:last)>2}) ?? destination
            let taxiHeading=atan2(next.y-last.y,next.x-last.x)
            let reversal=cos(exitHeading-taxiHeading)<(-0.5) ? 300.0:0
            var congestion=0.0,previous=rollout
            for point in landing+onward {congestion+=Self.trafficCost(from:previous,to:point,footprints:footprints);previous=point}
            let destinationSide=((destination.x-a.x)*dy-(destination.y-a.y)*dx)/l
            let sideSign=destinationSide>=0 ? 1.0:-1.0
            var wrongSide=0.0
            for point in landing {
                let signed=((point.x-a.x)*dy-(point.y-a.y)*dx)/l
                wrongSide=max(wrongSide,-sideSign*signed-0.5)
            }
            let score=Double(crossings)*100000+FlightCurves.length(from:last,route:onward)+FlightCurves.length(from:rollout,route:landing)+t*l+reversal+congestion+wrongSide*300
            if score<bestScore {bestScore=score;bestRoute=landing}
        }
        let key=AirportRouteGeometry.Key(runway:runway,span:(model?.span ?? 0)*0.55,minimum:destination == nil ? minimum:max(0.50,(model?.takeoffRollFraction ?? 0.64)+0.04),bothSides:destination != nil)
        let candidates:[AirportRouteGeometry.Candidate]
        if let cached=routeGeometry.value(key) {candidates=cached}
        else {
            candidates=AirportRouteGeometry.build(key,graph:network,a:a,b:b,authored:definition.runways[runway].activeEnd.landingExits ?? [])
            routeGeometry.save(candidates,for:key)
        }
        for candidate in candidates where candidate.progress>=minimum {
            if destination == nil {landingRouteCache[cacheKey]=candidate.path;return candidate.path}
            consider(candidate.path,rollout:candidate.rollout,t:candidate.progress)
        }
        if let bestRoute {if traffic.isEmpty {landingRouteCache[cacheKey]=bestRoute};return bestRoute}
        // Remain on the centreline if a traced exit is unavailable; never skid
        // toward a nearby parallel taxiway pin.
        return [runwayPoint(runway,0.92)]
    }
    func runwayCrossingCount(from start:Point,route:[Point])->Int {
        definition.runways.filter {runway in
            let a=runway.start,b=runway.end,length=a.distance(to:b),dx=(b.x-a.x)/length,dy=(b.y-a.y)/length
            func local(_ p:Point)->(Double,Double) {((p.x-a.x)*dx+(p.y-a.y)*dy,-(p.x-a.x)*dy+(p.y-a.y)*dx)}
            var previous=start
            for point in route {
                let p=local(previous),q=local(point)
                var lower=0.0,upper=1.0
                for (origin,delta,minimum,maximum) in [(p.0,q.0-p.0,0.0,length),(p.1,q.1-p.1,-runway.width/2,runway.width/2)] {
                    if abs(delta)<0.000001 {if origin<minimum || origin>maximum {upper = -1};continue}
                    let x=(minimum-origin)/delta,y=(maximum-origin)/delta
                    lower=max(lower,min(x,y));upper=min(upper,max(x,y))
                }
                if lower<=upper {return true}
                previous=point
            }
            return false
        }.count
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
    func taxiTrafficCost(from start:Point,to end:Point,traffic:[Aircraft],clearance:Double)->Double {
        Self.trafficCost(from:start,to:end,footprints:trafficFootprints(traffic,clearance:clearance))
    }
    private struct TrafficFootprint {let position:Point;let radius:Double}
    private func trafficFootprints(_ traffic:[Aircraft],clearance:Double)->[TrafficFootprint] {
        traffic.map{.init(position:$0.position,radius:clearance+max($0.model.length,$0.model.span)*0.275+10)}
    }
    private nonisolated static func trafficCost(from start:Point,to end:Point,footprints:[TrafficFootprint])->Double {
        let dx=end.x-start.x,dy=end.y-start.y,length=start.distance(to:end)
        guard length>0.01 else{return 0}
        return footprints.reduce(0.0) { cost,other in
            let p=other.position,t=min(1,max(0,((p.x-start.x)*dx+(p.y-start.y)*dy)/(length*length)))
            let distance=p.distance(to:Point.interpolate(start,end,fraction:t))
            let radius=other.radius
            // A continuous cost per travelled unit is independent of how
            // densely the author subdivided a lane into graph edges.
            return cost+length*max(0,1-distance/max(1,radius))*40
        }
    }
    func taxiRoute(from start: Point,to end: Point,minimumWidth:Double=0,traffic:[Aircraft]=[],heading:Double?=nil) -> [Point] {
        let footprints=trafficFootprints(traffic,clearance:minimumWidth/2)
        let delay:((Point,Point,Double)->Double)?=traffic.isEmpty ? nil:{a,b,_ in
            Self.trafficCost(from:a,to:b,footprints:footprints)
        }
        var path=taxiNetwork.shortestPath(from:start,to:end,maximumAccessDistance:2,minimumWidth:minimumWidth,edgeDelay:delay,initialHeading:heading,turnPenalty:heading == nil ? 0:35)
        if heading != nil && path.count>1 && path[0].distance(to:start)<1 {path.removeFirst()}
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

/// Immutable geometry, computed independently of mutable simulation traffic.
/// Ordered candidates and the original search/fillet arithmetic are preserved.
private enum AirportRouteGeometry {
    struct DepartureInput {
        let graph:RoadGraph,taxi:RoadGraph,a:Point,b:Point,start:Point,original:Point,fallbackLineup:Point
        let runwayLength:Double,minimumRunway:Double,span:Double,clearance:Double
        let initialHeading:Double?
        func build()->(Point,Point) {
            let dx=b.x-a.x,dy=b.y-a.y,l=a.distance(to:b)
            var best:(Double,Point,Point)?
            for p in graph.nodes {
                let t=((p.x-a.x)*dx+(p.y-a.y)*dy)/(l*l),side=abs((p.x-a.x)*dy-(p.y-a.y)*dx)/l
                guard t>0.025,t<0.52,side<5,(1-t)*runwayLength>=minimumRunway else{continue}
                let choices=taxi.nodes.filter {q in
                    let s=abs((q.x-a.x)*dy-(q.y-a.y)*dx)/l
                    return s>=clearance && s<clearance+35 && q.distance(to:p)<150
                }.sorted{$0.distance(to:p)<$1.distance(to:p)}
                for hold in choices {
                    let entry=graph.shortestPath(from:hold,to:p,maximumAccessDistance:2,minimumWidth:span)
                    guard !entry.isEmpty,FlightCurves.length(from:hold,route:entry)<200 else{continue}
                    let route=taxi.shortestPath(from:start,to:hold,maximumAccessDistance:2,minimumWidth:span,initialHeading:initialHeading,turnPenalty:initialHeading == nil ? 0:35)
                    guard !route.isEmpty else{continue}
                    // Do not taxi past an entry and hold facing away from it.
                    // The combined taxi/entry route must not double back here.
                    if let previous=([start]+route).dropLast().last(where:{$0.distance(to:hold)>1}),
                       let next=entry.first(where:{$0.distance(to:hold)>1}) {
                        let incoming=atan2(hold.y-previous.y,hold.x-previous.x)
                        let outgoing=atan2(next.y-hold.y,next.x-hold.x)
                        if cos(outgoing-incoming)<(-0.5) {continue}
                        var prior=hold,heading=incoming,rotation=0.0
                        for point in entry where point.distance(to:prior)>0.01 {
                            let nextHeading=atan2(point.y-prior.y,point.x-prior.x)
                            rotation+=abs(atan2(sin(nextHeading-heading),cos(nextHeading-heading)))
                            prior=point;heading=nextHeading
                        }
                        let runwayHeading=atan2(dy,dx)
                        rotation+=abs(atan2(sin(runwayHeading-heading),cos(runwayHeading-heading)))
                        if rotation>Double.pi*1.5 {continue}
                    }
                    let cost=FlightCurves.length(from:start,route:route)+FlightCurves.length(from:hold,route:entry)
                    if best == nil || cost<best!.0 {best=(cost,hold,p)}
                }
            }
            if let best {return(best.1,best.2)}
            func safe(_ p:Point)->Bool {
                let along=((p.x-a.x)*dx+(p.y-a.y)*dy)/l
                let side=abs((p.x-a.x)*dy-(p.y-a.y)*dx)/l
                return side>=clearance || along < -clearance || along>l+clearance
            }
            let route=[start]+taxi.shortestPath(from:start,to:original,maximumAccessDistance:2,minimumWidth:span)
            var near=route.last ?? original
            var safeHold:Point?=safe(near) ? near:nil
            if safeHold == nil {
                for far in route.dropLast().reversed() {
                    if safe(far) {
                        var low=0.0,high=1.0
                        for _ in 0..<24 {let mid=(low+high)/2;if safe(Point.interpolate(near,far,fraction:mid)){high=mid}else{low=mid}}
                        safeHold=Point.interpolate(near,far,fraction:min(1,high+1/max(1,near.distance(to:far))))
                        break
                    }
                    near=far
                }
            }
            return(safeHold ?? start,fallbackLineup)
        }
    }
    struct Key:Hashable {let runway:Int;let span:Double;let minimum:Double;let bothSides:Bool}
    struct Candidate {let rollout:Point;let progress:Double;let path:[Point]}
    final class Store:@unchecked Sendable {
        private let lock=NSLock()
        private let queue=DispatchQueue(label:"AirTrafficControl.exit-geometry",qos:.utility)
        private var cache:[Key:[Candidate]]=[:]
        private var pending=Set<Key>()
        private var entries:[String:(Point,Point)]=[:]
        private var pendingEntries=Set<String>()
        private var cancelled=false
        func cancel() {lock.lock();cancelled=true;lock.unlock()}
        func value(_ key:Key)->[Candidate]? {lock.lock();defer{lock.unlock()};return cache[key]}
        func save(_ value:[Candidate],for key:Key) {lock.lock();defer{lock.unlock()};if !cancelled {if cache.count>=128 {cache.removeAll(keepingCapacity:true)};cache[key]=value};pending.remove(key)}
        func submit(_ key:Key,graph:RoadGraph,a:Point,b:Point,authored:[[Point]]) {
            lock.lock()
            guard !cancelled,cache[key]==nil,pending.insert(key).inserted else{lock.unlock();return}
            lock.unlock()
            let job=Job(key:key,graph:graph,a:a,b:b,authored:authored,store:self)
            queue.async {job.run()}
        }
        func shouldRun(_ key:Key)->Bool {lock.lock();defer{lock.unlock()};return !cancelled && cache[key]==nil}
        func entry(_ key:String)->(Point,Point)? {lock.lock();defer{lock.unlock()};return entries[key]}
        func hasEntryOrPending(_ key:String)->Bool {lock.lock();defer{lock.unlock()};return entries[key] != nil || pendingEntries.contains(key)}
        func saveEntry(_ value:(Point,Point),for key:String) {lock.lock();defer{lock.unlock()};if !cancelled {if entries.count>=256 {entries.removeAll(keepingCapacity:true)};entries[key]=value};pendingEntries.remove(key)}
        func submitEntry(_ key:String,input:DepartureInput) {
            lock.lock()
            guard !cancelled,entries[key]==nil,pendingEntries.insert(key).inserted else{lock.unlock();return}
            lock.unlock()
            let job=EntryJob(key:key,input:input,store:self)
            queue.async {job.run()}
        }
        func shouldRunEntry(_ key:String)->Bool {lock.lock();defer{lock.unlock()};return !cancelled && entries[key]==nil}
    }
    // Every captured field is an immutable value snapshot; Store synchronizes
    // its only mutable state. No simulation or UI object crosses this queue.
    private final class Job:@unchecked Sendable {
        let key:Key,graph:RoadGraph,a:Point,b:Point,authored:[[Point]],store:Store
        init(key:Key,graph:RoadGraph,a:Point,b:Point,authored:[[Point]],store:Store) {self.key=key;self.graph=graph;self.a=a;self.b=b;self.authored=authored;self.store=store}
        func run() {if store.shouldRun(key) {store.save(build(key,graph:graph,a:a,b:b,authored:authored),for:key)}}
    }
    private final class EntryJob:@unchecked Sendable {
        let key:String,input:DepartureInput,store:Store
        init(key:String,input:DepartureInput,store:Store) {self.key=key;self.input=input;self.store=store}
        func run() {if store.shouldRunEntry(key) {store.saveEntry(input.build(),for:key)}}
    }
    static func build(_ key:Key,graph:RoadGraph,a:Point,b:Point,authored:[[Point]])->[Candidate] {
        let dx=b.x-a.x,dy=b.y-a.y,l=a.distance(to:b)
        var result:[Candidate]=[]
        if key.bothSides {
            for exit in authored {
                guard let first=exit.first else{continue}
                let t=((first.x-a.x)*dx+(first.y-a.y)*dy)/(l*l)
                if t>=key.minimum {result.append(.init(rollout:first,progress:t,path:[first]+AirportSurface.roundedPath(exit,radius:3)))}
            }
        }
        let joins=graph.nodes.compactMap {p -> (Point,Double)? in
            let t=((p.x-a.x)*dx+(p.y-a.y)*dy)/(l*l),side=abs((p.x-a.x)*dy-(p.y-a.y)*dx)/l
            return t>=key.minimum && t<=1.000001 && side<5 ? (p,t):nil
        }.sorted{$0.1<$1.1}
        for (join,t) in joins {
            let targets=graph.nodes.filter {p in
                let signed=((p.x-a.x)*dy-(p.y-a.y)*dx)/l,side=abs(signed)
                return side>22 && side<50 && p.distance(to:join)<90 && (key.bothSides || signed>0)
            }.sorted{$0.distance(to:join)<$1.distance(to:join)}
            for target in targets.prefix(20) {
                let path=graph.shortestPath(from:join,to:target,maximumAccessDistance:2,minimumWidth:key.span)
                guard !path.isEmpty else{continue}
                var exitPath:[Point]=[],valid=true
                for p in path {
                    let along=((p.x-a.x)*dx+(p.y-a.y)*dy)/(l*l),side=abs((p.x-a.x)*dy-(p.y-a.y)*dx)/l
                    if side<12 && along<t-0.035 {valid=false;break}
                    exitPath.append(p)
                    if side>22 {break}
                }
                guard valid,let last=exitPath.last,abs((last.x-a.x)*dy-(last.y-a.y)*dx)/l>22,FlightCurves.length(from:join,route:exitPath)<110 else{continue}
                let rollout=Point.interpolate(a,b,fraction:t)
                result.append(.init(rollout:rollout,progress:t,path:[rollout]+AirportSurface.roundedPath([rollout,join]+exitPath,radius:3)))
                if !key.bothSides {return result}
            }
        }
        return result
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
