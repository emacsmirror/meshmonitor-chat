# MeshMonitor Chat for Emacs

Chat client for [MeshMonitor](https://github.com/Yeraze/meshmonitor) (Meshtastic) in Emacs, inspired by ERC and rcirc.

Requires Emacs 28.1 or later.

Connects directly to the [MeshMonitor REST API](https://meshmonitor.org/) using a Bearer token. No Meshtastic client or external libraries required.

## Buffers

### Channel list (`M-x meshmonitor-chat-channels`)

```
  ID  Name          Role
  0   MediumFast    Primary
  1   Iberia        Secondary
  2   Valencia      Secondary
```

### Node list (`M-x meshmonitor-chat-nodes`)

```
  Hops  Name                           Node ID         Last heard
  1     Massimo 66 T114 Denia          !0cfbd0fe       2h
  1     RAY1 Solar                     !17639644       5m
  2     LinceTango                     !acaba0c4       now
  3     EA5iso-v4                      !9e9d5524       1h
  4     Zona-Castellon                 !f125d5b2       3d
```

### Chat buffer (channel or DM)

```
[21:54] <EA5iso-v4> Buenas noches
[21:54] <MobyDick Station> Buenas noches!!
[21:55] <30rojo4> Buenas noches desde ontinyent
[21:55] <Paterna> Buenas noches
[21:58] <lorakotick nktk> Buenas noches. Catarroja
[22:00] <EA5iso-v4> Que bien cuanta peña
[22:01] <lorakotick nktk> Me gusta ver que LoRa esta viva. Muy viva
[23:03] <MikeLima> Ya toca dormir. Buenas noches
[07:52] <LinceTango> Buenos dias comunidad mesh!
[08:03] <JL EA5KAE> Vamos con la semana
[08:07] <LinceTango> Va a ser dura?
[08:07] <LinceTango> Hola a todos ✓
#Valencia> _
```

## Features

- **Channel list**: browse available Meshtastic channels in a tabulated buffer.
- **Node list**: browse all mesh nodes sorted by hop count, with last-heard time.
- **Direct messages**: list active DM conversations with other nodes.
- **Chat buffers**: read and send messages with an ERC-like prompt interface.
- **Delivery confirmation**: sent messages display `·` (pending), `✓` (confirmed) or `✗` (failed).
- **Polling**: automatic periodic fetch of new messages in open chat buffers.
- **Input size indicator**: mode-line shows byte count with warnings for large messages (LoRa limit ~200 bytes per part, max 3 parts).
- **UTF-8 support**: correctly displays accented characters and emojis from mesh nodes.
- **Message deduplication**: avoids rendering the same message twice.
- **Input history**: navigate previous inputs with `M-p` / `M-n`.

## Keymap

### Channel / Node / DM list buffers

| Key   | Description                       |
|-------|-----------------------------------|
| `RET` | Open channel chat or DM with node |
| `g`   | Refresh list from server          |
| `q`   | Quit buffer                       |

### Chat buffers

| Key   | Description                  |
|-------|------------------------------|
| `RET` | Send message                 |
| `M-p` | Previous input from history  |
| `M-n` | Next input from history      |

## Installation

### MELPA

    M-x package-install RET meshmonitor-chat RET

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
2. Run one of the available commands:
   - `M-x meshmonitor-chat-channels` to browse channels.
   - `M-x meshmonitor-chat-nodes` to list all nodes sorted by hops.
   - `M-x meshmonitor-chat-direct-messages` to list DM conversations.
3. Press `RET` on a channel or node to open the chat buffer.
4. Type your message and press `RET` to send.

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

Username/password authentication is also supported via `meshmonitor-chat-username` and `meshmonitor-chat-password` if no token is provided.

## API

This package uses the MeshMonitor REST API v1:

- `GET /api/v1/channels`: list channels.
- `GET /api/v1/nodes`: list mesh nodes.
- `GET /api/v1/messages`: fetch messages with filters.
- `POST /api/v1/messages`: send messages.
- `GET /api/status`: connection and node info.

See the [MeshMonitor documentation](https://meshmonitor.org/) for details.

## Contributing

Contributions are welcome! Please see the [contribution guidelines](https://git.andros.dev/andros/contribute) for instructions on how to submit issues or pull requests.

## License

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program. If not, see [https://www.gnu.org/licenses/](https://www.gnu.org/licenses/).
