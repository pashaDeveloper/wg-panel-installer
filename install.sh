#!/usr/bin/env bash
# Public entry point. Fetch the current installer only after repository access works.
set -Eeuo pipefail
set +x
umask 077

bootstrap_fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

bootstrap_dependencies() {
  source /etc/os-release
  case "$ID" in ubuntu|debian) ;; *) bootstrap_fail 'Supported servers: Ubuntu or Debian.' ;; esac
  if ! command -v git >/dev/null || ! command -v ssh-keygen >/dev/null; then
    apt-get update
    apt-get install -y ca-certificates git openssh-client
  fi
}

bootstrap_access() {
  local config_dir=/etc/wg-panel key_file=/etc/wg-panel/deploy_key public_key choice
  install -d -m 0700 "$config_dir"
  if [[ ! -e $key_file ]]; then
    ssh-keygen -q -t ed25519 -N '' -C wg-panel-deploy -f "$key_file"
  fi
  chmod 0600 "$key_file"
  public_key=$(ssh-keygen -y -P '' -f "$key_file") || bootstrap_fail 'The saved Deploy Key must be unencrypted.'
  printf '%s\n' 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' >"$config_dir/known_hosts"
  export GIT_SSH_COMMAND="ssh -F /dev/null -i $key_file -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$config_dir/known_hosts -o HostKeyAlgorithms=ssh-ed25519"
  if git ls-remote git@github.com:pashaDeveloper/wg-pasha-master.git HEAD >/dev/null 2>&1; then
    printf 'Saved Deploy Key authorized. Downloading the current installer.\n'
    return
  fi
  printf '\nAdd this PUBLIC key at:\nhttps://github.com/pashaDeveloper/wg-pasha-master/settings/keys\nLeave Allow write access OFF.\n\n%s\n\n' "$public_key"
  while true; do
    printf '[Enter] Check access and continue | [Q] Cancel: ' >/dev/tty
    IFS= read -r choice </dev/tty || bootstrap_fail 'Input cancelled.'
    case "$choice" in q|Q) exit 130 ;; '') ;; *) continue ;; esac
    if git ls-remote git@github.com:pashaDeveloper/wg-pasha-master.git HEAD >/dev/null; then
      return
    fi
    printf 'Access is not ready. Register the key on the main repository, then retry here.\n'
  done
}

bootstrap_main() (
  [[ ${EUID} == 0 ]] || bootstrap_fail 'Run with sudo bash bootstrap.sh.'
  [[ -r /dev/tty ]] || bootstrap_fail 'Run from an interactive SSH terminal.'
  bootstrap_dependencies
  bootstrap_access
  local bootstrap_tmp revision
  bootstrap_tmp=$(mktemp -d)
  trap 'rm -rf -- "$bootstrap_tmp"' EXIT
  git clone --depth 1 --filter=blob:none --no-checkout \
    git@github.com:pashaDeveloper/wg-pasha-master.git "$bootstrap_tmp/source"
  revision=$(git -C "$bootstrap_tmp/source" rev-parse HEAD)
  git -C "$bootstrap_tmp/source" show HEAD:public-installer/install.sh >"$bootstrap_tmp/install.sh"
  [[ -s $bootstrap_tmp/install.sh ]] || bootstrap_fail 'The main repository does not contain the installer.'
  bash -n "$bootstrap_tmp/install.sh"
  printf 'Installer downloaded from main repository revision: %s\n' "$revision"
  bash "$bootstrap_tmp/install.sh"
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then bootstrap_main "$@"; fi
