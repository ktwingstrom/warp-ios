import Foundation
import Observation
import SwiftTerm
import UIKit

@MainActor
@Observable
class SSHSession {
    var isConnected = false
    var errorMessage: String?
    var blockStore = TerminalBlockStore()

    private var rustSession: SshSession?
    private var warpSessionController: WarpSessionController?
    private weak var terminalView: SwiftTerm.TerminalView?
    // Last known terminal size; stored so we can sync it to the PTY right
    // after the connection is established (sizeChanged fires before connect).
    private var pendingCols: UInt16 = 0
    private var pendingRows: UInt16 = 0
    private var promptUsername = ""
    private var promptHostname = ""
    private var awaitingRemotePromptEcho = false
    private var promptPrimeRetryPending = false
    private var lastSuppressState: Bool?
    private var suppressedBytes = 0
    private var fedBytes = 0
    private let maxHistoryItems = 250
    private var richHistoryOriginalBuffer = ""
    private var richHistoryRequested = false
    private(set) var richHistoryVisible = false
    private(set) var richHistoryIsLoading = false
    private(set) var richHistoryItems: [RichHistoryItem] = []
    private(set) var richHistorySelectionIndex = 0
    private(set) var currentInputBuffer = ""
    private var richHistoryNeedsRefresh = true
    private var localHistoryStorageKey: String?
    private enum PromptFeedState {
        case interactive
        case runningBlock
        case awaitingPrecmd
    }
    private var promptFeedState: PromptFeedState = .interactive

    func connect(host: SSHHost, password: String? = nil) async {
        blockStore.reset()
        promptFeedState = .interactive
        resetRichHistoryState()
        localHistoryStorageKey = historyStorageKey(for: host)
        blockStore.commandHistory = loadPersistedTypingHistory()
        seedRichHistoryFromLocalTypingHistory()
        promptUsername = host.username
        promptHostname = host.hostname
        awaitingRemotePromptEcho = false
        trace("connect start host=\(host.hostname) user=\(host.username)")
        do {
            switch host.authMethod {
            case .password:
                guard let pw = password else {
                    errorMessage = "Password required"
                    return
                }
                rustSession = try await sshConnectWithPassword(
                    host: host.hostname,
                    port: UInt16(host.port),
                    username: host.username,
                    password: pw
                )
            case .key(let tag):
                let pem = try KeychainService.loadKey(tag: tag)
                rustSession = try await sshConnectWithKey(
                    host: host.hostname,
                    port: UInt16(host.port),
                    username: host.username,
                    privateKeyPem: pem
                )
            }
            if let terminalView {
                rustSession?.setReceiver(receiver: TerminalDataReceiver(terminalView: terminalView, session: self))
            }
            let warpSessionController = WarpSessionController(store: blockStore, session: self)
            self.warpSessionController = warpSessionController
            rustSession?.setEventReceiver(receiver: warpSessionController)
            // Sync PTY size to what SwiftTerm actually rendered.
            // sizeChanged fires before the connection is up, so we apply the
            // stored dimensions now.  Fall back to terminal.cols/rows if
            // pendingCols was never set (e.g., first layout happened after connect).
            let terminal = terminalView?.getTerminal()
            let cols = pendingCols > 0 ? pendingCols : UInt16(terminal?.cols ?? 80)
            let rows = pendingRows > 0 ? pendingRows : UInt16(terminal?.rows ?? 24)
            if cols > 0 && rows > 0 {
                rustSession?.resize(cols: cols, rows: rows)
            }
            isConnected = true
            trace("connect success; session ready")
        } catch {
            errorMessage = error.localizedDescription
            trace("connect failed error=\(error.localizedDescription)")
        }
    }

    // Called by the Rust bridge when the remote session ends (channel EOF/close).
    func handleRemoteDisconnect() {
        persistTypingHistory()
        isConnected = false
        rustSession = nil
        warpSessionController = nil
        localHistoryStorageKey = nil
        resetRichHistoryState()
    }

