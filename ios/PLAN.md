# iOS Warp Client — Implementation Plan

## Phase 1 — Rust iOS Build Setup

### 1.1 Install iOS targets
```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
```

### 1.2 Add `warp_ios_bridge` to workspace

In root `Cargo.toml`, the `members` glob `"crates/*"` already picks up new crates automatically. No edit needed — just creating the crate directory is enough.

Add a workspace dependency entry in root `Cargo.toml` under `[workspace.dependencies]`:
```toml
warp_ios_bridge = { path = "crates/warp_ios_bridge" }
```

### 1.3 Verify
```bash
cargo check --target aarch64-apple-ios -p warp_ios_bridge
```

---

## Phase 2 — `crates/warp_ios_bridge/` Rust Crate

### 2.1 `crates/warp_ios_bridge/Cargo.toml`

```toml
[package]
name = "warp_ios_bridge"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["staticlib", "cdylib"]

[dependencies]
uniffi = { version = "0.28", features = ["tokio"] }
russh = "0.44"
russh-keys = "0.44"
tokio = { version = "1", features = ["rt-multi-thread", "net", "io-util", "sync", "macros"] }
thiserror = "2"
log = "0.4"

[build-dependencies]
uniffi = { version = "0.28", features = ["build"] }
```

### 2.2 `crates/warp_ios_bridge/build.rs`

```rust
fn main() {
    uniffi::generate_scaffolding("src/warp_ios_bridge.udl").unwrap();
}
```

### 2.3 `crates/warp_ios_bridge/src/warp_ios_bridge.udl`

UDL (UniFFI Definition Language) declares the Swift-visible API:

```
namespace warp_ios_bridge {};

[Error]
enum SshError {
    "ConnectionFailed",
    "AuthFailed",
    "ChannelError",
    "Disconnected",
    "InvalidKey",
};

callback interface DataReceiver {
    void on_data(sequence<u8> data);
    void on_disconnect(string reason);
};

interface SshSession {
    [Throws=SshError, Async]
    constructor connect_with_password(string host, u16 port, string username, string password);

    [Throws=SshError, Async]
    constructor connect_with_key(string host, u16 port, string username, string private_key_pem);

    [Throws=SshError, Async]
    void send_data(sequence<u8> data);

    [Throws=SshError, Async]
    void resize(u16 cols, u16 rows);

    void set_receiver(DataReceiver receiver);

    [Async]
    void disconnect();
};
```

### 2.4 `crates/warp_ios_bridge/src/lib.rs`

```rust
uniffi::include_scaffolding!("warp_ios_bridge");

use russh::client::{self, Handle};
use russh_keys::key::PrivateKeyWithHashAlg;
use std::sync::Arc;
use tokio::runtime::Runtime;
use tokio::sync::Mutex;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SshError {
    #[error("Connection failed: {0}")]
    ConnectionFailed(String),
    #[error("Authentication failed")]
    AuthFailed,
    #[error("Channel error: {0}")]
    ChannelError(String),
    #[error("Disconnected")]
    Disconnected,
    #[error("Invalid key")]
    InvalidKey,
}

pub trait DataReceiver: Send + Sync {
    fn on_data(&self, data: Vec<u8>);
    fn on_disconnect(&self, reason: String);
}

pub struct SshSession {
    handle: Mutex<Option<Handle<ClientHandler>>>,
    runtime: Arc<Runtime>,
    receiver: Mutex<Option<Arc<dyn DataReceiver>>>,
}

// russh client handler — receives incoming data from the server
struct ClientHandler {
    receiver: Arc<Mutex<Option<Arc<dyn DataReceiver>>>>,
}

#[async_trait::async_trait]
impl client::Handler for ClientHandler {
    type Error = russh::Error;

    async fn data(
        &mut self,
        _channel: russh::ChannelId,
        data: &[u8],
        _session: &mut client::Session,
    ) -> Result<(), Self::Error> {
        if let Some(rx) = self.receiver.lock().await.as_ref() {
            rx.on_data(data.to_vec());
        }
        Ok(())
    }
}

impl SshSession {
    pub async fn connect_with_password(
        host: String, port: u16, username: String, password: String,
    ) -> Result<Arc<Self>, SshError> {
        // See full implementation notes below
        todo!()
    }

    pub async fn connect_with_key(
        host: String, port: u16, username: String, private_key_pem: String,
    ) -> Result<Arc<Self>, SshError> {
        todo!()
    }

    pub async fn send_data(&self, data: Vec<u8>) -> Result<(), SshError> {
        todo!()
    }

    pub async fn resize(&self, cols: u16, rows: u16) -> Result<(), SshError> {
        todo!()
    }

    pub fn set_receiver(&self, receiver: Arc<dyn DataReceiver>) {
        // Store receiver so ClientHandler can forward data to Swift
        todo!()
    }

    pub async fn disconnect(&self) {
        todo!()
    }
}
```

