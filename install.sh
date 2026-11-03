#!/usr/bin/env bash
# Installer maintained in the main panel repository. Never embed private keys.
set -Eeuo pipefail
set +x
umask 077

readonly PANEL_REPOSITORY='pashaDeveloper/wg-pasha-master'

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ask() {
  local value
  printf '%s' "$2" >/dev/tty
  IFS= read -r value </dev/tty || fail 'Input cancelled.'
  printf -v "$1" '%s' "$value"
}
secret() {
  printf '%s' "$2" >/dev/tty
  IFS= read -rs "$1" </dev/tty || fail 'Input cancelled.'
  printf '\n' >/dev/tty
}
valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 )); }
env_line() {
  # Compose single quotes prevent $ interpolation; escape literal quotes.
  local value=${2//\'/\\\'}
  printf "%s='%s'\n" "$1" "$value"
}

install_dependencies() {
  # shellcheck disable=SC1091
  source /etc/os-release
  case "$ID" in ubuntu|debian) ;; *) fail 'Supported servers: Ubuntu or Debian.' ;; esac
  command -v systemctl >/dev/null || fail 'A systemd server is required.'
  printf 'Updating package lists and upgrading server packages before panel installation...\n'
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold
  apt-get install -y ca-certificates curl git openssh-client iproute2 util-linux
  if ! command -v docker >/dev/null; then
    if { dpkg-query -W -f='${Status}\n' docker.io containerd podman-docker 2>/dev/null || true; } | grep -q 'install ok installed'; then
      fail 'Existing container packages detected. Install Docker Engine and the Compose plugin first; no packages were removed.'
    fi
    install -m 0755 -d /etc/apt/keyrings
    curl --fail --silent --show-error --location "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/wg-panel-docker.asc
    chmod 0644 /etc/apt/keyrings/wg-panel-docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/wg-panel-docker.asc] https://download.docker.com/linux/%s %s stable\n' \
      "$(dpkg --print-architecture)" "$ID" "${UBUNTU_CODENAME:-$VERSION_CODENAME}" >/etc/apt/sources.list.d/wg-panel-docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  docker compose version >/dev/null || fail 'Install the Docker Compose plugin, then rerun.'
  systemctl enable --now docker
  docker info >/dev/null || fail 'Docker daemon is unavailable.'
}

prepare_key() {
  local pubkey registered
  key_file="$config_dir/deploy_key"
  if [[ ! -e $key_file ]]; then
    ssh-keygen -q -t ed25519 -N '' -C 'wg-panel-deploy' -f "$key_file"
  fi
  chmod 0600 "$key_file"
  pubkey=$(ssh-keygen -y -P '' -f "$key_file") || fail "Use an unencrypted deploy key. Replace $key_file and rerun."
  # Pinned GitHub host key, from GitHub SSH fingerprint documentation.
  printf '%s\n' 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' >"$config_dir/known_hosts"
  export GIT_SSH_COMMAND="ssh -F /dev/null -i $key_file -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$config_dir/known_hosts -o HostKeyAlgorithms=ssh-ed25519"
  if git ls-remote "git@github.com:$repository.git" HEAD >/dev/null 2>&1; then
    printf 'Deploy Key access verified. Continuing installation.\n'
    return
  fi
  printf '\nAdd this PUBLIC key to https://github.com/%s/settings/keys\n' "$repository"
  printf 'Settings > Deploy keys > Add deploy key. Leave Allow write access OFF.\n\n\033[1;31m%s\033[0m\n\n' "$pubkey"
  while true; do
    ask registered '[C] Copy public key | [Enter] Check GitHub access | [Q] Cancel: '
    case "$registered" in
      c|C)
        # OSC 52 asks the SSH client's terminal to copy to the local clipboard.
        # Only the PUBLIC key is sent; terminals may disable this feature.
        printf '\033]52;c;%s\007' "$(printf '%s' "$pubkey" | base64 | tr -d '\r\n')" >/dev/tty
        printf 'Copy requested. If your terminal blocks clipboard access, select and copy this PUBLIC key manually:\n%s\n' "$pubkey"
        continue
        ;;
      q|Q) printf 'Cancelled.\n'; exit 130 ;;
      '') ;;
      *) printf 'Invalid option. Use C, Enter or Q.\n'; continue ;;
    esac
    if git ls-remote "git@github.com:$repository.git" HEAD >/dev/null; then
      break
    fi
    printf 'ERROR: GitHub access failed. Check the read-only Deploy Key, repository and SSH port 22. Fix the problem, then press Enter to retry here.\n' >&2
  done
}

# Keep published WireGuard ports out of the host's automatic source-port pool.
# A subshell releases its reservation lock on every return/error.
reserve_panel_ports() (
  local first last
  first=${1:-$(setting WG_PORT)}
  last=${2:-$(setting WG_PORT_END || setting WG_PORT)}
  valid_port "$first" && valid_port "$last" && (( first <= last )) || fail 'Invalid WireGuard port range; reservation was not changed.'
  command -v python3 >/dev/null || { apt-get update; apt-get install -y python3; }
  exec 15>/var/lock/wg-panel-ports.lock
  flock -x 15
  python3 - "$first" "$last" <<'RESERVE_PORTS_PY'
import os
from pathlib import Path
import re
import sys
import tempfile


def parse_ports(value):
    result = []
    for part in value.strip().split(','):
        if not part:
            continue
        match = re.fullmatch(r'(\d+)(?:-(\d+))?', part.strip())
        if not match:
            raise ValueError('Invalid existing reserved-port list')
        first, last = int(match[1]), int(match[2] or match[1])
        if not 1 <= first <= last <= 65535:
            raise ValueError('Invalid existing reserved-port interval')
        result.append((first, last))
    return result


def merge_ports(intervals):
    merged = []
    for first, last in sorted(intervals):
        if merged and first <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], last))
        else:
            merged.append((first, last))
    return merged


def serialize(intervals):
    return ','.join(str(a) if a == b else str(a) + '-' + str(b) for a, b in intervals)


def reserve(first, last, kernel=Path('/proc/sys/net/ipv4/ip_local_reserved_ports'),
            config=Path('/etc/sysctl.d/99-wg-panel-reserved-ports.conf'),
            ephemeral=Path('/proc/sys/net/ipv4/ip_local_port_range')):
    if not 1 <= first <= last <= 65535:
        raise ValueError('Invalid WireGuard port range')
    if config.is_symlink() or config.parent.is_symlink():
        raise ValueError('Unsafe reserved-port configuration path')
    current = parse_ports(kernel.read_text())
    persistent = []
    if config.exists():
        for line in config.read_text().splitlines():
            key, sep, value = line.partition('=')
            if sep and key.strip() == 'net.ipv4.ip_local_reserved_ports':
                persistent += parse_ports(value.split('#', 1)[0])
    merged = merge_ports(current + persistent + [(first, last)])
    low, high = map(int, ephemeral.read_text().split())
    if any(a <= low and b >= high for a, b in merged):
        raise ValueError('Reservation would exhaust the automatic source-port pool')
    value = serialize(merged)
    content = '# WireGuard panel ports; preserve other host reservations.\nnet.ipv4.ip_local_reserved_ports = ' + value + '\n'
    if config.exists() and config.read_text() == content:
        if merge_ports(current) != merged:
            kernel.write_text(value + '\n')
        return value
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', dir=config.parent, prefix='.wg-panel-ports-', delete=False) as file:
            temporary = Path(file.name)
            file.write(content)
            file.flush()
            os.fsync(file.fileno())
        temporary.chmod(0o644)
        if merge_ports(current) != merged:
            kernel.write_text(value + '\n')
        os.replace(temporary, config)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()
    return value


if __name__ == '__main__':
    try:
        ports = reserve(int(sys.argv[1]), int(sys.argv[2]))
        print('Host reserved ports (persistent): ' + ports)
    except (OSError, ValueError) as error:
        sys.exit('Could not reserve WireGuard ports before starting the panel: ' + str(error))
RESERVE_PORTS_PY
)

write_runtime_wrapper() {
  [[ -f $config_dir/runtime.compose.yml ]] || fail 'Standalone runtime configuration is missing.'
  [[ $config_dir == /etc/wg-panel && ! -L $config_dir && ! -L $config_dir/compose && ! -L $config_dir/reserve-ports ]] || fail 'Unsafe runtime wrapper path.'
  {
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nconfig_dir=/etc/wg-panel\n'
    declare -f fail valid_port setting reserve_panel_ports
    printf '\nreserve_panel_ports "$@"\n'
  } >"$config_dir/reserve-ports"
  chmod 0700 "$config_dir/reserve-ports"
  cat >"$config_dir/compose" <<'RUNTIME_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
cd /etc/wg-panel
case "${1:-}" in
  up|start|restart) /etc/wg-panel/reserve-ports ;;
esac
exec docker compose --project-name wg-panel --env-file /etc/wg-panel/panel.env -f runtime.compose.yml "$@"
RUNTIME_WRAPPER
  chmod 0700 "$config_dir/compose"
}

configure_firewall() {
  reserve_panel_ports "$wg_port" "$wg_end"
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw allow "$panel_port/tcp"
    ufw allow "$wg_port:$wg_end/udp"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$panel_port/tcp"
    firewall-cmd --permanent --add-port="$wg_port-$wg_end/udp"
    firewall-cmd --add-port="$panel_port/tcp"
    firewall-cmd --add-port="$wg_port-$wg_end/udp"
  fi
  printf 'Cloud/provider firewall: allow TCP %s and UDP %s-%s.\n' "$panel_port" "$wg_port" "$wg_end"
}

