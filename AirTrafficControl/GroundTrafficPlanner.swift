import Foundation

/// The one source of truth for ground-motion forecasting, execution and the
/// short-range safety fallback. Values are game-world pixels and seconds.
/// Rendering may exaggerate sprite size/motion, but never changes this model.
struct GroundMotionProfile: Equatable {
    let cruiseSpeed: Double
    let acceleration: Double
    let deceleration: Double
    let reactionTime: Double
    let clearanceUncertainty: Double
    let maximumTurnRate: Double

    func stoppingDistance(at speed: Double) -> Double {
        let v=max(0,speed)
        return v*reactionTime+v*v/(2*deceleration)+clearanceUncertainty
    }
    func lookaheadDistance(at speed: Double,aircraftLength:Double) -> Double {
        stoppingDistance(at:speed)+aircraftLength*0.275
    }
    func turnSpeed(from incoming:Double,to outgoing:Double,over distance:Double)->Double {
        let turn=abs(atan2(sin(outgoing-incoming),cos(outgoing-incoming)))
        guard turn>0.001 else{return cruiseSpeed}
        return min(cruiseSpeed,max(2,distance*maximumTurnRate/turn))
    }
}

enum GroundMotionModel {
    static func profile(for flight:Aircraft)->GroundMotionProfile {
        switch flight.phase {
        case .pushback:
            return .init(cruiseSpeed:flight.model.speed(for:.pushback),acceleration:1.4,deceleration:2.2,reactionTime:0.45,clearanceUncertainty:2.5,maximumTurnRate:0.16)
        case .landingRoll, .landing:
            return .init(cruiseSpeed:flight.model.speed(for:.landing),acceleration:2.0,deceleration:3.0,reactionTime:0.35,clearanceUncertainty:2.5,maximumTurnRate:0.20)
        case .takeoffRoll, .takeoff:
            let lineup=flight.lineupRemaining>0
            return .init(cruiseSpeed:lineup ? 8:flight.model.speed(for:.takeoff),acceleration:lineup ? 3:2.4,deceleration:3.0,reactionTime:0.30,clearanceUncertainty:2.0,maximumTurnRate:0.20)
        case .lineup:
            return .init(cruiseSpeed:8,acceleration:2.0,deceleration:3.0,reactionTime:0.35,clearanceUncertainty:2.0,maximumTurnRate:0.18)
        case .runwayExit:
            return .init(cruiseSpeed:flight.model.speed(for:.runwayExit),acceleration:2.0,deceleration:3.0,reactionTime:0.35,clearanceUncertainty:2.5,maximumTurnRate:0.18)
        default:
            return .init(cruiseSpeed:flight.model.speed(for:.taxiing),acceleration:3.0,deceleration:3.0,reactionTime:0.35,clearanceUncertainty:2.0,maximumTurnRate:0.22)
        }
    }
}

