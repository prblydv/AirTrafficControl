import AppKit
import SwiftUI
import SpriteKit
import CryptoKit
import Darwin

@main struct PerformanceHarness {
    final class FrameProbe:NSObject,SKViewDelegate {
        private let lock=NSLock()
        private var previous:Double?
        private var recordedIntervals:[Double]=[]
        private var recordedFrames=0
        var intervals:[Double] {lock.lock();defer{lock.unlock()};return recordedIntervals}
        var frames:Int {lock.lock();defer{lock.unlock()};return recordedFrames}
        func view(_ view:SKView,shouldRenderAtTime time:TimeInterval)->Bool {
            lock.lock();defer{lock.unlock()}
            if let previous {recordedIntervals.append(time-previous)}
            previous=time;recordedFrames+=1
            return true
        }
        func clear() {lock.lock();defer{lock.unlock()};previous=nil;recordedIntervals=[];recordedFrames=0}
    }
    static func cpu()->Double {
        var usage=rusage();getrusage(RUSAGE_SELF,&usage)
        return Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1e6
    }
    static func memory()->UInt64 {
        var info=mach_task_basic_info(),count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<integer_t>.size)
        let capacity=Int(count)
        let result=withUnsafeMutablePointer(to:&info) {p in p.withMemoryRebound(to:integer_t.self,capacity:capacity) {task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)}}
        return result==KERN_SUCCESS ? UInt64(info.resident_size):0
    }
    static func percentile(_ values:[Double],_ p:Double)->Double {
        let sorted=values.sorted();guard !sorted.isEmpty else{return 0}
        return sorted[min(sorted.count-1,Int(Double(sorted.count-1)*p))]
    }
    @MainActor static func drive(_ s:Simulation,frame:Int) {
        if frame==0 {
            for id in s.aircraft.filter({$0.departure && $0.phase == .parked}).map(\.id) {
                s.selectedID=id
                if let runway=s.clearanceRunways(for:s.selected!).first {s.clearSelected(to:runway.id)}
            }
        }
        if frame%60==0 {
            for id in s.aircraft.filter({$0.crossingRequest != nil}).map(\.id) {s.selectedID=id;s.approveCrossing()}
            for id in s.aircraft.filter({$0.departure && $0.phase == .queued}).map(\.id) {
                s.selectedID=id
                if let runway=s.selected!.runway {s.clearSelected(to:runway)}
            }
        }
    }
    @MainActor static func state(_ s:Simulation)throws->Data {
        func point(_ p:Point)->[Double] {[p.x,p.y]}
        func target(_ target:ServiceTarget)->String {
            switch target {
            case .aircraft(let id):return id
            case .incident(let id):return s.incidents.first{$0.id==id}?.aircraftIDs.sorted().joined(separator:"+") ?? "incident"
            }
        }
        let aircraft=s.aircraft.map {a -> [String:Any] in
            ["id":a.id,"model":a.modelID,"stand":a.stand,"phase":a.phase.rawValue,"position":point(a.position),"heading":a.heading,"altitude":a.altitude,"speed":a.groundSpeed,"route":a.route.map(point),"pending":a.pendingTaxiRoute.map(point),"waiting":a.waitingForTraffic,"blocked":a.blockedBy ?? "","tow":a.underTow,"recovering":a.recoveringGround,"ready":a.readyToDepart,"fuel":a.fuelFraction,"crossing":a.crossingRequest ?? -1]
        }
        let tasks=s.serviceTasks.map {t -> [Any] in [t.kind.rawValue,target(t.target),t.state.rawValue,t.remaining,t.prepared,t.effectApplied]}
        let vehicles=s.vehicles.map {v -> [Any] in
            let task=v.taskID.flatMap{id in s.serviceTasks.first{$0.id==id}}
            return [v.id,v.kind.rawValue,point(v.position),v.heading,v.route.map(point),task.map{String($0.kind.rawValue)+":"+target($0.target)} ?? "",v.routeUnavailable]
        }
        return try JSONSerialization.data(withJSONObject:["aircraft":aircraft,"tasks":tasks,"vehicles":vehicles,"time":s.elapsed,"score":s.score,"sequence":s.trafficSequence,"runways":s.runways.map(\.closed),"incidents":s.incidents.map{[$0.aircraftIDs.sorted(),$0.runwayIDs.sorted()] as [Any]}],options:[.sortedKeys])
    }
    @MainActor static func simulation(seconds:Int)throws->[String:Any] {
        let s=Simulation(seed:17,continuousTraffic:true,airportPackage:.delhi,plansGroundTrafficInBackground:true)
        s.followsAssignedGroundRoutes=true;s.showBriefing=false;s.startLive()
        var times:[Double]=[],trace=SHA256(),memorySamples:[UInt64]=[]
        let wall=ProcessInfo.processInfo.systemUptime,processor=cpu()
        for frame in 0..<(seconds*60) {
            drive(s,frame:frame)
            let start=ProcessInfo.processInfo.systemUptime
            s.tick(1.0/60)
            times.append(ProcessInfo.processInfo.systemUptime-start)
            if frame%600==0 {trace.update(data:try state(s));memorySamples.append(memory())}
        }
        trace.update(data:try state(s))
        return ["mode":"simulation","simulated_seconds":seconds,"wall_seconds":ProcessInfo.processInfo.systemUptime-wall,"cpu_seconds":cpu()-processor,"tick_mean_ms":times.reduce(0,+)/Double(times.count)*1000,"tick_p95_ms":percentile(times,0.95)*1000,"tick_p99_ms":percentile(times,0.99)*1000,"tick_max_ms":times.max()!*1000,"ticks_over_16_7ms":times.filter{$0>1.0/60}.count,"state_sha256":trace.finalize().map{String(format:"%02x",$0)}.joined(),"rss_samples_bytes":memorySamples,"aircraft":s.aircraft.count,"vehicles":s.vehicles.count,"tasks":s.serviceTasks.count,"incidents":s.incidents.count]
    }
    @MainActor static func window(duration:Double)throws->[String:Any] {
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1300,height:850),styleMask:[.titled,.resizable,.closable],backing:.buffered,defer:false)
        window.title="Air Traffic Control — performance measurement"
        window.contentView=NSHostingView(rootView:ContentView())
        window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
        func pump(_ seconds:Double) {RunLoop.main.run(until:Date().addingTimeInterval(seconds))}
        func find(_ node:NSView)->SKView? {if let view=node as? SKView{return view};return node.subviews.lazy.compactMap{find($0)}.first}
        pump(2)
        let view=find(window.contentView!)!,scene=view.scene as! AirportScene,s=scene.simulation
        precondition(view.bounds.width>500 && view.bounds.height>300,"Game viewport is not laid out")
        s.reset(seed:17);s.followsAssignedGroundRoutes=true;s.showBriefing=false;s.startLive()
        for frame in 0..<5400 {drive(s,frame:frame);s.tick(1.0/60)}
        pump(2);s.startLive()
        let probe=FrameProbe();view.delegate=probe
        let simulationStart=s.elapsed
        let start=ProcessInfo.processInfo.systemUptime,processor=cpu()
        var memorySamples:[UInt64]=[],lastDriven = -1,lastSample=0.0
        while ProcessInfo.processInfo.systemUptime-start<duration {
            pump(0.02)
            let second=Int(s.elapsed)
            if second != lastDriven {drive(s,frame:second*60);lastDriven=second}
            let now=ProcessInfo.processInfo.systemUptime-start
            if now-lastSample>=1 {memorySamples.append(memory());lastSample=now}
        }
        let wall=ProcessInfo.processInfo.systemUptime-start,cpuSeconds=cpu()-processor
        precondition(probe.frames>Int(duration*40) && s.elapsed>simulationStart+duration*0.8,"Window benchmark failed to render/advance; its performance numbers are invalid")
        let active:[String:Any]=["wall_seconds":wall,"cpu_percent":cpuSeconds/wall*100,"frames":probe.frames,"fps":Double(probe.frames)/wall,"frame_p95_ms":percentile(probe.intervals,0.95)*1000,"frame_p99_ms":percentile(probe.intervals,0.99)*1000,"frame_max_ms":(probe.intervals.max() ?? 0)*1000,"frames_over_25ms":probe.intervals.filter{$0>0.025}.count,"rss_samples_bytes":memorySamples,"viewport_width":view.bounds.width,"viewport_height":view.bounds.height]
        s.running=false;pump(0.5);probe.clear()
        let pausedElapsed=s.elapsed,pauseStart=ProcessInfo.processInfo.systemUptime,pauseCPU=cpu()
        pump(5)
        let paused:[String:Any]=["wall_seconds":ProcessInfo.processInfo.systemUptime-pauseStart,"cpu_percent":(cpu()-pauseCPU)/(ProcessInfo.processInfo.systemUptime-pauseStart)*100,"frames":probe.frames,"simulation_advanced":s.elapsed != pausedElapsed]
        view.delegate=nil
        if let cg=view.texture(from:scene)?.cgImage(),let png=NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]),let output=ProcessInfo.processInfo.environment["ATC_PERF_OUTPUT"] {
            try png.write(to:URL(fileURLWithPath:output).deletingPathExtension().appendingPathExtension("png"))
        }
        window.orderOut(nil)
        return ["mode":"window","active":active,"paused":paused,"aircraft":s.aircraft.count,"vehicles":s.vehicles.count,"tasks":s.serviceTasks.count,"incidents":s.incidents.count]
    }
    @MainActor static func main()throws {
        setbuf(stdout,nil)
        let env=ProcessInfo.processInfo.environment
        let mode=env["ATC_PERF_MODE"] ?? "simulation"
        print("PERFORMANCE START",mode)
#if ATC_REGRESSION
        if mode=="checks" {try regressionChecks();return}
#endif
        let result=try mode=="window" ? window(duration:Double(env["ATC_PERF_DURATION"] ?? "30")!):simulation(seconds:Int(env["ATC_PERF_SECONDS"] ?? "600")!)
        let data=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:URL(fileURLWithPath:env["ATC_PERF_OUTPUT"]!))
        print(String(data:data,encoding:.utf8)!)
    }
}