detect_public_ip() {
  local address service octet
  local -a octets
  for service in https://api.ipify.org https://checkip.amazonaws.com; do
    address=$(curl -4fsS --connect-timeout 5 --max-time 10 "$service") || continue
    [[ $address =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || continue
    IFS=. read -r -a octets <<<"$address"
    for octet in "${octets[@]}"; do
      (( 10#$octet <= 255 )) || continue 2
    done
    printf '%s' "$address"
    return
  done
  return 1
}

prepare_runtime() {
  # Preserve Compose variables so later panel.env port changes still work.
  sed '/^    build: \.$/d' "$install_dir/docker-compose.private.yml" >"$config_dir/runtime.compose.yml"
  if grep -Eq '^[[:space:]]*build:' "$config_dir/runtime.compose.yml"; then
    fail 'Unsupported Compose build section; cannot create standalone runtime configuration.'
  fi
  chmod 0600 "$config_dir/runtime.compose.yml"
  write_runtime_wrapper
  "$config_dir/compose" config --quiet
}

cleanup_source() {
  [[ $install_dir == /opt/wg-panel && ! -L /opt && ! -L $install_dir ]] || fail 'Source cleanup safety check failed.'
  rm -rf -- /opt/wg-panel || return $?
  printf 'Downloaded source folder removed. Runtime configuration and panel data were kept.\n'
}

install_panel() (
  [[ ${EUID} == 0 ]] || fail 'Run with sudo bash install.sh.'
  [[ -r /dev/tty ]] || fail 'Run from an interactive SSH terminal.'
  config_dir=/etc/wg-panel
  install_dir=/opt/wg-panel
  [[ ! -L /opt && ! -L $install_dir ]] || fail 'Unsafe panel source directory.'
  finish_panel_install() {
    local result=$?
    trap - EXIT
    if [[ -e $install_dir || -L $install_dir ]]; then
      if ! cleanup_source; then
        printf 'ERROR: Panel source cleanup failed: %s\n' "$install_dir" >&2
        (( result != 0 )) || result=1
      fi
    fi
    exit "$result"
  }
  trap finish_panel_install EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  exec 8> /var/lock/wg-panel-install.lock
  flock -n 8 || { trap - EXIT; fail 'Another panel installation is running.'; }
  if [[ -x $config_dir/compose && -f $config_dir/panel.env && ( -f $config_dir/runtime.compose.yml || -f $install_dir/docker-compose.private.yml ) ]]; then
    printf 'Existing installation found. Downloading the latest source and reinstalling with the saved settings.\n'
    if [[ ! -f $config_dir/runtime.compose.yml ]]; then
      # A previous build may have failed. Preserve its deployment settings,
      # but never build its stale checkout again.
      prepare_runtime
    fi
    local reinstall_port saved_panel_port
    saved_panel_port=$(setting PANEL_PORT)
    ask reinstall_port "Panel TCP port [$saved_panel_port]: "
    reinstall_port=${reinstall_port:-$saved_panel_port}
    valid_port "$reinstall_port" || fail 'Port must be 1-65535.'
    if [[ $reinstall_port != "$saved_panel_port" ]] && ss -H -ltn "sport = :$reinstall_port" | grep -q .; then
      fail 'Panel TCP port is already in use.'
    fi
    update_panel --reinstall
    if [[ $reinstall_port != "$saved_panel_port" ]]; then
      # Apply through the existing port-change path so HTTPS and rollback are
      # handled consistently, including recovery when no image existed before.
      edit_panel_port "$reinstall_port"
    fi
    return
  fi
  [[ ! -e $install_dir ]] || fail "$install_dir contains an incomplete installation. Check it before retrying."
  printf 'Private WireGuard panel installer — Ubuntu / Debian\n'
  repository=$PANEL_REPOSITORY
  branch=''
  printf 'Private repository: %s (default branch)\n' "$repository"
  [[ $repository =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ && $repository != */.. && $repository != */. ]] || fail 'Use OWNER/REPO, not a URL.'
  [[ -z $branch || ( $branch != -* && $branch != *[[:space:]]* ) ]] || fail 'Invalid branch/tag.'
  ask panel_port 'Panel TCP port [51821]: '
  panel_port=${panel_port:-51821}
  valid_port "$panel_port" || fail 'Port must be 1-65535.'
  install_dependencies
  endpoint=$(detect_public_ip) || fail 'Could not detect public IPv4. Check outbound HTTPS and retry.'
  printf 'Detected server address: %s\n' "$endpoint"
  wg_port=51820
  wg_end=51920
  reserve_panel_ports "$wg_port" "$wg_end"
  if ss -H -ltn "sport = :$panel_port" | grep -q .; then fail 'Panel TCP port is already in use.'; fi
  install -d -m 0700 "$config_dir"
  prepare_key
  local -a clone_args=(--depth 1)
  [[ -z $branch ]] || clone_args+=(--branch "$branch")
  git clone "${clone_args[@]}" "git@github.com:$repository.git" "$install_dir"
  [[ -f $install_dir/docker-compose.private.yml && -f $install_dir/src/launcher.mjs ]] || fail 'The private repository is missing deployment files. Commit and push the panel changes first.'
  {
    env_line PANEL_PORT "$panel_port"
    env_line INIT_HOST "$endpoint"
    env_line WG_PORT "$wg_port"
    env_line WG_PORT_END "$wg_end"
  } >"$config_dir/panel.env"
  chmod 0600 "$config_dir/panel.env"
  # Save an independent runtime before building: cleanup must also work on failure.
  prepare_runtime
  git -C "$install_dir" config core.sshCommand "$GIT_SSH_COMMAND"
  docker compose --project-name wg-panel --env-file "$config_dir/panel.env" \
    -f "$install_dir/docker-compose.private.yml" build --build-arg "PANEL_REVISION=$(git -C "$install_dir" rev-parse HEAD)"
  setup_updater
  configure_firewall
  "$config_dir/compose" up -d --force-recreate --wait --wait-timeout 180
  local code attempt
  for ((attempt = 0; attempt < 30; attempt++)); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$panel_port/") || code=000
    case "$code" in 200|302|303|307|308)
      printf '\nInstalled: http://%s:%s/\n' "$endpoint" "$panel_port"
      printf 'Open this address to create your administrator account and complete setup.\n'
      printf 'WireGuard setup: server address %s, UDP port %s.\n' "$endpoint" "$wg_port"
      printf 'Manage: sudo /etc/wg-panel/compose ps\nLogs: sudo /etc/wg-panel/compose logs --tail 100\n'
      return 0 ;;
    esac
    sleep 2
  done
  fail 'Container started, but the panel did not respond. Run sudo /etc/wg-panel/compose logs --tail 100.'
)

require_panel() {
  [[ -x $config_dir/compose && -f $config_dir/panel.env ]] || fail 'Install the panel first (option 1).'
}

restart_panel() (
  require_panel
  exec 9>"$config_dir/update.lock"
  flock -n 9 || fail 'An update or edit is already running.'
  if [[ ! -f $config_dir/runtime.compose.yml ]]; then
    [[ -f $install_dir/docker-compose.private.yml ]] || fail 'Panel runtime configuration is missing.'
    prepare_runtime
  fi
  reserve_panel_ports
  write_runtime_wrapper
  printf 'Restarting the panel. VPN connections may briefly disconnect.\n'
  # Remove only this service's container, never its named data volume.
  # Explicit teardown releases its published ports before creating a new one.
  "$config_dir/compose" stop --timeout 30 wg-easy
  "$config_dir/compose" rm --force wg-easy
  if ! "$config_dir/compose" up -d --no-build --pull never --force-recreate --wait --wait-timeout 180 wg-easy; then
    "$config_dir/compose" ps --all || true
    "$config_dir/compose" logs --tail 50 wg-easy || true
    printf 'UDP sockets in the configured WireGuard range:\n'
    local first last
    first=$(setting WG_PORT)
    last=$(setting WG_PORT_END || setting WG_PORT)
    if valid_port "$first" && valid_port "$last"; then
      ss -H -uanp "sport >= :$first and sport <= :$last" || true
    fi
    fail 'Panel restart failed. Its old container was removed. Ports owned by other services were not changed; review the error and socket owners above.'
  fi
  if [[ -f $config_dir/ssl/compose.yml ]]; then
    ssl_compose up -d --pull never --force-recreate
  fi
  "$config_dir/compose" ps
  printf 'Panel restarted. Settings and VPN data were kept.\n'
)

setting() {
  # Read only simple, non-secret fields written by this installer; never source dotenv.
  local entry
  entry=$(grep -m1 "^$1=" "$config_dir/panel.env") || return 1
  entry=${entry#*=}
  entry=${entry#\'}
  entry=${entry%\'}
  printf '%s' "$entry"
}

ssl_compose() {
  docker compose --project-name wg-panel-ssl -f "$config_dir/ssl/compose.yml" "$@"
}

valid_domain() {
  [[ ${#1} -le 253 && $1 == *.* && $1 != *..* && ! $1 =~ ^[0-9.]+$ && $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

receive_ssl() {
  require_panel
  local domain ready port code attempt
  port=$(setting PANEL_PORT)
  valid_port "$port" || fail 'Invalid PANEL_PORT in panel.env.'
  [[ $port != 80 && $port != 443 ]] || fail 'Move the panel HTTP port away from 80/443 before enabling SSL.'
  ask domain 'Domain pointing to this server (example: panel.example.com): '
  valid_domain "$domain" || fail 'Enter a DNS domain without a scheme, port or path.'
  printf 'Point the domain A record (and any AAAA record) to this server. Allow inbound TCP 80 and 443 in the provider firewall.\n'
  ask ready 'DNS and firewall ready? Type YES to continue: '
  [[ $ready == YES ]] || { printf 'Cancelled.\n'; return; }
  if [[ ! -f $config_dir/ssl/compose.yml ]]; then
    for port in 80 443; do
      if ss -H -ltn "sport = :$port" | grep -q .; then fail "TCP $port is occupied. Existing web services were not changed."; fi
    done
  fi
  port=$(setting PANEL_PORT)
  install -d -m 0700 "$config_dir/ssl"
  printf '%s {\n  reverse_proxy 127.0.0.1:%s {\n    header_up X-Real-IP {http.request.remote.host}\n  }\n}\n' "$domain" "$port" >"$config_dir/ssl/Caddyfile"
  cat >"$config_dir/ssl/compose.yml" <<'SSL'
services:
  caddy:
    image: caddy:2
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
volumes:
  caddy_data:
  caddy_config:
SSL
  ssl_compose run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw allow 80/tcp
    ufw allow 443/tcp
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    for port in 80 443; do
      firewall-cmd --permanent --add-port="$port/tcp"
      firewall-cmd --add-port="$port/tcp"
    done
  fi
  ssl_compose up -d --force-recreate
  printf '%s\n' "$domain" >"$config_dir/ssl/domain"
  printf 'Waiting for a trusted HTTPS certificate...\n'
  for ((attempt = 0; attempt < 30; attempt++)); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$domain:443:127.0.0.1" --max-time 5 "https://$domain/") || code=000
    case "$code" in 200|302|303|307|308)
      printf 'HTTPS ready: https://%s/ (use your saved panel path, if changed).\nCertificates renew automatically while Caddy runs.\n' "$domain"
      return ;;
    esac
    sleep 2
  done
  printf 'HTTPS is not ready. Check DNS, inbound 80/443 and these logs:\n'
  ssl_compose logs --tail 30
  fail 'Certificate or upstream verification failed. Fix the issue and retry Edit > HTTPS certificate.'
}

subscription_proxy_compose() {
  docker compose --project-name wg-subscription-proxy -f /etc/wg-subscription-proxy/compose.yml "$@"
}

# Only validated, normalized values reach the generated Caddyfile.
subscription_proxy_config() {
  python3 - "$@" <<'SUBSCRIPTION_PY'
import ipaddress, json, re, sys
from urllib.parse import urlsplit

def base_path(value):
    value = value.strip()
    if value in ('', '/'):
        return '/'
    if len(value) > 128 or not re.fullmatch(r'/?[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*/?', value):
        raise ValueError('Use a base path such as / or /private/.')
    return '/' + value.strip('/') + '/'

try:
    domain, upstream, public_path, directory = sys.argv[1:]
    domain = domain.strip().lower()
    labels = domain.split('.')
    if len(domain) > 253 or len(labels) < 2 or any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label) for label in labels):
        raise ValueError('Enter a DNS domain without scheme, port or path.')
    try:
        ipaddress.ip_address(domain)
    except ValueError:
        pass
    else:
        raise ValueError('Automatic public HTTPS setup requires a DNS domain.')
    url = urlsplit(upstream.strip())
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment:
        raise ValueError('Enter the HTTPS panel base URL, without credentials, query or subscription token.')
    # Restrict to literal IPs or safe DNS names, never Caddyfile syntax.
    host = url.hostname
    try:
        ipaddress.ip_address(host)
    except ValueError:
        if not all(re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', label) for label in host.split('.')):
            raise ValueError('Invalid upstream hostname.')
    if host.lower() == domain:
        raise ValueError('Use a separate subscription domain, not the upstream panel domain.')
    port = url.port
    if port is not None and not 1 <= port <= 65535:
        raise ValueError('Invalid upstream port.')
    panel_path = base_path(url.path)
    public_path = base_path(public_path) if public_path.strip() else panel_path
    # Reserved paths cannot be used as subscription entry aliases.
    if public_path.strip('/').split('/')[0] in ('api', 'sub', '_nuxt', '_i18n', 'admin', 'login'):
        raise ValueError('Choose a non-reserved public base path, for example /vpn/.')
    authority = ('[' + host + ']') if ':' in host else host
    if port:
        authority += ':' + str(port)
    origin = 'https://' + authority
    # Keep browser routing/assets on the panel base path, on the Iran origin.
    alias = ''
    if public_path != panel_path:
        alias = f'''  @entry path_regexp entry ^{re.escape(public_path)}sub/([0-9]+)/([a-f0-9]{{32}})/?$
  redir @entry {panel_path}sub/{{re.entry.1}}/{{re.entry.2}} 302
'''
    page = re.escape(panel_path) + r'sub/[0-9]+/[a-f0-9]{32}/?'
    api = re.escape(panel_path) + r'api/sub/[0-9]+/[a-f0-9]{32}/(?:info|configuration|qrcode\.svg)'
    asset = re.escape(panel_path) + r'(?:_nuxt|_i18n)/(?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*'
    # The subscription page currently requests /api/sub from the origin root.
    root_api = ''
    if panel_path != '/':
        root_api = f'''  @rootApi {{
    method GET HEAD
    path_regexp rootapi ^/api/sub/[0-9]+/[a-f0-9]{{32}}/(info|configuration|qrcode\\.svg)$
  }}
  handle @rootApi {{
    rewrite * {panel_path.rstrip('/')}{{uri}}
    reverse_proxy {origin} {{
      header_up Host {authority}
      header_up -Cookie
      header_up -Authorization
      header_down -Set-Cookie
      header_down Cache-Control "no-store"
    }}
  }}
'''
    caddy = f'''{{
  admin off
}}
{domain} {{
  header Referrer-Policy "no-referrer"
  respond /__wg_subscription_health "wg-subscription-proxy" 200
{alias}  @subscription {{
    method GET HEAD
    path_regexp subscription ^(?:{page}|{api}|{asset})$
  }}
  handle @subscription {{
    reverse_proxy {origin} {{
      header_up Host {authority}
      header_up -Cookie
      header_up -Authorization
      header_down -Set-Cookie
      header_down Cache-Control "no-store"
    }}
  }}
{root_api}  handle {{
    respond "Not found" 404
  }}
}}
'''
    from pathlib import Path
    target = Path(directory)
    (target / 'Caddyfile.next').write_text(caddy)
    values = dict(domain=domain, upstream=origin + panel_path, origin='https://' + domain, path=public_path, panelPath=panel_path)
    (target / 'settings.next.json').write_text(json.dumps(values) + '\n')
except (ValueError, OSError) as error:
    sys.exit(str(error))
SUBSCRIPTION_PY
}

subscription_proxy_values() {
  python3 -c 'import json; s=json.load(open("/etc/wg-subscription-proxy/settings.json")); print("Subscription origin: " + s["origin"]); print("Subscription base path: " + s["path"]); print("Outside panel: " + s["upstream"]); print("Set General > Alternate subscription links to enabled, then paste the origin and base path above. Existing links remain valid.")'
}

setup_subscription_proxy() (
  local domain upstream public_path port directory=/etc/wg-subscription-proxy attempt body code
  [[ ! -L $directory ]] || fail 'Unsafe subscription proxy directory.'
  if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then install_dependencies; fi
  if ! command -v python3 >/dev/null || ! command -v curl >/dev/null || ! command -v ss >/dev/null; then
    apt-get update
    apt-get install -y python3 curl ca-certificates iproute2
  fi
  docker info >/dev/null || fail 'Start Docker before setting up the subscription proxy.'
  printf '\nRun this on the Iran entry server. No panel installation is needed here.\nSet a subscription domain A record to this server, correct/remove any unrelated AAAA record, and allow provider TCP 80/443.\n'
  ask domain 'Subscription domain (example: sub.example.com): '
  ask upstream 'Outside panel HTTPS base URL including its panel path (example: https://panel.example.com/private/): '
  ask public_path 'Public subscription base path (Enter = same as panel; example /vpn/): '
  install -d -m 0700 "$directory"
  for port in Caddyfile Caddyfile.next settings.json settings.next.json compose.yml; do
    [[ ! -L $directory/$port ]] || fail 'Unsafe subscription proxy configuration path.'
  done
  subscription_proxy_config "$domain" "$upstream" "$public_path" "$directory"
  domain=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$directory/settings.next.json")
  upstream=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["upstream"])' "$directory/settings.next.json")
  getent ahosts "$domain" >/dev/null || fail 'Subscription DNS is not resolving yet. Set its DNS record, wait, then retry.'
  code=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --connect-timeout 10 --max-time 20 "$upstream") || fail 'The Iran server cannot reach the HTTPS panel or verify its certificate. Fix that connection first.'
  case "$code" in 200|301|302|303|307|308) ;; *) fail "Outside panel returned HTTP $code. Check its base URL and path." ;; esac
  if [[ ! -f $directory/compose.yml ]] || [[ -z $(subscription_proxy_compose ps --status running -q) ]]; then
    for port in 80 443; do
      if ss -H -ltn "sport = :$port" | grep -q .; then fail "TCP $port is occupied. Existing web services were not changed. Use a separate entry server or configure that web server manually."; fi
    done
  fi
  # Validate the candidate before replacing any running configuration.
  docker pull caddy:2
  docker run --rm --network host -v "$directory/Caddyfile.next:/etc/caddy/Caddyfile:ro" caddy:2 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  cat >"$directory/compose.yml" <<'SUBSCRIPTION_COMPOSE'
services:
  caddy:
    image: caddy:2
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
volumes:
  caddy_data:
  caddy_config:
SUBSCRIPTION_COMPOSE
  if [[ -f $directory/Caddyfile ]]; then cp -p "$directory/Caddyfile" "$directory/Caddyfile.previous"; fi
  if [[ -f $directory/settings.json ]]; then cp -p "$directory/settings.json" "$directory/settings.previous.json"; fi
  mv -f "$directory/Caddyfile.next" "$directory/Caddyfile"
  mv -f "$directory/settings.next.json" "$directory/settings.json"
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw allow 80/tcp
    ufw allow 443/tcp
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    for port in 80 443; do firewall-cmd --permanent --add-port="$port/tcp"; firewall-cmd --add-port="$port/tcp"; done
  fi
  if ! subscription_proxy_compose up -d --force-recreate; then
    if [[ -f $directory/Caddyfile.previous && -f $directory/settings.previous.json ]]; then
      cp -p "$directory/Caddyfile.previous" "$directory/Caddyfile"
      cp -p "$directory/settings.previous.json" "$directory/settings.json"
      subscription_proxy_compose up -d --force-recreate || true
    fi
    fail 'Proxy could not start; previous configuration restored when available.'
  fi
  printf 'Waiting for automatic HTTPS issuance (up to 2 minutes)...\n'
  for ((attempt = 0; attempt < 24; attempt++)); do
    body=$(curl --silent --resolve "$domain:443:127.0.0.1" --connect-timeout 2 --max-time 3 "https://$domain/__wg_subscription_health") || body=''
    if [[ $body == wg-subscription-proxy ]]; then
      printf 'Subscription HTTPS is ready. Certificates renew automatically.\n'
      subscription_proxy_values
      printf 'Copy a real client link after saving the panel settings and verify its info, configuration download and QR.\n'
      return
    fi
    sleep 2
  done
  fail 'HTTPS is not ready. The proxy remains installed and retries issuance automatically. Fix DNS/provider TCP 80/443, then use Subscription proxy > Check HTTPS. Do not enable the panel option yet.'
)

subscription_proxy_check() {
  local domain body
  [[ -f /etc/wg-subscription-proxy/settings.json ]] || fail 'Subscription proxy is not configured.'
  domain=$(python3 -c 'import json; print(json.load(open("/etc/wg-subscription-proxy/settings.json"))["domain"])')
  body=$(curl --fail --silent --show-error --max-time 15 "https://$domain/__wg_subscription_health") || fail 'Public HTTPS check failed. Check DNS, provider firewall and proxy logs.'
  [[ $body == wg-subscription-proxy ]] || fail 'The domain is not serving this subscription proxy.'
  printf 'Public subscription HTTPS verified.\n'
  subscription_proxy_values
}

subscription_proxy_menu() {
  local selection
  while true; do
    printf '\nSubscription proxy (run on Iran server)\n1. Automatic setup / edit\n2. Status and panel settings\n3. Check public HTTPS\n4. Start/restart\n5. Disable (keep certificates and settings)\n6. Logs\nb) Back\n'
    ask selection 'Select: '
    case "$selection" in
      1) run_action setup_subscription_proxy ;;
      2) [[ -f /etc/wg-subscription-proxy/compose.yml ]] && { subscription_proxy_values; subscription_proxy_compose ps; } || printf 'Not configured.\n' ;;
      3) run_action subscription_proxy_check ;;
      4) [[ -f /etc/wg-subscription-proxy/compose.yml ]] && subscription_proxy_compose up -d --force-recreate || printf 'Not configured or start failed.\n' ;;
      5) [[ -f /etc/wg-subscription-proxy/compose.yml ]] && subscription_proxy_compose down || printf 'Not configured or stop failed.\n' ;;
      6) [[ -f /etc/wg-subscription-proxy/compose.yml ]] && subscription_proxy_compose logs --tail 40 || printf 'Not configured.\n' ;;
      b|B) return ;;
      *) printf 'Invalid option.\n' ;;
    esac
  done
}