**Implementation notes for `connect_with_password`:**
1. Create a `tokio::runtime::Runtime` (or use `#[tokio::main]` + uniffi async support)
2. `russh::client::connect(config, (host, port), handler).await`
3. `session.authenticate_password(username, password).await`
4. Open a PTY channel: `session.channel_open_session().await`, then `channel.request_pty(...)`, then `channel.request_shell()`
5. Spawn a task that reads from the channel and calls `receiver.on_data()`

**Implementation notes for `connect_with_key`:**
- Parse PEM with `russh_keys::decode_secret_key(&pem, None)`
- Use `session.authenticate_publickey(username, key).await`

---

## Phase 3 — xcframework Build Script

### `scripts/build_ios_xcframework.sh`

```bash
#!/bin/bash
set -euo pipefail

CRATE=warp_ios_bridge
OUT_DIR="ios/WarpIOSBridge.xcframework"
GENERATED_DIR="ios/WarpApp/Generated"

echo "Building for iOS device (aarch64-apple-ios)..."
cargo build --release --target aarch64-apple-ios -p $CRATE

echo "Building for iOS simulator (aarch64-apple-ios-sim)..."
cargo build --release --target aarch64-apple-ios-sim -p $CRATE

echo "Generating Swift bindings..."
mkdir -p "$GENERATED_DIR"
cargo run --features uniffi/cli --bin uniffi-bindgen generate \
  --library "target/aarch64-apple-ios/release/lib${CRATE}.a" \
  --language swift \
  --out-dir "$GENERATED_DIR"

# Move the generated header to a dedicated include dir for xcframework packaging
mkdir -p "target/ios-headers"
cp "$GENERATED_DIR"/*.h "target/ios-headers/"

echo "Packaging xcframework..."
rm -rf "$OUT_DIR"
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-ios/release/lib${CRATE}.a" \
  -headers "target/ios-headers" \
  -library "target/aarch64-apple-ios-sim/release/lib${CRATE}.a" \
  -headers "target/ios-headers" \
  -output "$OUT_DIR"

echo "Done: $OUT_DIR"
```

**Note:** The `uniffi-bindgen` binary requires adding to `Cargo.toml`:
```toml
[[bin]]
name = "uniffi-bindgen"
path = "src/bin/uniffi-bindgen.rs"
```
With contents:
```rust
fn main() {
    uniffi::uniffi_bindgen_main()
}
```

---

## Phase 4 — Xcode Project Setup

1. Open Xcode → **File → New → Project → iOS → App**
   - Product Name: `Warp`
   - Bundle Identifier: `com.kevintwingstrom.warp-ios`
   - Interface: SwiftUI
   - Language: Swift
   - Save to: `warp-ios/ios/`

2. Add Swift Package dependency:
   - **File → Add Package Dependencies**
   - URL: `https://github.com/migueldeicaza/SwiftTerm`
   - Add to target: `Warp`

3. Add xcframework:
   - Drag `ios/WarpIOSBridge.xcframework` into the Xcode project navigator
   - Target membership: `Warp`
   - Embed: **Embed & Sign**

4. Add the generated Swift file:
   - Drag `ios/WarpApp/Generated/warp_ios_bridge.swift` into Xcode
   - (This is the uniffi-generated glue code)