    func attachTerminalView(_ terminalView: SwiftTerm.TerminalView) {
        self.terminalView = terminalView
        if let session = rustSession {
            session.setReceiver(receiver: TerminalDataReceiver(terminalView: terminalView, session: self))
        }
        // Bootstrapped can arrive before this TerminalView is attached in the
        // block-first layout path. Prime the prompt once attachment is ready.
        if blockStore.isBootstrapped,
           !blockStore.fallbackModeEnabled,
           blockStore.activeBlockID == nil {
            awaitingRemotePromptEcho = true
            renderSyntheticPromptInTerminal()
            trace("attachTerminalView primed prompt")
        }
    }

    func handleTerminalInput(bytes: [UInt8]) -> Bool {
        if richHistoryVisible,
           !isUpArrow(bytes),
           !isDownArrow(bytes),
           !isEscape(bytes),
           !isEnter(bytes) {
            closeRichHistory(restoreInput: true, reason: "typed-dismiss")
        }

        if isUpArrow(bytes), isRichHistoryEligible {
            openOrAdvanceRichHistory()
            return true
        }

        if isDownArrow(bytes), richHistoryVisible {
            moveRichHistorySelectionDown()
            return true
        }

        if isEscape(bytes), richHistoryVisible {
            closeRichHistory(restoreInput: true, reason: "escape")
            return true
        }

        if isEnter(bytes), richHistoryVisible {
            acceptRichHistorySelection()
            return true
        }

        updateCurrentInputBuffer(for: bytes)
        return false
    }

