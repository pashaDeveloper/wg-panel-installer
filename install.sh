#!/usr/bin/env bash
# Public bootstrap only. Never put a private key or panel source in this repo.
set -Eeuo pipefail
set +x
umask 077

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
  apt-get update
  apt-get install -y ca-certificates curl git openssh-client iproute2
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
  local mode key_source line pubkey registered
  key_file="$config_dir/deploy_key"
  if [[ -e $key_file ]]; then
    printf 'Using existing deploy key: %s\n' "$key_file"
  else
    ask mode 'Deploy Key: [1] generate on server (recommended), [2] existing private-key file, [3] paste private key [1]: '
    case "${mode:-1}" in
      1) ssh-keygen -q -t ed25519 -N '' -C 'wg-panel-deploy' -f "$key_file" ;;
      2)
        ask key_source 'Absolute path to the PRIVATE key file: '
        [[ $key_source == /* && -f $key_source ]] || fail 'Private-key file not found.'
        install -m 0600 -- "$key_source" "$key_file"
        ;;
      3)
        printf 'Paste the complete PRIVATE key, then type END on a new line. Input is hidden.\n'
        : >"$key_file"
        while true; do
          secret line ''
          [[ $line == END ]] && break
          printf '%s\n' "${line%$'\r'}" >>"$key_file"
        done
        ;;
      *) fail 'Invalid Deploy Key option.' ;;
    esac
  fi
  chmod 0600 "$key_file"
  pubkey=$(ssh-keygen -y -P '' -f "$key_file") || fail "Use an unencrypted deploy key. Replace $key_file and rerun."
  printf '\nAdd this PUBLIC key to https://github.com/%s/settings/keys\n' "$repository"
  printf 'Settings > Deploy keys > Add deploy key. Leave Allow write access OFF.\n\n%s\n\n' "$pubkey"
  ask registered 'Press Enter after adding the public key to the PRIVATE repository: '
  # Pinned GitHub host key, from GitHub SSH fingerprint documentation.
  printf '%s\n' 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' >"$config_dir/known_hosts"
  export GIT_SSH_COMMAND="ssh -F /dev/null -i $key_file -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$config_dir/known_hosts -o HostKeyAlgorithms=ssh-ed25519"
  git ls-remote "git@github.com:$repository.git" HEAD >/dev/null || fail 'GitHub access failed. Check the repository and its read-only Deploy Key; SSH port 22 must be reachable.'
}

configure_firewall() {
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

install_panel() {
  [[ ${EUID} == 0 ]] || fail 'Run with sudo bash install.sh.'
  [[ -r /dev/tty ]] || fail 'Run from an interactive SSH terminal.'
  config_dir=/etc/wg-panel
  install_dir=/opt/wg-panel
  if [[ -x $config_dir/compose && -f $install_dir/docker-compose.private.yml ]]; then
    printf 'Existing installation found. Starting it with its saved settings.\n'
    "$config_dir/compose" up -d --wait --wait-timeout 180
    return
  fi
  [[ ! -e $install_dir ]] || fail "$install_dir contains an incomplete installation. Check it before retrying."
  printf 'Private WireGuard panel installer — Ubuntu / Debian\n'
  repository=pashaDeveloper/wg-pasha-master
  branch=''
  printf 'Private repository: %s (default branch)\n' "$repository"
  [[ $repository =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ && $repository != */.. && $repository != */. ]] || fail 'Use OWNER/REPO, not a URL.'
  [[ -z $branch || ( $branch != -* && $branch != *[[:space:]]* ) ]] || fail 'Invalid branch/tag.'
  ask panel_port 'Panel TCP port [51821]: '
  panel_port=${panel_port:-51821}
  valid_port "$panel_port" || fail 'Port must be 1-65535.'
  ask endpoint 'Server public IPv4 address or DNS name (no http:// or path): '
  [[ $endpoint =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail 'Enter a public IPv4 address or DNS name.'
  ask wg_port 'First WireGuard UDP port [51820]: '
  wg_port=${wg_port:-51820}
  valid_port "$wg_port" || fail 'Invalid WireGuard port.'
  ask wg_end "Last WireGuard UDP port [$((wg_port + 100 > 65535 ? 65535 : wg_port + 100))]: "
  wg_end=${wg_end:-$((wg_port + 100 > 65535 ? 65535 : wg_port + 100))}
  valid_port "$wg_end" && (( wg_end >= wg_port )) || fail 'Invalid UDP range.'
  ask username 'Panel administrator username [admin]: '
  username=${username:-admin}
  [[ $username =~ ^[A-Za-z0-9_.-]{2,64}$ ]] || fail 'Use 2-64 letters, numbers, dots, underscores or hyphens.'
  case "$username" in __proto__|constructor|prototype) fail 'Choose a different username.' ;; esac
  secret password 'Panel administrator password (at least 12 characters): '
  (( ${#password} >= 12 )) || fail 'Password must have at least 12 characters.'
  secret confirmation 'Repeat password: '
  [[ $password == "$confirmation" ]] || fail 'Passwords do not match.'
  unset confirmation

  install_dependencies
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
    env_line INIT_USERNAME "$username"
    env_line INIT_PASSWORD "$password"
  } >"$config_dir/panel.env"
  unset password
  chmod 0600 "$config_dir/panel.env"
  # Keep credentials outside the clone and Docker build context.
  printf '#!/usr/bin/env bash\nset -euo pipefail\ncd /opt/wg-panel\nexec docker compose --project-name wg-panel --env-file /etc/wg-panel/panel.env -f docker-compose.private.yml "$@"\n' >"$config_dir/compose"
  chmod 0700 "$config_dir/compose"
  git -C "$install_dir" config core.sshCommand "$GIT_SSH_COMMAND"
  "$config_dir/compose" config --quiet
  "$config_dir/compose" build
  configure_firewall
  "$config_dir/compose" up -d --force-recreate --wait --wait-timeout 180
  local code attempt
  for ((attempt = 0; attempt < 30; attempt++)); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$panel_port/") || code=000
    case "$code" in 200|302|303|307|308)
      printf '\nInstalled: http://%s:%s/\nUsername: %s\n' "$endpoint" "$panel_port" "$username"
      printf 'Manage: sudo /etc/wg-panel/compose ps\nLogs: sudo /etc/wg-panel/compose logs --tail 100\n'
      return 0 ;;
    esac
    sleep 2
  done
  fail 'Container started, but the panel did not respond. Run sudo /etc/wg-panel/compose logs --tail 100.'
}

require_panel() {
  [[ -x $config_dir/compose && -f $config_dir/panel.env ]] || fail 'Install the panel first (option 1).'
}

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
  printf '%s {\n  reverse_proxy 127.0.0.1:%s\n}\n' "$domain" "$port" >"$config_dir/ssl/Caddyfile"
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
  fail 'Certificate or upstream verification failed. Fix the issue and retry option 2.'
}

