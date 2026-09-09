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

main() {
  [[ ${EUID} == 0 ]] || fail 'Run with sudo bash install.sh.'
  [[ -r /dev/tty ]] || fail 'Run from an interactive SSH terminal.'
  config_dir=/etc/wg-panel
  install_dir=/opt/wg-panel
  [[ ! -e $install_dir ]] || fail "$install_dir already exists. Use the update instructions in README; existing data was not changed."
  printf 'Private WireGuard panel installer — Ubuntu / Debian\n'
  ask repository 'Private GitHub repository (OWNER/REPO): '
  [[ $repository =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ && $repository != */.. && $repository != */. ]] || fail 'Use OWNER/REPO, not a URL.'
  ask branch 'Branch or tag (blank = repository default branch): '
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

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  trap 'printf "Installation stopped at line %s. Existing files and volumes were preserved.\n" "$LINENO" >&2' ERR
  main "$@"
fi
