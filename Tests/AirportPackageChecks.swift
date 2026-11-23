import Foundation
import ImageIO
import CoreGraphics

@main struct AirportPackageChecks {
    static func writeImage(_ url:URL,width:Int,height:Int) {
        let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red:0.07,green:0.12,blue:0.14,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:height))
        let destination=CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,context.makeImage()!,nil);precondition(CGImageDestinationFinalize(destination))
    }
    static func write(_ definition:AirportDefinition,_ routes:AirportRouteDocument,at folder:URL)throws {
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let encoder=JSONEncoder()
        try encoder.encode(definition).write(to:folder.appendingPathComponent("airport.json"))
        try encoder.encode(routes).write(to:folder.appendingPathComponent("routes.json"))
        writeImage(folder.appendingPathComponent("background.png"),width:Int(definition.image.width),height:Int(definition.image.height))
    }
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let delhi=AirportPackage.delhi
        precondition(delhi.definition.stands.count==19 && delhi.definition.runways.count==4 && delhi.definition.serviceBases.count==2)
        let packagedRoutes=try Data(contentsOf:delhi.directory.appendingPathComponent("routes.json")),sourceRoutes=try Data(contentsOf:root.appendingPathComponent("AirTrafficControl/airport-routes.json"))
        let packagedImage=try Data(contentsOf:delhi.backgroundURL),sourceImage=try Data(contentsOf:root.appendingPathComponent("AirTrafficControl/Assets.xcassets/DelhiBoard.imageset/delhi-board-expanded.png"))
        precondition(packagedRoutes==sourceRoutes && packagedImage==sourceImage)
        let package=try AirportPackage.load(at:root.appendingPathComponent("Tests/Fixtures/Airports/testfield"))
        let first=Simulation(seed:17,continuousTraffic:false,airportPackage:delhi)
        let other=Simulation(seed:17,continuousTraffic:false,airportPackage:package)
        precondition(first.aircraft.count==12 && other.aircraft.count==2 && other.runways.count==1)
        precondition(other.vehicles.count==17 && other.vehicles.filter{$0.kind != .pushback}.allSatisfy{$0.base==7})
        let cargo=other.aircraft.first{$0.id=="CARGO1"}!
        precondition(cargo.model.family == .transport && cargo.operatingPurpose == .commercialCargo && !other.surface.gates[cargo.stand].military)
        precondition(other.surface.gates[cargo.stand].accepts(cargo.model,purpose:.commercialCargo) && !other.surface.gates[cargo.stand].accepts(cargo.model,purpose:.militaryCargo))
        precondition(!other.requiredServices(for:cargo).contains(.bus) && other.requiredServices(for:cargo).contains(.belt))
        precondition(cargo.origin=="TST · Testfield" && cargo.destination=="AAA · Coast")
        precondition(!package.acceptsOverride(delhi.routes) && first.surface.gates.count==19 && first.runways.count==4)
        precondition(first.surface.revision != other.surface.revision)
        print("PASS:Delhi package preserves source bytes; a second airport has independent geometry, fleet, identities, service inventory and commercial cargo purpose")

        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:temporary)}
        var definition=package.definition,graph=package.routes
        let q:(Point)->Point={Point(x:600-$0.y,y:$0.x)}
        definition.identity.id="rotated-testfield";definition.identity.title="Renamed test field"
        definition.image.width=600;definition.image.height=900
        for i in definition.stands.indices {
            definition.stands[i].name="Renamed G-\(i)";definition.stands[i].position=q(definition.stands[i].position);definition.stands[i].nose=q(definition.stands[i].nose)
            definition.stands[i].port=q(definition.stands[i].port);definition.stands[i].tugBay=q(definition.stands[i].tugBay);definition.stands[i].access=definition.stands[i].access.map(q)
        }
        for i in definition.runways.indices {
            definition.runways[i].start=q(definition.runways[i].start);definition.runways[i].end=q(definition.runways[i].end)
            definition.runways[i].hold=q(definition.runways[i].hold);definition.runways[i].exit=q(definition.runways[i].exit)
            if definition.runways[i].operatingEnds != nil {
                for j in definition.runways[i].operatingEnds!.indices {
                    definition.runways[i].operatingEnds![j].threshold=q(definition.runways[i].operatingEnds![j].threshold)
                    definition.runways[i].operatingEnds![j].oppositeThreshold=q(definition.runways[i].operatingEnds![j].oppositeThreshold)
                    definition.runways[i].operatingEnds![j].hold=q(definition.runways[i].operatingEnds![j].hold)
                    definition.runways[i].operatingEnds![j].exit=q(definition.runways[i].operatingEnds![j].exit)
                }
            }
        }
        for i in definition.serviceBases.indices {
            definition.serviceBases[i].entry=q(definition.serviceBases[i].entry);definition.serviceBases[i].connection=q(definition.serviceBases[i].connection)
            definition.serviceBases[i].accessLanes=definition.serviceBases[i].accessLanes.map{$0.map(q)}
            for j in definition.serviceBases[i].bays.indices {definition.serviceBases[i].bays[j].position=q(definition.serviceBases[i].bays[j].position);definition.serviceBases[i].bays[j].heading += .pi/2}
        }
        for i in definition.approaches.indices {definition.approaches[i].start=q(definition.approaches[i].start);definition.approaches[i].fix=q(definition.approaches[i].fix)}
        definition.traffic.spawnPoints=definition.traffic.spawnPoints.map(q)
        graph.airportID=definition.identity.id;graph.image=definition.identity.id;graph.width=600;graph.height=900
        for i in graph.nodes.indices {graph.nodes[i].point=q(graph.nodes[i].point)}
        for i in graph.pins.indices {graph.pins[i].point=q(graph.pins[i].point)}
        graph.boundary=graph.boundary.map(q)
        let rotatedFolder=temporary.appendingPathComponent("rotated")
        try write(definition,graph,at:rotatedFolder)
        let rotatedPackage=try AirportPackage.load(at:rotatedFolder)
        let rotated=Simulation(seed:17,continuousTraffic:false,airportPackage:rotatedPackage)
        precondition(rotated.surface.gates[0].position==q(other.surface.gates[0].position) && rotated.runways[0].start==q(other.runways[0].start))
        precondition(rotated.clearanceRunways(for:rotated.aircraft[0]).map(\.id)==other.clearanceRunways(for:other.aircraft[0]).map(\.id))
        let entry=other.surface.departureEntry(for:cargo.model,runway:0,from:other.surface.gates[0].port)
        let turnedEntry=rotated.surface.departureEntry(for:cargo.model,runway:0,from:rotated.surface.gates[0].port)
        let path=other.surface.taxiRoute(from:other.surface.gates[0].port,to:entry.hold)
        let turnedPath=rotated.surface.taxiRoute(from:rotated.surface.gates[0].port,to:turnedEntry.hold)
        precondition(!path.isEmpty && !turnedPath.isEmpty)
        precondition(abs(FlightCurves.length(from:other.surface.gates[0].port,route:path)-FlightCurves.length(from:rotated.surface.gates[0].port,route:turnedPath))<0.001)
        precondition(first.surface.gates.count==19 && first.airport.identity.id=="delhi" && other.airport.identity.id=="testfield")
        print("PASS:rotation, renaming and changed image dimensions preserve routing/permissions without cross-airport cache leakage")

        var bad=package.definition;bad.schemaVersion=99;precondition(!bad.problems(routes:package.routes).isEmpty)
        bad=package.definition;bad.stands[1].id=bad.stands[0].id;precondition(!bad.problems(routes:package.routes).isEmpty)
        bad=package.definition;bad.stands[0].departureRunways=[99];precondition(!bad.problems(routes:package.routes).isEmpty)
        bad=package.definition;bad.traffic.initial[0].modelIDs=["missing"];precondition(!bad.problems(routes:package.routes).isEmpty)
        bad=package.definition;bad.serviceBases=[];precondition(!bad.problems(routes:package.routes).isEmpty)
        bad=definition;bad.routesFile="../routes.json"
        try JSONEncoder().encode(bad).write(to:rotatedFolder.appendingPathComponent("airport.json"))
        do {_ = try AirportPackage.load(at:rotatedFolder);preconditionFailure("Resource escape accepted")} catch {}
        bad=definition;bad.image.file="missing.png"
        try JSONEncoder().encode(bad).write(to:rotatedFolder.appendingPathComponent("airport.json"))
        do {_ = try AirportPackage.load(at:rotatedFolder);preconditionFailure("Missing image accepted")} catch {}
        try write(definition,graph,at:rotatedFolder)
        writeImage(rotatedFolder.appendingPathComponent("background.png"),width:10,height:10)
        do {_ = try AirportPackage.load(at:rotatedFolder);preconditionFailure("Wrong image dimensions accepted")} catch {}
        print("PASS:invalid schema, references, duplicate identities, unavailable services, resource paths and image calibration are rejected")

        // Operate the new package through the shared engine while the Delhi
        // simulation remains alive, exercising context isolation beyond loading.
        let s=Simulation(seed:17,continuousTraffic:false,airportPackage:package)
        s.aircraft[1].stopped=true;s.selectedID="CARGO1";s.clearSelected(to:0)
        func advance(until done:()->Bool) {
            for _ in 0..<18000 {
                if done(){return}
                if let f=s.aircraft.first(where:{$0.id==s.selectedID}) {
                    if f.crossingRequest != nil {s.approveCrossing()}
                    if f.phase == .queued {s.clearSelected(to:f.runway!)}
                }
                s.tick(0.1)
            }
            for f in s.aircraft {print("PENDING",f.id,f.phase,f.position,"route",f.route.count,"wait",f.waitingForTraffic,"plan",s.groundTrafficPlans[f.id] != nil,f.blockedBy as Any)}
            precondition(done(),"Second-airport lifecycle stalled")
        }
        advance {s.aircraft[0].phase == .complete}
        precondition(s.violations==0 && s.aircraft[0].operatingPurpose == .commercialCargo)
        s.aircraft[1].stopped=false;s.selectedID="PAX2";s.clearSelected(to:0)
        advance {s.aircraft[1].readyToDepart && s.busyVehicleCount==0}
        precondition(s.aircraft[1].origin=="TST · Testfield" && s.aircraft[1].destination=="AAA · Coast")
        precondition(s.vehicles.allSatisfy{$0.position.distance(to:$0.depot)<0.1})
        s.clearSelected(to:0)
        advance {s.finished}
        precondition(s.resolved==3 && s.score==300 && s.violations==0 && s.vehicles.allSatisfy{$0.position.distance(to:$0.depot)<0.1})
        first.tick(0.1);precondition(first.runways.count==4 && first.surface.gates.count==19)
        print("PASS:second data-only airport completes cargo departure and passenger arrival/services/departure with all crews home",Int(s.elapsed))
    }
}
