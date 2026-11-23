#if os(macOS) && DEBUG
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AirportRouteFile: FileDocument {
    static var readableContentTypes:[UTType] { [.json] }
    var document:AirportRouteDocument
    init(_ value:AirportRouteDocument) { document=value }
    init(configuration:ReadConfiguration) throws { document=try JSONDecoder().decode(AirportRouteDocument.self,from:configuration.file.regularFileContents ?? Data()) }
    func fileWrapper(configuration:WriteConfiguration)throws->FileWrapper {
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        return FileWrapper(regularFileWithContents:try encoder.encode(document))
    }
}

@MainActor struct RouteEditorView:View {
    enum Tool:String,CaseIterable { case draw="Draw",select="Select",move="Move",pan="Pan",test="Test route",pin="Landmark" }
    @Environment(\.dismiss) private var dismiss
    @State private var model:RouteEditorModel
    @State private var tool:Tool = .draw
    @State private var zoom=1.0
    @State private var pan=CGSize.zero
    @State private var pinchOrigin:(Double,CGSize)?
    @State private var dragOrigin:CGSize?
    @State private var moving:Int?
    @State private var suppressTap=Date.distantPast
    @State private var role=0
    @State private var pin="gate-0-port"
    @State private var importFile=false
    @State private var exportFile=false
    @State private var clearConfirm=false
    @State private var applyConfirm=false
    let editorSurface:AirportSurface
    private var editorRoads:AirportServiceRoads {AirportServiceRoads(surface:editorSurface)}
    var backgroundImage=Image("DelhiBoard")
    var autosaveOnDismiss=true
    var onApply:()->Void
    init(backgroundImage:Image=Image("DelhiBoard"),document:AirportRouteDocument?=nil,surface:AirportSurface?=nil,autosaveOnDismiss:Bool=true,onApply:@escaping ()->Void) {
        self.editorSurface=surface ?? SurfaceLayout.legacy
        self.backgroundImage=backgroundImage;self.autosaveOnDismiss=autosaveOnDismiss;self.onApply=onApply;_model=State(initialValue:RouteEditorModel(document:document))
    }
    private let accent=Color(red:0.57,green:0.86,blue:0.71)
    private var pins:[(String,String,Point)] {
        var result:[(String,String,Point)]=[]
        for (i,g) in editorSurface.gates.enumerated() {
            result += [("gate-\(i)-port","\(g.name) · pushback/taxi join",g.port),("gate-\(i)-position","\(g.name) · parked centre",g.position),("gate-\(i)-nose","\(g.name) · nose / terminal",g.nose),("tug-\(i)","\(g.name) · tug parking",editorRoads.tugBay(i))]
        }
        for i in editorSurface.definition.runways.indices { result += [("rollout-\(i)","Runway \(i+1) · exit turn starts",editorSurface.runwayPoint(i,0.82)),("lineup-\(i)","Runway \(i+1) · line-up",editorSurface.runwayPoint(i,0.06)),("hold-\(i)","Runway \(i+1) · holding point",editorSurface.hold(i)),("exit-\(i)","Runway \(i+1) · exit",editorSurface.exit(i))] }
        for base in editorSurface.definition.serviceBases {for bay in base.bays {result.append(("depot-\(bay.id)","\(base.name) · \(ServiceKind(rawValue:bay.role)!.name)",bay.position))}}
        return result
    }
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Text("DEV · AIRPORT ROUTE EDITOR").font(.headline)
                Spacer()
                Button("Save draft") { model.saveDraft() }
                Button("Import JSON") { importFile=true }
                Button("Export JSON") { exportFile=true }
                Button("Apply & new shift") { applyConfirm=true }.buttonStyle(.bordered).tint(accent)
                Button("Done") { model.saveDraft();dismiss() }
            }.padding(12)
            Divider()
            GeometryReader { geometry in
                if geometry.size.width>800 {
                    HStack(spacing:0) { ScrollView { controls.padding(14) }.frame(width:260);Divider();map }
                } else {
                    VStack(spacing:0) { map;Divider();ScrollView { controls.padding(12) }.frame(height:210) }
                }
            }
            Divider()
            Text(model.message).font(.system(size:11,design:.monospaced)).frame(maxWidth:.infinity,alignment:.leading).padding(10)
        }.background(Color(red:0.055,green:0.085,blue:0.10)).foregroundStyle(.white).tint(accent).preferredColorScheme(.dark)
#if os(macOS)
        .frame(minWidth:1050,minHeight:720)