panel_information() {
  require_panel
  printf 'Repository: %s\n' "$PANEL_REPOSITORY"
  printf 'HTTP address: http://%s:%s/\n' "$(setting INIT_HOST)" "$(setting PANEL_PORT)"
  printf 'Administrator accounts are managed in the panel. On a fresh installation, open the panel to create the first account.\n'
  printf 'WireGuard UDP ports: %s-%s\n' "$(setting WG_PORT)" "$(setting WG_PORT_END || setting WG_PORT)"
  if [[ -f $config_dir/ssl/domain ]]; then
    printf 'Configured HTTPS address: https://%s/\n' "$(cat "$config_dir/ssl/domain")"
    ssl_compose ps
  fi
  printf 'Use the saved panel path if changed. Passwords and private keys are not displayed.\n'
  "$config_dir/compose" ps
}

remove_panel() {
  require_panel
  local confirmation purge
  ask confirmation 'Stop and remove panel containers? Type REMOVE to confirm: '
  [[ $confirmation == REMOVE ]] || { printf 'Cancelled.\n'; return; }
  ask purge 'Also permanently delete all users, settings, certificates, source and Deploy Key? Type DELETE DATA, or Enter to keep data: '
  if [[ $purge == 'DELETE DATA' ]]; then
    [[ $config_dir == /etc/wg-panel && $install_dir == /opt/wg-panel && ! -L $config_dir && ! -L $install_dir ]] || fail 'Unexpected installation paths.'
    if [[ -f /etc/systemd/system/wg-panel-apply.path ]]; then
      systemctl disable --now wg-panel-apply.path
      systemctl stop wg-panel-apply.service
      rm -f /etc/systemd/system/wg-panel-apply.path /etc/systemd/system/wg-panel-apply.service
    fi
    if [[ -f /etc/systemd/system/wg-panel-update.path ]]; then
      if [[ -f /etc/systemd/system/wg-panel-update-check.timer ]]; then
        systemctl disable --now wg-panel-update-check.timer
        systemctl stop wg-panel-update-check.service
        rm -f /etc/systemd/system/wg-panel-update-check.timer /etc/systemd/system/wg-panel-update-check.service
      fi
      systemctl disable --now wg-panel-update.path
      systemctl stop wg-panel-update.service
      rm -f /etc/systemd/system/wg-panel-update.path /etc/systemd/system/wg-panel-update.service
      systemctl daemon-reload
    fi
    if [[ -f $config_dir/ssl/compose.yml ]]; then ssl_compose down --volumes; fi
    "$config_dir/compose" down --volumes
    if [[ -f /etc/systemd/system/wg-panel-metrics.service ]]; then
      systemctl disable --now wg-panel-metrics.service
      rm -f /etc/systemd/system/wg-panel-metrics.service
      systemctl daemon-reload
      [[ ! -L /var/lib/wg-panel-metrics ]] || fail 'Unsafe host metrics directory.'
      rm -rf -- /var/lib/wg-panel-metrics
    fi
    rm -rf -- /opt/wg-panel /etc/wg-panel
    printf 'Panel and its data removed. Remove its Deploy Key entry in GitHub if no longer needed.\n'
  else
    if [[ -f $config_dir/ssl/compose.yml ]]; then ssl_compose down; fi
    "$config_dir/compose" down
    printf 'Containers removed. Data and settings kept. Option 1 starts the panel again; Edit > HTTPS certificate starts HTTPS.\n'
  fi
  printf 'Docker and shared firewall rules were kept.\n'
}

edit_panel_port() (
  require_panel
  local panel_port old_port backup wg_port wg_end
  old_port=$(setting PANEL_PORT)
  if [[ -n ${1:-} ]]; then panel_port=$1; else ask panel_port "Panel TCP port [$old_port]: "; fi
  panel_port=${panel_port:-$old_port}
  valid_port "$panel_port" || fail 'Port must be 1-65535.'
  if [[ $panel_port != "$old_port" ]] && ss -H -ltn "sport = :$panel_port" | grep -q .; then fail 'Panel TCP port is already in use.'; fi
  if [[ -f $config_dir/ssl/compose.yml ]]; then
    [[ $panel_port != 80 && $panel_port != 443 ]] || fail 'Ports 80 and 443 are reserved for HTTPS.'
  fi
  exec 9>"$config_dir/update.lock"
  flock -n 9 || fail 'An update or edit is already running.'
  backup=$(mktemp "$config_dir/panel.env.backup.XXXXXXXX")
  cp -p "$config_dir/panel.env" "$backup"
  wg_port=$(setting WG_PORT)
  wg_end=$(setting WG_PORT_END || setting WG_PORT)
  configure_firewall
  sed -i "s/^PANEL_PORT=.*/PANEL_PORT='$panel_port'/" "$config_dir/panel.env"
  if ! "$config_dir/compose" config --quiet || ! "$config_dir/compose" up -d --force-recreate --wait --wait-timeout 180; then
    cp -p "$backup" "$config_dir/panel.env"
    "$config_dir/compose" up -d --force-recreate --wait --wait-timeout 180 || true
    fail "Port change failed; previous settings restored. Backup: $backup"
  fi
  printf 'Panel port changed to %s. Settings backup: %s\n' "$panel_port" "$backup"
  if [[ -f $config_dir/ssl/compose.yml ]]; then
    cp -p "$config_dir/ssl/Caddyfile" "$config_dir/ssl/Caddyfile.backup"
    sed -i "s/127[.]0[.]0[.]1:$old_port\\b/127.0.0.1:$panel_port/g" "$config_dir/ssl/Caddyfile"
    if ! ssl_compose run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile || ! ssl_compose up -d --force-recreate; then
      cp -p "$config_dir/ssl/Caddyfile.backup" "$config_dir/ssl/Caddyfile"
      cp -p "$backup" "$config_dir/panel.env"
      "$config_dir/compose" up -d --force-recreate --wait --wait-timeout 180 || true
      ssl_compose up -d --force-recreate || true
      fail 'Reverse proxy reload failed; previous settings restored.'
    fi
  fi
)

apply_panel_settings() (
  config_dir=/etc/wg-panel
  local requested_port
  mv "$config_dir/update-control/apply-request" "$config_dir/update-control/apply-running"
  trap 'rm -f -- "$config_dir/update-control/apply-running"' EXIT
  IFS= read -r requested_port <"$config_dir/update-control/apply-running"
  valid_port "$requested_port" || fail 'Invalid requested panel port.'
  edit_panel_port "$requested_port"
)

edit_panel() {
  require_panel
  local edit_choice
  while true; do
    printf '\n1. Change panel port\n2. HTTPS certificate\n3. Panel information\nb) Back\n'
    ask edit_choice 'Select an edit: '
    case "$edit_choice" in
      1) run_action edit_panel_port ;;
      2) run_action receive_ssl ;;
      3) run_action panel_information ;;
      b|B) return ;;
      *) printf 'Invalid option.\n' ;;
    esac
  done
}

