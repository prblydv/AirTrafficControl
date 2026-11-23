import Foundation

enum AircraftFamily: String, CaseIterable {
    case narrowbody = "Passenger jet"
    case widebody = "Long-haul passenger jet"
    case regional = "Regional jet"
    case turboprop = "Regional turboprop"
    case transport = "Transport aircraft"
    case fighter = "Military fast jet"
}

struct AircraftModel: Identifiable {
    let id: String
    let shortName: String
    let displayName: String
    let family: AircraftFamily
    let length: Double
    let span: Double
    let weight: Int
    // Deliberate game balance limits, not certified real-aircraft performance.
    var minimumRunwayMeters: Double {
        switch family {
        case .widebody: return 3200
        case .transport: return length >= 57 ? 3300 : 2900
        case .narrowbody: return 2850
        case .regional: return 1850
        case .turboprop: return 1400
        case .fighter: return 1800
        }
    }
    var takeoffRollFraction: Double {
        switch family { case .widebody: return 0.78;case .transport:return 0.76;case .narrowbody:return 0.64;case .regional:return 0.52;case .turboprop:return 0.42;case .fighter:return 0.48 }
    }
    var assetName: String { "Aircraft-" + id }
    var approachFactor: Double {
        switch family {
        case .narrowbody: return 1
        case .widebody: return 1.04
        case .regional: return 0.88
        case .turboprop: return 0.76
        case .transport: return 0.92
        case .fighter: return 1.12
        }
    }
    func speed(for phase: FlightPhase) -> Double {
        switch phase {
        case .climbing: return 46 * approachFactor
        case .takeoffRoll, .takeoff: return 32 * approachFactor
        case .approach: return 36 * approachFactor
        case .landingRoll, .landing: return 34 * (family == .turboprop ? 0.8 : family == .widebody ? 0.95 : 1)
        case .lineup, .runwayExit: return 8 * (family == .transport || family == .widebody ? 0.9 : 1)
        case .inbound, .holding: return 28 * approachFactor
        case .pushback: return 4.2
        default: return 11 * (family == .transport ? 0.9 : family == .widebody ? 0.95 : 1)
        }
    }
}