#endif
        .fileImporter(isPresented:$importFile,allowedContentTypes:[.json]) { result in
            do {
                let url=try result.get(),access=url.startAccessingSecurityScopedResource();defer { if access { url.stopAccessingSecurityScopedResource() } }
                let value=try JSONDecoder().decode(AirportRouteDocument.self,from:Data(contentsOf:url))
                if let problem=value.problems().first { model.message=problem;return }
                model.checkpoint();model.document=value;model.selectedNode=nil;model.selectedEdge=nil;model.message="Imported. Review the graph, then Apply & new shift."
            } catch { model.message=error.localizedDescription }
        }
        .fileExporter(isPresented:$exportFile,document:AirportRouteFile(model.document),contentType:.json,defaultFilename:"delhi-routes") { result in
            switch result { case .success: model.message="Graph exported. This JSON can be reviewed or imported on another device.";case .failure(let error):model.message=error.localizedDescription }
        }
        .confirmationDialog("Clear the current layer? You can undo this.",isPresented:$clearConfirm) { Button("Clear \(model.layer.rawValue)",role:.destructive) { model.clearLayer() } }
        .confirmationDialog("Apply this graph and start a new shift?",isPresented:$applyConfirm) {
            Button("Apply graph & restart shift") {
                do {
                    if let issue=model.document.activationProblems().first { model.message=issue;return }
                    guard model.document.image==editorSurface.routes.image,model.document.width==editorSurface.definition.image.width,model.document.height==editorSurface.definition.image.height,
                          model.document.airportID==editorSurface.definition.identity.id || (model.document.airportID==nil && editorSurface.definition.identity.id=="delhi") else{throw CocoaError(.fileReadCorruptFile)}
                    try RoutingOverrides.activate(model.document);model.saveDraft();onApply();dismiss()
                } catch { model.message=error.localizedDescription }
            }
        }
        .onDisappear { if autosaveOnDismiss { model.saveDraft() } }
    }
    private var controls:some View {
        VStack(alignment:.leading,spacing:13) {
            Text("Trace directly on the photograph").font(.headline)
            Text("Existing lines are rough guides, not verified pavement.").font(.caption).foregroundStyle(.orange)
            Text("Start with a blank layer or correct the existing lines. Place nodes on pavement; connect junctions by clicking existing nodes. Crossing lines join only when they share a node.").font(.caption).foregroundStyle(.secondary)
            Picker("Network",selection:Binding(get:{model.layer},set:{ value in model.changeLayer(value);role=value == .aircraft ? 0 : 2 })) {
                ForEach(RouteLayer.allCases,id:\.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Tool",selection:$tool) { ForEach(Tool.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
            HStack {
                Button("Break chain") { model.selectedNode=nil;model.selectedEdge=nil;model.message="Chain ended. Click a new start point." }
                Button("Fit") { zoom=1;pan = .zero }
            }.buttonStyle(.bordered)
            HStack {
                Button("−") { zoom=max(1,zoom/1.35);pan = .zero }
                Text(String(format:"%.1f×",zoom)).monospacedDigit()
                Button("+") { zoom=min(8,zoom*1.35) }
                Spacer()
            }.buttonStyle(.bordered)
            Text("Two-finger trackpad drag pans in any tool. Pinch to zoom (up to 8×). Pan tool: mouse-drag the image. Move tool: drag a node. Draw tool: clicking an edge splits it.").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Undo") { model.undo() }.disabled(!model.canUndo)
                Button("Redo") { model.redo() }.disabled(!model.canRedo)
                Button("Delete") { model.deleteSelected() }.keyboardShortcut("d",modifiers:[]).help("Delete the selected dot or edge (D)").disabled(model.selectedNode==nil && model.selectedEdge==nil)
            }.buttonStyle(.bordered).font(.caption)
            if model.layer == .services {
                Picker("Preview vehicle",selection:$role) { ForEach(ServiceKind.allCases,id:\.rawValue) { Text($0.name).tag($0.rawValue) } }
                Text("Permissions for new edges").font(.caption.bold())
                HStack {
                    Button("All vehicles") { model.access=Set(1...16) }
                    Button("Only this one") { model.access=[role] }
                }.buttonStyle(.bordered).font(.caption)
                ForEach(ServiceKind.allCases,id:\.rawValue) { kind in
                    Toggle(kind.name,isOn:Binding(get:{model.access.contains(kind.rawValue)},set:{ value in if value { model.access.insert(kind.rawValue) } else if model.access.count>1 { model.access.remove(kind.rawValue) } })).font(.caption)
                }
                if let selected=model.selectedEdge {
                    Button("Set permissions on selected edge") { model.checkpoint();if let i=model.document.edges.firstIndex(where:{ $0.id==selected }) { model.document.edges[i].access=model.access.sorted() } }
                }
            }
            if tool == .pin {
                Picker("Landmark",selection:$pin) { ForEach(pins,id:\.0) { Text($0.1).tag($0.0) } }
                Text("Click the exact location on the image. Parking centre and nose define the aircraft's orientation. Taxi join is where pushback ends. Connect its node to your network.").font(.caption).foregroundStyle(.secondary)
            }
            if tool == .test { Text("Click a start node, then a destination. The green route and moving dot preview Dijkstra routing for the chosen vehicle.").font(.caption).foregroundStyle(accent) }
            Divider()
            Text("\(model.visibleNodes.count) nodes · \(model.visibleEdges.count) edges").font(.caption.monospaced())
            Text("Cyan: aircraft · Amber: vehicles · Purple: landmarks · Grey: other layer").font(.caption2).foregroundStyle(.secondary)
            Button("Clear this layer…",role:.destructive) { clearConfirm=true }.buttonStyle(.bordered)
        }
    }
    private func transform(_ size:CGSize)->(Double,CGPoint) {
        let scale=min(size.width/model.document.width,size.height/model.document.height)*zoom
        return (scale,CGPoint(x:(size.width-model.document.width*scale)/2+pan.width,y:(size.height-model.document.height*scale)/2+pan.height))
    }
    private func world(_ p:CGPoint,size:CGSize)->Point { let (s,o)=transform(size);return Point(x:(p.x-o.x)/s,y:(p.y-o.y)/s) }
    private func clampPan(_ size:CGSize) {
        let s=min(size.width/model.document.width,size.height/model.document.height)*zoom
        let x=max(0,(model.document.width*s-size.width)/2),y=max(0,(model.document.height*s-size.height)/2)
        pan=CGSize(width:min(x,max(-x,pan.width)),height:min(y,max(-y,pan.height)))
    }
    private var map:some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval:0.1)) { time in
                Canvas { context,size in drawMap(context:&context,size:size,time:time.date) }
            }.contentShape(Rectangle()).clipped()
            .background(EditorTrackpadPan { delta in
                guard pinchOrigin == nil else { return }
                pan=CGSize(width:pan.width+delta.width,height:pan.height+delta.height)
                clampPan(geometry.size)
                suppressTap=Date().addingTimeInterval(0.2)
            })
            .gesture(DragGesture(minimumDistance:0).onChanged { value in
                guard pinchOrigin == nil else { return }
                if tool == .pan {
                    if dragOrigin==nil { dragOrigin=pan };pan=CGSize(width:dragOrigin!.width+value.translation.width,height:dragOrigin!.height+value.translation.height);clampPan(geometry.size)
                } else if tool == .move {
                    if moving==nil,let id=model.nearestNode(world(value.startLocation,size:geometry.size),radius:12/transform(geometry.size).0) { model.checkpoint();moving=id;model.selectedNode=id }
                    if let moving { let p=world(value.location,size:geometry.size);model.move(moving,to:Point(x:min(model.document.width,max(0,p.x)),y:min(model.document.height,max(0,p.y)))) }
                }
            }.onEnded { value in
                defer { dragOrigin=nil;moving=nil }
                guard Date()>suppressTap,tool != .pan,tool != .move,hypot(value.translation.width,value.translation.height)<8 else{return}
                let p=world(value.location,size:geometry.size),snap=10/transform(geometry.size).0
                guard p.x>=0 && p.y>=0 && p.x<=model.document.width && p.y<=model.document.height else{return}
                switch tool {
                case .draw:model.draw(p,snap:snap)
                case .select:model.select(p,snap:snap)
                case .test:model.testRoute(p,snap:snap,role:role)
                case .pin:
                    model.checkpoint();model.document.pins.removeAll { $0.id==pin };model.document.pins.append(RoutePin(id:pin,point:p));model.selectedNode=nil;model.draw(p,snap:snap);model.message="Landmark moved. Connect this node to the correct pavement path."
                default:break
                }
            })
            .simultaneousGesture(MagnifyGesture().onChanged { value in editorPinch(value,size:geometry.size) }.onEnded { _ in pinchOrigin=nil;suppressTap=Date().addingTimeInterval(0.3) })
        }.background(.black)
    }
    private func editorPinch(_ value:MagnifyGesture.Value,size:CGSize) {
        if pinchOrigin==nil { pinchOrigin=(zoom,pan) }
        let prior=pinchOrigin!,w=Double(size.width),h=Double(size.height)
        let ax=Double(value.startAnchor.x)*w,ay=Double(value.startAnchor.y)*h
        let fit=min(w/model.document.width,h/model.document.height),oldScale=fit*prior.0
        let ox=(w-model.document.width*oldScale)/2+Double(prior.1.width)
        let oy=(h-model.document.height*oldScale)/2+Double(prior.1.height)
        let px=(ax-ox)/oldScale,py=(ay-oy)/oldScale
        zoom=min(8,max(1,prior.0*Double(value.magnification)))
        let scale=fit*zoom
        pan=CGSize(width:ax-px*scale-(w-model.document.width*scale)/2,height:ay-py*scale-(h-model.document.height*scale)/2)
        clampPan(size);suppressTap=Date().addingTimeInterval(0.3)
    }
    private func drawMap(context:inout GraphicsContext,size:CGSize,time:Date) {
                    let (scale,origin)=transform(size)
                    func screen(_ p:Point)->CGPoint { CGPoint(x:origin.x+p.x*scale,y:origin.y+p.y*scale) }
                    context.draw(backgroundImage,in:CGRect(x:origin.x,y:origin.y,width:model.document.width*scale,height:model.document.height*scale))
                    let indexed=Dictionary(uniqueKeysWithValues:model.document.nodes.map { ($0.id,$0) })
                    for edge in model.document.edges {
                        guard let a=indexed[edge.a],let b=indexed[edge.b] else { continue }
                        let active=a.layer==model.layer,allowed=edge.access.contains(role)
                        var path=Path();path.move(to:screen(a.point));path.addLine(to:screen(b.point))
                        let color:Color = !active ? .white.opacity(0.18) : model.layer == .aircraft ? .cyan : .orange
                        context.stroke(path,with:.color(color.opacity(active && allowed ? 0.95 : 0.35)),lineWidth:edge.id==model.selectedEdge ? 4 : active ? 2 : 1)
                    }
                    for n in model.visibleNodes {
                        let p=screen(n.point),r=n.id==model.selectedNode || n.id==model.routeStart ? 6.0 : 3.5
                        let color:Color=model.layer == .aircraft ? .cyan : .orange
                        context.fill(Path(ellipseIn:CGRect(x:p.x-r,y:p.y-r,width:r*2,height:r*2)),with:.color(color))
                    }
                    for entry in pins {
                        let p=screen(model.document.pins.first(where:{ $0.id==entry.0 })?.point ?? entry.2)
                        context.stroke(Path(ellipseIn:CGRect(x:p.x-5,y:p.y-5,width:10,height:10)),with:.color(.purple.opacity(tool == .pin ? 1 : 0.55)),lineWidth:1)
                        if tool == .pin && entry.0==pin { context.draw(Text(entry.1).font(.system(size:10,weight:.bold)).foregroundStyle(.white),at:CGPoint(x:p.x,y:p.y-15)) }
                    }
                    if !model.preview.isEmpty { drawPreview(context:&context,points:model.preview,screen:screen,time:time.timeIntervalSinceReferenceDate) }
    }
    private func drawPreview(context:inout GraphicsContext,points:[Point],screen:(Point)->CGPoint,time:Double) {
        guard let first=points.first else{return}
        var path=Path();path.move(to:screen(first));for p in points.dropFirst(){path.addLine(to:screen(p))}
        context.stroke(path,with:.color(.green),style:StrokeStyle(lineWidth:4,dash:[6,3]))
        let length=FlightCurves.length(from:first,route:Array(points.dropFirst()))
        var remaining=time.truncatingRemainder(dividingBy:8)/8*length
        for (a,b) in zip(points,points.dropFirst()) {
            let d=a.distance(to:b)
            if remaining<=d && d>0 { let p=screen(Point.interpolate(a,b,fraction:remaining/d));context.fill(Path(ellipseIn:CGRect(x:p.x-6,y:p.y-6,width:12,height:12)),with:.color(.white));break };remaining-=d
        }
    }
}