/// A committed ground movement is a trajectory, including its waits, rather than
/// a polyline whose timing is guessed independently by the renderer/executor.
struct GroundTrafficLeg {
    let from: Point
    let to: Point
    let start: Double
    let end: Double
    let heading: Double
    let cruise: Double
    let acceleration: Double
    let deceleration: Double
    let entrySpeed: Double
    let exitSpeed: Double
    var distance: Double { from.distance(to: to) }
    private var peakSpeed:Double {min(cruise,sqrt(max(0,(2*acceleration*deceleration*distance+deceleration*entrySpeed*entrySpeed+acceleration*exitSpeed*exitSpeed)/(acceleration+deceleration))))}
    private var accelerationDistance:Double {max(0,(peakSpeed*peakSpeed-entrySpeed*entrySpeed)/(2*acceleration))}
    private var brakingDistance:Double {max(0,(peakSpeed*peakSpeed-exitSpeed*exitSpeed)/(2*deceleration))}
    private var accelerationTime:Double {max(0,(peakSpeed-entrySpeed)/acceleration)}
    private var cruiseTime:Double {max(0,distance-accelerationDistance-brakingDistance)/max(0.001,peakSpeed)}
    private var brakingTime:Double {max(0,(peakSpeed-exitSpeed)/deceleration)}
    private func integratedDistance(at time:Double)->Double {
        let t=min(end-start,max(0,time-start)),cruiseEnd=accelerationTime+cruiseTime
        if t<accelerationTime {return entrySpeed*t+acceleration*t*t/2}
        if t<cruiseEnd {return accelerationDistance+peakSpeed*(t-accelerationTime)}
        let down=min(brakingTime,max(0,t-cruiseEnd))
        return min(distance,accelerationDistance+peakSpeed*cruiseTime+peakSpeed*down-deceleration*down*down/2)
    }
    private func integratedSpeed(at time:Double)->Double {
        let t=min(end-start,max(0,time-start)),cruiseEnd=accelerationTime+cruiseTime
        if t<accelerationTime {return min(peakSpeed,entrySpeed+acceleration*t)}
        if t<cruiseEnd {return peakSpeed}
        return max(exitSpeed,peakSpeed-deceleration*(t-cruiseEnd))
    }
    func travelled(at time: Double) -> Double {
        integratedDistance(at:time)
    }
    func position(at time: Double) -> Point {
        let f=distance>0.00001 ? travelled(at:time)/distance : 0
        return Point(x:from.x+(to.x-from.x)*f,y:from.y+(to.y-from.y)*f)
    }
    func speed(at time:Double)->Double {
        return integratedSpeed(at:time)
    }
}
struct GroundTrafficPlan {
    let owner: String
    let revision: Int
    let phase: FlightPhase
    let start: Point
    let initialHeading: Double
    let legs: [GroundTrafficLeg]
    let horizon: Double
    var finish: Double { legs.last?.end ?? horizon }
    func position(at time:Double)->Point {
        var p=start
        for leg in legs { if time<leg.start{return p};if time<leg.end{return leg.position(at:time)};p=leg.to }
        return p
    }
    func heading(at time:Double)->Double {
        var h=initialHeading
        for leg in legs {
            if time<leg.start {break}
            if time<leg.end {
                let turn=atan2(sin(leg.heading-h),cos(leg.heading-h))
                return h+turn*min(1,max(0,(time-leg.start)/max(0.001,min(1,leg.end-leg.start))))
            }
            h=leg.heading
        }
        return h
    }
    func remainingRoute(at time:Double)->[Point] { legs.filter{$0.end>time+0.000001}.map(\.to) }
    func waiting(at time:Double)->Bool { !legs.contains{$0.start<=time && time<$0.end} && time<finish }
    func speed(at time:Double)->Double { legs.first{$0.start<=time && time<$0.end}?.speed(at:time) ?? 0 }
    func shifted(by offset:Double)->GroundTrafficPlan {
        guard abs(offset)>0.000001 else{return self}
        return .init(owner:owner,revision:revision,phase:phase,start:start,initialHeading:initialHeading,legs:legs.map {
            .init(from:$0.from,to:$0.to,start:$0.start+offset,end:$0.end+offset,heading:$0.heading,cruise:$0.cruise,acceleration:$0.acceleration,deceleration:$0.deceleration,entrySpeed:$0.entrySpeed,exitSpeed:$0.exitSpeed)
        },horizon:horizon+offset)
    }
}

/// Conservative swept convex footprints: an entire edge and its turn are held
/// for the traversal interval. This catches opposite edges AND geometric
/// intersections with no shared graph node. It intentionally trades capacity
/// for safety; it does not claim globally optimal multi-aircraft planning.
struct GroundTrafficReservation {
    let owner:String
    let start:Double
    let end:Double
    let polygon:[Point]
    let minX:Double, maxX:Double, minY:Double, maxY:Double
    init(owner:String,start:Double,end:Double,polygon:[Point]) {
        self.owner=owner;self.start=start;self.end=end;self.polygon=polygon
        var x0=Double.infinity,x1 = -Double.infinity,y0=Double.infinity,y1 = -Double.infinity
        for p in polygon {x0=min(x0,p.x);x1=max(x1,p.x);y0=min(y0,p.y);y1=max(y1,p.y)}
        minX=x0;maxX=x1;minY=y0;maxY=y1
    }
    func intersects(_ other:GroundTrafficReservation)->Bool {
        if maxX<other.minX || other.maxX<minX || maxY<other.minY || other.maxY<minY {return false}
        for polygon in [polygon,other.polygon] {
            for i in polygon.indices {
                let a=polygon[i],b=polygon[(i+1)%polygon.count],dx=b.y-a.y,dy=a.x-b.x
                var a0=Double.infinity,a1 = -Double.infinity,b0=Double.infinity,b1 = -Double.infinity
                for p in self.polygon {let d=p.x*dx+p.y*dy;a0=min(a0,d);a1=max(a1,d)}
                for p in other.polygon {let d=p.x*dx+p.y*dy;b0=min(b0,d);b1=max(b1,d)}
                if a1<b0 || b1<a0 {return false}
            }
        }
        return true
    }
}
struct GroundTrafficSnapshot {
    let revision:Int
    let now:Double
    let horizon:Double
    let reservations:[GroundTrafficReservation]
}