5. Set deployment target: **iOS 16.0**

6. Add `ios/.gitignore`:
```
WarpApp/Generated/
WarpIOSBridge.xcframework/
*.xcworkspace/xcuserdata/
*.xcodeproj/xcuserdata/
*.xcodeproj/project.xcworkspace/xcuserdata/
DerivedData/
```

---

## Phase 5 — Swift App Code

### `ios/WarpApp/Models/SSHHost.swift`

```swift
import Foundation

enum AuthMethod: Codable {
    case password
    case key(keychainTag: String)
}

struct SSHHost: Identifiable, Codable {
    let id: UUID
    var label: String
    var hostname: String
    var port: Int
    var username: String
    var authMethod: AuthMethod

    init(label: String, hostname: String, port: Int = 22,
         username: String, authMethod: AuthMethod) {
        self.id = UUID()
        self.label = label
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
    }
}

// UserDefaults persistence
extension SSHHost {
    static func loadAll() -> [SSHHost] {
        guard let data = UserDefaults.standard.data(forKey: "ssh_hosts"),
              let hosts = try? JSONDecoder().decode([SSHHost].self, from: data)
        else { return [] }
        return hosts
    }

    static func saveAll(_ hosts: [SSHHost]) {
        let data = try? JSONEncoder().encode(hosts)
        UserDefaults.standard.set(data, forKey: "ssh_hosts")
    }
}
```

### `ios/WarpApp/Services/KeychainService.swift`

```swift
import Foundation
import Security

enum KeychainService {
    static func saveKey(_ pem: String, tag: String) throws {
        let data = Data(pem.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: tag,
            kSecAttrService: "warp-ios-ssh-keys",
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func loadKey(tag: String) throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: tag,
            kSecAttrService: "warp-ios-ssh-keys",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let pem = String(data: data, encoding: .utf8)
        else { throw KeychainError.notFound }
        return pem
    }

    static func deleteKey(tag: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: tag,
            kSecAttrService: "warp-ios-ssh-keys",
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: Error {
        case saveFailed(OSStatus)
        case notFound
    }
}
```

### `ios/WarpApp/Services/SSHSession.swift`

```swift
import Foundation
import SwiftTerm

@MainActor
class SSHSession: ObservableObject {
    @Published var isConnected = false
    @Published var errorMessage: String?

    private var rustSession: WarpIosBridgeSshSession?  // uniffi type name may vary
    private weak var terminal: Terminal?

    func connect(host: SSHHost) async {
        do {
            switch host.authMethod {
            case .password:
                // Prompt for password — pass via SecureField in UI
                break
            case .key(let tag):
                let pem = try KeychainService.loadKey(tag: tag)
                rustSession = try await WarpIosBridgeSshSession.connectWithKey(
                    host: host.hostname,
                    port: UInt16(host.port),
                    username: host.username,
                    privateKeyPem: pem
                )
            }
            rustSession?.setReceiver(receiver: TerminalDataReceiver(terminal: terminal))
            isConnected = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send(_ data: Data) {
        Task {
            try? await rustSession?.sendData(data: Array(data))
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        Task {
            try? await rustSession?.resize(cols: cols, rows: rows)
        }
    }

    func disconnect() async {
        await rustSession?.disconnect()
        isConnected = false
    }
}

// Forwards incoming PTY bytes from Rust → SwiftTerm's Terminal object
class TerminalDataReceiver: WarpIosBridgeDataReceiver {
    weak var terminal: Terminal?
    init(terminal: Terminal?) { self.terminal = terminal }

    func onData(data: [UInt8]) {
        DispatchQueue.main.async {
            self.terminal?.feed(byteArray: data)
        }
    }

    func onDisconnect(reason: String) {
        DispatchQueue.main.async {
            // Optionally show disconnection notice in terminal
        }
    }
}
```

### `ios/WarpApp/Views/TerminalView.swift`