setup_host_metrics() (
  local candidate script_directory staging metrics_directory=/var/lib/wg-panel-metrics
  [[ $config_dir == /etc/wg-panel && ! -L $config_dir && ! -L $metrics_directory ]] || fail 'Unsafe host metrics directory.'
  command -v python3 >/dev/null || { apt-get update; apt-get install -y python3; }
  install -d -m 0700 "$config_dir" "$metrics_directory"
  for candidate in "$config_dir/metrics-agent.py" "$metrics_directory/history.sqlite" "$metrics_directory/latest.json" /etc/systemd/system/wg-panel-metrics.service; do
    [[ ! -L $candidate ]] || fail 'Unsafe host metrics file.'
  done
  staging=$(mktemp -d)
  trap 'rm -rf -- "$staging"' EXIT
  script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  candidate=''
  if [[ -n ${source_dir:-} && -f $source_dir/public-installer/metrics-agent.py ]]; then
    candidate="$source_dir/public-installer/metrics-agent.py"
  elif [[ -f $install_dir/public-installer/metrics-agent.py ]]; then
    candidate="$install_dir/public-installer/metrics-agent.py"
  elif [[ -f $script_directory/metrics-agent.py ]]; then
    candidate="$script_directory/metrics-agent.py"
  fi
  if [[ -n $candidate ]]; then
    cp -- "$candidate" "$staging/agent.py"
  else
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
      "https://raw.githubusercontent.com/pashaDeveloper/wg-panel-installer/main/metrics-agent.py?fresh=$(date +%s)" -o "$staging/agent.py"
  fi
  python3 - "$staging/agent.py" <<'VALIDATE_METRICS'
import ast, sys
from pathlib import Path
ast.parse(Path(sys.argv[1]).read_text())
VALIDATE_METRICS
  install -C -m 0700 "$staging/agent.py" "$config_dir/metrics-agent.py"
  cat >"$staging/metrics.service" <<'METRICS_SERVICE'
[Unit]
Description=Lightweight host metrics for WireGuard panel graphs
After=local-fs.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 -u /etc/wg-panel/metrics-agent.py
Restart=on-failure
RestartSec=10
TimeoutStopSec=10
UMask=0077
Nice=10
MemoryMax=64M
CPUQuota=5%
TasksMax=16
NoNewPrivileges=true
CapabilityBoundingSet=
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX
ReadWritePaths=/var/lib/wg-panel-metrics
[Install]
WantedBy=multi-user.target
METRICS_SERVICE
  install -C -m 0644 "$staging/metrics.service" /etc/systemd/system/wg-panel-metrics.service
  if ! grep -q '/var/lib/wg-panel-metrics:/run/wg-panel-metrics:ro' "$config_dir/runtime.compose.yml"; then
    sed -i '/^    volumes:$/a\      - /var/lib/wg-panel-metrics:/run/wg-panel-metrics:ro' "$config_dir/runtime.compose.yml"
  fi
  systemctl daemon-reload
  systemctl enable wg-panel-metrics.service
  systemctl restart wg-panel-metrics.service
  systemctl is-active --quiet wg-panel-metrics.service || fail 'Host metrics collector did not start.'
)

setup_updater() {
  write_runtime_wrapper
  setup_host_metrics
  install -d -m 0700 "$config_dir/update-control" "$config_dir/backups"
  local script_path
  script_path=$(readlink -f "${BASH_SOURCE[0]}")
  if [[ $script_path != "$config_dir/updater.sh" ]]; then
    install -m 0700 "$script_path" "$config_dir/updater.sh.new"
    mv -f "$config_dir/updater.sh.new" "$config_dir/updater.sh"
  fi
  if [[ -f $config_dir/runtime.compose.yml ]] && ! grep -q '/run/wg-panel-update' "$config_dir/runtime.compose.yml"; then
    grep -q '^    volumes:$' "$config_dir/runtime.compose.yml" || fail 'Unsupported runtime Compose file.'
    sed -i '/^    volumes:$/a\      - /etc/wg-panel/update-control:/run/wg-panel-update' "$config_dir/runtime.compose.yml"
  fi
  if [[ -f $config_dir/runtime.compose.yml ]] && ! grep -q 'PANEL_PORT_OVERRIDE:' "$config_dir/runtime.compose.yml"; then
    sed -i '/^      PANEL_PUBLISHED_PORT:/a\      PANEL_PORT_OVERRIDE: ${PANEL_PORT:-51821}' "$config_dir/runtime.compose.yml"
  fi
  cat >/etc/systemd/system/wg-panel-apply.service <<'APPLYSERVICE'
[Unit]
Description=Apply WireGuard panel settings
After=docker.service
Requires=docker.service
[Service]
Type=oneshot
ExecStartPre=/bin/sleep 2
ExecStart=/bin/bash /etc/wg-panel/updater.sh --apply-settings
TimeoutStartSec=240
UMask=0077
StandardOutput=append:/etc/wg-panel/apply.log
StandardError=append:/etc/wg-panel/apply.log
APPLYSERVICE
  cat >/etc/systemd/system/wg-panel-apply.path <<'APPLYPATH'
[Unit]
Description=Watch for WireGuard panel settings
[Path]
PathExists=/etc/wg-panel/update-control/apply-request
Unit=wg-panel-apply.service
[Install]
WantedBy=multi-user.target
APPLYPATH
  cat >/etc/systemd/system/wg-panel-update.service <<'SERVICE'
[Unit]
Description=Update private WireGuard panel
After=docker.service network-online.target
Requires=docker.service
[Service]
Type=oneshot
ExecStart=/bin/bash /etc/wg-panel/updater.sh --update-worker
TimeoutStartSec=infinity
UMask=0077
StandardOutput=append:/etc/wg-panel/update.log
StandardError=append:/etc/wg-panel/update.log
SERVICE
  cat >/etc/systemd/system/wg-panel-update.path <<'PATHUNIT'
[Unit]
Description=Watch for WireGuard panel update requests
[Path]
PathExists=/etc/wg-panel/update-control/request
Unit=wg-panel-update.service
[Install]
WantedBy=multi-user.target
PATHUNIT
  cat >/etc/systemd/system/wg-panel-update-check.service <<'CHECKSERVICE'
[Unit]
Description=Check private WireGuard panel source revision
After=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash /etc/wg-panel/updater.sh --check-update
TimeoutStartSec=45
UMask=0077
CHECKSERVICE
  cat >/etc/systemd/system/wg-panel-update-check.timer <<'CHECKTIMER'
[Unit]
Description=Check for WireGuard panel updates periodically
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
CHECKTIMER
  systemctl daemon-reload
  systemctl enable --now wg-panel-update.path wg-panel-update-check.timer wg-panel-apply.path
  printf 'enabled\n' >"$config_dir/update-control/apply-enabled"
  systemctl start --no-block wg-panel-update-check.service
  printf 'enabled\n' >"$config_dir/update-control/enabled"
}

check_panel_update() (
  config_dir=/etc/wg-panel
  export GIT_SSH_COMMAND="ssh -F /dev/null -i $config_dir/deploy_key -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$config_dir/known_hosts -o HostKeyAlgorithms=ssh-ed25519"
  local remote revision latest_file
  remote=$(git ls-remote "git@github.com:$PANEL_REPOSITORY.git" HEAD) || {
    rm -f "$config_dir/update-control/latest.json"
    return 1
  }
  revision=${remote%%$'\t'*}
  [[ $revision =~ ^[a-f0-9]{40,64}$ ]] || return 1
  latest_file=$(mktemp "$config_dir/update-control/.latest.XXXXXXXX")
  printf '{"revision":"%s","checkedAt":"%s"}\n' "$revision" "$(date -u +%FT%TZ)" >"$latest_file"
  mv -f "$latest_file" "$config_dir/update-control/latest.json"
)

update_status() {
  # Only fixed states and a validated Git revision are written; never expose logs.
  local status_file
  status_file=$(mktemp "$config_dir/update-control/.status.XXXXXXXX")
  printf '{"state":"%s","revision":"%s","updatedAt":"%s"}\n' "$1" "${revision:-unknown}" "$(date -u +%FT%TZ)" >"$status_file"
  mv -f "$status_file" "$config_dir/update-control/status.json"
}

check_wireguard_update_routes() {
  # Inspect the running version before stopping it. Never silently replace a
  # WireGuard user's proxy egress with direct routing when removing that core.
  local -a route_command=("$config_dir/compose" exec -T wg-easy node)
  if [[ -n ${1:-} ]]; then
    route_command=(docker run --rm -i --entrypoint node --mount "type=volume,src=$2,dst=/etc/wireguard,readonly" "$1")
  fi
  "${route_command[@]}" --input-type=module <<'ROUTECHECK'
import { readFile } from 'node:fs/promises';
let settings;
try {
  settings = JSON.parse(await readFile('/etc/wireguard/outbound-routing.json', 'utf8'));
} catch (error) {
  if (error.code === 'ENOENT') process.exit(0);
  throw error;
}
if (!Array.isArray(settings.rules) || !Array.isArray(settings.outbounds) || typeof settings.enabled !== 'boolean') {
  throw new Error('Cannot verify saved routing settings. Existing panel was not stopped.');
}
if (settings.enabled && settings.rules.some(rule => {
  if (!/^wg\d{1,5}$/.test(rule.inbound) || rule.outbound === null) return false;
  const outbound = settings.outbounds.find(entry => entry.id === rule.outbound);
  return !outbound || !['wireguard', 'openvpn'].includes(outbound.protocol);
})) {
  throw new Error('Update blocked: WireGuard users depend on a proxy core removed in this version. In the current panel, migrate these routes to WireGuard/OpenVPN or explicitly select direct routing, then retry. Existing panel was not stopped.');
}
ROUTECHECK
}

