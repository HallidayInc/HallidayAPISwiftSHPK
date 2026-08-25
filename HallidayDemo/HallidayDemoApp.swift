import SwiftUI

@main
struct HallidayDemoApp: App {
    @AppStorage("appearance") private var appearance = Appearance.system
    @State private var store = WalletStore()
    @State private var assets = AssetStore()
    @State private var onramp = OnrampStore()
    @State private var ready = false

    init() {
        Theme.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if ready {
                    HomeView()
                } else {
                    SplashView()
                }
            }
                .environment(store)
                .environment(assets)
                .environment(onramp)
                .haffer(16, .regular)
                .tint(.crtGreen)
                .preferredColorScheme(appearance.colorScheme)
                .task {
                    async let boot: Void = onramp.load()
                    await assets.load()
                    await boot
                    // Floor the splash so a fast load does not flash it.
                    try? await Task.sleep(for: .milliseconds(350))
                    ready = true
                }
        }
    }
}
