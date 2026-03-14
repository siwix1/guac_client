# Guac Client

A native macOS client for [Apache Guacamole](https://guacamole.apache.org/), replacing the browser-based remote desktop experience.

## Features

- Login with username/password and TOTP two-factor authentication
- Browse and search available remote connections
- Recently used connections appear at the top of the list
- Full remote desktop rendering with mouse and keyboard input
- Server URL and username remembered across launches
- Works with any Guacamole server (RDP, VNC, SSH connections)

## Requirements

- macOS 14+ (Apple Silicon and Intel)
- Swift 6.2+
- An Apache Guacamole server with WebSocket tunnel enabled

## Building

```bash
swift build
swift run
```

## How It Works

The app connects to a Guacamole server via its REST API for authentication and connection listing, then establishes a WebSocket tunnel using the Guacamole protocol. The remote display is rendered using CoreGraphics layers, with mouse and keyboard events forwarded as Guacamole protocol instructions.

### Architecture

| File | Purpose |
|------|---------|
| `GuacApp.swift` | App entry point and navigation |
| `LoginView.swift` | Login form (server URL, credentials, TOTP) |
| `ServerListView.swift` | Connection list with search and recents |
| `ConnectionView.swift` | Remote desktop view with RDP credential prompt |
| `AppState.swift` | Observable app state |
| `GuacamoleAPI.swift` | REST API client (auth, connection listing) |
| `GuacamoleTunnel.swift` | WebSocket tunnel management |
| `GuacamoleProtocol.swift` | Protocol parser and encoder |
| `GuacamoleDisplay.swift` | Layer-based display renderer |
| `RemoteDisplayView.swift` | NSView for rendering and input capture |
| `KeySymMapping.swift` | macOS keycode to X11 keysym mapping |
| `ConnectionSession.swift` | Ties tunnel, display, and view together |

## Roadmap

- [ ] Clipboard sync (copy/paste between local and remote)
- [ ] Dynamic resolution on window resize
- [ ] Auto-reconnect on connection drop
- [ ] Multiple sessions / tabs
- [ ] Fullscreen mode
- [ ] Custom cursor rendering (use server-provided cursor images)
- [ ] Dirty-rect rendering for better performance
- [ ] GPU-accelerated rendering (Metal/IOSurface)
- [ ] Audio playback support
- [ ] File transfer support
- [ ] VNC and SSH connection support testing

## License

MIT
