#!/usr/bin/env bash
set -Eeuo pipefail

# Debian 12 hardened Docker host bootstrap (rootful Docker)
# Read and edit the CONFIG section before first run.

############################
# CONFIG (edit these)
############################
ADMIN_USER="${ADMIN_USER:-}"              # REQUIRED: admin Linux username (existing user)
SSH_PORT="${SSH_PORT:-22}"                # Keep 22 unless you've already moved SSH
HARDEN_SSH="${HARDEN_SSH:-true}"          # true/false
INSTALL_DOCKER="${INSTALL_DOCKER:-false}" # true/false (default false on existing hosts)
ENABLE_UFW="${ENABLE_UFW:-false}"         # true/false (false by default to avoid lockout)
# Comma-separated TCP ports to allow publicly if UFW is enabled. Example: "22,80,443"
UFW_ALLOW_TCP_PORTS="${UFW_ALLOW_TCP_PORTS:-22}"
ENABLE_UNATTENDED_UPGRADES="${ENABLE_UNATTENDED_UPGRADES:-true}"
ENABLE_WATCHTOWER="${ENABLE_WATCHTOWER:-true}"
WATCHTOWER_SCHEDULE="${WATCHTOWER_SCHEDULE:-0 0 4 * * *}"  # 04:00 daily
FORCE_DAEMON_JSON="${FORCE_DAEMON_JSON:-false}"            # true/false; overwrite /etc/docker/daemon.json
PROJECT_PATH="${PROJECT_PATH:-}"                            # Optional: compose project path to harden .env perms

############################
# Helpers
############################
log() { printf "\n[%s] %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root (sudo bash secure-docker-debian12.sh)."
}

check_os() {
  [[ -r /etc/os-release ]] || fail "/etc/os-release not found"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "debian" ]] || fail "This script supports Debian only. Found: ${ID:-unknown}"
  [[ "${VERSION_CODENAME:-}" == "bookworm" ]] || fail "This script targets Debian 12 (bookworm). Found: ${VERSION_CODENAME:-unknown}"
}

