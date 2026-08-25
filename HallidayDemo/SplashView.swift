import SwiftUI

// Drawn by the app rather than by UILaunchScreen. iOS caches the static launch image per
// bundle and that cache can survive a delete-and-reinstall, so artwork changes were not
// showing up. Rendering it here means it always matches the build, and scaledToFit keeps
// the composition intact on screens taller than the artwork.
struct SplashView: View {
    var body: some View {
        ZStack {
            Color("LaunchBackground")
            Image("Splash")
                .resizable()
                .scaledToFit()
        }
        .ignoresSafeArea()
    }
}