    func send(_ data: Data) {
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            trace("send text='\(text)' bytes=\(data.count)")
        } else if data.contains(0x0D) || data.contains(0x0A) {
            trace("send newline bytes=\(data.count)")
        }
        rustSession?.sendData(data: Array(data))
    }

    func requestRichHistory() {
        guard !richHistoryIsLoading else { return }
        guard isRichHistoryEligible else { return }
        guard let rustSession else { return }
        richHistoryRequested = true
        richHistoryIsLoading = true
        trace("history-menu request limit=\(maxHistoryItems)")
        rustSession.requestHistory(limit: UInt32(maxHistoryItems))
    }

    func handleHistorySnapshot(encoded: String) {
        richHistoryIsLoading = false
        richHistoryNeedsRefresh = false
        let decoded = decodeHistoryCommands(encoded: encoded)
        let merged = mergeWithSessionCommands(remoteCommands: decoded)
        let oldestToNewest = merged.reversed()
        richHistoryItems = oldestToNewest.enumerated().map { RichHistoryItem(id: $0.offset, command: $0.element) }
        if richHistoryVisible {
            richHistorySelectionIndex = max(0, richHistoryItems.count - 1)
            previewCurrentHistorySelection()
        }
        trace("history-menu snapshot remoteItems=\(decoded.count) mergedItems=\(richHistoryItems.count)")
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard cols > 0, rows > 0 else { return }
        pendingCols = cols
        pendingRows = rows
        rustSession?.resize(cols: cols, rows: rows)
    }

    func disconnect() async {
        persistTypingHistory()
        await rustSession?.disconnect()
        isConnected = false
        rustSession = nil
        warpSessionController = nil
        localHistoryStorageKey = nil
        resetRichHistoryState()
    }

    func handlePreexecEvent() {
        trace("hook preexec activeBlock=\(String(describing: blockStore.activeBlockID))")
        persistTypingHistory()
        richHistoryVisible = false
        currentInputBuffer = ""
        promptFeedState = .runningBlock
        awaitingRemotePromptEcho = false
        if blockStore.isBootstrapped, !blockStore.fallbackModeEnabled {
            clearPromptTerminal()
        }
    }

    func handleCommandFinishedEvent() {
        trace("hook command_finished activeBlock=\(String(describing: blockStore.activeBlockID))")
        richHistoryNeedsRefresh = true
        // Keep suppressing stream bytes until precmd arrives so trailing output
        // does not leak into the prompt area.
        promptFeedState = .awaitingPrecmd
        if blockStore.isBootstrapped, !blockStore.fallbackModeEnabled {
            DispatchQueue.main.async { [weak terminalView] in
                _ = terminalView?.becomeFirstResponder()
            }
        }
    }

    func handleBootstrappedEvent() {
        promptFeedState = .interactive
        awaitingRemotePromptEcho = true
        renderSyntheticPromptInTerminal()
        if !richHistoryRequested {
            requestRichHistory()
        }
        trace("bootstrapped prompt primed")
    }

    func handlePrecmdEvent() {
        currentInputBuffer = ""
        promptFeedState = .interactive
        awaitingRemotePromptEcho = true
        renderSyntheticPromptInTerminal()
        trace("hook precmd")
    }

    private func clearPromptTerminal() {
        guard let terminalView else { return }
        // Keep the bottom prompt zone fresh like desktop Warp's input area.
        terminalView.feed(byteArray: [0x1B, 0x5B, 0x33, 0x4A]) // CSI 3J
        terminalView.feed(byteArray: [0x1B, 0x5B, 0x32, 0x4A]) // CSI 2J
        terminalView.feed(byteArray: [0x1B, 0x5B, 0x48]) // CSI H
    }

    func shouldSuppressPromptOutput() -> Bool {
        blockStore.isBootstrapped
            && !blockStore.fallbackModeEnabled
            && promptFeedState != .interactive
    }

    func recordPromptOutputPath(dataCount: Int, suppressed: Bool) {
        if suppressed {
            suppressedBytes += dataCount
        } else {
            fedBytes += dataCount
        }

        if lastSuppressState != suppressed {
            trace(
                "prompt-output suppressed=\(suppressed) activeBlock=\(String(describing: blockStore.activeBlockID)) " +
                "fedBytes=\(fedBytes) suppressedBytes=\(suppressedBytes)"
            )
            lastSuppressState = suppressed
        }
    }

    func trace(_ message: String) {
        #if DEBUG
        print("[WarpTrace] \(message)")
        #endif
    }

    private func renderSyntheticPromptInTerminal() {
        renderPromptWithInput(currentInputBuffer)
    }

    private var isRichHistoryEligible: Bool {
        blockStore.isBootstrapped && !blockStore.fallbackModeEnabled
    }

    private func resetRichHistoryState() {
        richHistoryVisible = false
        richHistoryIsLoading = false
        richHistoryRequested = false
        richHistoryNeedsRefresh = true
        richHistoryItems = []
        richHistorySelectionIndex = 0
        richHistoryOriginalBuffer = ""
        currentInputBuffer = ""
    }

    private func openOrAdvanceRichHistory() {
        if !richHistoryVisible {
            richHistoryVisible = true
            richHistoryOriginalBuffer = currentInputBuffer
            richHistorySelectionIndex = max(0, richHistoryItems.count - 1)
            if !richHistoryRequested || richHistoryNeedsRefresh || richHistoryItems.isEmpty {
                requestRichHistory()
            }
            previewCurrentHistorySelection()
            trace("history-menu open original='\(richHistoryOriginalBuffer)'")
            return
        }

        guard !richHistoryItems.isEmpty else { return }
        let nextIndex = max(0, richHistorySelectionIndex - 1)
        richHistorySelectionIndex = nextIndex
        previewCurrentHistorySelection()
        trace("history-menu navigate direction=up index=\(richHistorySelectionIndex)")
    }

    private func moveRichHistorySelectionDown() {
        guard !richHistoryItems.isEmpty else {
            closeRichHistory(restoreInput: true, reason: "down-empty")
            return
        }

        let nextIndex = richHistorySelectionIndex + 1
        if nextIndex >= richHistoryItems.count {
            closeRichHistory(restoreInput: true, reason: "down-end")
            return
        }

        richHistorySelectionIndex = nextIndex
        previewCurrentHistorySelection()
        trace("history-menu navigate direction=down index=\(richHistorySelectionIndex)")
    }

    private func previewCurrentHistorySelection() {
        guard richHistoryVisible else { return }
        guard richHistoryItems.indices.contains(richHistorySelectionIndex) else {
            if richHistoryVisible {
                renderPromptWithInput(richHistoryOriginalBuffer)
            }
            return
        }
        let selected = richHistoryItems[richHistorySelectionIndex].command
        currentInputBuffer = selected
        renderPromptWithInput(selected)
        trace("history-menu preview index=\(richHistorySelectionIndex)")
    }

    private func acceptRichHistorySelection() {
        guard richHistoryItems.indices.contains(richHistorySelectionIndex) else {
            closeRichHistory(restoreInput: true, reason: "accept-empty")
            return
        }
        let command = richHistoryItems[richHistorySelectionIndex].command
        closeRichHistory(restoreInput: false, reason: "accept")
        trace("history-menu accept command='\(command)'")
        executeHistorySelection(command)
    }

    private func executeHistorySelection(_ command: String) {
        let bytes = [UInt8(0x15)] + Array(command.utf8) + [UInt8(0x0D)]
        currentInputBuffer = ""
        send(Data(bytes))
    }

    private func closeRichHistory(restoreInput: Bool, reason: String) {
        guard richHistoryVisible else { return }
        richHistoryVisible = false
        if restoreInput {
            currentInputBuffer = richHistoryOriginalBuffer
            renderPromptWithInput(richHistoryOriginalBuffer)
        }
        trace("history-menu close reason=\(reason)")
    }

    private func updateCurrentInputBuffer(for bytes: [UInt8]) {
        guard isRichHistoryEligible else { return }
        guard !bytes.isEmpty else { return }

        if isEnter(bytes) {
            currentInputBuffer = ""
            return
        }

        if isBackspace(bytes) {
            if !currentInputBuffer.isEmpty {
                currentInputBuffer.removeLast()
            }
            return
        }

        if bytes.first == 0x1B {
            return
        }

        if let typed = String(bytes: bytes, encoding: .utf8), !typed.isEmpty {
            currentInputBuffer.append(typed)
        }
    }

    private func decodeHistoryCommands(encoded: String) -> [String] {
        guard let decodedData = Data(base64Encoded: encoded),
              let text = String(data: decodedData, encoding: .utf8)
        else {
            return []
        }

        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isInternalHistoryCommand($0) }

        var seen = Set<String>()
        var result: [String] = []
        for command in lines.reversed() {
            if seen.insert(command).inserted {
                result.append(command)
            }
        }
        return result
    }

    private func mergeWithSessionCommands(remoteCommands: [String]) -> [String] {
        var merged: [String] = []
        var seen = Set<String>()

        for command in remoteCommands {
            let normalized = normalizeHistoryCommand(command)
            guard !normalized.isEmpty else { continue }
            if seen.insert(normalized).inserted {
                merged.append(normalized)
            }
        }

        let sessionCommands = blockStore.commandHistory
            .reversed()
            .map(normalizeHistoryCommand)
            .filter { !$0.isEmpty && !isInternalHistoryCommand($0) }

        for command in sessionCommands where seen.insert(command).inserted {
            merged.append(command)
        }

        return merged
    }

    private func seedRichHistoryFromLocalTypingHistory() {
        let localHistory = compactedHistory(commands: blockStore.commandHistory)
        richHistoryItems = localHistory.enumerated().map { RichHistoryItem(id: $0.offset, command: $0.element) }
    }

    private func persistTypingHistory() {
        guard let key = localHistoryStorageKey else { return }
        let compacted = compactedHistory(commands: blockStore.commandHistory)
        blockStore.commandHistory = compacted
        guard let encoded = try? JSONEncoder().encode(compacted) else { return }
        UserDefaults.standard.set(encoded, forKey: key)
    }

    private func loadPersistedTypingHistory() -> [String] {
        guard let key = localHistoryStorageKey,
              let encoded = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String].self, from: encoded)
        else {
            return []
        }
        return compactedHistory(commands: decoded)
    }

    private func historyStorageKey(for host: SSHHost) -> String {
        let scope = "\(host.username.lowercased())@\(host.hostname.lowercased()):\(host.port)"
        return "ssh_local_typing_history_\(scope)"
    }

    private func compactedHistory(commands: [String]) -> [String] {
        var seen = Set<String>()
        var newestFirst: [String] = []

        for command in commands.reversed() {
            let normalized = normalizeHistoryCommand(command)
            guard !normalized.isEmpty, !isInternalHistoryCommand(normalized) else { continue }
            if seen.insert(normalized).inserted {
                newestFirst.append(normalized)
            }
            if newestFirst.count >= maxHistoryItems {
                break
            }
        }

        return newestFirst.reversed()
    }

    private func normalizeHistoryCommand(_ command: String) -> String {
        var normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }

        // Bash preexec reports alias-expanded `ls --color=auto`, sometimes duplicated
        // when replayed. Normalize history entries back to what users expect to recall.
        if normalized == "ls --color=auto" {
            return "ls"
        }
        if normalized.hasPrefix("ls ") {
            let tokens = normalized.split(whereSeparator: \.isWhitespace)
            if tokens.first == "ls" {
                let filtered = tokens.filter { $0 != "--color=auto" }
                if filtered.count == 1 {
                    return "ls"
                }
                normalized = filtered.joined(separator: " ")
            }
        }

        return normalized
    }

    private func isInternalHistoryCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // Shell startup/teardown probes from distro profile scripts can leak
        // into remote history snapshots; keep recall focused on user commands.
        if lower.hasPrefix("/usr/bin/clear_console")
            || lower.hasPrefix("clear_console")
            || lower.contains("clear_console -q") {
            return true
        }

        if lower.hasPrefix("["),
           lower.hasSuffix("]"),
           (lower.contains("shlvl") || lower.contains("clear_console")) {
            return true
        }

        let internalNeedles = [
            "__warp_ios_",
            "PROMPT_COMMAND",
            "add-zsh-hook",
            "autoload -Uz add-zsh-hook",
            "stty erase '^H' echo echoe",
            "[ -n \"${ZSH_VERSION:-}\" ]",
            "[ -n \"${BASH_VERSION:-}\" ]",
            "case \";${PROMPT_COMMAND};\" in"
        ]
        return internalNeedles.contains { command.contains($0) }
    }

    private func isBackspace(_ bytes: [UInt8]) -> Bool {
        bytes == [0x08] || bytes == [0x7F]
    }

    private func isEscape(_ bytes: [UInt8]) -> Bool {
        bytes == [0x1B]
    }

    private func isEnter(_ bytes: [UInt8]) -> Bool {
        bytes == [0x0D] || bytes == [0x0A]
    }

    private func isUpArrow(_ bytes: [UInt8]) -> Bool {
        bytes == [0x1B, 0x5B, 0x41] || csiUKeyCode(bytes) == 65
    }

    private func isDownArrow(_ bytes: [UInt8]) -> Bool {
        bytes == [0x1B, 0x5B, 0x42] || csiUKeyCode(bytes) == 66
    }

    private func csiUKeyCode(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 6, bytes.first == 0x1B, bytes[1] == 0x5B, bytes.last == 0x75 else {
            return nil
        }
        let body = String(decoding: bytes.dropFirst(2).dropLast(), as: UTF8.self)
        let keyCodePart = body.split(separator: ";", maxSplits: 1).first.map(String.init) ?? body
        return Int(keyCodePart)
    }

    private func promptPrefix() -> String {
        let cwd = blockStore.currentWorkingDirectory
        let dir: String
        if cwd.isEmpty {
            dir = "~"
        } else if cwd == "/" {
            dir = "/"
        } else {
            dir = cwd.split(separator: "/").last.map(String.init) ?? cwd
        }
        return "\(promptUsername)@\(promptHostname):\(dir) $ "
    }

    private func renderPromptWithInput(_ input: String) {
        guard blockStore.isBootstrapped, !blockStore.fallbackModeEnabled else { return }
        guard let terminalView else { return }
        let cols = terminalView.getTerminal().cols
        // TerminalView can attach before layout and briefly report tiny widths
        // (e.g. 1 col), which would wrap prompt text vertically.
        if cols < 20 {
            if !promptPrimeRetryPending {
                promptPrimeRetryPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                    guard let self else { return }
                    self.promptPrimeRetryPending = false
                    self.renderSyntheticPromptInTerminal()
                }
            }
            trace("defer synthetic prompt until layout settles cols=\(cols)")
            return
        }

        let fullPrompt = promptPrefix() + input
        let bytes = Array(fullPrompt.utf8)
        terminalView.feed(byteArray: [0x1B, 0x5B, 0x32, 0x4A]) // CSI 2J
        terminalView.feed(byteArray: [0x1B, 0x5B, 0x48]) // CSI H
        terminalView.feed(byteArray: [0x0D, 0x1B, 0x5B, 0x32, 0x4B]) // CR + CSI 2K
        terminalView.feed(byteArray: bytes[...])
    }

    private func looksLikePromptLine(_ text: String) -> Bool {
        let ansiPattern = "\u{001B}\\[[0-9;?]*[ -/]*[@-~]"
        let cleaned: String
        if let regex = try? NSRegularExpression(pattern: ansiPattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            cleaned = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        } else {
            cleaned = text
        }
        let line = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }
        return line.contains("@")
            && line.contains(":")
            && (line.hasSuffix("$") || line.hasSuffix("$ ") || line.hasSuffix("%") || line.hasSuffix("% "))
    }

    func filterIdlePromptEcho(_ data: [UInt8]) -> [UInt8] {
        guard awaitingRemotePromptEcho else { return data }
        guard let text = String(bytes: data, encoding: .utf8) else { return data }
        if looksLikePromptLine(text) {
            awaitingRemotePromptEcho = false
            trace("dropped remote prompt echo (using synthetic prompt)")
            return []
        }
        return data
    }
}