enum GroundTrafficPlanner {
    static let timeMargin=0.15
    static func hull(_ points:[Point])->[Point] {
        let sorted=points.sorted{$0.x==$1.x ? $0.y<$1.y : $0.x<$1.x}
        guard sorted.count>2 else{return sorted}
        func cross(_ a:Point,_ b:Point,_ c:Point)->Double {(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)}
        var lower:[Point]=[],upper:[Point]=[]
        for p in sorted {while lower.count>1 && cross(lower[lower.count-2],lower.last!,p)<=0 {lower.removeLast()};lower.append(p)}
        for p in sorted.reversed() {while upper.count>1 && cross(upper[upper.count-2],upper.last!,p)<=0 {upper.removeLast()};upper.append(p)}
        return Array(lower.dropLast())+Array(upper.dropLast())
    }
    private static let profile=hull([(0.5,0.0),(0.18,-0.08),(-0.08,-0.5),(-0.20,-0.49),(-0.49,-0.23),(-0.5,0),(-0.49,0.23),(-0.20,0.49),(-0.08,0.5),(0.18,0.08)].map{Point(x:$0.0,y:$0.1)})
    static func body(_ flight:Aircraft,at p:Point,heading:Double)->[Point] {
        let uncertainty=GroundMotionModel.profile(for:flight).clearanceUncertainty
        let l=flight.model.length*0.55+uncertainty,w=flight.model.span*0.55+uncertainty,c=cos(heading),s=sin(heading)
        return profile.map{q in Point(x:p.x+q.x*l*c-q.y*w*s,y:p.y+q.x*l*s+q.y*w*c)}
    }
    static func swept(_ flight:Aircraft,from a:Point,to b:Point,heading:Double,previousHeading:Double?=nil)->[Point] {
        var points=body(flight,at:a,heading:heading)+body(flight,at:b,heading:heading)
        if let previousHeading {
            let turn=atan2(sin(heading-previousHeading),cos(heading-previousHeading))
            if abs(turn)>0.001 {
                let steps=max(1,Int(ceil(abs(turn)/0.15)))
                for i in 0...steps {
                    let h=previousHeading+turn*Double(i)/Double(steps)
                    points += body(flight,at:a,heading:h)+body(flight,at:b,heading:h)
                }
            }
        }
        return hull(points)
    }
    static func duration(_ distance:Double,entrySpeed:Double=0,exitSpeed:Double=0,speed:Double,acceleration:Double,deceleration:Double)->Double {
        let peak=min(speed,sqrt(max(0,(2*acceleration*deceleration*distance+deceleration*entrySpeed*entrySpeed+acceleration*exitSpeed*exitSpeed)/(acceleration+deceleration))))
        let up=max(0,(peak-entrySpeed)/acceleration),down=max(0,(peak-exitSpeed)/deceleration)
        let upDistance=max(0,(peak*peak-entrySpeed*entrySpeed)/(2*acceleration)),downDistance=max(0,(peak*peak-exitSpeed*exitSpeed)/(2*deceleration))
        return up+max(0,distance-upDistance-downDistance)/max(0.001,peak)+down
    }

