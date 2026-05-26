import SwiftUI
import SwiftTerm

struct TerminalView: UIViewRepresentable {
    var session: SSHSession
    /// Called when the user taps the house button in the accessory bar.
    var onDisconnect: () -> Void

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let tv = SwiftTerm.TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv
        session.attachTerminal(tv.getTerminal())

        // Disable iOS text-editing aids that corrupt terminal input.
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.spellCheckingType = .no

        // Grab keyboard focus immediately so the first keypress isn't lost.
        DispatchQueue.main.async { _ = tv.becomeFirstResponder() }

        // Attach the keyboard accessory bar as the terminal's inputAccessoryView.
        // Doing it here (rather than as a SwiftUI view below the terminal) lets
        // iOS manage its position above the keyboard without any layout-constraint
        // conflicts, and gives the Coordinator direct access to ctrlActive state.
        let bar = KeyAccessoryBar(session: session, accessoryState: context.coordinator.accessoryState, onDisconnect: onDisconnect)
        let host = UIHostingController(rootView: bar)
        host.view.backgroundColor = UIColor.systemBackground
        host.view.frame = CGRect(x: 0, y: 0, width: 0, height: 44)
        host.view.autoresizingMask = [.flexibleWidth]
        tv.inputAccessoryView = host.view
        context.coordinator.hostingVC = host

        return tv
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    class Coordinator: NSObject, TerminalViewDelegate {
        let session: SSHSession
        weak var terminalView: SwiftTerm.TerminalView?
        let accessoryState = AccessoryState()
        // Strong reference keeps the hosting controller alive for the view's lifetime.
        var hostingVC: UIHostingController<KeyAccessoryBar>?

        init(session: SSHSession) {
            self.session = session
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            if accessoryState.ctrlActive, data.count == 1,
               let byte = data.first, byte >= 0x40 && byte <= 0x7F {
                session.send(Data([byte & 0x1F]))
            } else {
                session.send(Data(data))
            }
        }

        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            session.resize(cols: UInt16(newCols), rows: UInt16(newRows))
        }
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
        func bell(source: SwiftTerm.TerminalView) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            UIPasteboard.general.string = String(data: content, encoding: .utf8)
        }
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
