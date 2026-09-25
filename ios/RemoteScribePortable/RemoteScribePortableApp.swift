import SwiftUI

@main
struct RemoteScribePortableApp: App {
    @StateObject private var model = PortableClientModel()

    var body: some Scene {
        WindowGroup { ContentView(model: model) }
    }
}
