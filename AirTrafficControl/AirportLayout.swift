import Foundation

/// One fixed aerial photograph, with positions measured in that image's map
/// projection. Artwork is edited, but pavement centerlines retain their anchors.
enum AirportLayout {
    static let width = 1672.0
    static let height = 941.0
    static let runwayWidth = 17.0
    static let taxiwayWidth = 10.0
    static let imageScale = 1.6995154023847876
    static let imageOrigin = Point(x: -245.94594594578024, y: -253.988320145522)
    private static func originalPixel(_ p: Point) -> Point {
        Point(x: imageOrigin.x + p.x * imageScale, y: imageOrigin.y + p.y * imageScale)
    }
    // Centreline landmarks measured on the final 1484×1060 edited image,
    // normalized to this fixed 1400×1000 board. The same warp is used for paths
    // and aircraft; no scrolling map or independent background transform exists.
    static let imageRunways: [(Point, Point)] = [
        (Point(x: 480, y: 253), Point(x: 1215, y: 417)),
        (Point(x: 183, y: 705), Point(x: 960, y: 858)),
        (Point(x: 579, y: 175), Point(x: 1180, y: 188)),
        (Point(x: 200, y: 613), Point(x: 979, y: 766))
    ]
    // Pixel registration of the previous 1484×1060 image into the user's
    // unchanged 1672×941 expanded image. Seven matched landmarks, <=1.25 px
    // residual. Preserve the source aspect ratio and apply this once to every
    // aircraft, route, marking and hit target.
    static func expandedPixel(_ original: Point) -> Point {
        Point(x: original.x * 0.6958519303224427 + original.y * 0.002735071907355962 + 315.84546015694815,
              y: original.x * 0.0011345345785606792 + original.y * 0.6944189643512513 + 102.43652351574202)
    }
    static func display(_ p: Point) -> Point {
        let compact = compactDisplay(p)
        return expandedPixel(Point(x: compact.x * 1.06, y: compact.y * 1.06))
    }
    private static func compactDisplay(_ p: Point) -> Point {
        let q = originalPixel(p)
        var dx = 0.0, dy = 0.0, total = 0.0
        var nearest: (Double, Point)?
        for (index, definition) in runwayDefinitions.enumerated() {
            let a = originalPixel(definition.2), b = originalPixel(definition.3)
            let (targetA, targetB) = imageRunways[index]
            for (source, target) in [(a, targetA), (b, targetB)] {
                let weight = 1 / (pow(q.distance(to: source), 2) + 900)
                dx += (target.x - source.x) * weight
                dy += (target.y - source.y) * weight
                total += weight
            }
            let vx = b.x - a.x, vy = b.y - a.y, length = a.distance(to: b)
            let t = ((q.x - a.x) * vx + (q.y - a.y) * vy) / (length * length)
            let distance = ((q.x - a.x) * -vy + (q.y - a.y) * vx) / length
            if (-0.12...1.15).contains(t), abs(distance) < 32 {
                let newLength = targetA.distance(to: targetB)
                let mapped = Point(x: targetA.x + (targetB.x - targetA.x) * t - (targetB.y - targetA.y) / newLength * distance,
                                   y: targetA.y + (targetB.y - targetA.y) * t + (targetB.x - targetA.x) / newLength * distance)
                if nearest == nil || abs(distance) < nearest!.0 { nearest = (abs(distance), mapped) }
            }
        }
        // Three generously spaced apron positions keep enlarged aircraft off
        // terminal roofs in the edited photograph. These are scenario stands.
        let apronStands = [Point(x: 390, y: 590), Point(x: 390, y: 495), Point(x: 390, y: 400)]
        for (index, stand) in stands.enumerated() {
            let source = originalPixel(stand)
            let weight = 1 / (pow(q.distance(to: source), 4) + 0.01)
            dx += (apronStands[index].x - source.x) * weight
            dy += (apronStands[index].y - source.y) * weight
            total += weight
        }
        let smooth = Point(x: q.x + dx / total, y: q.y + dy / total)
        guard let nearest else { return smooth }
        let blend = min(1, max(0, (32 - nearest.0) / 14))
        return Point(x: smooth.x + (nearest.1.x - smooth.x) * blend,
                     y: smooth.y + (nearest.1.y - smooth.y) * blend)
    }
    static let runwayDefinitions: [(String, String, Point, Point)] = [
        ("10", "28", DelhiLayout.northStart, DelhiLayout.northEnd),
        ("11R", "29L", DelhiLayout.southStart, DelhiLayout.southEnd),
        ("09", "27", DelhiLayout.visualRunways[0].2, DelhiLayout.visualRunways[0].3),
        ("11L", "29R", DelhiLayout.visualRunways[2].2, DelhiLayout.visualRunways[2].3)
    ]
    static let operatingBounds: (left: Double, top: Double, right: Double, bottom: Double) = {
        let points=runwayDefinitions.flatMap { [display($0.2),display($0.3)] }
        return (points.map(\.x).min()!-35,points.map(\.y).min()!-35,points.map(\.x).max()!+35,points.map(\.y).max()!+35)
    }()
    static let stands = DelhiGroundData.stands
    static let standNames = ["Apron D1", "Apron D2", "Apron D3"]
    static var holds: [Point] { DelhiGroundData.holds }
    static var exits: [Point] { DelhiGroundData.exits }
    static func route(_ key: String) -> [Point] { DelhiGroundData.route(key) }
    static func arrivalPoint(runway: Int, nauticalMiles: Double) -> Point {
        DelhiLayout.arrivalPoint(runway: runway, nauticalMiles: nauticalMiles)
    }
    static func nauticalMiles(_ a: Point, _ b: Point) -> Double { DelhiLayout.nauticalMiles(a, b) }
}
