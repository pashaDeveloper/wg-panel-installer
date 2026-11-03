#!/usr/bin/env bash
# Launcher for the repository-owned UDP2RAW / FEC source.
set -Eeuo pipefail
umask 077
[[ $EUID == 0 ]] || { printf 'Run as root.\n' >&2; exit 1; }
directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$directory"
case "$(uname -m)" in
  x86_64) architecture=amd64 ;;
  aarch64) architecture=arm64 ;;
  *) printf 'Unsupported architecture.\n' >&2; exit 1 ;;
esac
apt-get update
apt-get install -y ca-certificates curl wget git tar cron
# Keep the upstream compiler version in this install's own directory.
# Do not overwrite /usr/local/go or source/modify the administrator's profile.
if [[ ! -x toolchain/go/bin/go ]]; then
  archive=$(mktemp "$directory/go.XXXXXXXX.tar.gz")
  trap 'rm -f -- "$archive"' EXIT
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "https://go.dev/dl/go1.21.5.linux-$architecture.tar.gz" -o "$archive"
  mkdir -p toolchain
  tar -xzf "$archive" -C toolchain
  rm -f -- "$archive"
  trap - EXIT
fi
export PATH="$directory/toolchain/go/bin:$PATH"
install -m 0700 udp2raw-logo.sh /etc/udp2raw-logo.sh
# Keep the module separate from the toolchain and its Go test fixtures.
# Rewrite direct requirements so retries also repair interrupted installations.
mkdir -p "$directory/build"
install -m 0600 udp2raw.go "$directory/build/udp2raw.go"
install -m 0600 manage.go "$directory/build/manage.go"
cd "$directory/build"
cat >go.mod <<'GOMOD'
module wg-panel-udp2raw-fec

go 1.21

require (
  github.com/AlecAivazis/survey/v2 v2.3.7
  github.com/fatih/color v1.16.0
)
GOMOD
export GOWORK=off
go mod tidy
go build -o "$directory/udp2raw-menu" udp2raw.go manage.go
# Upstream downloads relative to the working directory, but its systemd units
# use absolute /root/udp paths. Preserve that working directory at runtime.
cd /root
exec "$directory/udp2raw-menu"