ensure_admin_user() {
  [[ -n "$ADMIN_USER" ]] || fail "Set ADMIN_USER env var or edit script CONFIG."
  id "$ADMIN_USER" >/dev/null 2>&1 || fail "Admin user '$ADMIN_USER' does not exist."
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

configure_sysctl() {
  log "Applying baseline inbound/network hardening sysctl settings"
  cat >/etc/sysctl.d/99-docker-host-hardening.conf <<'SYSCTL'
# Inbound/network hardening baseline
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
kernel.randomize_va_space = 2
SYSCTL
  sysctl --system >/dev/null
}

install_base_security_tools() {
  log "Installing security baseline packages"
  apt_install ca-certificates curl gnupg lsb-release ufw fail2ban apparmor apparmor-utils
}

configure_ssh() {
  [[ "$HARDEN_SSH" == "true" ]] || { log "Skipping SSH hardening"; return; }

  log "Hardening SSH"
  install -m 0644 -D /dev/null /etc/ssh/sshd_config.d/99-hardening.conf
  cat >/etc/ssh/sshd_config.d/99-hardening.conf <<EOFSSH
# Managed by secure-docker-debian12.sh
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
X11Forwarding no
AllowTcpForwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
EOFSSH

  sshd -t
  systemctl reload ssh
}

configure_fail2ban() {
  log "Configuring fail2ban for SSH"
  install -m 0644 -D /dev/null /etc/fail2ban/jail.d/sshd.local
  cat >/etc/fail2ban/jail.d/sshd.local <<EOFJAIL
[sshd]
enabled = true
port = ${SSH_PORT}
logpath = %(sshd_log)s
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOFJAIL
  systemctl enable --now fail2ban
}

install_docker() {
  [[ "$INSTALL_DOCKER" == "true" ]] || { log "Skipping Docker install"; return; }

  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed; ensuring packages are up to date"
  else
    log "Installing Docker CE from official Docker repository"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    cat >/etc/apt/sources.list.d/docker.list <<EOFDOCKERLIST
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable
EOFDOCKERLIST
  fi

  apt-get update
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

configure_docker_daemon() {
  log "Applying Docker daemon hardening baseline"
  install -d -m 0755 /etc/docker

  if [[ -f /etc/docker/daemon.json && "$FORCE_DAEMON_JSON" != "true" ]]; then
    log "Existing /etc/docker/daemon.json detected; not overwriting (set FORCE_DAEMON_JSON=true to replace)"
    return
  fi

  if [[ -f /etc/docker/daemon.json ]]; then
    cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
  fi

  # NOTE: Avoid userns-remap by default to prevent breaking existing root-run containers.
  cat >/etc/docker/daemon.json <<'EOFDOCKERJSON'
{
  "live-restore": true,
  "icc": false,
  "userland-proxy": false,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOFDOCKERJSON

  systemctl restart docker
}

grant_docker_access() {
  log "Granting Docker access to admin user: $ADMIN_USER"
  getent group docker >/dev/null || groupadd docker
  usermod -aG docker "$ADMIN_USER"
}

configure_unattended_upgrades() {
  [[ "$ENABLE_UNATTENDED_UPGRADES" == "true" ]] || { log "Skipping unattended-upgrades"; return; }

  log "Configuring unattended security upgrades"
  apt_install unattended-upgrades apt-listchanges
  dpkg-reconfigure -f noninteractive unattended-upgrades || true

  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOFAUTO'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOFAUTO
}

configure_ufw() {
  [[ "$ENABLE_UFW" == "true" ]] || { log "Skipping UFW changes (ENABLE_UFW=false)"; return; }

  log "Configuring UFW"
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  IFS=',' read -ra PORTS <<<"$UFW_ALLOW_TCP_PORTS"
  for p in "${PORTS[@]}"; do
    p_trimmed="$(echo "$p" | xargs)"
    [[ -n "$p_trimmed" ]] && ufw allow "${p_trimmed}/tcp"
  done

  ufw --force enable
  ufw status verbose
}

install_watchtower() {
  [[ "$ENABLE_WATCHTOWER" == "true" ]] || { log "Skipping Watchtower"; return; }

  log "Deploying Watchtower for automatic container updates"
  docker rm -f watchtower >/dev/null 2>&1 || true
  docker run -d \
    --name watchtower \
    --restart unless-stopped \
    -v /var/run/docker.sock:/var/run/docker.sock \
    containrrr/watchtower \
    --schedule "$WATCHTOWER_SCHEDULE" \
    --cleanup \
    --rolling-restart
}

harden_env_permissions() {
  log "Applying baseline .env permissions"
  if [[ -d /opt ]]; then
    find /opt -type f -name '.env' -exec chown "$ADMIN_USER:$ADMIN_USER" {} + 2>/dev/null || true
    find /opt -type f -name '.env' -exec chmod 600 {} + 2>/dev/null || true
  fi

  if [[ -n "$PROJECT_PATH" && -d "$PROJECT_PATH" ]]; then
    find "$PROJECT_PATH" -maxdepth 2 -type f \( -name '.env' -o -name '.env.*' \) -exec chown "$ADMIN_USER:$ADMIN_USER" {} + 2>/dev/null || true
    find "$PROJECT_PATH" -maxdepth 2 -type f \( -name '.env' -o -name '.env.*' \) -exec chmod 600 {} + 2>/dev/null || true
  fi
}

print_next_steps() {
  cat <<'EOFNEXT'

Setup complete.

Post-checks:
1. Reconnect SSH in a separate terminal before closing your current session.
2. Confirm Docker access for admin user (new login required): docker ps
3. Verify fail2ban: fail2ban-client status sshd
4. Verify unattended upgrades: systemctl status unattended-upgrades
5. Verify Watchtower logs: docker logs --tail 50 watchtower

Recommended container runtime flags going forward:
- --read-only
- --cap-drop ALL
- --security-opt no-new-privileges:true
- --pids-limit 200
- --memory / --cpus limits
EOFNEXT
}

main() {
  require_root
  check_os
  ensure_admin_user

  apt-get update
  install_base_security_tools
  configure_sysctl
  configure_ssh
  configure_fail2ban
  install_docker
  configure_docker_daemon
  grant_docker_access
  configure_unattended_upgrades
  configure_ufw
  install_watchtower
  harden_env_permissions
  print_next_steps
}

main "$@"
