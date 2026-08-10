# MeshMonitor Chat for Emacs

Chat client for [MeshMonitor](https://github.com/Yeraze/meshmonitor) (Meshtastic) in Emacs, inspired by ERC and rcirc.

Requires Emacs 28.1 or later.

Connects directly to the [MeshMonitor REST API](https://meshmonitor.org/) using a Bearer token. No Meshtastic client or external libraries required.

## How it works

```
  LoRa Radio            MeshMonitor             Emacs
 +-----------+      +----------------+      +------------------+
 | Meshtastic|----->| Web server     |----->| meshmonitor-chat |
 |   Node    |<-----| REST API       |<-----| (this package)   |
 +-----------+      +----------------+      +------------------+
   Physical           Proxy + DB              Chat buffers
   device             (port 3000)             Polling / Send
```

1. A **Meshtastic node** sends and receives messages over LoRa radio.
2. **MeshMonitor** connects to the node (TCP/serial/BLE), caches messages in a database and exposes a REST API.
3. **meshmonitor-chat.el** talks to the REST API to list channels, fetch messages and send new ones.

## Buffers

### Welcome screen (`M-x meshmonitor-chat`)

```
  MeshMonitor Chat
  ══════════════════════════════════════

  Connection
  Server:    192.168.1.100:3000
  Version:   3.12.0
  Status:    Connected
  Node:      Hilltop Relay (!a1b2c3d4)
  Uptime:    3d 7h

  Statistics
  Nodes:     128
  Messages:  2450
  Channels:  3

  ──────────────────────────────────────

  [c] Channels          [n] Nodes
  [d] Direct Messages   [u] Unread
  [g] Refresh           [q] Quit

  ──────────────────────────────────────
```

### Channel list (`M-x meshmonitor-chat-channels`)

```
  ID  Name          Role
  0   LongFast      Primary
  1   HikingGroup   Secondary
  2   EmergNet      Secondary
```

### Node list (`M-x meshmonitor-chat-nodes`)

```
  Hops  Name                           Node ID         Last heard
  1     🟢 🔑 Hilltop Relay            !a1b2c3d4       5m
  1     🟢 🔑 Solar Node 7             !d4e5f6a7       12m
  2     🟢 BaseStation K9              !b8c9d0e1       now
  3     ⚫ 🔑 Mountain Peak            !f2a3b4c5       1h
  4     ⚫ River Bridge                !e6f7a8b9       3d
```

### Unread messages (`M-x meshmonitor-chat-unread`)

```
  Unread  Name                       Node ID         Last message
  3       Hilltop Relay              !a1b2c3d4       Are you there?
  1       River Bridge               !e6f7a8b9       New repeater is up
```

### Chat buffer (channel or DM)

```
[08:15] <Hilltop Relay> Good morning mesh!
  ↳ 👋 Solar Node 7, 👍 BaseStation K9
[08:20] <BaseStation K9> Morning! Signal is great today
[08:21] <Solar Node 7> Copy that, 3 hops from here
[08:45] <Mountain Peak> Anyone near the trailhead?
[09:02] <Hilltop Relay> I can see 12 nodes from up here
  ↳ 🔥 Mountain Peak, 👀 River Bridge
[09:05] <BaseStation K9> ↩ Hilltop Relay: Nice coverage!
[09:30] <River Bridge> Just set up a new repeater
[09:31] <Solar Node 7> ↩ River Bridge: Welcome aboard!
  ↳ 🎉 BaseStation K9
[09:33] <River Bridge> Thanks, running on solar
[09:41] <BaseStation K9> Testing now ·
[09:42] <BaseStation K9> Yes, confirmed ✓
#LongFast> _
```

## Features

- **Channel list**: browse available Meshtastic channels in a tabulated buffer.
- **Node list**: browse all mesh nodes sorted by hop count, with online indicator, key exchange status and last-heard time.
- **Unread messages**: list nodes with unread direct messages, with count and preview.
- **Direct messages**: list active DM conversations with other nodes.
- **Chat buffers**: read and send messages with an ERC-like prompt interface.
- **Delivery confirmation**: sent messages display `·` (pending), `✓` (confirmed) or `✗` (failed).
- **Resend**: place cursor on a failed message and press `C-c C-r` to resend.
- **Reply**: press `C-c C-r` on a message to reply to it. Replies show `↩ Name:` prefix.
- **Emoji reactions**: press `C-c C-e` on a message to react with an emoji. Reactions from others appear inline below the message.
- **Message info**: press `C-c C-i` on a message to open a buffer with its details (sender, channel, delivery state, hop count, SNR/RSSI and other radio metadata).
- **Traceroute**: press `t` on a node to send a traceroute.
- **Request position**: press `p` on a node to request its position.
- **Key exchange check**: DM is blocked for nodes without encryption keys (no PKC).
- **Desktop notifications**: get notified when new messages arrive in background buffers.
- **Polling**: automatic periodic fetch of new messages in open chat buffers. Auto-recovers after sleep/suspend.
- **Refresh**: press `C-c C-l` to reload the full message history in any chat buffer.
- **Input size indicator**: mode-line shows byte count with warnings for large messages (LoRa limit ~200 bytes per part, max 3 parts).
- **UTF-8 support**: correctly displays accented characters and emojis from mesh nodes.
- **Message deduplication**: avoids rendering the same message twice.
- **Input history**: navigate previous inputs with `M-p` / `M-n`.

## Keymap

### Channel / Node / DM list buffers

| Key   | Description                       |
|-------|-----------------------------------|
| `RET` | Open channel chat or DM with node |
| `0-7` | Open channel by number (channels) |
| `t`   | Send traceroute to node (nodes)   |
| `p`   | Request position from node (nodes)|
| `g`   | Refresh list from server          |
| `q`   | Quit buffer                       |

### Chat buffers

| Key   | Description                  |
|-------|------------------------------|
| `RET`     | Send message                 |
| `M-p`     | Previous input from history  |
| `M-n`     | Next input from history      |
| `C-c C-r` | Reply to message at point    |
| `C-c C-s` | Resend message at point      |
| `C-c C-e` | React with emoji at point    |
| `C-c C-i` | Show message info at point   |
| `C-c C-k` | Cancel reply                 |
| `C-c C-d` | Open DM with sender at point |
| `C-c C-l` | Reload message history        |

## Installation

### MELPA

```
M-x package-install RET meshmonitor-chat RET
```

### use-package with :vc (Emacs 29+)

```elisp
(use-package meshmonitor-chat
  :vc (:url "https://git.andros.dev/andros/meshmonitor-chat.el"
       :rev :newest)
  :config
  (setq meshmonitor-chat-host "192.168.1.100"
        meshmonitor-chat-port 3000
        meshmonitor-chat-token "mm_v1_your_token_here"))
```

### use-package with :load-path

For manual installation or Emacs < 29:

```elisp
(use-package meshmonitor-chat
  :load-path "/path/to/meshmonitor-chat.el"
  :config
  (setq meshmonitor-chat-host "192.168.1.100"
        meshmonitor-chat-port 3000
        meshmonitor-chat-token "mm_v1_your_token_here"))
```

### Manual

Clone the repository and place the files in a directory on your `load-path`:

```sh
git clone https://git.andros.dev/andros/meshmonitor-chat.el.git
```

Then add to your init file:

```elisp
(add-to-list 'load-path "/path/to/meshmonitor-chat.el")
(require 'meshmonitor-chat)
(setq meshmonitor-chat-host "192.168.1.100"
      meshmonitor-chat-port 3000
      meshmonitor-chat-token "mm_v1_your_token_here")
```

## Usage

1. Configure `meshmonitor-chat-host`, `meshmonitor-chat-port` and `meshmonitor-chat-token` in your init file.
2. Run `M-x meshmonitor-chat` to open the welcome screen with server status and shortcuts.
3. From there, press `c`, `n`, `d` or `u` to navigate to channels, nodes, DMs or unread.
4. Press `RET` on a channel or node to open the chat buffer.
5. Type your message and press `RET` to send.

Connection is established automatically on first use.

## Customization

Run `M-x customize-group RET meshmonitor-chat RET` to list all available options.

Key options:

- `meshmonitor-chat-host`: MeshMonitor server hostname or IP.
- `meshmonitor-chat-port` (default `3000`): server port.
- `meshmonitor-chat-token`: Bearer token for API authentication.
- `meshmonitor-chat-use-tls` (default `nil`): use HTTPS.
- `meshmonitor-chat-poll-interval` (default `10`): seconds between polling for new messages.
- `meshmonitor-chat-message-limit` (default `50`): number of messages to fetch per request.
- `meshmonitor-chat-timestamp-format` (default `"%H:%M"`): format for message timestamps.
- `meshmonitor-chat-notify` (default `t`): enable desktop notifications for new messages (via D-Bus).

Username/password authentication is also supported via `meshmonitor-chat-username` and `meshmonitor-chat-password` if no token is provided.

## API

This package uses the MeshMonitor REST API v1.  Since MeshMonitor 4.0 the
v1 endpoints are scoped under a per-source prefix `/api/v1/sources/<id>/`;
the source is configurable via `meshmonitor-chat-source-id` (default
`default`, which targets the first readable source):

- `GET /api/v1/sources/<id>/channels`: list channels.
- `GET /api/v1/sources/<id>/nodes`: list mesh nodes.
- `GET /api/v1/sources/<id>/messages`: fetch messages with filters.
- `POST /api/v1/sources/<id>/messages`: send messages.
- `GET /api/status`: connection and node info.

See the [MeshMonitor documentation](https://meshmonitor.org/) for details.

## Contributing

Contributions are welcome! Please see the [contribution guidelines](https://git.andros.dev/andros/contribute) for instructions on how to submit issues or pull requests.

## License

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program. If not, see [https://www.gnu.org/licenses/](https://www.gnu.org/licenses/).