```swift
import SwiftUI
import SwiftTerm

struct TerminalView: UIViewRepresentable {
    @ObservedObject var session: SSHSession

    func makeUIView(context: Context) -> TerminalView {
        let tv = SwiftTerm.TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        // Wire up session → terminal data flow
        return tv
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    class Coordinator: NSObject, TerminalViewDelegate {
        let session: SSHSession
        init(session: SSHSession) { self.session = session }

        // SwiftTerm calls this when user types
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            session.send(Data(data))
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
```

### `ios/WarpApp/Views/HostListView.swift`

```swift
import SwiftUI

struct HostListView: View {
    @State private var hosts: [SSHHost] = SSHHost.loadAll()
    @State private var showingAddHost = false
    @State private var selectedHost: SSHHost?

    var body: some View {
        NavigationStack {
            List {
                ForEach(hosts) { host in
                    Button {
                        selectedHost = host
                    } label: {
                        VStack(alignment: .leading) {
                            Text(host.label).font(.headline)
                            Text("\(host.username)@\(host.hostname):\(host.port)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indexSet in
                    hosts.remove(atOffsets: indexSet)
                    SSHHost.saveAll(hosts)
                }
            }
            .navigationTitle("Warp")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAddHost = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingAddHost) {
                AddHostView { newHost in
                    hosts.append(newHost)
                    SSHHost.saveAll(hosts)
                }
            }
            .fullScreenCover(item: $selectedHost) { host in
                ConnectedTerminalView(host: host)
            }
        }
    }
}
```

### `ios/WarpApp/Views/AddHostView.swift`

```swift
import SwiftUI

struct AddHostView: View {
    var onSave: (SSHHost) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var useKey = false
    @State private var keyPEM = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("Label (e.g. My Server)", text: $label)
                    TextField("Hostname or IP", text: $hostname)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("Authentication") {
                    Toggle("Use SSH Key", isOn: $useKey)
                    if useKey {
                        TextEditor(text: $keyPEM)
                            .frame(minHeight: 120)
                            .font(.system(.caption, design: .monospaced))
                            .overlay(
                                Group {
                                    if keyPEM.isEmpty {
                                        Text("Paste private key PEM here")
                                            .foregroundStyle(.secondary)
                                            .padding(8)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    }
                                }
                            )
                    } else {
                        SecureField("Password", text: $password)
                    }
                }
            }
            .navigationTitle("New Host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(label.isEmpty || hostname.isEmpty || username.isEmpty)
                }
            }
        }
    }

    private func save() {
        let portNum = Int(port) ?? 22
        let auth: AuthMethod
        if useKey {
            let tag = UUID().uuidString
            try? KeychainService.saveKey(keyPEM, tag: tag)
            auth = .key(keychainTag: tag)
        } else {
            // For v1, password stored insecurely. TODO: move to Keychain.
            auth = .password
        }
        let host = SSHHost(label: label, hostname: hostname, port: portNum,
                           username: username, authMethod: auth)
        onSave(host)
        dismiss()
    }
}
```

### `ios/WarpApp/Views/ConnectedTerminalView.swift`

```swift
import SwiftUI

struct ConnectedTerminalView: View {
    let host: SSHHost
    @StateObject private var session = SSHSession()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if session.isConnected {
                VStack(spacing: 0) {
                    TerminalView(session: session)
                    KeyAccessoryBar(session: session)
                        .frame(height: 44)
                }
            } else {
                ProgressView("Connecting…").tint(.white).foregroundStyle(.white)
            }
        }
        .task { await session.connect(host: host) }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Disconnect") {
                    Task { await session.disconnect(); dismiss() }
                }
            }
        }
    }
}
```

### `ios/WarpApp/Views/KeyAccessoryBar.swift`

The terminal key toolbar — shown above the software keyboard.