# Recover a failed first installation (or a removed container) using the newly
# cloned checkout. The caller holds update.lock. Existing volumes are backed up.
resume_panel_install() (
  local source_dir=$1 revision=$2 old_image='' new_image volume backup_dir='' snapshot=0 switched=0
  finish_reinstall() {
    local result=$?
    trap - EXIT
    if (( result != 0 )); then
      if (( switched )); then
        "$config_dir/compose" stop || true
        if (( snapshot )); then
          docker run --rm --entrypoint sh --mount "type=volume,src=$volume,dst=/data" --mount "type=bind,src=$backup_dir,dst=/backup,readonly" "$new_image" -c 'test -d /backup/wireguard && find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && cp -a /backup/wireguard/. /data/' || printf 'Restore failed. Keep the panel stopped; backup: %s\n' "$backup_dir"
        fi
        cp -p "$backup_dir/runtime.compose.yml" "$config_dir/runtime.compose.yml"
      fi
      if [[ -n $old_image ]]; then docker tag "$old_image" pasha-forever-wireguard:local || true; fi
      if [[ -n $backup_dir ]]; then
        printf 'Reinstallation failed. Settings and any existing data backup: %s\n' "$backup_dir"
      else
        printf 'Reinstallation failed before starting the panel; saved settings and data were kept.\n'
      fi
    fi
    exit "$result"
  }
  trap finish_reinstall EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  old_image=$(docker image inspect --format '{{.Id}}' pasha-forever-wireguard:local 2>/dev/null) || old_image=''
  if [[ -n $old_image ]]; then docker tag "$old_image" pasha-forever-wireguard:rollback; fi
  docker build --build-arg "PANEL_REVISION=$revision" -t pasha-forever-wireguard:local "$source_dir"
  new_image=$(docker image inspect --format '{{.Id}}' pasha-forever-wireguard:local)
  # Compose resolves the existing volume name, including explicit custom names.
  volume=$("$config_dir/compose" config --format json | docker run --rm -i --entrypoint node "$new_image" -e 'let input="";for await(const chunk of process.stdin)input+=chunk;const config=JSON.parse(input);const mount=config.services["wg-easy"].volumes.find(entry=>entry.target==="/etc/wireguard"&&entry.type==="volume");if(!mount)process.exit(1);const name=config.volumes[mount.source]?.name;if(!name)process.exit(1);process.stdout.write(name);')
  [[ $volume =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || fail 'Reinstallation requires the named WireGuard data volume.'
  backup_dir=$(mktemp -d "$config_dir/backups/reinstall-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")
  cp -p "$config_dir/runtime.compose.yml" "$config_dir/panel.env" "$backup_dir/"
  if docker volume inspect "$volume" >/dev/null 2>&1; then
    check_wireguard_update_routes "$new_image" "$volume" || fail 'Saved WireGuard routes require the previous proxy runtime.'
    docker run --rm --entrypoint sh --mount "type=volume,src=$volume,dst=/data,readonly" --mount "type=bind,src=$backup_dir,dst=/backup" "$new_image" -c 'mkdir -p /backup/wireguard && cp -a /data/. /backup/wireguard/'
    snapshot=1
  fi
  switched=1
  sed -i '/XRAY_PORT_START.*XRAY_PORT_END/d' "$config_dir/runtime.compose.yml"
  setup_updater
  local panel_port wg_port wg_end
  panel_port=$(setting PANEL_PORT)
  wg_port=$(setting WG_PORT)
  wg_end=$(setting WG_PORT_END || setting WG_PORT)
  configure_firewall
  "$config_dir/compose" up -d --force-recreate --wait --wait-timeout 180
  "$config_dir/compose" exec -T wg-easy node --input-type=module -e 'import {applyPanelSettings,readPanelSettings} from "/app/launcher.mjs";applyPanelSettings(readPanelSettings("/etc/wireguard/wg-easy.db"),process.env);const http=await import(process.env.PANEL_TLS_ACTIVE === "true"?"node:https":"node:http");const r=http.get({hostname:"127.0.0.1",port:process.env.PORT,path:process.env.NUXT_APP_BASE_URL,rejectUnauthorized:false},res=>process.exit([200,301,302,303,307,308].includes(res.statusCode)?0:1));r.setTimeout(10000,()=>{r.destroy();process.exit(1)});r.on("error",()=>process.exit(1));'
  printf 'Latest panel installed from %s. Settings backup: %s\n' "$revision" "$backup_dir"
)

update_panel() (
  [[ ${EUID} == 0 ]] || fail 'Run with sudo bash install.sh.'
  config_dir=/etc/wg-panel
  install_dir=/opt/wg-panel
  require_panel
  command -v flock >/dev/null || fail 'Install util-linux first.'
  install -d -m 0700 "$config_dir/update-control" "$config_dir/backups"
  exec 9>"$config_dir/update.lock"
  flock -n 9 || { printf 'An update is already running.\n'; return 0; }
  reserve_panel_ports
  local source_dir='' revision=unknown old_image='' volume='' backup_dir='' stopped=0 switched=0
  finish_update() {
    local result=$?
    trap - EXIT
    if (( result != 0 )); then
      if [[ -n $old_image ]]; then docker tag "$old_image" pasha-forever-wireguard:local || true; fi
      if (( stopped )); then
        if (( switched )); then
          if "$config_dir/compose" stop && docker run --rm --entrypoint sh --mount "type=volume,src=$volume,dst=/data" --mount "type=bind,src=$backup_dir,dst=/backup,readonly" "$old_image" -c 'test -d /backup/wireguard && find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && cp -a /backup/wireguard/. /data/'; then
            docker tag "$old_image" pasha-forever-wireguard:local
            cp -p "$backup_dir/runtime.compose.yml" "$config_dir/runtime.compose.yml"
            "$config_dir/compose" up -d --force-recreate --wait --wait-timeout 180 || true
          else
            printf 'Automatic restore failed. Backup: %s. Keep the panel stopped and restore manually.\n' "$backup_dir"
          fi
        else
          "$config_dir/compose" start || true
        fi
      fi
      update_status failed
      printf 'Update failed. Review /etc/wg-panel/update.log and backups in /etc/wg-panel/backups.\n'
    fi
    rm -f "$config_dir/update-control/request"
    if [[ $source_dir == /opt/wg-panel-update.* && -d $source_dir && ! -L $source_dir ]]; then rm -rf -- "$source_dir"; fi
    exit "$result"
  }
  trap finish_update EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  update_status running
  [[ -f $config_dir/runtime.compose.yml ]] || fail 'Finish the initial installation before updating.'
  [[ -f $config_dir/deploy_key && -f $config_dir/known_hosts ]] || fail 'The saved GitHub Deploy Key or known_hosts file is missing.'
  export GIT_SSH_COMMAND="ssh -F /dev/null -i $config_dir/deploy_key -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$config_dir/known_hosts -o HostKeyAlgorithms=ssh-ed25519"
  source_dir=$(mktemp -d /opt/wg-panel-update.XXXXXXXX)
  git clone --depth 1 "git@github.com:$PANEL_REPOSITORY.git" "$source_dir"
  revision=$(git -C "$source_dir" rev-parse HEAD)
  [[ $revision =~ ^[a-f0-9]{40,64}$ ]] || fail 'Invalid source revision.'
  printf 'Downloaded source revision: %s\n' "$revision"
  # The installer and panel source are maintained in the same repository.
  local required_file
  for required_file in Dockerfile src/package.json src/launcher.mjs; do
    [[ -f $source_dir/$required_file ]] || fail "Private repository revision $revision is missing $required_file. Push the panel source to the default branch."
  done
  local container current
  container=$("$config_dir/compose" ps -q wg-easy)
  if [[ -z $container && ${1:-} == --reinstall ]]; then
    resume_panel_install "$source_dir" "$revision"
    update_status succeeded
    return
  fi
  [[ -n $container ]] || fail 'Start the existing panel before updating.'
  old_image=$(docker inspect --format '{{.Image}}' "$container")
  volume=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/etc/wireguard"}}{{.Name}}{{end}}{{end}}' "$container")
  [[ $volume =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || fail 'Updates require the named WireGuard data volume.'
  current=$("$config_dir/compose" exec -T wg-easy node -e 'process.stdout.write(process.env.PANEL_REVISION || "unknown")')
  if [[ $current == "$revision" && ${1:-} != --reinstall ]]; then
    setup_updater
    "$config_dir/compose" up -d --wait --wait-timeout 180
    update_status unchanged
    printf 'The panel is already up to date.\n'
    return
  fi
  # Build before stopping the running panel. Preserve its image for rollback.
  check_wireguard_update_routes || fail 'Routing compatibility check failed; the existing panel is still running.'
  docker tag "$old_image" pasha-forever-wireguard:rollback
  docker build --build-arg "PANEL_REVISION=$revision" -t pasha-forever-wireguard:local "$source_dir"
  backup_dir=$(mktemp -d "$config_dir/backups/update-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")
  cp -p "$config_dir/runtime.compose.yml" "$config_dir/panel.env" "$backup_dir/"
  stopped=1
  "$config_dir/compose" stop
  # Offline snapshot includes the database, WAL, keys and interface configuration.
  docker run --rm --entrypoint sh --mount "type=volume,src=$volume,dst=/data,readonly" --mount "type=bind,src=$backup_dir,dst=/backup" "$old_image" -c 'mkdir -p /backup/wireguard && cp -a /data/. /backup/wireguard/'
  switched=1
  # Remove only the retired core's generated port mappings. WireGuard ports,
  # volumes and network settings stay in the existing runtime Compose file.
  sed -i '/XRAY_PORT_START.*XRAY_PORT_END/d' "$config_dir/runtime.compose.yml"
  setup_updater
  "$config_dir/compose" up -d --force-recreate --wait --wait-timeout 180
  "$config_dir/compose" exec -T wg-easy node --input-type=module -e 'import {applyPanelSettings,readPanelSettings} from "/app/launcher.mjs";applyPanelSettings(readPanelSettings("/etc/wireguard/wg-easy.db"),process.env);const http=await import(process.env.PANEL_TLS_ACTIVE === "true"?"node:https":"node:http");const r=http.get({hostname:"127.0.0.1",port:process.env.PORT,path:process.env.NUXT_APP_BASE_URL,rejectUnauthorized:false},res=>process.exit([200,301,302,303,307,308].includes(res.statusCode)?0:1));r.setTimeout(10000,()=>{r.destroy();process.exit(1)});r.on("error",()=>process.exit(1));'
  # Refresh the host installer from the same checked-out panel revision only
  # after the new panel has passed its checks. Keep compatibility with old tags.
  if [[ -f $source_dir/public-installer/install.sh ]]; then
    bash -n "$source_dir/public-installer/install.sh"
    install -m 0700 "$source_dir/public-installer/install.sh" "$config_dir/updater.sh.new"
    mv -f "$config_dir/updater.sh.new" "$config_dir/updater.sh"
  fi
  stopped=0
  update_status succeeded
  printf 'Panel updated to %s. Backup: %s\n' "$revision" "$backup_dir"
)

#!/usr/bin/env bash
# Sourced by install.sh. Independent from panel updates and panel data.
tunnel_root=/etc/wg-panel-tunnels
tunnel_image='gogost/gost:3.2.6@sha256:1ae76fcd556aec335ff602a1828c1140c27d6243c7f02a89f41e177baa265faf'

valid_tunnel_name() { [[ $1 =~ ^[a-z][a-z0-9-]{0,31}$ ]]; }
valid_tunnel_host() {
  local host=$1 octet
  [[ ${#host} -le 253 && $host != *..* && $host =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
  if [[ $host =~ ^[0-9.]+$ ]]; then
    local -a octets
    IFS=. read -r -a octets <<<"$host"
    [[ ${#octets[@]} == 4 ]] || return 1
    for octet in "${octets[@]}"; do [[ $octet =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( 10#$octet <= 255 )) || return 1; done
  else
    [[ $host == *.* && $host != *.-* && $host != *-.* && $host != *- ]] || return 1
  fi
}
tunnel_transport() {
  case "$1" in 1) echo udp ;; 2) echo tcp ;; 3) echo tls ;; 4) echo ws ;; 5) echo wss ;; 6) echo quic ;; 7) echo kcp ;; *) return 1 ;; esac
}
tunnel_protocol() { case "$1" in udp|quic|kcp) echo udp ;; tcp|tls|ws|wss) echo tcp ;; *) return 1 ;; esac; }
tunnel_tls() { [[ $1 == tls || $1 == wss || $1 == quic ]]; }
tunnel_compose() {
  local name=$1; shift
  valid_tunnel_name "$name" || fail 'Invalid tunnel name.'
  docker compose --project-name "wg-tunnel-$name" -f "$tunnel_root/$name/compose.yml" "$@"
}
tunnel_firewall() {
  local port=$1 protocol=$2
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw allow "$port/$protocol"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$port/$protocol"
    firewall-cmd --add-port="$port/$protocol"
  fi
  printf 'Provider firewall: allow inbound %s %s on this server.\n' "$protocol" "$port"
}

# Parameters are validated before writing single-line YAML values.
write_tunnel_config() {
  local directory=$1 transport=$2 role=$3 listen=$4 host=$5 remote_port=$6 user=$7 password=$8
  if [[ $transport == udp ]]; then
    cat >"$directory/gost.yml" <<EOF
services:
  - name: wireguard-udp
    addr: ":$listen"
    handler:
      type: udp
    listener:
      type: udp
    forwarder:
      nodes:
        - name: wireguard
          addr: "$host:$remote_port"
EOF
  elif [[ $role == server ]]; then
    cat >"$directory/gost.yml" <<EOF
services:
  - name: wireguard-relay
    addr: ":$listen"
    handler:
      type: relay
      auth:
        username: "$user"
        password: "$password"
    listener:
      type: $transport
EOF
    if tunnel_tls "$transport"; then
      cat >>"$directory/gost.yml" <<'EOF'
      tls:
        certFile: /config/cert.pem
        keyFile: /config/key.pem
EOF
    fi
    cat >>"$directory/gost.yml" <<EOF
    forwarder:
      nodes:
        - name: wireguard
          addr: "127.0.0.1:$remote_port"
EOF
  else
    cat >"$directory/gost.yml" <<EOF
services:
  - name: wireguard-entry
    addr: ":$listen"
    handler:
      type: udp
      chain: wireguard-chain
    listener:
      type: udp
chains:
  - name: wireguard-chain
    hops:
      - name: destination
        nodes:
          - name: relay
            addr: "$host:$remote_port"
            connector:
              type: relay
              auth:
                username: "$user"
                password: "$password"
            dialer:
              type: $transport
EOF
    if tunnel_tls "$transport"; then
      cat >>"$directory/gost.yml" <<'EOF'
              tls:
                secure: true
                serverName: wg-tunnel.local
                caFile: /config/ca.pem
EOF
    fi
  fi
  cat >"$directory/compose.yml" <<EOF
services:
  tunnel:
    image: $tunnel_image
    restart: unless-stopped
    network_mode: host
    command: ["-C", "/config/gost.yml"]
    volumes:
      - ./:/config:ro
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt: ["no-new-privileges:true"]
    logging:
      driver: json-file
      options:
        max-size: "5m"
        max-file: "2"
EOF
  printf 'Transport: %s\nRole: %s\nListen port: %s\nDestination: %s:%s\n' "$transport" "$role" "$listen" "$host" "$remote_port" >"$directory/info.txt"
  chmod 0600 "$directory"/*
}

create_tunnel() (
  local name selection transport role listen host remote_port user password certificate directory protocol
  local complete=0
  ask name 'Tunnel name (lowercase letters/digits/hyphens, e.g. iran1): '
  valid_tunnel_name "$name" || fail 'Name must start with a letter; maximum 32 characters.'
  [[ ! -L $tunnel_root && ! -e $tunnel_root/$name ]] || fail 'Tunnel already exists or unsafe directory; use the management menu.'
  printf '\n1. Direct UDP relay\n2. UDP over TCP\n3. UDP over TLS\n4. UDP over WebSocket\n5. UDP over WSS\n6. UDP over QUIC\n7. UDP over KCP\n'
  printf 'Direct UDP, QUIC and KCP need UDP between servers. TCP/TLS/WS/WSS use TCP between servers.\n'
  ask selection 'Transport [3]: '
  transport=$(tunnel_transport "${selection:-3}") || fail 'Invalid transport.'
  role=client
  if [[ $transport != udp ]]; then
    printf 'Run server mode on the WireGuard/panel server, then client mode on the entry server.\n'
    ask role 'This server role: server or client [client]: '
    role=${role:-client}
    [[ $role == server || $role == client ]] || fail 'Role must be server or client.'
  fi
  if [[ $role == server ]]; then
    ask listen 'Tunnel listen port [40000]: '; listen=${listen:-40000}
    host=127.0.0.1
    ask remote_port 'Existing WireGuard UDP port on this server [51820]: '; remote_port=${remote_port:-51820}
    protocol=$(tunnel_protocol "$transport")
  else
    ask listen 'UDP entry port for WireGuard clients [51820]: '; listen=${listen:-51820}
    ask host 'Destination server IPv4 or DNS name: '
    valid_tunnel_host "$host" || fail 'Use IPv4 or a DNS hostname without scheme, path or port.'
    ask remote_port 'Destination port (WireGuard for direct UDP; tunnel port otherwise): '
    if [[ $transport == udp ]]; then remote_port=${remote_port:-51820}; else remote_port=${remote_port:-40000}; fi
    protocol=udp
  fi
  valid_port "$listen" && valid_port "$remote_port" || fail 'Ports must be 1-65535.'
  [[ $role != server || $protocol != udp || $listen != "$remote_port" ]] || fail 'UDP tunnel and WireGuard must use different ports.'
  [[ $transport != udp || $host != 127.0.0.1 || $listen != "$remote_port" ]] || fail 'A UDP relay cannot forward to itself.'
  if ! command -v docker >/dev/null || ! command -v ss >/dev/null || ! docker compose version >/dev/null 2>&1; then install_dependencies; fi
  command -v ss >/dev/null || fail 'Install iproute2 first.'
  if [[ $protocol == udp ]]; then
    if ss -H -lun "sport = :$listen" | grep -q .; then fail 'UDP entry/tunnel port is occupied.'; fi
  elif ss -H -ltn "sport = :$listen" | grep -q .; then fail 'TCP tunnel port is occupied.'; fi
  user=wireguard; password=''
  if [[ $transport != udp ]]; then
    ask user 'Shared tunnel username [wireguard]: '; user=${user:-wireguard}
    [[ $user =~ ^[A-Za-z0-9_-]{1,64}$ ]] || fail 'Username: letters, digits, underscore or hyphen only.'
    secret password 'Shared password (12-128 letters/digits/_/-; blank generates one in server mode): '
    if [[ -z $password && $role == server ]]; then password=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n'); fi
    [[ $password =~ ^[A-Za-z0-9_-]{12,128}$ ]] || fail 'Use the same shared password on both servers (12-128 safe characters).'
  fi
  docker info >/dev/null || fail 'Start Docker before creating a tunnel.'
  install -d -m 0700 "$tunnel_root"
  mkdir -m 0700 -- "$tunnel_root/$name" || fail 'Tunnel directory already exists.'
  directory="$tunnel_root/$name"
  trap 'if (( ! complete )); then tunnel_compose "$name" down >/dev/null 2>&1 || true; remove_tunnel_directory "$name"; fi' EXIT
  if tunnel_tls "$transport"; then
    if [[ $role == server ]]; then
      command -v openssl >/dev/null || { apt-get update; apt-get install -y openssl; }
      openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 365 -subj /CN=wg-tunnel.local -addext subjectAltName=DNS:wg-tunnel.local -keyout "$directory/key.pem" -out "$directory/cert.pem" >/dev/null 2>&1
    else
      ask certificate 'Path to cert.pem copied from the tunnel server (public certificate only): '
      [[ -f $certificate && -r $certificate ]] || fail 'Certificate file not found.'
      cp -- "$certificate" "$directory/ca.pem"
    fi
  fi
  write_tunnel_config "$directory" "$transport" "$role" "$listen" "$host" "$remote_port" "$user" "$password"
  tunnel_compose "$name" config --quiet
  tunnel_compose "$name" pull
  tunnel_firewall "$listen" "$protocol"
  tunnel_compose "$name" up -d --wait --wait-timeout 60
  sleep 2
  local container
  container=$(tunnel_compose "$name" ps -q tunnel)
  [[ -n $container && $(docker inspect --format '{{.State.Running}}' "$container") == true ]] || fail 'Tunnel process did not stay running.'
  complete=1
  cat "$directory/info.txt"
  if [[ $role == server ]]; then
    printf '\nShared username: %s\nShared password: %s\nSave these for the client server.\n' "$user" "$password"
    if tunnel_tls "$transport"; then printf 'Copy PUBLIC %s/cert.pem to the client. Certificate expires in 365 days; recreate both ends before expiry.\n' "$directory"; fi
  else
    printf '\nSet the WireGuard client Endpoint to this entry server IPv4:%s. Keep VPN keys, addresses and allowed IPs unchanged.\n' "$listen"
  fi
  printf 'Process started. Verify a WireGuard handshake through the entry server before switching all users.\n'
)

remove_tunnel_directory() {
  valid_tunnel_name "$1" && [[ $tunnel_root == /etc/wg-panel-tunnels && ! -L $tunnel_root && ! -L $tunnel_root/$1 ]] || fail 'Unsafe tunnel path.'
  rm -rf -- "$tunnel_root/$1"
}
select_tunnel() {
  local candidate
  [[ -d $tunnel_root && ! -L $tunnel_root ]] || fail 'No managed tunnels.'
  printf 'Managed tunnels:\n'
  for candidate in "$tunnel_root"/*; do
    [[ -d $candidate && ! -L $candidate && -f $candidate/compose.yml ]] || continue
    printf '  %s\n' "${candidate##*/}"
  done
  ask selected_tunnel 'Tunnel name: '
  valid_tunnel_name "$selected_tunnel" && [[ ! -L $tunnel_root/$selected_tunnel && -f $tunnel_root/$selected_tunnel/compose.yml ]] || fail 'Unknown tunnel.'
}
tunnel_status() { local selected_tunnel; select_tunnel; cat "$tunnel_root/$selected_tunnel/info.txt"; tunnel_compose "$selected_tunnel" ps; }
tunnel_logs() { local selected_tunnel; select_tunnel; tunnel_compose "$selected_tunnel" logs --tail 100; }
tunnel_restart() { local selected_tunnel; select_tunnel; tunnel_compose "$selected_tunnel" up -d --wait --wait-timeout 60; tunnel_compose "$selected_tunnel" restart; }
remove_tunnel() {
  local selected_tunnel confirmation
  select_tunnel
  ask confirmation "Remove tunnel $selected_tunnel? Type REMOVE: "
  [[ $confirmation == REMOVE ]] || { printf 'Cancelled.\n'; return; }
  tunnel_compose "$selected_tunnel" down
  remove_tunnel_directory "$selected_tunnel"
  printf 'Tunnel removed. Panel and VPN data were kept. Shared firewall rules were kept.\n'
}
udp2raw_fec_menu() (
  local assets script_directory checkout runtime=/opt/wg-panel-udp2raw-fec asset
  script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  assets="$script_directory/vendor/udp2raw"
  checkout=''
  trap 'if [[ -n $checkout ]]; then rm -rf -- "$checkout"; fi' EXIT
  if [[ ! -f $assets/run.sh || ! -f $assets/udp2raw.go || ! -f $assets/manage.go ]]; then
    command -v curl >/dev/null || { apt-get update; apt-get install -y ca-certificates curl; }
    checkout=$(mktemp -d)
    assets="$checkout"
    for asset in run.sh udp2raw.go manage.go udp2raw-logo.sh LICENSE; do
      curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        "https://raw.githubusercontent.com/pashaDeveloper/wg-panel-installer/main/vendor/udp2raw/$asset?fresh=$(date +%s)" \
        -o "$assets/$asset"
    done
    bash -n "$assets/run.sh"
  fi
  [[ -d $assets ]] || fail 'UDP2RAW source files are missing from the repository.'
  install -d -m 0700 "$runtime"
  local asset
  for asset in run.sh udp2raw.go manage.go udp2raw-logo.sh LICENSE; do
    [[ -f $assets/$asset ]] || fail "Missing UDP2RAW asset: $asset"
    install -m 0600 "$assets/$asset" "$runtime/$asset"
  done
  bash "$runtime/run.sh"
)

tunnel_menu() {
  local tunnel_choice
  while true; do
    printf '\nTunnels\n1. UDP2RAW / FEC\n2. Create GOST tunnel\n3. GOST status\n4. GOST logs\n5. GOST start/restart\n6. Remove GOST tunnel\n7. UDP2RAW managed by panel (automatic inbounds)\nb) Back\n'
    ask tunnel_choice 'Select: '
    case "$tunnel_choice" in
      1) run_action udp2raw_fec_menu ;; 2) run_action create_tunnel ;; 3) run_action tunnel_status ;;
      4) run_action tunnel_logs ;; 5) run_action tunnel_restart ;;
      6) run_action remove_tunnel ;; 7) udp2raw_menu ;; b|B) return ;;
      *) printf 'Invalid option.\n' ;;
    esac
  done
}