    static func reservations(for plan:GroundTrafficPlan,flight:Aircraft,now:Double,horizon:Double)->[GroundTrafficReservation] {
        var result:[GroundTrafficReservation]=[],p=plan.start,t=now,h=plan.initialHeading
        for leg in plan.legs {
            if leg.end<now {p=leg.to;h=leg.heading;continue}
            if leg.start>t {result.append(.init(owner:flight.id,start:t,end:leg.start,polygon:body(flight,at:p,heading:h)))}
            result.append(.init(owner:flight.id,start:max(now,leg.start)-timeMargin,end:leg.end+timeMargin,polygon:swept(flight,from:leg.from,to:leg.to,heading:leg.heading,previousHeading:h)))
            p=leg.to;t=leg.end;h=leg.heading
        }
        if t<horizon {result.append(.init(owner:flight.id,start:t,end:horizon,polygon:body(flight,at:p,heading:h)))}
        return result
    }
    static func validated(_ plan:GroundTrafficPlan,flight:Aircraft,against snapshot:GroundTrafficSnapshot)->Bool {
        guard plan.revision==snapshot.revision else{return false}
        return !reservations(for:plan,flight:flight,now:snapshot.now,horizon:snapshot.horizon).contains {a in
            snapshot.reservations.contains{b in b.owner != flight.id && a.start<b.end && b.start<a.end && a.intersects(b)}
        }
    }

