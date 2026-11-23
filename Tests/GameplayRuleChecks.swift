import Foundation

@main struct GameplayRuleChecks {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        precondition(AircraftCatalog.model("07").speed(for:.inbound)>AircraftCatalog.model("07").speed(for:.landingRoll))
        let altitude=Simulation(seed:17,continuousTraffic:false)
        altitude.aircraft=[
            Aircraft(id:"A",modelID:"07",departure:false,stand:0,position:Point(x:100,y:100),phase:.holding,route:[Point(x:200,y:100)],altitude:3000),
            Aircraft(id:"B",modelID:"07",departure:false,stand:1,position:Point(x:300,y:100),phase:.inbound,route:[Point(x:400,y:100)],altitude:5700)
        ]
        altitude.running=true;altitude.tick(0.1)
        precondition(altitude.aircraft.allSatisfy{$0.altitude==Simulation.sharedAirborneAltitude})
        print("PASS:fast inbound traffic shares one non-landing altitude")

        let collision=Simulation(seed:17,continuousTraffic:false)
        collision.aircraft=[
            Aircraft(id:"AIR1",modelID:"07",departure:false,stand:0,position:Point(x:200,y:200),phase:.holding,route:[Point(x:300,y:200)],altitude:4500),
            Aircraft(id:"AIR2",modelID:"07",departure:false,stand:1,position:Point(x:225,y:200),heading:.pi,phase:.holding,route:[Point(x:100,y:200)],altitude:4500)
        ]
        collision.running=true;collision.tick(0.1)
        precondition(collision.aircraft.allSatisfy{$0.phase == .crashed} && collision.score == -1000)
        print("PASS:aircraft entering airborne vicinity collide and reduce score")

        let vehicles=Simulation(seed:17,continuousTraffic:false)
        let unit=GroundVehicle(kind:.fuel,depot:Point(x:0,y:0),position:Point(x:0,y:0))
        vehicles.aircraft=[Aircraft(id:"GROUND",modelID:"07",departure:true,stand:0,position:Point(x:50,y:0),phase:.parked)]
        precondition(!vehicles.vehicleBlocked(unit,from:Point(x:0,y:0),to:Point(x:100,y:0)))
        print("PASS:ground vehicles never wait for aircraft footprints")
    }
}
