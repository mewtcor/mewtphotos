// Camera scanner for the pairing QR code the PC dashboard shows. It reads only QR codes and hands the first
// Mewt Photos pairing link to the caller; the link carries the address and the code, so the pairing flow does
// the rest. Nothing is stored here.
import SwiftUI
import VisionKit

struct PairScanner: UIViewControllerRepresentable {
    /// VisionKit's scanner needs a camera and iOS support; the simulator and some devices do not have it.
    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    let onLink: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLink: onLink)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onLink: (String) -> Void
        private var handled = false

        init(onLink: @escaping (String) -> Void) {
            self.onLink = onLink
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            // Only the first pairing link counts; a second code in view must not start another pairing.
            guard !handled else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue, payload.contains("#pair=") {
                    handled = true
                    onLink(payload)
                    return
                }
            }
        }
    }
}