    /// SIPP-style search: labels are (node, incoming edge, safe interval), not
    /// one distance per node. Waiting must fit at the source; traversal AND the
    /// destination interval must be free. Endpoints remain occupied afterwards.
    static func plan(flight:Aircraft,graph input:RoadGraph,target:Point,snapshot:GroundTrafficSnapshot,expansionLimit:Int=18000)->GroundTrafficPlan? {
        guard flight.position.distance(to:target)>0.001 else{return nil}
        var graph=input
        graph.edges=graph.edges.filter{$0.fits(flight.model.span*0.55)}
        guard let se=graph.closestEdge(to:flight.position),let ee=graph.closestEdge(to:target),
              graph.projection(flight.position,onto:graph.edges[se]).distance(to:flight.position)<=2,
              graph.projection(target,onto:graph.edges[ee]).distance(to:target)<=2 else{return nil}
        guard let start=graph.attach(flight.position,maximumAccessDistance:2),let goal=graph.attach(target,maximumAccessDistance:2) else{return nil}
        return search(flight:flight,graph:graph,start:start,goal:goal,snapshot:snapshot,expansionLimit:expansionLimit)
    }
    /// Used for authored pushback/stand access and tower-authorized line-up.
    /// Restricting the graph to this polyline preserves its geometric intent.
    static func plan(flight:Aircraft,route:[Point],snapshot:GroundTrafficSnapshot,constraints:RoadGraph?=nil)->GroundTrafficPlan? {
        var graph=RoadGraph();graph.addLane([flight.position]+route)
        guard graph.nodes.count>1 else{return nil}
        if let source=constraints {
            graph.turnRules=source.turnRules;graph.junctionRules=source.junctionRules
            for i in graph.edges.indices {
                let edge=graph.edges[i],a=graph.nodes[edge.a],b=graph.nodes[edge.b],mid=Point.interpolate(a,b,fraction:0.5)
                guard let index=source.closestEdge(to:mid) else{return nil}
                if source.hasRestrictions && source.projection(mid,onto:source.edges[index]).distance(to:mid)>4 {return nil}
                var metadata=source.edges[index]
                let x=source.nodes[metadata.a],y=source.nodes[metadata.b]
                if (b.x-a.x)*(y.x-x.x)+(b.y-a.y)*(y.y-x.y)<0 {
                    if metadata.direction == .forward {metadata.direction = .reverse} else if metadata.direction == .reverse {metadata.direction = .forward}
                }
                metadata.a=edge.a;metadata.b=edge.b;graph.edges[i]=metadata
            }
            for i in graph.nodes.indices {
                if let original=source.nodes.indices.first(where:{source.nodes[$0].distance(to:graph.nodes[i])<0.001}) {
                    graph.sourceNodeIDs[i]=source.sourceNodeIDs[original]
                    graph.waitPermissions[i]=source.waitPermissions[original]
                }
            }
        }
        // Directed chain: no shortcut across curves or reverse along a spur.
        guard let target=route.last,let goal=graph.nodes.firstIndex(where:{$0.distance(to:target)<0.01}) else{return nil}
        return search(flight:flight,graph:graph,start:0,goal:goal,snapshot:snapshot,expansionLimit:18000,directed:true)
    }
    private struct Interval {var start:Double;var end:Double}
    private struct Key:Hashable {let node:Int;let from:Int;let interval:Int;var edge:Int = -1;var speed:Double = 0}
    private struct Label {let key:Key;let time:Double;let heading:Double;let parent:Int?;let depart:Double}
    private struct Heap {
        var items:[(Int,Double)]=[]
        mutating func push(_ item:(Int,Double)) {items.append(item);var i=items.count-1;while i>0 {let p=(i-1)/2;if items[p].1<=items[i].1{break};items.swapAt(i,p);i=p}}
        mutating func pop()->(Int,Double)? {guard !items.isEmpty else{return nil};if items.count==1{return items.removeLast()};let first=items[0];items[0]=items.removeLast();var i=0;while i*2+1<items.count {var c=i*2+1;if c+1<items.count && items[c+1].1<items[c].1{c+=1};if items[i].1<=items[c].1{break};items.swapAt(i,c);i=c};return first}
    }
    private static func search(flight:Aircraft,graph:RoadGraph,start:Int,goal:Int,snapshot:GroundTrafficSnapshot,expansionLimit:Int,directed:Bool=false)->GroundTrafficPlan? {
        let motion=GroundMotionModel.profile(for:flight),speed=motion.cruiseSpeed
        let obstacles=snapshot.reservations.filter{$0.owner != flight.id}
        // A queued aircraft may hold this exact destination indefinitely. Do
        // not explore thousands of cyclic time labels for an occupied endpoint.
        if obstacles.contains(where:{$0.start<=snapshot.now && $0.end>=snapshot.horizon && AirportFence.contains(graph.nodes[goal],polygon:$0.polygon)}) {return nil}
        var adjacency=Array(repeating:[(Int,Int)](),count:graph.nodes.count)
        let stationary=obstacles.filter{$0.start<=snapshot.now && $0.end>=snapshot.horizon}
        for (edgeIndex,e) in graph.edges.enumerated() where e.fits(flight.model.span*0.55) {
            for (u,v) in directed ? [(e.a,e.b)] : [(e.a,e.b),(e.b,e.a)] {
                guard e.permits(from:u) else{continue}
                let a=graph.nodes[u],b=graph.nodes[v],heading=a.distance(to:b)>0.001 ? atan2(b.y-a.y,b.x-a.x)+(flight.phase == .pushback ? .pi : 0) : flight.heading
                let shape=GroundTrafficReservation(owner:flight.id,start:0,end:0,polygon:swept(flight,from:a,to:b,heading:heading))
                if !stationary.contains(where:{shape.intersects($0)}) {adjacency[u].append((v,edgeIndex))}
            }
        }
        var reachable=Set([start]),stack=[start]
        while let u=stack.popLast() {for (v,_) in adjacency[u] where reachable.insert(v).inserted {stack.append(v)}}
        guard reachable.contains(goal) else{return nil}
        var intervalCache:[String:[Interval]]=[:]
        var transitionCache:[String:[GroundTrafficReservation]]=[:]
        func safe(_ node:Int,_ from:Int,_ heading:Double)->[Interval] {
            let key="\(node):\(from)"
            if let cached=intervalCache[key]{return cached}
            let shape=GroundTrafficReservation(owner:flight.id,start:snapshot.now,end:snapshot.horizon,polygon:body(flight,at:graph.nodes[node],heading:heading))
            let blocked=obstacles.filter{shape.intersects($0)}.map{Interval(start:max(snapshot.now,$0.start-timeMargin),end:min(snapshot.horizon,$0.end+timeMargin))}.filter{$0.end>$0.start}.sorted{$0.start<$1.start}
            var intervals:[Interval]=[],t=snapshot.now
            for b in blocked {if b.start>t {intervals.append(.init(start:t,end:b.start))};t=max(t,b.end)}
            if t<snapshot.horizon {intervals.append(.init(start:t,end:snapshot.horizon))}
            intervalCache[key]=intervals;return intervals
        }
        guard let initial=safe(start,-1,flight.heading).firstIndex(where:{$0.start<=snapshot.now+0.00001}) else{return nil}
        let first=Key(node:start,from:-1,interval:initial)
        var labels=[Label(key:first,time:snapshot.now,heading:flight.heading,parent:nil,depart:snapshot.now)],best=[first:snapshot.now],heap=Heap(),expansions=0
        heap.push((0,snapshot.now))
        while let (index,_)=heap.pop() {
            let label=labels[index],u=label.key.node
            if label.time>(best[label.key] ?? .infinity)+0.00001 {continue}
            expansions+=1;if expansions>expansionLimit{return nil}
            let source=safe(u,label.key.from,label.heading)[label.key.interval]
            if u==goal && source.end>=snapshot.horizon-0.00001 && (graph.canWait(at:u) || [.lineup,.takeoff].contains(flight.phase)) {
                var chain:[Int]=[],cursor:Int?=index
                while let i=cursor {chain.append(i);cursor=labels[i].parent}
                var legs:[GroundTrafficLeg]=[]
                let route=Array(chain.reversed())
                var nodeSpeeds=route.map { labels[$0].key.speed }
                if !nodeSpeeds.isEmpty {nodeSpeeds[0]=0;nodeSpeeds[nodeSpeeds.count-1]=0}
                for k in 1..<route.count {
                    let i=route[k],l=labels[i],p=labels[l.parent!]
                    let edge=graph.edges[l.key.edge],edgeSpeed=min(speed,edge.speedLimit ?? speed,motion.turnSpeed(from:p.heading,to:l.heading,over:graph.nodes[l.key.node].distance(to:graph.nodes[p.key.node])))
                    let cap=nodeSpeeds[k]
                    nodeSpeeds[k]=min(cap,edgeSpeed)
                    if k>1 {nodeSpeeds[k-1]=min(nodeSpeeds[k-1],edgeSpeed)}
                }
                if route.count>1 {
                    for k in 1..<route.count {
                        let d=graph.nodes[labels[route[k]].key.node].distance(to:graph.nodes[labels[route[k-1]].key.node])
                        nodeSpeeds[k]=min(nodeSpeeds[k],sqrt(max(0,nodeSpeeds[k-1]*nodeSpeeds[k-1]+2*motion.acceleration*d)))
                    }
                }
                if route.count>1 {
                    for k in stride(from:route.count-2,through:0,by:-1) {
                        let d=graph.nodes[labels[route[k+1]].key.node].distance(to:graph.nodes[labels[route[k]].key.node])
                        nodeSpeeds[k]=min(nodeSpeeds[k],sqrt(max(0,nodeSpeeds[k+1]*nodeSpeeds[k+1]+2*motion.deceleration*d)))
                    }
                }
                var scheduleTime=snapshot.now
                for k in 1..<route.count {
                    let i=route[k],l=labels[i],p=labels[l.parent!],edgeSpeed=min(speed,graph.edges[l.key.edge].speedLimit ?? speed)
                    let d=graph.nodes[l.key.node].distance(to:graph.nodes[p.key.node])
                    let travel=duration(d,entrySpeed:nodeSpeeds[k-1],exitSpeed:nodeSpeeds[k],speed:edgeSpeed,acceleration:motion.acceleration,deceleration:motion.deceleration)
                    let start=max(scheduleTime,l.depart)
                    legs.append(.init(from:graph.nodes[p.key.node],to:graph.nodes[l.key.node],start:start,end:start+travel,heading:l.heading,cruise:edgeSpeed,acceleration:motion.acceleration,deceleration:motion.deceleration,entrySpeed:nodeSpeeds[k-1],exitSpeed:nodeSpeeds[k]))
                    scheduleTime=start+travel
                }
                let plan=GroundTrafficPlan(owner:flight.id,revision:snapshot.revision,phase:flight.phase,start:flight.position,initialHeading:flight.heading,legs:legs,horizon:snapshot.horizon)
                if validated(plan,flight:flight,against:snapshot) {return plan}
                continue
            }
            for (v,edgeIndex) in adjacency[u] where graph.canTurn(incoming:label.key.edge,outgoing:edgeIndex,at:u) {
                let a=graph.nodes[u],b=graph.nodes[v],d=a.distance(to:b)
                let heading=d>0.001 ? atan2(b.y-a.y,b.x-a.x)+(flight.phase == .pushback ? .pi : 0) : label.heading
                let edgeSpeed=min(speed,graph.edges[edgeIndex].speedLimit ?? speed,motion.turnSpeed(from:label.heading,to:heading,over:d))
                let exitSpeed=min(edgeSpeed,sqrt(max(0,label.key.speed*label.key.speed+2*motion.acceleration*d)))
                let travel=max(0.001,duration(d,entrySpeed:label.key.speed,exitSpeed:exitSpeed,speed:edgeSpeed,acceleration:motion.acceleration,deceleration:motion.deceleration))
                let transition="\(label.key.from):\(u):\(v)"
                let blocked:[GroundTrafficReservation]
                if let cached=transitionCache[transition] {blocked=cached}
                else {
                    let sweep=GroundTrafficReservation(owner:flight.id,start:0,end:0,polygon:swept(flight,from:a,to:b,heading:heading,previousHeading:label.heading))
                    blocked=obstacles.filter{sweep.intersects($0)}.sorted{$0.start<$1.start}
                    transitionCache[transition]=blocked
                }
                for (interval,destination) in safe(v,u,heading).enumerated() {
                    var depart=max(label.time,destination.start-travel+timeMargin)
                    for reservation in blocked {
                        if depart<reservation.end+timeMargin && depart+travel>reservation.start-timeMargin {depart=max(depart,reservation.end+timeMargin*2)}
                    }
                    let arrival=depart+travel
                    if depart>label.time+0.000001 && !graph.canWait(at:u) {continue}
                    guard depart<source.end-timeMargin,arrival<destination.end-timeMargin,arrival<snapshot.horizon else{continue}
                    let key=Key(node:v,from:u,interval:interval,edge:edgeIndex,speed:exitSpeed)
                    if arrival+0.00001<(best[key] ?? .infinity) {
                        best[key]=arrival;labels.append(.init(key:key,time:arrival,heading:heading,parent:index,depart:depart));heap.push((labels.count-1,arrival+b.distance(to:graph.nodes[goal])/speed))
                    }
                }
            }
        }
        return nil
    }
}

