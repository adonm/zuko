import SwiftUI
import SwiftTerm
import UIKit

/// Bridges SwiftTerm's UIKit `TerminalView` into SwiftUI and wires it to an
/// `IrohSession`. Keystrokes and resizes go out over Iroh; host output is fed
/// back into the terminal.
struct TerminalRepresentable: UIViewRepresentable {
    let session: IrohSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> TerminalView {
        let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = TerminalView(frame: .zero, font: font)
        view.backgroundColor = .black
        view.terminalDelegate = context.coordinator
        let coordinator = context.coordinator
        coordinator.terminal = view

        // Route host output back into the terminal. The session calls this on
        // the main actor (the read loop runs there).
        session.onTerminalOutput = { [weak coordinator] data in
            coordinator?.feed(data)
        }
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        // No diffing needed; the session owns all dynamic state.
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        uiView.terminalDelegate = nil
        coordinator.terminal = nil
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        weak var session: IrohSession?
        weak var terminal: TerminalView?

        init(session: IrohSession) { self.session = session }

        func feed(_ data: Data) {
            // SwiftTerm expects ArraySlice<UInt8>; Data is a Collection<UInt8>.
            terminal?.feed(byteArray: ArraySlice(data))
        }

        // MARK: - TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // SwiftTerm invokes delegate methods on the main thread; the
            // Coordinator is @MainActor-isolated (matching SwiftTerm's main-
            // thread contract), so this is a direct synchronous forward.
            // Keystroke / paste from the user -> host.
            session?.enqueueData(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            session?.enqueueResize(
                cols: UInt16(clamping: newCols),
                rows: UInt16(clamping: newRows)
            )
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func bell(source: TerminalView) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            UIApplication.shared.open(url)
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            // OSC 52 copy from the host.
            UIPasteboard.general.string = String(data: content, encoding: .utf8)
        }

        func clipboardRead(source: TerminalView) -> Data? {
            // Deny OSC 52 read for safety.
            nil
        }
    }
}
