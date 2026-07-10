import SwiftUI
import VisionKit
import ZukoWire

struct PairingCodeScanner: View {
    let onScan: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var errorMessage: String?
    @State private var scannerID = UUID()

    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            Group {
                if Self.isSupported {
                    ScannerRepresentable(
                        isActive: scenePhase == .active,
                        onPayload: handlePayload,
                        onError: { errorMessage = $0 }
                    )
                    .id(scannerID)
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottom) {
                        Text("Point the camera at the QR code printed by `zuko share`.")
                            .font(.callout.weight(.medium))
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                            .padding()
                    }
                } else {
                    ContentUnavailableView(
                        "Scanner unavailable",
                        systemImage: "camera.fill",
                        description: Text("Type the pairing code instead.")
                    )
                }
            }
            .navigationTitle("Scan pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .alert(
            "Couldn't scan code",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("Try again") { scannerID = UUID() }
            Button("Cancel", role: .cancel) { dismiss() }
        } message: {
            Text(errorMessage ?? "Unknown scanner error")
        }
    }

    private func handlePayload(_ payload: String) -> Bool {
        guard let code = PairingLink.code(from: payload) else {
            errorMessage = "That QR code isn't a Zuko pairing code."
            return false
        }
        onScan(code)
        return true
    }
}

private struct ScannerRepresentable: UIViewControllerRepresentable {
    let isActive: Bool
    let onPayload: (String) -> Bool
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPayload: onPayload, onError: onError)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        if isActive {
            context.coordinator.startScanning(controller)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        if isActive, !uiViewController.isScanning {
            context.coordinator.startScanning(uiViewController)
        } else if !isActive, uiViewController.isScanning {
            uiViewController.stopScanning()
        }
    }

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onPayload: (String) -> Bool
        let onError: (String) -> Void
        private var delivered = false

        init(onPayload: @escaping (String) -> Bool, onError: @escaping (String) -> Void) {
            self.onPayload = onPayload
            self.onError = onError
        }

        func startScanning(_ dataScanner: DataScannerViewController) {
            do {
                try dataScanner.startScanning()
            } catch {
                onError(error.localizedDescription)
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !delivered else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue
                else { continue }
                if onPayload(payload) {
                    delivered = true
                    dataScanner.stopScanning()
                    return
                }
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            onError(error.localizedDescription)
        }
    }
}