panel_information() {
  require_panel
  printf 'Repository: pashaDeveloper/wg-pasha-master\n'
  printf 'HTTP address: http://%s:%s/\n' "$(setting INIT_HOST)" "$(setting PANEL_PORT)"
  printf 'Initial administrator: %s\n' "$(setting INIT_USERNAME)"
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
    if [[ -f $config_dir/ssl/compose.yml ]]; then ssl_compose down --volumes; fi
    "$config_dir/compose" down --volumes
    rm -rf -- /opt/wg-panel /etc/wg-panel
    printf 'Panel and its data removed. Remove its Deploy Key entry in GitHub if no longer needed.\n'
  else
    if [[ -f $config_dir/ssl/compose.yml ]]; then ssl_compose down; fi
    "$config_dir/compose" down
    printf 'Containers removed. Data and settings kept. Option 1 starts the panel again; option 2 starts HTTPS.\n'
  fi
  printf 'Docker and shared firewall rules were kept.\n'
}

run_tunnel() {
  printf 'Tunnel setup is not configured yet. This option is reserved for a future update.\n'
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
    printf '\n1. Install panel\n2. Receive SSL certificate\n3. Panel information\n4. Remove panel\n5. Run tunnel\nq) Exit\n'
    ask choice 'Select an option: '
    case "$choice" in
      1) run_action install_panel ;;
      2) run_action receive_ssl ;;
      3) run_action panel_information ;;
      4) run_action remove_panel ;;
      5) run_action run_tunnel ;;
      q|Q) return ;;
      *) printf 'Invalid option.\n' ;;
    esac
  done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
