import Foundation

@main struct LandingExitSelectionChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let s=Simulation(seed:17,continuousTraffic:false),model=AircraftCatalog.model("07")
        let surface=s.surface
        let north=surface.gates.min{$0.position.y<$1.position.y}!.position
        let south=surface.gates.max{$0.position.y<$1.position.y}!.position
        var checked=0
        for runway in [0,3] {
            let old=surface.landingRoute(runway,model:model)
            for destination in [north,south] {
                let chosen=surface.landingRoute(runway,model:model,destination:destination)
                let onward=surface.taxiRoute(from:chosen.last!,to:destination,minimumWidth:model.span*0.55)
                let oldOnward=surface.taxiRoute(from:old.last!,to:destination,minimumWidth:model.span*0.55)
                guard !oldOnward.isEmpty else{continue}
                precondition(!onward.isEmpty,"Selected exit has no connected onward route")
                let selectedCrossings=surface.runwayCrossingCount(from:chosen.last!,route:onward)
                let oldCrossings=surface.runwayCrossingCount(from:old.last!,route:oldOnward)
                precondition(selectedCrossings<=oldCrossings,"Exit adds unnecessary runway crossings")
                print("EXIT",runway,"destination",destination,"crossings",oldCrossings,"->",selectedCrossings)
                checked+=1
            }
        }
        precondition(checked>0)
        s.followsAssignedGroundRoutes=true
        let p=Point(x:700,y:470),route=[Point(x:650,y:470)]
        s.aircraft=[Aircraft(id:"CROSS",modelID:"07",departure:false,stand:0,position:p,heading:0,phase:.taxiing,route:route)]
        s.aircraft[0].crossingRequest=0;s.selectedID="CROSS"
        s.approveCrossing()
        precondition(s.aircraft[0].route==route && s.aircraft[0].position==p)
        s.tick(0.01)
        precondition(s.aircraft[0].position==p && abs(s.aircraft[0].heading)<0.02,"Taxi reversed before turning")
        print("PASS:destination-aware exits do not add crossings; crossing approval preserves route; sharp reversal turns before translating")
    }
}
