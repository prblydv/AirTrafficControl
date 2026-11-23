import SwiftUI

@main
struct AirTrafficControlApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
#if os(macOS)
                .frame(minWidth: 900, minHeight: 640)
#endif
        }
#if os(macOS)
        .defaultSize(width: 1300, height: 850)
#endif
    }
}
