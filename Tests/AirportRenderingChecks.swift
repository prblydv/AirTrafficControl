import AppKit
import SpriteKit
@main struct AirportRenderingChecks {
    @MainActor static func main() throws {
        _=NSApplication.shared
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let package=try AirportPackage.load(at:root.appendingPathComponent("Tests/Fixtures/Airports/testfield"))
        let second=Simulation(seed:17,continuousTraffic:false,airportPackage:package)
        let delhi=Simulation(seed:17,continuousTraffic:false,airportPackage:.delhi)
        let assets=root.appendingPathComponent("AirTrafficControl/Assets.xcassets")
        func texture(_ name:String)->SKTexture {SKTexture(image:NSImage(contentsOf:assets.appendingPathComponent(name+".imageset/"+name.lowercased()+".png"))!)}
        let aircraft=Dictionary(uniqueKeysWithValues:AircraftCatalog.models.map{($0.assetName,texture($0.assetName))})
        let services=Dictionary(uniqueKeysWithValues:ServiceKind.allCases.map{($0.assetName,texture($0.assetName))})
        let otherScene=AirportScene(simulation:second,aircraftTextures:aircraft,serviceTextures:services)
        let delhiScene=AirportScene(simulation:delhi,aircraftTextures:aircraft,serviceTextures:services)
        precondition(otherScene.size==CGSize(width:900,height:600) && delhiScene.size==CGSize(width:1672,height:941))
        func count(_ name:String,in scene:SKScene)->Int {var total=0;scene.enumerateChildNodes(withName:name){_,_ in total+=1};return total}
        precondition(count("//runway-paint",in:otherScene)==2 && count("//runway-paint",in:delhiScene)==8)
        for gate in package.definition.stands {precondition(otherScene.childNode(withName:"//gate-"+gate.name) != nil)}
        let view=SKView(frame:NSRect(x:0,y:0,width:900,height:600));view.presentScene(otherScene);otherScene.update(1)
        precondition(view.texture(from:otherScene) != nil)
        precondition(delhiScene.size.height==941 && second.airport.identity.title=="TESTFIELD CONTROL")
        print("PASS:renderer loads package PNGs, independent image dimensions, stand names and runway labels for two simultaneous airports")
    }
}
