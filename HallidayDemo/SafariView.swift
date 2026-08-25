import SafariServices
import SwiftUI

// SFSafariViewController keeps the onramp inside the app and, unlike WKWebView, supports
// Apple Pay on the Web without a merchant entitlement of our own.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.barCollapsingEnabled = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .done
        controller.preferredControlTintColor = UIColor(Color.crtInk)
        controller.preferredBarTintColor = UIColor(Color.crtGreen)
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
