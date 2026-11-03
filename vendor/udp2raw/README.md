# UDP2RAW / FEC

Open the panel installer, then choose **5. WireGuard UDP tunnels → 1. UDP2RAW / FEC**.
This directory contains the menu source (`udp2raw.go`), its launcher (`run.sh`),
port management (`manage.go`), and its logo (`udp2raw-logo.sh`). The installer loads these files from this
repository, including when running as a standalone downloaded script.
The existing panel-managed UDP2RAW integration remains at tunnel option 7.

Runtime files live in `/opt/wg-panel-udp2raw-fec`. The launcher installs an
isolated Go toolchain and builds the local source. The menu runs from `/root`
to match its `/root/udp` systemd service paths. Dependencies and tunnel binaries
still download from their upstream providers; no remote menu script is executed.

Commit and push this directory together with `public-installer/install.sh`
before using the standalone installer on a server.

## Source attribution

Adapted from https://github.com/Azumi67/UDP2RAW_FEC at revision
`215e9f9d885820e737da1d3746b4f2635c724147`, the implementation invoked by
option 6 of opiran-club/pf-tun. The original MIT license is included in LICENSE.
The source and logo files have been renamed; the logo path in the Go source
has been adjusted accordingly. The original downloader is replaced by the
local launcher with an isolated compiler/module directory and pinned direct
Go dependencies. The menu adds options 8 (add ports using an existing template)
and 9 (edit existing ports), preserving credentials, raw mode and remote hosts.
Paired FEC services are updated together; failed applies restore prior files
and running states. Configure matching ports on the other server and update
firewall rules and client endpoints as needed. Scheduled reset scripts are
left unchanged; add new unit names to `/etc/udp.sh` if using scheduled resets.

Run `test-management.sh` in a disposable `golang:1.21.5` container to check
port remapping, IPv4/IPv6, duplicate ports, rollback, menu routing and compilation.