/// Runs expensive safe-interval searches away from the main actor. Requests
/// are serialized so several newly released aircraft do not saturate every
/// core, while completed plans are collected by the simulation on a later
/// frame and committed against fresh traffic state.
final class BackgroundGroundTrafficPlanner: @unchecked Sendable {
    enum Route {
        case graph(RoadGraph,Point,fallback:[Point]?,constraints:RoadGraph?)
        case authored([Point],RoadGraph?)
    }
    struct Result {
        let owner:String
        let token:Int
        let snapshotTime:Double
        let plan:GroundTrafficPlan?
    }
    private final class Work: @unchecked Sendable {
        let owner:String,token:Int
        let flight:Aircraft
        let route:Route
        let snapshot:GroundTrafficSnapshot
        let delay:Double
        let planner:BackgroundGroundTrafficPlanner
        init(owner:String,token:Int,flight:Aircraft,route:Route,snapshot:GroundTrafficSnapshot,delay:Double,planner:BackgroundGroundTrafficPlanner) {
            self.owner=owner;self.token=token;self.flight=flight;self.route=route;self.snapshot=snapshot;self.delay=delay;self.planner=planner
        }
        func run() {
            let plan=BackgroundGroundTrafficPlanner.calculate(flight:flight,route:route,snapshot:snapshot,delay:delay)
            planner.finish(.init(owner:owner,token:token,snapshotTime:snapshot.now,plan:plan))
        }
    }
    private let queue=DispatchQueue(label:"AirTrafficControl.ground-planning",qos:.userInitiated)
    private let lock=NSLock()
    private var completed:[Result]=[]
    static func calculate(flight:Aircraft,route:Route,snapshot:GroundTrafficSnapshot,delay:Double=0)->GroundTrafficPlan? {
        if delay>0 {Thread.sleep(forTimeInterval:delay)}
        switch route {
        case .graph(let graph,let target,let fallback,let constraints):
            return GroundTrafficPlanner.plan(flight:flight,graph:graph,target:target,snapshot:snapshot) ?? fallback.flatMap {
                GroundTrafficPlanner.plan(flight:flight,route:$0,snapshot:snapshot,constraints:constraints)
            }
        case .authored(let path,let constraints):
            return GroundTrafficPlanner.plan(flight:flight,route:path,snapshot:snapshot,constraints:constraints)
        }
    }
    func submit(owner:String,token:Int,flight:Aircraft,route:Route,snapshot:GroundTrafficSnapshot,delay:Double=0) {
        let work=Work(owner:owner,token:token,flight:flight,route:route,snapshot:snapshot,delay:delay,planner:self)
        queue.async {work.run()}
    }
    private func finish(_ result:Result) {
        lock.lock();completed.append(result);lock.unlock()
    }
    func drain()->[Result] {
        lock.lock();defer{lock.unlock()}
        let result=completed;completed.removeAll(keepingCapacity:true);return result
    }
}
