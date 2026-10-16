import SwiftUI

@main
struct RBBScanApp: App {
    @State private var model = ScanViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
