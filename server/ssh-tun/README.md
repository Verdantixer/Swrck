# SSH tunnel notes

The current app does not use this directory's legacy `swock-ssh-tun` helper.
SSH profiles now carry TCP connections through ordinary SSH
`direct-tcpip` channels and do not require a remote helper, root privileges, a
server-side TUN interface, or NAT rules.

The SSH account must be permitted to open TCP forwarding channels. If the
server restricts forwarding with `AllowTcpForwarding` or `PermitOpen`, allow
the destinations users need to reach. DNS uses TCP forwarding when UDPGW is
disabled.

## Optional UDP

To carry UDP through an SSH profile, install and run BadVPN's `badvpn-udpgw`
on the SSH server, bound to loopback (for example `127.0.0.1:7200`). Enable
**SSH UDP Gateway** in the app's Advanced Options and set the listener port.
The SSH account must be allowed to forward to `127.0.0.1:<port>`. Without this
optional service, SSH connections still carry TCP and DNS traffic, but other
UDP traffic is unavailable.

## App profile

Set the SSH server address and port, username, and password or private key.
Optionally pin the server's SHA-256 host-key fingerprint. The upstream proxy,
TLS SNI wrapper, and payload options control how the app reaches the SSH
server; they do not require any additional server helper.

The files alongside this note are retained for older app builds only.
