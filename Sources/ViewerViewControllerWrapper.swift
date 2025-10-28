import SwiftUI
import UIKit

struct ViewerViewControllerWrapper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        return ViewerViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