```swift
import SwiftUI

struct KeyAccessoryBar: View {
    @ObservedObject var session: SSHSession
    @State private var ctrlActive = false

    private let functionKeys: [(label: String, bytes: [UInt8])] = [
        ("Esc",  [0x1B]),
        ("Tab",  [0x09]),
        ("↑",    [0x1B, 0x5B, 0x41]),
        ("↓",    [0x1B, 0x5B, 0x42]),
        ("←",    [0x1B, 0x5B, 0x44]),
        ("→",    [0x1B, 0x5B, 0x43]),
    ]

    var body: some View {
        HStack(spacing: 2) {
            // Ctrl modifier toggle
            Button {
                ctrlActive.toggle()
            } label: {
                Text("Ctrl")
                    .frame(minWidth: 44)
                    .padding(.vertical, 8)
                    .background(ctrlActive ? Color.accentColor : Color(UIColor.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Divider().frame(height: 28)

            ForEach(functionKeys, id: \.label) { key in
                Button {
                    session.send(Data(key.bytes))
                } label: {
                    Text(key.label)
                        .frame(minWidth: 36)
                        .padding(.vertical, 8)
                        .background(Color(UIColor.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .background(Color(UIColor.systemGray6))
        .font(.system(.footnote, design: .monospaced))
        .foregroundStyle(.primary)
    }
}
```

**Ctrl handling**: When `ctrlActive` is true and the user types a letter in SwiftTerm, intercept it in `Coordinator.send()` and transform the byte: `ctrl_byte = ascii_byte & 0x1F`.

### `ios/WarpApp/WarpApp.swift`

```swift
import SwiftUI

@main
struct WarpApp: App {
    var body: some Scene {
        WindowGroup {
            HostListView()
                .preferredColorScheme(.dark)
        }
    }
}
```

---

## Phase 6 — Keyboard UX Notes

- **Software keyboard**: `UIInputView` or SwiftTerm's built-in handling covers the main input. The `KeyAccessoryBar` above handles terminal-specific keys.
- **Hardware keyboard (iPad)**: SwiftTerm handles most keys natively. Override `UIKeyCommand` for F-keys and special combos if needed.
- **Ctrl+C**: Send `Data([0x03])` — kills foreground process.
- **Ctrl+Z**: Send `Data([0x1A])` — suspends to background.
- **Two-finger swipe**: SwiftTerm handles scroll natively.

---

## Phase 7 — TestFlight Prep

1. Set Bundle ID in Xcode: `com.kevintwingstrom.warp-ios`
2. Set version: `1.0.0` build `1`
3. **Product → Archive**
4. Xcode Organizer → **Distribute App → TestFlight**
5. No App Store review needed for personal TestFlight builds

---

## Verification Checklist

- [ ] `cargo check --target aarch64-apple-ios -p warp_ios_bridge` compiles without errors
- [ ] `bash scripts/build_ios_xcframework.sh` produces `ios/WarpIOSBridge.xcframework`
- [ ] Xcode builds for iPhone 16 simulator without errors
- [ ] Add a host in the app, tap it, connection screen appears
- [ ] SSH to a real server, run `ls` — output appears in terminal
- [ ] Run `top` — live output updates scroll correctly
- [ ] `Ctrl+C` (via key bar) kills the running process
- [ ] Resize works: rotate device, terminal reflows
- [ ] Hardware keyboard types through correctly on iPad
- [ ] Archive → TestFlight upload succeeds
- [ ] Install on physical device from TestFlight, repeat SSH test

---

## Known Gotchas

1. **uniffi async + Tokio**: Requires `features = ["tokio"]` on the uniffi crate and a Tokio runtime in the Rust layer. Do NOT use `#[tokio::main]` — create the runtime manually and store it in the `SshSession` struct so it lives as long as the session.

2. **Static library + cdylib**: For xcframework, you need `crate-type = ["staticlib"]`. The `cdylib` is only needed if you want a `.dylib` — for iOS you want static.

3. **`aarch64-apple-ios-sim` vs `x86_64-apple-ios`**: On Apple Silicon Macs, the simulator is `aarch64-apple-ios-sim`. On Intel Macs it's `x86_64-apple-ios`. The build script targets the M-series (arm64 sim). Adjust if on Intel.

4. **russh host key verification**: The default `russh` client rejects unknown host keys. For v1, you can use a permissive handler (`client::Handler::check_server_key` returning `Ok(true)`). For v2, implement proper known_hosts verification.

5. **Password auth storage**: The v1 plan stores passwords in-memory only (user re-enters on each connect). Moving passwords to Keychain is a v2 improvement.