/// Observe native trackpad scroll events only while the pointer is over this
/// editor's map. Click/draw and pinch gestures retain their existing handlers.
private struct EditorTrackpadPan:NSViewRepresentable {
    var onPan:(CGSize)->Void
    func makeCoordinator()->Coordinator { Coordinator(onPan) }
    func makeNSView(context:Context)->NSView {
        let view=PassthroughView()
        context.coordinator.attach(view)
        return view
    }
    func updateNSView(_ view:NSView,context:Context) { context.coordinator.onPan=onPan }
    static func dismantleNSView(_ view:NSView,coordinator:Coordinator) { coordinator.stop() }
    final class PassthroughView:NSView {
        override func hitTest(_ point:NSPoint)->NSView? { nil }
    }
    @MainActor final class Coordinator {
        var onPan:(CGSize)->Void
        private var monitor:Any?
        init(_ callback:@escaping (CGSize)->Void) { onPan=callback }
        func attach(_ view:NSView) {
            monitor=NSEvent.addLocalMonitorForEvents(matching:.scrollWheel) { [weak self,weak view] event in
                guard let self,let view,let window=view.window,event.window===window,
                      window.isKeyWindow,event.hasPreciseScrollingDeltas,
                      view.bounds.contains(view.convert(event.locationInWindow,from:nil)) else { return event }
                self.onPan(CGSize(width:event.scrollingDeltaX,height:event.scrollingDeltaY))
                return nil
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) };monitor=nil }
    }
}

#endif
