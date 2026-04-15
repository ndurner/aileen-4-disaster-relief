import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)

        // On Designed-for-iPad-on-Mac, ShareKit can abort while constructing the
        // SharePlay service icon. Exclude that service on this runtime only.
        if #available(iOS 15.4, *), ProcessInfo.processInfo.isiOSAppOnMac {
            controller.excludedActivityTypes = [.sharePlay]
        }

        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
