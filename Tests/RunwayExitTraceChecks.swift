import Foundation

@main struct RunwayExitTraceChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let s=Simulation(seed:17,continuousTraffic:false),model=AircraftCatalog.model("05")
        for runway in [0,3] {
            let surface=s.surface,a=surface.threshold(runway),b=surface.runwayEnds[runway].1,l=a.distance(to:b),dx=b.x-a.x,dy=b.y-a.y
            func side(_ p:Point)->Double {((p.x-a.x)*dy-(p.y-a.y)*dx)/l}
            let gate=surface.gates.min{$0.position.y<$1.position.y}!
            let path=surface.landingRoute(runway,model:model,destination:gate.position)
            print("TRACE runway",runway,"gate",gate.name,"nodes",path.count,"first",path.first!,"last",path.last!,"side",side(path.last!))
            print("EXIT PIN",surface.exit(runway),"side",side(surface.exit(runway)))
            let joins=surface.network.nodes.filter {p in let t=((p.x-a.x)*dx+(p.y-a.y)*dy)/(l*l);return t>=0.82 && t<=1.000001 && abs(side(p))<5}
            for join in joins {
                let targets=surface.network.nodes.filter{side($0)>22 && side($0)<50 && $0.distance(to:join)<90}
                var viable=0
                for target in targets {
                    let route=surface.network.shortestPath(from:join,to:target,maximumAccessDistance:2,minimumWidth:model.span*0.55)
                    if !route.isEmpty && FlightCurves.length(from:join,route:route)<200 {viable+=1}
                }
                print("JOIN",join,"north targets",targets.count,"connected",viable)
            }
        }
    }
}