# BEGIN UDP2RAW HOST SUPPORT
write_udp2raw_agent() {
  cat >"$udp2raw_dir/agent.py" <<'UDP2RAW_PY'
#!/usr/bin/env python3
"""Host-side inbound reconciliation. No panel password or VPN private keys."""
import argparse
from contextlib import contextmanager
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import socket
import subprocess
import time
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler

ROOT = Path('/etc/wg-panel-udp2raw')
MANIFEST = Path('/etc/wg-panel/update-control/udp2raw-manifest.json')
MODES = {'icmp', 'udp', 'faketcp'}
NAME = re.compile(r'wg\d{1,8}\Z')
KEY = re.compile(r'[a-f0-9]{64}\Z')

def atomic_json(path, value):
    atomic_text(path, json.dumps(value, separators=(',', ':')) + '\n')

def atomic_text(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_suffix(path.suffix + '.tmp')
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as file:
        file.write(value)
        file.flush()
        os.fsync(file.fileno())
    os.replace(temp, path)

def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=45).stdout

def port(value):
    if type(value) is not int or not 1 <= value <= 65535:
        raise ValueError('Invalid port')
    return value

def entries(value):
    if not isinstance(value, list) or len(value) > 1000:
        raise ValueError('Invalid inbound snapshot')
    seen_names, seen_ports = set(), set()
    for entry in value:
        if not isinstance(entry, dict) or not NAME.fullmatch(str(entry.get('name', ''))):
            raise ValueError('Invalid inbound name')
        number = port(entry.get('wireguardPort'))
        if entry['name'] in seen_names or number in seen_ports:
            raise ValueError('Duplicate inbound')
        seen_names.add(entry['name']); seen_ports.add(number)
    return value

def valid_config(config):
    if config.get('role') not in {'outside', 'iran'} or config.get('mode') not in MODES:
        raise ValueError('Invalid role or raw mode')
    if not KEY.fullmatch(str(config.get('token', ''))):
        raise ValueError('Invalid pairing token')
    if config['role'] == 'outside':
        if not KEY.fullmatch(str(config.get('key', ''))):
            raise ValueError('Invalid tunnel key')
    else:
        parsed = urlsplit(config.get('panelUrl', ''))
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ValueError('Use a trusted HTTPS panel URL without credentials/query/fragment')
        if not re.fullmatch(r'[A-Za-z0-9.-]{1,253}', config.get('remoteHost', '')):
            raise ValueError('Invalid direct server host')
        port(config.get('entryPort'))
    return config

def outside_inbounds():
    # Read-only SQLite snapshot in the existing panel container, including WAL.
    script = "import{DatabaseSync}from'node:sqlite';const d=new DatabaseSync('/etc/wireguard/wg-easy.db',{readOnly:true});try{console.log(JSON.stringify(d.prepare('SELECT name,port AS wireguardPort FROM interfaces_table WHERE enabled=1 ORDER BY name').all()))}finally{d.close()}"
    return entries(json.loads(run('/etc/wg-panel/compose', 'exec', '-T', 'wg-easy', 'node', '--input-type=module', '-e', script)))

class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args):
        raise ValueError('Panel redirects are not accepted; enter the final HTTPS URL')

def fetch_manifest(config):
    request = Request(config['panelUrl'].rstrip('/') + '/api/udp2raw/manifest', headers={'Authorization': 'Bearer ' + config['token']})
    with build_opener(NoRedirect()).open(request, timeout=20) as response:
        data = response.read(256001)
    if len(data) > 256000:
        raise ValueError('Manifest too large')
    value = json.loads(data)
    if value.get('mode') != config['mode'] or not KEY.fullmatch(str(value.get('key', ''))):
        raise ValueError('Tunnel mode or key mismatch')
    if type(value.get('updatedAt')) is not int or not -30 <= time.time() - value['updatedAt'] <= 120:
        raise ValueError('Outside tunnel snapshot is stale')
    entries(value.get('entries'))
    seen = set()
    for entry in value['entries']:
        if entry.get('mode', value['mode']) not in MODES:
            raise ValueError('Invalid inbound raw mode')
        tunnel_port = port(entry.get('tunnelPort'))
        if tunnel_port in seen:
            raise ValueError('Duplicate tunnel port')
        seen.add(tunnel_port)
    return value

def used_ports():
    output = run('ss', '-H', '-lntu')
    return {int(match.group(1)) for line in output.splitlines() for match in re.finditer(r':(\d+)\b', line)}

def allocate_port(reserved):
    for _ in range(2000):
        candidate = 20000 + secrets.randbelow(29000)
        if candidate not in reserved:
            reserved.add(candidate)
            return candidate
    raise ValueError('No free random tunnel port available')

def conf(role, mode, listen, host, target, key):
    port(listen); port(target)
    if role not in {'outside', 'iran'} or mode not in MODES or not KEY.fullmatch(key):
        raise ValueError('Invalid udp2raw configuration')
    ipaddress.IPv4Address(host)
    return '\n'.join([
        '-s' if role == 'outside' else '-c', f'-l 0.0.0.0:{listen}',
        f'-r {host}:{target}', '-k ' + key, '--raw-mode ' + mode,
        '--cipher-mode aes128cbc', '--auth-mode hmac_sha1', '-a', '--keep-rule', '--fix-gro', '',
    ])

def allow_port(number, mode):
    protocol = 'tcp' if mode == 'faketcp' else 'udp'
    if mode == 'icmp':
        # ICMP has no TCP/UDP destination port. Never disable echo replies globally.
        print('ICMP mode: provider/host firewall must permit ICMP between the two servers.', flush=True)
        return
    if subprocess.run(['sh', '-c', 'command -v ufw >/dev/null'], capture_output=True).returncode == 0:
        if 'Status: active' in run('ufw', 'status'):
            run('ufw', 'allow', f'{number}/{protocol}')
            return
    if subprocess.run(['sh', '-c', 'command -v firewall-cmd >/dev/null'], capture_output=True).returncode == 0:
        if subprocess.run(['firewall-cmd', '--state'], capture_output=True).returncode == 0:
            run('firewall-cmd', '--permanent', f'--add-port={number}/{protocol}')
            run('firewall-cmd', f'--add-port={number}/{protocol}')