class TerminalDataReceiver: DataReceiver {
    weak var terminalView: SwiftTerm.TerminalView?
    weak var session: SSHSession?

    init(terminalView: SwiftTerm.TerminalView?, session: SSHSession) {
        self.terminalView = terminalView
        self.session = session
    }

    func onData(data: [UInt8]) {
        guard let session else { return }
        // Once warp blocks are live, keep SwiftTerm focused on interactive prompt/input.
        // Command output flows through block events instead of terminal scrollback.
        let suppressed = session.shouldSuppressPromptOutput()
        session.recordPromptOutputPath(dataCount: data.count, suppressed: suppressed)
        if suppressed {
            return
        }
        let filtered = session.filterIdlePromptEcho(data)
        if filtered.isEmpty {
            return
        }

        let containsEraseControl = data.contains(0x08) && data.contains(0x4B)

        let applyDataToTerminal = { [weak terminalView] in
            guard let terminalView else { return }
            // Feed the TerminalView (not bare Terminal) so SwiftTerm runs
            // feedPrepare/feedFinish and schedules display updates immediately.
            terminalView.feed(byteArray: filtered[...])

            // Force a repaint when we receive erase-to-end-of-line traffic so
            // stale glyphs do not linger visually after backspace.
            if containsEraseControl {
                terminalView.setNeedsDisplay(terminalView.bounds)
            }
        }

        // Rust callbacks arrive on a Tokio worker thread. SwiftTerm mutates
        // UIKit state during feed(), so updates must run on main.
        //
        // SwiftTerm's iOS scroller can snap back to bottom when feed() runs
        // while the user is actively dragging (UITrackingRunLoopMode). By
        // scheduling feeds in .default mode, we let swipe scrollback win.
        if Thread.isMainThread {
            RunLoop.main.perform(inModes: [.default], block: applyDataToTerminal)
        } else {
            DispatchQueue.main.async {
                RunLoop.main.perform(inModes: [.default], block: applyDataToTerminal)
            }
        }
    }

    func onDisconnect(reason: String) {
        // Rust drops the Arc<DataReceiver> immediately after this call returns,
        // which deallocates TerminalDataReceiver.  A [weak self] capture would
        // therefore always resolve to nil.  Capture session strongly instead so
        // handleRemoteDisconnect() is guaranteed to fire even after self is gone.
        guard let session = session else { return }
        DispatchQueue.main.async {
            session.handleRemoteDisconnect()
        }
    }
}