/// The supplied atlas is unlabelled. Names describe visible families/liveries;
/// exact manufacturers/variants are deliberately not inferred from generated art.
enum AircraftCatalog {
    static let models: [AircraftModel] = [
        .init(id: "01", shortName: "WB-RED", displayName: "Red-tail long-haul jet", family: .widebody, length: 65, span: 60, weight: 5),
        .init(id: "02", shortName: "WB-NAVY", displayName: "Navy-tail long-haul jet", family: .widebody, length: 67, span: 60, weight: 5),
        .init(id: "03", shortName: "WB-TRI", displayName: "Tricolour long-haul jet", family: .widebody, length: 63, span: 58, weight: 5),
        .init(id: "04", shortName: "WB-GOLD", displayName: "Gold-tail long-haul jet", family: .widebody, length: 62, span: 58, weight: 5),
        .init(id: "05", shortName: "WB-SILV", displayName: "Silver long-haul jet", family: .widebody, length: 64, span: 60, weight: 5),
        .init(id: "06", shortName: "NB-RED", displayName: "Red-tail passenger jet", family: .narrowbody, length: 49, span: 43, weight: 12),
        .init(id: "07", shortName: "NB-BLUE", displayName: "Blue-tail passenger jet", family: .narrowbody, length: 45, span: 40, weight: 12),
        .init(id: "08", shortName: "NB-WINE", displayName: "Burgundy passenger jet", family: .narrowbody, length: 44, span: 40, weight: 12),
        .init(id: "09", shortName: "NB-NAVY", displayName: "Navy passenger jet", family: .narrowbody, length: 45, span: 41, weight: 12),
        .init(id: "10", shortName: "NB-AMBR", displayName: "Amber-tail passenger jet", family: .narrowbody, length: 44, span: 40, weight: 12),
        .init(id: "11", shortName: "RJ-BLUE", displayName: "Blue regional jet", family: .regional, length: 36, span: 33, weight: 3),
        .init(id: "12", shortName: "RJ-CYAN", displayName: "Cyan-tail regional jet", family: .regional, length: 35, span: 32, weight: 3),
        .init(id: "13", shortName: "RJ-RED", displayName: "Red-tail regional jet", family: .regional, length: 35, span: 31, weight: 3),
        .init(id: "14", shortName: "TP-RED", displayName: "Red-tail twin turboprop", family: .turboprop, length: 34, span: 36, weight: 4),
        .init(id: "15", shortName: "RJ-SILV", displayName: "Silver regional jet", family: .regional, length: 35, span: 32, weight: 3),
        .init(id: "16", shortName: "HEAVY", displayName: "Heavy jet transport", family: .transport, length: 65, span: 66, weight: 1),
        .init(id: "17", shortName: "CARGO-TP", displayName: "Four-engine turboprop transport", family: .transport, length: 46, span: 55, weight: 1),
        .init(id: "18", shortName: "CARGO-J", displayName: "Four-engine jet transport", family: .transport, length: 57, span: 55, weight: 1),
        .init(id: "19", shortName: "FAST-1", displayName: "Canard fast jet", family: .fighter, length: 30, span: 24, weight: 1),
        .init(id: "20", shortName: "FAST-2", displayName: "Delta-wing fast jet", family: .fighter, length: 29, span: 23, weight: 1)
    ]
    // Wing-tip anchors measured from each actual transparent sprite (texture UV).
    static let wingLights:[String:(Point,Point)] = [
        "01":(Point(x:0.018116,y:0.683849),Point(x:0.981884,y:0.682131)),
        "02":(Point(x:0.016878,y:0.686047),Point(x:0.974684,y:0.689922)),
        "03":(Point(x:0.017857,y:0.661871),Point(x:0.982143,y:0.663669)),
        "04":(Point(x:0.020833,y:0.677903),Point(x:0.975000,y:0.681648)),
        "05":(Point(x:0.018868,y:0.657795),Point(x:0.981132,y:0.661597)),
        "06":(Point(x:0.016194,y:0.664122),Point(x:0.975709,y:0.660305)),
        "07":(Point(x:0.017778,y:0.654472),Point(x:0.977778,y:0.658537)),
        "08":(Point(x:0.018182,y:0.641975),Point(x:0.977273,y:0.644033)),
        "09":(Point(x:0.019512,y:0.611111),Point(x:0.975610,y:0.611111)),
        "10":(Point(x:0.021505,y:0.629108),Point(x:0.973118,y:0.629108)),
        "11":(Point(x:0.023364,y:0.616114),Point(x:0.976636,y:0.620853)),
        "12":(Point(x:0.027174,y:0.609375),Point(x:0.967391,y:0.609375)),
        "13":(Point(x:0.029412,y:0.631313),Point(x:0.970588,y:0.636364)),
        "14":(Point(x:0.018779,y:0.448276),Point(x:0.976526,y:0.442529)),
        "15":(Point(x:0.019139,y:0.707317),Point(x:0.971292,y:0.702439)),
        "16":(Point(x:0.014760,y:0.631356),Point(x:0.977860,y:0.631356)),
        "17":(Point(x:0.016461,y:0.452514),Point(x:0.975309,y:0.449721)),
        "18":(Point(x:0.015936,y:0.673554),Point(x:0.976096,y:0.669421)),
        "19":(Point(x:0.025000,y:0.710900),Point(x:0.962500,y:0.720379)),
        "20":(Point(x:0.025806,y:0.772277),Point(x:0.961290,y:0.772277)),
    ]
    private static let byID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
    static func model(_ id: String) -> AircraftModel {
        guard let model = byID[id] else { preconditionFailure("Unknown aircraft model: \(id)") }
        return model
    }
    static func fleet<R: RandomNumberGenerator>(count: Int, using random: inout R) -> [AircraftModel] {
        precondition(count <= models.count)
        var remaining = models
        var result: [AircraftModel] = []
        for _ in 0..<count {
            let total = remaining.reduce(0) { $0 + $1.weight }
            var ticket = Int.random(in: 0..<total, using: &random)
            let index = remaining.firstIndex { model in
                if ticket < model.weight { return true }
                ticket -= model.weight
                return false
            }!
            result.append(remaining.remove(at: index))
        }
        return result
    }
}

/// Seeded shifts support reproducible scenario checks while normal restarts
/// advance the random stream and produce another weighted fleet.
struct ShiftRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