def ensure_unit(name, text, firewall_port, firewall_mode):
    if not re.fullmatch(r'(outside|iran)-wg\d{1,8}', name):
        raise ValueError('Invalid service instance')
    path = ROOT / 'tunnels' / (name + '.conf')
    changed = not path.exists() or path.read_text() != text
    if changed:
        atomic_text(path, text)
        allow_port(firewall_port, firewall_mode)
    unit = f'wg-panel-udp2raw@{name}.service'
    run('systemctl', 'enable', '--now', unit)
    if changed:
        run('systemctl', 'restart', unit)
    run('systemctl', 'is-active', '--quiet', unit)

def remove_units(role, desired):
    directory = ROOT / 'tunnels'
    for path in directory.glob(role + '-wg*.conf'):
        if path.stem not in desired:
            run('systemctl', 'disable', '--now', f'wg-panel-udp2raw@{path.stem}.service')
            path.unlink()

def reconcile(config):
    valid_config(config)
    state_path = ROOT / 'state.json'
    state = json.loads(state_path.read_text()) if state_path.exists() else {'assignments': {}}
    assignments = state['assignments']
    override_path = ROOT / 'overrides.json'
    overrides = json.loads(override_path.read_text()) if override_path.exists() else {}
    if not isinstance(assignments, dict):
        raise ValueError('Invalid persisted assignments')
    desired, published = set(), []
    if config['role'] == 'outside':
        inbounds = outside_inbounds()  # No mutation on failed/incomplete snapshots.
        inbounds = [entry for entry in inbounds if not overrides.get(entry['name'], {}).get('disabled', False)]
        reserved = used_ports() | {entry['wireguardPort'] for entry in inbounds}
        for value in assignments.values():
            reserved.add(port(value))
        for entry in inbounds:
            name = entry['name']
            if 'port' in overrides.get(name, {}):
                assignments[name] = port(overrides[name]['port'])
                if assignments[name] in {item['wireguardPort'] for item in inbounds}:
                    raise ValueError('Manual tunnel port conflicts with WireGuard')
                continue
            if name not in assignments or assignments[name] in {item['wireguardPort'] for item in inbounds}:
                assignments[name] = allocate_port(reserved)
        # Persist before starting services so retries/reboots never reshuffle ports.
        atomic_json(state_path, state)
        for entry in inbounds:
            name = 'outside-' + entry['name']
            tunnel_port = assignments[entry['name']]
            mode = overrides.get(entry['name'], {}).get('mode', config['mode'])
            ensure_unit(name, conf('outside', mode, tunnel_port, '127.0.0.1', entry['wireguardPort'], config['key']), tunnel_port, mode)
            desired.add(name)
            published.append({**entry, 'tunnelPort': tunnel_port, 'mode': mode})
        remove_units('outside', desired)
        # The panel exposes only a bearer-authenticated, no-cache copy of this file.
        atomic_json(MANIFEST, {'token': config['token'], 'mode': config['mode'], 'key': config['key'], 'updatedAt': int(time.time()), 'entries': published})
    else:
        manifest = fetch_manifest(config)
        manifest['entries'] = [entry for entry in manifest['entries'] if not overrides.get(entry['name'], {}).get('disabled', False)]
        host = str(ipaddress.IPv4Address(socket.gethostbyname(config['remoteHost'])))
        reserved = used_ports() | {port(value) for value in assignments.values()}
        for entry in manifest['entries']:
            name = entry['name']
            if 'port' in overrides.get(name, {}):
                assignments[name] = port(overrides[name]['port'])
                continue
            if name not in assignments:
                preferred = config['entryPort'] if name == 'wg0' else entry['wireguardPort']
                if preferred in reserved:
                    if name == 'wg0':
                        raise ValueError('Requested WireGuard UDP entry port is occupied')
                    preferred = allocate_port(reserved)
                assignments[name] = preferred
                reserved.add(preferred)
        atomic_json(state_path, state)
        for entry in manifest['entries']:
            name = 'iran-' + entry['name']
            local_port = assignments[entry['name']]
            mode = entry.get('mode', manifest.get('mode', config['mode']))
            ensure_unit(name, conf('iran', mode, local_port, host, entry['tunnelPort'], manifest['key']), local_port, 'udp')
            desired.add(name)
            published.append({**entry, 'entryPort': local_port, 'mode': mode})
        remove_units('iran', desired)
    atomic_json(ROOT / 'status.json', {'role': config['role'], 'mode': config['mode'], 'updatedAt': int(time.time()), 'entries': published})
    return published

@contextmanager
def worker_lock():
    with (ROOT / 'worker.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield

def manage_inbound(config, name, *, new_port=None, new_mode=None, disabled=None, restart=False):
    if not NAME.fullmatch(name):
        raise ValueError('Invalid inbound name')
    state = json.loads((ROOT / 'state.json').read_text())
    assignments = state['assignments']
    if name not in assignments:
        raise ValueError('Unknown inbound; synchronize first')
    path = ROOT / 'overrides.json'
    overrides = json.loads(path.read_text()) if path.exists() else {}
    current = overrides.setdefault(name, {})
    if new_mode is not None:
        if config['role'] != 'outside' or new_mode not in MODES:
            raise ValueError('Change raw mode on the Outside server; Iran follows it automatically')
        current['mode'] = new_mode
    if new_port is not None:
        number = port(new_port)
        if number != assignments[name] and number in used_ports() | {value for key, value in assignments.items() if key != name}:
            raise ValueError('Port is occupied or reserved by another inbound')
        if config['role'] == 'outside' and number in {entry['wireguardPort'] for entry in outside_inbounds()}:
            raise ValueError('Tunnel port cannot be a WireGuard port')
        current['port'] = number
    if disabled is not None:
        current['disabled'] = disabled
    atomic_json(path, overrides)
    instance = config['role'] + '-' + name
    if disabled is True:
        run('systemctl', 'disable', '--now', f'wg-panel-udp2raw@{instance}.service')
        (ROOT / 'tunnels' / (instance + '.conf')).unlink(missing_ok=True)
        # Disabling is immediate even when the panel/network is unavailable.
        for saved in [ROOT / 'status.json'] + ([MANIFEST] if config['role'] == 'outside' else []):
            if saved.exists():
                value = json.loads(saved.read_text())
                value['entries'] = [entry for entry in value['entries'] if entry['name'] != name]
                atomic_json(saved, value)
        return
    reconcile(config)
    if restart and not current.get('disabled', False):
        run('systemctl', 'restart', f'wg-panel-udp2raw@{instance}.service')

def show_status(config):
    status_path = ROOT / 'status.json'
    value = json.loads(status_path.read_text()) if status_path.exists() else {'entries': []}
    overrides_path = ROOT / 'overrides.json'
    overrides = json.loads(overrides_path.read_text()) if overrides_path.exists() else {}
    print('Role:', config['role'], 'Default mode:', config['mode'])
    print('Last successful sync:', time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime(value['updatedAt'])) if value.get('updatedAt') else 'pending')
    for entry in value['entries']:
        unit = f"wg-panel-udp2raw@{config['role']}-{entry['name']}.service"
        result = subprocess.run(['systemctl', 'is-active', unit], text=True, capture_output=True, timeout=10)
        print(entry['name'], 'Mode:', entry.get('mode', config['mode']), 'WireGuard:', entry['wireguardPort'], 'Tunnel:', entry['tunnelPort'], 'Iran entry:', entry.get('entryPort', 'see Iran server'), 'Service:', result.stdout.strip() or 'inactive')
    for name, override in overrides.items():
        if override.get('disabled', False): print(name, 'DISABLED / removed manually; automatic recreation blocked')
    print('Active service status does not confirm a WireGuard handshake.')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--once', action='store_true')
    parser.add_argument('--validate', action='store_true')
    parser.add_argument('--status', action='store_true')
    parser.add_argument('--inbound')
    parser.add_argument('--set-port', type=int)
    parser.add_argument('--set-mode', choices=sorted(MODES))
    parser.add_argument('--disable', action='store_true')
    parser.add_argument('--enable', action='store_true')
    parser.add_argument('--restart-inbound', action='store_true')
    args = parser.parse_args()
    config = valid_config(json.loads((ROOT / 'config.json').read_text()))
    if args.validate:
        print('Configuration valid')
        return
    if args.status:
        show_status(config)
        return
    if args.inbound:
        with worker_lock():
            manage_inbound(config, args.inbound, new_port=args.set_port, new_mode=args.set_mode, disabled=True if args.disable else False if args.enable else None, restart=args.restart_inbound)
        print('Inbound settings saved')
        return
    while True:
        with worker_lock():
            try:
                result = reconcile(config)
                if args.once:
                    print(json.dumps(result))
                    return
            except Exception as error:
                # Never print subprocess command/config, HTTP headers or shared keys.
                print('udp2raw synchronization failed (' + type(error).__name__ + '); existing tunnels kept. Check panel connectivity, mode, ports and systemd status.', flush=True)
                if args.once:
                    raise SystemExit(1)
        time.sleep(20)

if __name__ == '__main__':
    main()
UDP2RAW_PY
  chmod 0700 "$udp2raw_dir/agent.py"
}
# Embedded in install.sh; keep the public installer usable as one downloaded file.
udp2raw_dir=/etc/wg-panel-udp2raw
udp2raw_binary_dir=/usr/local/lib/wg-panel-udp2raw

udp2raw_mode() {
  case "$1" in tcp|faketcp|3|'') echo faketcp ;; udp|2) echo udp ;; icmp|1) echo icmp ;; *) return 1 ;; esac
}

install_udp2raw_binary() (
  local binary archive_dir
  case "$(uname -m)" in
    x86_64) binary=udp2raw_amd64 ;; i386|i686) binary=udp2raw_x86 ;; armv7l) binary=udp2raw_arm ;;
    *) fail 'This pinned udp2raw release supports x86_64, x86 and ARMv7; no native binary is available here for this architecture.' ;;
  esac
  [[ ! -L $udp2raw_binary_dir ]] || fail 'Unsafe udp2raw binary directory.'
  archive_dir=$(mktemp -d)
  trap 'rm -rf -- "$archive_dir"' EXIT
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 'https://github.com/wangyu-/udp2raw/releases/download/20230206.0/udp2raw_binaries.tar.gz' -o "$archive_dir/release.tar.gz"
  printf '503cf5781aa97e50b4954c6bc4622c3ea6be02f6a35def4bb3b3eaf95bd2c7e8  %s\n' "$archive_dir/release.tar.gz" | sha256sum -c - >/dev/null
  tar -xzf "$archive_dir/release.tar.gz" -C "$archive_dir" "$binary"
  install -d -m 0700 "$udp2raw_binary_dir"
  install -m 0700 "$archive_dir/$binary" "$udp2raw_binary_dir/udp2raw"
)

setup_udp2raw() (
  local location mode entry_port panel_url remote_host pairing_token
  [[ ! -L $udp2raw_dir && ! -f $udp2raw_dir/config.json ]] || fail 'udp2raw is already configured; manage or remove it from this menu first.'
  ask location 'This server location: 1) Iran  2) Outside [2]: '
  case "${location:-2}" in 1|iran|Iran) location=iran ;; 2|outside|Outside) location=outside ;; *) fail 'Choose Iran or Outside.' ;; esac
  ask mode 'Raw tunnel mode: 1) ICMP  2) UDP  3) TCP/FakeTCP [3]: '
  mode=$(udp2raw_mode "$mode") || fail 'Choose ICMP, UDP or TCP.'
  source /etc/os-release
  case "$ID" in ubuntu|debian) ;; *) fail 'Supported servers: Ubuntu or Debian.' ;; esac
  command -v systemctl >/dev/null || fail 'systemd is required.'
  apt-get update
  apt-get install -y python3 curl ca-certificates iptables iproute2 util-linux
  entry_port=51820; panel_url=''; remote_host=''; pairing_token=''
  if [[ $location == outside ]]; then
    require_panel
    [[ -f $config_dir/runtime.compose.yml ]] && grep -q '/run/wg-panel-update' "$config_dir/runtime.compose.yml" || fail 'Run panel installer option 4 first to enable the control volume.'
    printf 'All enabled panel inbounds will be discovered automatically. Each gets a stable random tunnel port (20000-48999).\n'
  else
    ask entry_port 'WireGuard UDP entry port on Iran server [51820]: '
    entry_port=${entry_port:-51820}
    valid_port "$entry_port" || fail 'Port must be 1-65535.'
    ask panel_url 'Outside panel HTTPS URL, including its panel path if any: '
    remote_host=$(python3 -c 'import sys;from urllib.parse import urlsplit;print(urlsplit(sys.argv[1]).hostname or "")' "$panel_url") || fail 'Install python3 and enter a valid panel URL.'
    ask remote_host "Outside direct IPv4/hostname (not a CDN) [$remote_host]: "
    if [[ -z $remote_host ]]; then remote_host=$(python3 -c 'import sys;from urllib.parse import urlsplit;print(urlsplit(sys.argv[1]).hostname or "")' "$panel_url"); fi
    valid_tunnel_host "$remote_host" || fail 'Enter the outside direct IPv4 or DNS hostname.'
    secret pairing_token 'Pairing key printed by the Outside installer: '
    [[ $pairing_token =~ ^[a-f0-9]{64}$ ]] || fail 'Pairing key must have 64 hexadecimal characters.'
  fi
  install_udp2raw_binary
  install -d -m 0700 "$udp2raw_dir" "$udp2raw_dir/tunnels"
  # Generate secrets locally; input pairing token is passed over stdin, never argv.
  printf '%s' "$pairing_token" | python3 -c 'import json,secrets,sys,os; role,mode,entry,url,host=sys.argv[1:]; config={"role":role,"mode":mode,"entryPort":int(entry),"panelUrl":url,"remoteHost":host,"token":sys.stdin.read() if role=="iran" else secrets.token_hex(32)}; config.update({"key":secrets.token_hex(32)} if role=="outside" else {}); f=os.open("/etc/wg-panel-udp2raw/config.json",os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); os.write(f,json.dumps(config).encode()); os.close(f)' "$location" "$mode" "$entry_port" "$panel_url" "$remote_host"
  write_udp2raw_agent
  python3 "$udp2raw_dir/agent.py" --validate
  cat >/etc/systemd/system/wg-panel-udp2raw@.service <<'UNIT'
