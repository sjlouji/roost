import SwiftUI

@main
struct RoostApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 580)
        }
        .windowToolbarStyle(.unified)
    }
}
