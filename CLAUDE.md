# CLAUDE.md

See `WARP.md` for existing desktop build/test/lint commands.

## iOS Client Project

This repo is being extended with a native iOS SSH terminal app. The goal is to bring Warp's SSH experience (eventually: block-structured output, AI completions) to iPhone and iPad as a personal TestFlight build.

### Architecture Overview

```
SwiftUI (universal iPhone + iPad)
  ↕ tap/keyboard input
SwiftTerm (Swift Package — ANSI rendering, VT100, keyboard handling)
  ↕ raw PTY bytes
SSHSession.swift (Swift wrapper)
  ↕ uniffi-rs generated Swift bindings
crates/warp_ios_bridge/   ← Rust crate (new)
  ↕ async SSH via russh (pure Rust, no C deps, iOS-safe)
Remote SSH server
```

**Why not the existing SSH code?** `crates/remote_server/src/ssh.rs` spawns the system `ssh` binary via subprocess. iOS sandboxing forbids process spawning and has no system `ssh`. We need a pure-Rust SSH implementation (`russh`).

**Why SwiftTerm for rendering?** It handles ANSI/VT100 parsing, glyph layout, and keyboard input out of the box. This lets v1 ship fast. Warp-specific block rendering is a v2 concern.

### Directory Layout (target state)

```
warp-ios/
├── CLAUDE.md                         ← this file
├── WARP.md                           ← existing desktop guidance
├── Cargo.toml                        ← add warp_ios_bridge to workspace members
├── crates/
│   └── warp_ios_bridge/              ← new Rust crate
│       ├── Cargo.toml
│       ├── build.rs
│       └── src/lib.rs
├── ios/
│   ├── PLAN.md                       ← detailed phase-by-phase plan
│   ├── Warp.xcodeproj/               ← created in Xcode
│   ├── WarpApp/
│   │   ├── WarpApp.swift
│   │   ├── Views/
│   │   │   ├── HostListView.swift
│   │   │   ├── AddHostView.swift
│   │   │   └── TerminalView.swift
│   │   ├── Services/
│   │   │   ├── KeychainService.swift
│   │   │   └── SSHSession.swift
│   │   ├── Models/
│   │   │   └── SSHHost.swift
│   │   └── Generated/                ← uniffi-generated Swift bindings (git-ignored)
│   └── WarpIOSBridge.xcframework     ← built by script (git-ignored)
└── scripts/
    └── build_ios_xcframework.sh      ← new build script
```

### iOS Build Commands

```bash
# One-time: install iOS Rust targets
rustup target add aarch64-apple-ios aarch64-apple-ios-sim

# Check the bridge crate compiles for iOS (no Xcode needed)
cargo check --target aarch64-apple-ios -p warp_ios_bridge

# Build the xcframework (device + simulator)
bash scripts/build_ios_xcframework.sh

# After xcframework is built, open the Xcode project
open ios/Warp.xcodeproj
```

### Key Dependencies

| Dependency | Version | Purpose |
|-----------|---------|---------|
| `russh` | 0.44 | Pure-Rust SSH client (iOS-safe, no C deps) |
| `russh-keys` | 0.44 | SSH key parsing and auth |
| `uniffi` | 0.28 | Rust → Swift bindings codegen |
| `tokio` | 1 | Async runtime for Rust SSH layer |
| SwiftTerm | latest | Swift terminal renderer (ANSI/VT100) |

### v1 Scope

**In scope:**
- SSH password + key auth
- Universal iPhone/iPad app
- ANSI terminal rendering via SwiftTerm
- SSH key storage in iOS Keychain
- Host bookmarks stored locally (UserDefaults)
- Software keyboard accessory bar (Esc, Tab, Ctrl, arrows)
- Hardware keyboard support (iPad)
- TestFlight distribution

**Out of scope (v2+):**
- Warp Drive host sync (uses `crates/graphql/`)
- Block-structured output UI (uses `crates/warp_terminal/`)
- AI completions
- Multiple panes/tabs
- Local shell (iOS sandbox forbids it)

### Gitignore Additions Needed

Add to `.gitignore` or `ios/.gitignore`:
```
ios/WarpApp/Generated/
ios/WarpIOSBridge.xcframework/
ios/*.xcworkspace/xcuserdata/
ios/*.xcodeproj/xcuserdata/
```
