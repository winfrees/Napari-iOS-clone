import SwiftUI

@main
struct NapariApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
