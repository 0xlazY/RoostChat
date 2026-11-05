# RoosterChat

A native SwiftUI XMPP client for iOS, in the spirit of Pidgin: several accounts, one
buddy list, a global status, and plain timestamped conversation logs.

## Features

- Multiple accounts, passwords stored in the Keychain
- Buddy list with groups, presence, aliases and authorization requests
- One-to-one chat with typing notifications and delivery receipts
- Group chat (XEP-0045): rooms, passwords, invitations, members, private messages
- Catches up after being suspended: stream resumption (XEP-0198), message archive (XEP-0313), carbons (XEP-0280)
- History stored on the device
- iMessage-style conversations with profile pictures (XEP-0084 and XEP-0153)
- Notifications while the app is running
- Status that never changes by itself, with a choice of available, away, do not disturb and more
- Custom server host and port, direct TLS, custom resource, and connect-on-launch per account
- Self-signed certificates, trusted on first use and pinned
- Image attachments, loaded on tap or automatically
- Connection diagnostics, a server capabilities pane and an optional, redacted debug log

## Limitations

- **No end-to-end encryption.** Messages are protected by TLS to the server, and the
  server can read them. OMEMO is possible later through MartinOMEMO.
- **No connection while suspended.** iOS suspends apps shortly after they leave the
  screen. The server then holds your session and status until its own time limit, after
  which contacts see you offline. Missed messages arrive when you reopen the app, and
  notifications only fire before the suspension, Push through a
  [self-hosted relay](relay/README.md) is written but off until it can be tested. It needs
  a paid developer account, and shows a generic "New Message" alert.
- **No sending files.** Links and images can be received, but not uploaded. No avatars or calls.
- **Buddy list needs a connection.** The roster is held in memory, so it's empty until
  the account connects.

## Build

The project has no committed `.xcodeproj`. It's generated from [project.yml](project.yml).

- **Remotely:** push to GitHub. [The Build workflow](.github/workflows/build.yml) produces an unsigned IPA.
- **On a Mac:** `brew install xcodegen && xcodegen generate && open RoostChat.xcodeproj`

Run the core tests on any OS that has Swift or Docker:

```sh
docker run --rm -v "$PWD/Packages/RoostChatCore:/src:ro" swift:6.1 \
  bash -c 'cp -r /src /tmp/p && cd /tmp/p && swift test'
```

To install the app on an iPhone, see [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).

## Layout

| Path | Contents |
| --- | --- |
| `Packages/RoostChatCore` | Platform-independent rules: message routing, address validation, backoff. Tested on Linux and macOS. |
| `RoostChat/XMPP` | Wrapper around the [Martin](https://github.com/tigase/Martin) library |
| `RoostChat/Model` | SwiftData storage |
| `RoostChat/Views` | SwiftUI screens |

## Licence

AGPL-3.0, because the app links the AGPL-licensed Martin library. Anyone you distribute
the app to is entitled to its source code. See [LICENSE](LICENSE).