[Unit]
Description=Managed WireGuard udp2raw tunnel %i
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/lib/wg-panel-udp2raw/udp2raw --conf-file /etc/wg-panel-udp2raw/tunnels/%i.conf
Restart=always
RestartSec=5
KillSignal=SIGINT
TimeoutStopSec=15
UMask=0077
LimitNOFILE=65536
# udp2raw may print its shared key at startup. Keep raw output out of journals.
StandardOutput=null
StandardError=null
[Install]
WantedBy=multi-user.target
UNIT
  cat >/etc/systemd/system/wg-panel-udp2raw-sync.service <<'UNIT'
[Unit]
Description=Synchronize WireGuard inbounds and udp2raw tunnels
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 -u /etc/wg-panel-udp2raw/agent.py
Restart=always
RestartSec=10
UMask=0077
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  python3 "$udp2raw_dir/agent.py" --once || fail 'Initial synchronization failed. Configuration was retained; check panel HTTPS, API version, pairing key and systemd, then select Start/restart.'
  systemctl enable --now wg-panel-udp2raw-sync.service
  if [[ $location == outside ]]; then
    printf '\nPairing key for the Iran server (keep private):\n'
    python3 -c 'import json;print(json.load(open("/etc/wg-panel-udp2raw/config.json"))["token"])'
    printf 'On Iran choose the same raw mode and enter your outside panel HTTPS URL. Update the panel image first if /api/udp2raw/manifest is unavailable.\n'
    if [[ $mode == icmp ]]; then
      printf 'Provider firewall: allow ICMP between Iran and Outside. ICMP does not use TCP/UDP ports.\n'
    else
      printf 'Provider firewall: permit the displayed tunnel ports (or 20000-48999 for automatic new inbounds), preferably only from the Iran server IP.\n'
    fi
  fi
  udp2raw_status
  printf 'Synchronization runs every 20 seconds. New inbounds are added on both servers. Test a WireGuard handshake before moving users.\n'
)

udp2raw_status() {
  [[ -f $udp2raw_dir/config.json ]] || fail 'Set up udp2raw first.'
  python3 "$udp2raw_dir/agent.py" --status
  systemctl --no-pager status wg-panel-udp2raw-sync.service || true
}
udp2raw_restart() {
  [[ -f $udp2raw_dir/config.json ]] || fail 'Set up udp2raw first.'
  systemctl enable --now wg-panel-udp2raw-sync.service
  systemctl restart wg-panel-udp2raw-sync.service
  printf 'Synchronization restarted. Check Status and Logs after 20 seconds.\n'
}
remove_udp2raw() {
  local confirmation path
  [[ -f $udp2raw_dir/config.json ]] || fail 'Set up udp2raw first.'
  ask confirmation 'Remove managed udp2raw tunnels and pairing key? Type REMOVE: '
  [[ $confirmation == REMOVE ]] || { printf 'Cancelled.\n'; return; }
  [[ $udp2raw_dir == /etc/wg-panel-udp2raw && ! -L $udp2raw_dir ]] || fail 'Unsafe udp2raw directory.'
  if [[ -f /etc/systemd/system/wg-panel-udp2raw-sync.service ]]; then
    systemctl disable --now wg-panel-udp2raw-sync.service
  fi
  for path in "$udp2raw_dir"/tunnels/*.conf; do
    [[ -f $path ]] || continue
    [[ ${path##*/} =~ ^(iran|outside)-wg[0-9]{1,8}\.conf$ ]] || fail 'Invalid tunnel configuration name.'
    systemctl disable --now "wg-panel-udp2raw@$(basename "$path" .conf).service"
  done
  rm -f -- /etc/wg-panel/update-control/udp2raw-manifest.json /etc/systemd/system/wg-panel-udp2raw-sync.service /etc/systemd/system/wg-panel-udp2raw@.service
  rm -rf -- /etc/wg-panel-udp2raw
  systemctl daemon-reload
  printf 'udp2raw removed; panel, VPN data, other tunnel types and shared firewall rules kept.\n'
}
udp2raw_inbound_menu() {
  local name action number mode role confirmation
  [[ -f $udp2raw_dir/config.json ]] || fail 'Set up udp2raw first.'
  python3 "$udp2raw_dir/agent.py" --status
  ask name 'Inbound name (for example wg0): '
  [[ $name =~ ^wg[0-9]{1,8}$ ]] || fail 'Invalid inbound name.'
  role=$(python3 -c 'import json;print(json.load(open("/etc/wg-panel-udp2raw/config.json"))["role"])')
  while true; do
    printf '\nInbound %s\n1. Edit port\n2. Edit raw mode (Outside only)\n3. Disable / remove this tunnel\n4. Enable / recreate\n5. Restart this tunnel\nb) Back\n' "$name"
    ask action 'Select: '
    case "$action" in
      1)
        if [[ $role == outside ]]; then ask number 'New Outside raw tunnel port: '; else ask number 'New Iran WireGuard UDP entry port: '; fi
        valid_port "$number" || fail 'Port must be 1-65535.'
        python3 "$udp2raw_dir/agent.py" --inbound "$name" --set-port "$number"
        printf 'Update the provider firewall. An Iran entry port change also requires updating client Endpoints.\n'
        ;;
      2)
        [[ $role == outside ]] || { printf 'Change raw mode on Outside; Iran follows it automatically.\n'; continue; }
        ask mode 'Mode: 1) ICMP 2) UDP 3) TCP/FakeTCP [3]: '
        mode=$(udp2raw_mode "$mode") || fail 'Invalid mode.'
        python3 "$udp2raw_dir/agent.py" --inbound "$name" --set-mode "$mode"
        printf 'Iran receives the new raw mode at its next synchronization. Update the provider firewall.\n'
        ;;
      3)
        ask confirmation "Disable/remove tunnel $name (keep panel inbound and VPN users)? Type REMOVE: "
        if [[ $confirmation == REMOVE ]]; then python3 "$udp2raw_dir/agent.py" --inbound "$name" --disable; fi
        ;;
      4) python3 "$udp2raw_dir/agent.py" --inbound "$name" --enable ;;
      5) python3 "$udp2raw_dir/agent.py" --inbound "$name" --restart-inbound ;;
      b|B) return ;;
      *) printf 'Invalid option.\n' ;;
    esac
    python3 "$udp2raw_dir/agent.py" --status
  done
}
udp2raw_menu() {
  local selection
  if [[ -f $udp2raw_dir/config.json && ! -L $udp2raw_dir ]]; then
    # Refresh an older agent without resetting keys, assignments or overrides.
    write_udp2raw_agent
    if [[ -f /etc/systemd/system/wg-panel-udp2raw-sync.service ]]; then systemctl try-restart wg-panel-udp2raw-sync.service; fi
  fi
  while true; do
    printf '\nUDP2RAW (Iran / Outside)\n1. Setup\n2. Status / port mappings\n3. Synchronization logs\n4. Start/restart\n5. Remove all\n6. Manage individual inbound tunnels\nb) Back\n'
    ask selection 'Select: '
    case "$selection" in
      1) run_action setup_udp2raw ;; 2) run_action udp2raw_status ;;
      3) journalctl --no-pager -u wg-panel-udp2raw-sync.service -n 50 ;;
      4) run_action udp2raw_restart ;; 5) run_action remove_udp2raw ;;
      6) run_action udp2raw_inbound_menu ;; b|B) return ;;
      *) printf 'Invalid option.\n' ;;
    esac
  done
}

# END UDP2RAW HOST SUPPORT

password_recovery_program() {
  cat <<'RECOVERYJS'
const { createRequire } = require('node:module');
const { existsSync } = require('node:fs');
const appRequire = createRequire('/app/server/cli.mjs');
const argon2 = appRequire('argon2');
const { createClient } = appRequire('@libsql/client');
(async () => {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const input = Buffer.concat(chunks).toString('utf8');
  const split = input.indexOf('\0');
  if (split < 0) throw new Error('Invalid recovery input');
  const username = input.slice(0, split);
  const password = input.slice(split + 1);
  if (typeof username !== 'string' || typeof password !== 'string' || password.length < 12 || password.length > 256) {
    throw new Error('Invalid recovery input');
  }
  const path = '/etc/wireguard/wg-easy.db';
  if (!existsSync(path)) throw new Error('Panel database not found');
  const client = createClient({ url: `file:${path}` });
  let tx;
  try {
    const hash = await argon2.hash(password);
    tx = await client.transaction('write');
    const result = await tx.execute({
      sql: username ? 'SELECT id, role FROM users_table WHERE username = ?' : 'SELECT id, role FROM users_table WHERE id = 1',
      args: username ? [username] : [],
    });
    const user = result.rows[0];
    if (!user || ![1, 3].includes(Number(user.role))) throw new Error('Administrator not found');
    const updated = await tx.execute({
      sql: 'UPDATE users_table SET password = ?, totp_verified = 0, totp_key = NULL WHERE id = ?',
      args: [hash, user.id],
    });
    if (updated.rowsAffected !== 1) throw new Error('Administrator was not updated');
    const saved = await tx.execute({ sql: 'SELECT password, totp_verified, totp_key FROM users_table WHERE id = ?', args: [user.id] });
    const row = saved.rows[0];
    if (!row || !(await argon2.verify(row.password, password)) || Number(row.totp_verified) !== 0 || row.totp_key !== null) {
      throw new Error('Password verification failed');
    }
    await tx.commit();
    console.log('PASSWORD_RECOVERY_VERIFIED');
  } catch (error) {
    if (tx) await tx.rollback().catch(() => {});
    throw error;
  } finally {
    tx?.close();
    client.close();
  }
})().catch(() => {
  console.error('Password recovery failed. Check the administrator username and container database/dependencies.');
  process.exitCode = 1;
});
RECOVERYJS
}

reset_panel_password() {
  [[ -x $config_dir/compose ]] || fail 'Install the panel first.'
  local username password confirmation
  ask username 'Administrator username (blank = main admin): '
  secret password 'New password (12-256 characters): '
  secret confirmation 'Repeat new password: '
  [[ $password == "$confirmation" ]] || fail 'Passwords do not match.'
  (( ${#password} >= 12 && ${#password} <= 256 )) || fail 'Use 12-256 characters.'
  local result
  # A NUL separator preserves special characters; secrets enter only over stdin.
  # Use the existing image's dependencies, independent of its CLI argument support.
  if ! result=$(printf '%s\0%s' "$username" "$password" |
    "$config_dir/compose" exec -T wg-easy node -e "$(password_recovery_program)"); then
    unset password confirmation
    fail 'Password recovery failed; no success was confirmed.'
  fi
  unset password confirmation
  [[ $result == PASSWORD_RECOVERY_VERIFIED ]] || fail 'Password recovery was not verified.'
  printf 'Password recovery completed. TOTP was reset for this account.\n'
}

update_menu() {
  local selection
  printf '\n1. Update panel from GitHub\n2. Recover/change administrator password\nb) Back\n'
  ask selection 'Select: '
  case "$selection" in
    1) update_panel ;; 2) reset_panel_password ;; b|B) return ;;
    *) printf 'Invalid option.\n' ;;
  esac
}

run_action() {
  local status
  # A separate shell preserves errexit inside actions and returns to the menu on failure.
  trap ':' INT
  set +e
  (set -e; trap 'exit 130' INT; "$1")
  status=$?
  set -e
  trap - INT
  if (( status != 0 && status != 130 )); then printf 'Action failed (exit %s). Review the message above.\n' "$status"; fi
}

main() {
  [[ ${EUID} == 0 ]] || fail 'Run with sudo bash install.sh.'
  [[ -r /dev/tty ]] || fail 'Run from an interactive SSH terminal.'
  config_dir=/etc/wg-panel
  install_dir=/opt/wg-panel
  local choice
  while true; do
    printf '\n1. Install panel\n2. Edit panel\n3. Remove panel\n4. Update panel / recover password\n5. Tunnels\n6. Recover/change administrator password\n7. Start/restart panel\n8. Subscription proxy (Iran / automatic HTTPS)\nq) Exit\n'
    ask choice 'Select an option: '
    case "$choice" in
      1) run_action install_panel ;;
      2) run_action edit_panel ;;
      3) run_action remove_panel ;;
      4) run_action update_menu ;;
      5) run_action tunnel_menu ;;
      6) run_action reset_panel_password ;;
      7) run_action restart_panel ;;
      8) run_action subscription_proxy_menu ;;
      q|Q) return ;;
      *) printf 'Invalid option.\n' ;;
    esac
  done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  if [[ ${1:-} == --update-worker ]]; then
    [[ -e /etc/wg-panel/update-control/request ]] || exit 0
    update_panel
  elif [[ ${1:-} == --apply-settings ]]; then
    apply_panel_settings
  elif [[ ${1:-} == --reserve-ports ]]; then
    config_dir=/etc/wg-panel
    reserve_panel_ports
  elif [[ ${1:-} == --check-update ]]; then
    check_panel_update
  else
    main "$@"
  fi
fi
