import SwiftUI
import UIKit

struct HostViewControllerWrapper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        return HostViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
