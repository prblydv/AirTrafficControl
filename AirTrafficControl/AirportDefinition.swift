import Foundation
import ImageIO

/// Airframe family describes a model; purpose describes the flight and stand.
/// The same transport airframe can fly commercial cargo or military cargo.
enum AirportPurpose:String,Codable,CaseIterable {
    case passenger, commercialCargo, militaryFighter, militaryCargo
    var military:Bool {self == .militaryFighter || self == .militaryCargo}
    var cargo:Bool {self == .commercialCargo || self == .militaryCargo}
}
extension AircraftModel {
    var defaultPurpose:AirportPurpose {family == .fighter ? .militaryFighter : family == .transport ? .militaryCargo : .passenger}
}
struct AirportIdentity:Codable {
    var id:String;var code:String;var city:String;var name:String;var title:String;var subtitle:String
    var flightLabel:String {code+" · "+city}
}
struct AirportImage:Codable {
    struct Calibration:Codable {var source:String;var referenceWidth:Double;var referenceHeight:Double;var referenceToImage:[Double]}
    var file:String;var assetName:String?;var width:Double;var height:Double;var coordinateSystem:String
    var calibration:Calibration?
}
struct AirportRunwayEndDefinition:Codable {
    var id:String;var name:String;var threshold:Point;var oppositeThreshold:Point
    var hold:Point;var exit:Point;var usableLengthMeters:Double
    var landingExits:[[Point]]? = nil
}
struct AirportRunwayDefinition:Codable {
    var id:Int;var name:String;var reciprocalName:String;var start:Point;var end:Point
    var lengthMeters:Double;var width:Double;var hold:Point;var exit:Point
    var orbitDirection:Double;var rangeReferenceNM:Double
    var operatingEnds:[AirportRunwayEndDefinition]? = nil
    var preferredEndID:String? = nil
    var activeEnd:AirportRunwayEndDefinition {
        if let ends=operatingEnds,let selected=ends.first(where:{$0.id==preferredEndID}) ?? ends.first {return selected}
        return .init(id:"runway-\(id)-primary",name:name,threshold:start,oppositeThreshold:end,hold:hold,exit:exit,usableLengthMeters:lengthMeters)
    }
}
struct AirportStand:Codable {
    var id:String;var name:String;var position:Point;var nose:Point;var port:Point
    var maxLength:Double;var maxSpan:Double;var purpose:AirportPurpose;var access:[Point]
    var tugBay:Point;var departureRunways:[Int];var tugRequired:Bool
    var preferredModelIDs:[String]?=nil
    func preference(for model:AircraftModel)->Int {
        guard let preferredModelIDs else{return 1}
        return preferredModelIDs.contains(model.id) ? 0:2
    }
    var military:Bool {purpose.military}
    var cargo:Bool {purpose.cargo}
    var heading:Double {atan2(nose.y-position.y,nose.x-position.x)}
    func accepts(_ model:AircraftModel,purpose requested:AirportPurpose?=nil)->Bool {
        purpose == (requested ?? model.defaultPurpose) && model.length*0.55<=maxLength+0.01 && model.span*0.55<=maxSpan+0.01
    }
}
struct AirportServiceBase:Codable {
    struct Bay:Codable {var id:Int;var role:Int;var position:Point;var heading:Double}
    var id:Int;var name:String;var entry:Point;var connection:Point;var accessLanes:[[Point]];var bays:[Bay]
}
struct AirportApproach:Codable {var id:String;var start:Point;var fix:Point;var altitude:Double}
struct AirportInitialFlight:Codable {
    var id:String;var modelIDs:[String];var purpose:AirportPurpose;var arrival:Bool;var standIDs:[String];var approachID:String?
}
struct AirportTraffic:Codable {
    struct Choice:Codable {var modelID:String;var purpose:AirportPurpose}
    var initial:[AirportInitialFlight];var continuousModels:[Choice];var peers:[String];var continuousPeers:[String];var spawnPoints:[Point]
    var callsignPrefix:String;var sequenceStart:Int;var firstArrivalSeconds:Double;var baseIntervalSeconds:Double
    var minimumIntervalSeconds:Double;var intervalDecaySeconds:Double;var airborneLimit:Int;var retireAfterSeconds:Double
}
struct AirportRules:Codable {var turnRadius:Double;var finalApproachDistance:Double;var taxiwayWidth:Double;var runwayMargin:Double}
struct AirportDefinition:Codable {
    var schemaVersion:Int;var version:Int;var identity:AirportIdentity;var image:AirportImage;var routesFile:String
    var stands:[AirportStand];var runways:[AirportRunwayDefinition];var serviceBases:[AirportServiceBase]
    var approaches:[AirportApproach];var traffic:AirportTraffic;var rules:AirportRules
    var serviceProfiles:[String:[Int]]
    func problems(routes:AirportRouteDocument)->[String] {
        var errors:[String]=[]
        func require(_ condition:Bool,_ message:String) {if !condition {errors.append(message)}}
        func point(_ p:Point)->Bool {p.x.isFinite && p.y.isFinite && p.x>=0 && p.y>=0 && p.x<=image.width && p.y<=image.height}
        func positive(_ x:Double)->Bool {x.isFinite && x>0}
        require(schemaVersion==1 && version>0,"Unsupported airport schema or definition version.")
        require(!identity.id.isEmpty && identity.id.allSatisfy({$0.isLetter || $0.isNumber || $0=="-" || $0=="_"}) && !identity.code.isEmpty && !identity.title.isEmpty,"Airport identity is incomplete.")
        require(positive(image.width) && positive(image.height) && image.coordinateSystem=="imagePixelsTopLeft","Invalid image size or coordinate system.")
        if let c=image.calibration {require(positive(c.referenceWidth) && positive(c.referenceHeight) && c.referenceToImage.count==6 && c.referenceToImage.allSatisfy(\.isFinite),"Invalid image calibration.")}
        require(routes.image==(image.assetName ?? identity.id) && routes.width==image.width && routes.height==image.height,"Route graph belongs to a different airport image/calibration.")
        require(routes.airportID==identity.id || (routes.airportID==nil && identity.id=="delhi"),"Route graph belongs to a different airport identity.")
        require(routes.boundary.count>=3 && routes.boundary.allSatisfy(point) && routes.pins.allSatisfy{point($0.point)},"Invalid airport boundary or landmark pins.")
        errors += routes.problems()
        require(!runways.isEmpty && runways.map(\.id)==Array(runways.indices),"Runway IDs must be unique contiguous array indices.")
        for r in runways {
            require(!r.name.isEmpty && !r.reciprocalName.isEmpty && point(r.start) && point(r.end) && r.start.distance(to:r.end)>1 && point(r.hold) && point(r.exit) && positive(r.lengthMeters) && positive(r.width) && positive(r.rangeReferenceNM) && [-1,1].contains(r.orbitDirection),"Invalid runway \(r.id).")
            let ends=r.operatingEnds ?? []
            require(!ends.isEmpty && Set(ends.map(\.id)).count==ends.count && r.preferredEndID != nil && ends.contains{$0.id==r.preferredEndID} && ends.allSatisfy{!$0.id.isEmpty && !$0.name.isEmpty && point($0.threshold) && point($0.oppositeThreshold) && $0.threshold.distance(to:$0.oppositeThreshold)>1 && point($0.hold) && point($0.exit) && positive($0.usableLengthMeters)},"Invalid operating ends for runway \(r.id).")
            for end in ends {
                for path in end.landingExits ?? [] {
                    require(path.count>=2 && path.allSatisfy(point),"Invalid authored landing exit for \(end.id).")
                    if let first=path.first,let last=path.last {
                        let a=end.threshold,b=end.oppositeThreshold,dx=b.x-a.x,dy=b.y-a.y,l=a.distance(to:b)
                        let t=((first.x-a.x)*dx+(first.y-a.y)*dy)/(l*l)
                        require(t>=0 && t<=1 && abs((first.x-a.x)*dy-(first.y-a.y)*dx)/l<5,"Landing exit must start on its runway: \(end.id).")
                        require(routes.nodes.contains{$0.layer == .aircraft && $0.point.distance(to:last)<0.1},"Landing exit must join a traced taxiway: \(end.id).")
                    }
                }
            }
        }
        require(!stands.isEmpty && Set(stands.map(\.id)).count==stands.count,"Missing stands or duplicate stand IDs.")
        for s in stands {
            if let preferred=s.preferredModelIDs {require(preferred.allSatisfy{id in AircraftCatalog.models.contains{$0.id == id}},"Invalid preferred aircraft at \(s.id).")}
            require(!s.id.isEmpty && !s.name.isEmpty && point(s.position) && point(s.nose) && s.position.distance(to:s.nose)>0.01 && point(s.port) && point(s.tugBay) && positive(s.maxLength) && positive(s.maxSpan) && !s.departureRunways.isEmpty && s.departureRunways.allSatisfy{runways.indices.contains($0)},"Invalid stand \(s.id).")
            require(s.access.count>=2 && s.access.allSatisfy(point) && (s.access.first?.distance(to:s.position) ?? 99)<0.1 && (s.access.last?.distance(to:s.port) ?? 99)<0.1,"Stand access must connect position to port: \(s.id).")
        }
        require(Set(serviceBases.map(\.id)).count==serviceBases.count && !serviceBases.isEmpty,"Missing service bases or duplicate base IDs.")
        let bays=serviceBases.flatMap(\.bays)
        require(Set(bays.map(\.id)).count==bays.count && bays.allSatisfy{$0.id>=0 && $0.id<10000 && $0.role != ServiceKind.pushback.rawValue && ServiceKind(rawValue:$0.role) != nil && point($0.position) && $0.heading.isFinite},"Invalid or duplicate vehicle bays/roles.")
        for b in serviceBases {require(point(b.entry) && point(b.connection) && !b.accessLanes.isEmpty && b.accessLanes.allSatisfy{$0.count>=2 && $0.allSatisfy(point)},"Invalid service access at \(b.name).")}
        for purpose in AirportPurpose.allCases {require(serviceProfiles[purpose.rawValue]?.isEmpty==false && serviceProfiles[purpose.rawValue]!.allSatisfy{ServiceKind(rawValue:$0) != nil && $0 != 8},"Missing/invalid service profile: \(purpose.rawValue).")}
        let indexed=Dictionary(routes.nodes.map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
        for base in serviceBases {
            let lanePoints=base.accessLanes.flatMap{$0}
            require(base.bays.allSatisfy{bay in lanePoints.contains{$0.distance(to:bay.position)<0.1}},"A service bay has no authored access lane at \(base.name).")
            for role in Set(base.bays.map(\.role)) {
                let connected=routes.edges.contains{edge in
                    guard edge.access.contains(role),let a=indexed[edge.a],let b=indexed[edge.b],a.layer == .services,b.layer == .services else{return false}
                    let dx=b.point.x-a.point.x,dy=b.point.y-a.point.y
                    let t=min(1,max(0,((base.connection.x-a.point.x)*dx+(base.connection.y-a.point.y)*dy)/max(0.0001,dx*dx+dy*dy)))
                    return base.connection.distance(to:Point(x:a.point.x+t*dx,y:a.point.y+t*dy))<=2.1
                }
                require(connected,"Service base connection has no road for role \(role): \(base.name).")
            }
        }
        for profile in serviceProfiles.values {
            let kinds=Set(profile)
            require(!kinds.contains(12) || Set([6,7]).isSubset(of:kinds),"A stairs service profile requires passenger bus and catering completion.")
            require(kinds.isDisjoint(with:[9,10,11]) || Set([9,10,11]).isSubset(of:kinds),"Baggage profiles require tractor, cart and belt together.")
        }
        let roles=Set(bays.map(\.role)),required=Set(stands.flatMap{serviceProfiles[$0.purpose.rawValue] ?? []}+[1,2,3,4,16])
        require(required.isSubset(of:roles),"Service inventory cannot perform the configured turnarounds and emergency response.")
        require(Set(approaches.map(\.id)).count==approaches.count && approaches.allSatisfy{point($0.start) && point($0.fix) && positive($0.altitude)},"Invalid/duplicate approaches.")
        require(Set(traffic.initial.map(\.id)).count==traffic.initial.count,"Duplicate initial callsigns.")
        let models=Set(AircraftCatalog.models.map(\.id))
        for flight in traffic.initial {
            require(!flight.id.isEmpty && !flight.modelIDs.isEmpty && flight.modelIDs.allSatisfy{models.contains($0)} && !flight.standIDs.isEmpty && flight.standIDs.allSatisfy{id in stands.contains{$0.id==id && $0.purpose==flight.purpose}},"Invalid initial flight \(flight.id).")
            if flight.modelIDs.allSatisfy({models.contains($0)}) {
                require(flight.modelIDs.contains{id in let model=AircraftCatalog.model(id);return stands.contains{stand in flight.standIDs.contains(stand.id) && stand.accepts(model,purpose:flight.purpose) && runways.contains{$0.activeEnd.usableLengthMeters>=model.minimumRunwayMeters && (flight.arrival || stand.departureRunways.contains($0.id))}}},"Initial flight has no compatible stand/runway: \(flight.id).")
            }
            require(!flight.arrival || approaches.contains{$0.id==flight.approachID},"Missing initial approach for \(flight.id).")
        }
        require(!traffic.continuousModels.isEmpty && traffic.continuousModels.allSatisfy{choice in models.contains(choice.modelID) && stands.contains{$0.accepts(AircraftCatalog.model(choice.modelID),purpose:choice.purpose)}},"Invalid continuous model/mission pool.")
        require(!traffic.peers.isEmpty && !traffic.continuousPeers.isEmpty && !traffic.callsignPrefix.isEmpty && !traffic.spawnPoints.isEmpty && traffic.spawnPoints.allSatisfy(point),"Traffic labels or spawn points are incomplete.")
        require(positive(traffic.firstArrivalSeconds) && positive(traffic.baseIntervalSeconds) && positive(traffic.minimumIntervalSeconds) && traffic.minimumIntervalSeconds<=traffic.baseIntervalSeconds && positive(traffic.intervalDecaySeconds) && traffic.airborneLimit>0 && positive(traffic.retireAfterSeconds),"Invalid traffic timing/capacity.")
        require(positive(rules.turnRadius) && positive(rules.finalApproachDistance) && positive(rules.taxiwayWidth) && rules.runwayMargin.isFinite && rules.runwayMargin>=0,"Invalid operating rules.")
        return errors
    }
}
struct AirportPackage {
    let definition:AirportDefinition
    let routes:AirportRouteDocument
    let backgroundURL:URL
    let directory:URL
    static func load(at directory:URL)throws->AirportPackage {
        let decoder=JSONDecoder(),definition=try decoder.decode(AirportDefinition.self,from:Data(contentsOf:directory.appendingPathComponent("airport.json")))
        func resource(_ name:String)throws->URL {
            let base=directory.standardizedFileURL.resolvingSymlinksInPath(),url=directory.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
            guard !name.isEmpty,url.path.hasPrefix(base.path+"/") else{throw AirportPackageError.invalid(["Airport resource must stay inside its package: \(name)"])}
            return url
        }
        let routes=try decoder.decode(AirportRouteDocument.self,from:Data(contentsOf:resource(definition.routesFile)))
        let background=try resource(definition.image.file)
        var errors=definition.problems(routes:routes)
        if let source=CGImageSourceCreateWithURL(background as CFURL,nil),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let w=properties[kCGImagePropertyPixelWidth] as? NSNumber,let h=properties[kCGImagePropertyPixelHeight] as? NSNumber {
            if w.doubleValue != definition.image.width || h.doubleValue != definition.image.height {errors.append("Background dimensions do not match the airport calibration.")}
        } else {errors.append("Airport background cannot be decoded.")}
        guard errors.isEmpty else{throw AirportPackageError.invalid(errors)}
        return .init(definition:definition,routes:routes,backgroundURL:background,directory:directory)
    }
    func acceptsOverride(_ document:AirportRouteDocument)->Bool {
        (document.airportID==definition.identity.id || (document.airportID==nil && definition.identity.id=="delhi")) &&
        document.image==routes.image && document.width==definition.image.width && document.height==definition.image.height && document.problems().isEmpty
    }
    private struct Catalog:Decodable {let schemaVersion:Int;let defaultAirportID:String;let airports:[String]}
    static var bundledRoot:URL {
        var candidates:[URL]=[]
        if let root=Bundle.main.resourceURL {candidates.append(root.appendingPathComponent("Airports"))}
#if DEBUG
        candidates.append(URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Airports"))
#endif
        return candidates.first{FileManager.default.fileExists(atPath:$0.appendingPathComponent("catalog.json").path)} ?? candidates[0]
    }
    static func bundled(_ id:String)throws->AirportPackage {
        let catalog=try JSONDecoder().decode(Catalog.self,from:Data(contentsOf:bundledRoot.appendingPathComponent("catalog.json")))
        guard catalog.schemaVersion==1,catalog.airports.contains(id),!id.isEmpty,id.allSatisfy({$0.isLetter || $0.isNumber || $0=="-" || $0=="_"}) else{throw AirportPackageError.invalid(["Unknown airport identifier: \(id)"])}
        let package=try load(at:bundledRoot.appendingPathComponent(id))
        guard package.definition.identity.id==id else{throw AirportPackageError.invalid(["Catalog and airport identities do not match."])}
        return package
    }
    static let defaultAirport:AirportPackage = {
        do {
            let catalog=try JSONDecoder().decode(Catalog.self,from:Data(contentsOf:bundledRoot.appendingPathComponent("catalog.json")))
            return try bundled(catalog.defaultAirportID)
        } catch {fatalError("Invalid bundled airport catalog: \(error)")}
    }()
    static let delhi:AirportPackage = {
        do {return try bundled("delhi")} catch {fatalError("Invalid Delhi airport package: \(error)")}
    }()

}
enum AirportPackageError:Error,CustomStringConvertible {
    case invalid([String])
    var description:String {switch self {case .invalid(let errors):return errors.joined(separator:"\n")}}
}
