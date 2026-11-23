import Foundation
@main struct ContinuousTrafficAudit {
 @MainActor static func main() throws {
 setbuf(stdout,nil)
 let s=Simulation(seed:17,continuousTraffic:true);s.running=true
 for frame in 0..<3000 {
  if frame%1000==0 {print("CLOCK",Int(s.elapsed),"COUNT",s.aircraft.count)}
  s.tick(0.1)
  if frame%10==0 {
   let ground=s.aircraft.filter{!$0.airborne && ![.complete,.crashed,.diverted].contains($0.phase)}
   for (i,a) in ground.enumerated() {for b in ground.dropFirst(i+1) where s.groundConflict(a,from:a.position,to:a.position,other:b,margin:0) {preconditionFailure("Automatic arrivals overlapped on the ground: \(a.id), \(b.id)")}}
  }
 }
 precondition(s.violations==0)
 let active=s.aircraft.filter{![.complete,.crashed,.diverted].contains($0.phase)}
 precondition(Set(active.map(\.stand)).count==active.count,"An occupied stand was assigned twice")
 precondition(s.aircraft.contains{$0.phase == .taxiing || $0.arrivalHandled},"No arrival cleared the runway")
 print("PASS:continuous automatic arrivals have no ground overlaps/losses or duplicate stands; arrivals clear the runway")
 }
}
