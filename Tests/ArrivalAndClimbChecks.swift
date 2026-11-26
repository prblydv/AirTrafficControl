import Foundation

@main struct ArrivalAndClimbChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let arrivals=Simulation(seed:17,continuousTraffic:false)
        let incoming=arrivals.aircraft.filter{!$0.departure}
        precondition(!incoming.isEmpty)
        precondition(incoming.allSatisfy{$0.runway != nil && $0.phase == .approach && !$0.route.isEmpty},"Initial arrivals must attempt their assigned runway")
        let index=arrivals.aircraft.firstIndex{!$0.departure}!
        arrivals.selectedID=arrivals.aircraft[index].id
        arrivals.holdSelected()
        precondition(arrivals.aircraft[index].phase == .holding)
        let target=arrivals.clearanceRunways(for:arrivals.aircraft[index]).last!.id
        arrivals.clearSelected(to:target)
        precondition(arrivals.aircraft[index].phase == .approach && arrivals.aircraft[index].runway==target)
        print("PASS:initial arrivals have automatic approaches; player can hold and reassign runway")
        arrivals.aircraft=[arrivals.aircraft[index]]
        arrivals.selectedID=arrivals.aircraft[0].id
        arrivals.aircraft[0].altitude=500
        let alternate=arrivals.clearanceRunways(for:arrivals.aircraft[0]).first{$0.id != target}!.id
        arrivals.clearSelected(to:alternate)
        precondition(arrivals.aircraft[0].phase == .holding && arrivals.aircraft[0].approachesAfterClimb)
        arrivals.tick(0.1)
        precondition(arrivals.aircraft[0].altitude>500 && arrivals.aircraft[0].altitude<540,"Go-around altitude jumped")
        for _ in 0..<150 {arrivals.tick(0.1)}
        precondition(arrivals.aircraft[0].phase == .approach && arrivals.aircraft[0].runway==alternate)
        print("PASS:runway reassignment climbs gradually before joining the new approach")
        let climb=Simulation(seed:17,continuousTraffic:false)
        climb.aircraft=[Aircraft(id:"CLIMB",modelID:"07",departure:true,stand:0,position:Point(x:100,y:100),phase:.climbing,route:[Point(x:10000,y:100)],altitude:1200)]
        climb.running=true
        var previous=climb.aircraft[0].apparentScale
        for _ in 0..<100 {
            climb.tick(0.1)
            let next=climb.aircraft[0].apparentScale
            precondition(next>=previous && next-previous<0.005,"Climb scale changed abruptly")
            previous=next
        }
        print("PASS:departure scale grows gradually over successive climb frames")
    }
}
