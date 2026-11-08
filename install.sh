#!/usr/bin/env bash
# =============================================================================
#  One-shot installer: InfiniDysk 2.x beta (built-in mount, no rclone)
#  + Sonarr/Radarr/Prowlarr (develop) + Silo media server, all under /data.
#
#  Usage:
#    sudo bash install.sh              fresh install; asks before wiping anything
#    sudo bash install.sh --wipe-yes   fresh install, wipe without asking
#    sudo bash install.sh --upgrade    move an existing 1.x + rclone stack to
#                                      InfiniDysk 2.x; keeps all settings, logins
#                                      and library symlinks, wipes nothing
#    sudo bash install.sh --update     already on 2.x: refresh compose, dashboard
#                                      and images; keeps everything, wipes nothing
#  Files are owned by, and the apps run as, a normal (non-root) user. The script
#  picks: RUN_USER=name if given > owner of an existing stack > whoever ran sudo
#  > your login name > asks you. Example: sudo RUN_USER=alice bash install.sh
#
#  Optional overrides (prefix the command):
#    sudo PUID=1000 PGID=1000 TZ=Europe/London bash install.sh
# =============================================================================
set -euo pipefail

STACK_DIR=/data/stack
TZ="${TZ:-$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---- Which user owns the files and runs the apps ---------------------------
usable() { [ -n "$1" ] && [ "$1" != root ] && id "$1" >/dev/null 2>&1; }
RUN_USER="${RUN_USER:-}"
if [ -n "$RUN_USER" ]; then
  usable "$RUN_USER" || die "RUN_USER '$RUN_USER' doesn't exist or is root - use a normal user"
else
  # 1. keep the owner of an existing stack, so updates don't change ownership
  OLD_PUID="$(grep -oP '^PUID=\K[0-9]+' "$STACK_DIR/.env" 2>/dev/null || true)"
  [ -n "$OLD_PUID" ] && RUN_USER="$(getent passwd "$OLD_PUID" | cut -d: -f1 || true)"
  # 2. whoever ran sudo, 3. the login name
  usable "$RUN_USER" || RUN_USER="${SUDO_USER:-}"
  usable "$RUN_USER" || RUN_USER="$(logname 2>/dev/null || true)"
  # 4. ask
  if ! usable "$RUN_USER"; then
    [ -t 0 ] || die "Can't tell which user to use. Re-run as: sudo RUN_USER=<your username> bash install.sh"
    mapfile -t CANDIDATES < <(getent passwd | awk -F: '$3>=1000 && $3<60000 && $6 ~ /^\/home\// && $7 !~ /(nologin|false)$/ {print $1}')
    echo "Which normal (non-root) user should own the media files and run the apps?"
    [ "${#CANDIDATES[@]}" -gt 0 ] && echo "  Users on this machine: ${CANDIDATES[*]}"
    read -rp "  Username: " RUN_USER
    usable "$RUN_USER" || die "'$RUN_USER' isn't a normal user on this machine"
  fi
fi
PUID="${PUID:-$(id -u "$RUN_USER")}"
PGID="${PGID:-$(id -g "$RUN_USER")}"
USER_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"

WIPE_YES=0; UPGRADE=0; UPDATE=0
for a in "$@"; do
  case "$a" in
    --wipe-yes) WIPE_YES=1 ;;
    --upgrade)  UPGRADE=1 ;;
    --update)   UPDATE=1 ;;
    *) die "unknown option: $a" ;;
  esac
done
MOUNT_DIR=/data/mount/infinidysk    # same path rclone used, so old symlinks keep working

# ----------------------------------------------------------------------------
say "Checking prerequisites"
[ "$(id -u)" -eq 0 ] || die "run with sudo:  sudo bash install.sh"
command -v docker >/dev/null || die "Docker is not installed (https://docs.docker.com/engine/install/)"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 plugin is missing"
command -v openssl >/dev/null || die "openssl is missing (apt install openssl)"
if [ ! -e /dev/fuse ]; then
  if command -v apt-get >/dev/null; then
    warn "Installing fuse3"; apt-get update -qq && apt-get install -y -qq fuse3
  fi
  [ -e /dev/fuse ] || die "/dev/fuse missing - install fuse3 and re-run"
fi
grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null || echo user_allow_other >> /etc/fuse.conf
echo "    OK  (user=$RUN_USER PUID=$PUID PGID=$PGID home=$USER_HOME TZ=$TZ)"

# ----------------------------------------------------------------------------
# Clean slate: remove ALL existing containers and their config/data.
#   - Shows everything first and asks you to type WIPE (or pass --wipe-yes).
#   - Never deletes system paths, mount points, or folders containing media.
#   - /data/media (your library) is always kept.
# ----------------------------------------------------------------------------

is_protected() {
  local p="${1%/}"; [ -z "$p" ] && return 0
  case "$p" in
    /|/root|/home|/home/*[!/]|/etc|/etc/*|/usr|/usr/*|/bin*|/sbin*|/lib*|/boot*|\
    /dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/run|/run/*|/tmp|/var|/var/lib|/var/run*|\
    /var/lib/docker*|/opt|/srv|/mnt|/media|/data|/data/media|/data/media/*) ;;
    *) return 1 ;;
  esac
  # /home/<user>/something is fine; /home/<user> itself is protected
  # Inside a home folder: the folder itself and its top level (Downloads,
  # Documents, Videos...) are protected; deeper app folders such as
  # /home/<user>/docker/sonarr can be removed.
  [[ "$p" == /home/*/*/* ]] && return 1
  return 0
}
has_media() {
  find "$1" -xdev -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' \
    -o -iname '*.m4v' -o -iname '*.ts' -o -iname '*.iso' -o -iname '*.flac' \
    -o -iname '*.mp3' -o -iname '*.epub' -o -iname '*.m4b' \) -print -quit 2>/dev/null | grep -q .
}
contains_mount() { findmnt -rn -o TARGET | awk -v p="${1%/}" '$0==p || index($0, p"/")==1' | grep -q .; }

if [ "$UPGRADE" -eq 1 ]; then
  # --------------------------------------------------------------------------
  # Upgrade InfiniDysk 1.x + rclone -> 2.x, following infinidysk.com/v2/upgrade
  # --------------------------------------------------------------------------
  [ -f "$STACK_DIR/.env" ] && [ -f "$STACK_DIR/docker-compose.yml" ] \
    || die "No existing stack in $STACK_DIR - run without --upgrade for a fresh install."
  cd "$STACK_DIR"
  BACKUP="$STACK_DIR/backup-v1-$(date +%Y%m%d-%H%M%S)"
  say "Backing up current stack files to $BACKUP"
  mkdir -p "$BACKUP"
  cp -a docker-compose.yml .env "$BACKUP"/
  [ -f docker-compose.gpu.yml ] && cp -a docker-compose.gpu.yml "$BACKUP"/

  say "Stopping InfiniDysk 1.x and removing rclone"
  docker compose stop infinidysk >/dev/null 2>&1 || true
  docker compose rm -sf rclone >/dev/null 2>&1 || true
  docker rm -f rclone >/dev/null 2>&1 || true
  if mountpoint -q "$MOUNT_DIR"; then
    fusermount3 -uz "$MOUNT_DIR" 2>/dev/null || fusermount -uz "$MOUNT_DIR" 2>/dev/null || umount -l "$MOUNT_DIR" || true
  fi
  mountpoint -q "$MOUNT_DIR" && die "$MOUNT_DIR is still mounted - unmount it and re-run."
  echo "    rclone gone, $MOUNT_DIR unmounted"

  say "Copying InfiniDysk config for 2.x (1.x config is left untouched for rollback)"
  if [ -d /data/config/infinidysk-2.0 ]; then
    echo "    /data/config/infinidysk-2.0 already exists - keeping it (not re-copying)"
  else
    cp -a /data/config/infinidysk /data/config/infinidysk-2.0
    echo "    /data/config/infinidysk -> /data/config/infinidysk-2.0"
  fi

  say "Updating $STACK_DIR/.env for 2.x"
  sed -i 's/^INFINIDYSK_TAG=.*/INFINIDYSK_TAG=edge/' .env
  sed -i 's/^# InfiniDysk: dev (noisiest) | rc | latest | lts$/# InfiniDysk 2.x beta (image infinidysk-next): edge | v2.0.0-beta.N | sha-<commit>/' .env
  sed -i '/^# ---- rclone/d;/^RCLONE_/d;s/ (also used by rclone)//' .env
  sed -i '/^INFINIDYSK_CONFIG=/d' .env
  sed -i '/^INFINIDYSK_TAG=/a INFINIDYSK_CONFIG=/data/config/infinidysk-2.0' .env
  rm -f /data/config/rclone/rclone.conf
  echo "    image -> infinidysk-next:edge, rclone settings removed"
elif [ "$UPDATE" -eq 1 ]; then
  [ -f "$STACK_DIR/.env" ] && [ -f "$STACK_DIR/docker-compose.yml" ] \
    || die "No existing stack in $STACK_DIR - run without --update for a fresh install."
  if grep -q '^RCLONE_' "$STACK_DIR/.env" || grep -q '^  rclone:' "$STACK_DIR/docker-compose.yml"; then
    die "This stack is still on InfiniDysk 1.x with rclone - run: sudo bash install.sh --upgrade"
  fi
  say "Updating existing stack (nothing is wiped)"
  BACKUP="$STACK_DIR/backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP" && cp -a "$STACK_DIR/docker-compose.yml" "$STACK_DIR/.env" "$BACKUP"/
  echo "    previous compose/.env saved to $BACKUP"
else

mapfile -t CONTAINERS < <(docker ps -aq)
OLD_STACK=0; { [ -d /data/config ] || [ -d /data/stack ]; } && OLD_STACK=1

# Media apps installed natively (apt / systemd), not in Docker
NATIVE_SVCS=(sonarr radarr prowlarr lidarr readarr whisparr bazarr jellyfin jellyseerr overseerr emby-server plexmediaserver)
NATIVE=()
for s in "${NATIVE_SVCS[@]}"; do
  systemctl list-unit-files --no-legend "$s.service" 2>/dev/null | grep -q . && NATIVE+=("$s")
done

# Orphaned *arr configs anywhere on local disks (e.g. a container deleted
# earlier, or a native install's data folder). Found by their database file.
say "Searching local disks for old Sonarr/Radarr/Prowlarr configs (can take a minute)"
ORPHANS=()
while IFS= read -r fs; do
  while IFS= read -r db; do ORPHANS+=("$(dirname "$db")"); done < <(
    find "$fs" -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run \
         -o -path /var/lib/docker -o -path /data/media -o -path /data/mount \
         -o -path /data/config -o -path /data/stack -o -path /snap \) -prune \
      -o -type f \( -name sonarr.db -o -name radarr.db -o -name prowlarr.db \
         -o -name lidarr.db -o -name readarr.db -o -name whisparr.db \) -print 2>/dev/null)
done < <(findmnt -rn -o TARGET -t ext2,ext3,ext4,xfs,btrfs,zfs,f2fs | sort -u)
for s in "${NATIVE[@]}"; do [ -d "/var/lib/$s" ] && ORPHANS+=("/var/lib/$s"); done
mapfile -t ORPHANS < <(printf '%s\n' "${ORPHANS[@]}" | sort -u | sed '/^$/d')
echo "    Found ${#ORPHANS[@]} config folder(s), ${#NATIVE[@]} native app(s), ${#CONTAINERS[@]} container(s)."

if [ "${#CONTAINERS[@]}" -gt 0 ] || [ "$OLD_STACK" -eq 1 ] || [ "${#NATIVE[@]}" -gt 0 ] || [ "${#ORPHANS[@]}" -gt 0 ]; then
  say "Existing media setup found - planning cleanup"
  DEL_DIRS=(); KEEP_DIRS=(); VOLUMES=()
  classify() {  # decide delete/keep for one host folder
    local src="$1"
    if is_protected "$src" || contains_mount "$src"; then KEEP_DIRS+=("$src (system/mount point)")
    elif has_media "$src"; then KEEP_DIRS+=("$src (contains media files)")
    else DEL_DIRS+=("$src"); fi
  }
  if [ "${#CONTAINERS[@]}" -gt 0 ]; then
    echo "    Containers to remove:"
    docker ps -a --format '      - {{.Names}}  ({{.Image}}, {{.Status}})'
    while IFS='|' read -r type src name; do
      [ -z "$type" ] && continue
      if [ "$type" = "volume" ]; then VOLUMES+=("$name"); continue; fi
      [ "$type" = "bind" ] && [ -d "$src" ] || continue
      classify "$src"
    done < <(docker inspect -f '{{range .Mounts}}{{.Type}}|{{.Source}}|{{.Name}}{{"\n"}}{{end}}' "${CONTAINERS[@]}" | sort -u)
  fi
  if [ "${#NATIVE[@]}" -gt 0 ]; then
    echo "    Native apps to stop and uninstall:"
    printf '      - %s\n' "${NATIVE[@]}"
  fi
  # Folders identified by an *arr database are app config for certain, so they
  # may be deleted even directly inside a home folder (e.g. /home/<user>/sonarr).
  for d in "${ORPHANS[@]}"; do
    if [[ "$d" == /home/*/* ]] && ! contains_mount "$d" && ! has_media "$d"; then DEL_DIRS+=("$d")
    else classify "$d"; fi
  done
  # Previous run of this installer (library is kept)
  for d in /data/config /data/cache /data/stack; do [ -d "$d" ] && DEL_DIRS+=("$d"); done
  mapfile -t DEL_DIRS  < <(printf '%s\n' "${DEL_DIRS[@]}"  | sort -u | sed '/^$/d')
  mapfile -t KEEP_DIRS < <(printf '%s\n' "${KEEP_DIRS[@]}" | sort -u | sed '/^$/d')
  mapfile -t VOLUMES   < <(printf '%s\n' "${VOLUMES[@]}"   | sort -u | sed '/^$/d')

  [ "${#VOLUMES[@]}" -gt 0 ]   && { echo "    Docker volumes to delete:";  printf '      - %s\n' "${VOLUMES[@]}"; }
  [ "${#DEL_DIRS[@]}" -gt 0 ]  && { echo "    Host folders to DELETE:";     printf '      - %s\n' "${DEL_DIRS[@]}"; }
  [ "${#KEEP_DIRS[@]}" -gt 0 ] && { echo "    Host folders KEPT (safety):"; printf '      - %s\n' "${KEEP_DIRS[@]}"; }
  echo "    Unused images and networks will also be pruned."
  echo "    /data/media (your library) is NOT touched."

  if [ "$WIPE_YES" -ne 1 ]; then
    if [ -t 0 ]; then
      printf '\n\033[1;31m    This cannot be undone. Type WIPE to continue, anything else to abort: \033[0m'
      read -r answer
      [ "$answer" = "WIPE" ] || die "Aborted - nothing was removed."
    else
      die "Existing setup found and no terminal to confirm. Re-run with --wipe-yes to remove it."
    fi
  fi

  say "Removing old setup"
  [ "${#CONTAINERS[@]}" -gt 0 ] && docker rm -f "${CONTAINERS[@]}" >/dev/null
  for s in "${NATIVE[@]}"; do
    systemctl disable --now "$s.service" >/dev/null 2>&1 || true
    if dpkg -s "$s" >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "$s" >/dev/null 2>&1 || warn "could not purge package $s"
    fi
    for u in "/etc/systemd/system/$s.service" "/lib/systemd/system/$s.service"; do
      [ -f "$u" ] && ! dpkg -S "$u" >/dev/null 2>&1 && rm -f "$u"
    done
    echo "    removed native $s"
  done
  systemctl daemon-reload 2>/dev/null || true
  # Release a stale rclone FUSE mount from a previous run before deleting around it
  if mountpoint -q /data/mount/infinidysk; then
    fusermount3 -uz /data/mount/infinidysk 2>/dev/null || fusermount -uz /data/mount/infinidysk 2>/dev/null \
      || umount -l /data/mount/infinidysk || true
  fi
  [ "${#VOLUMES[@]}" -gt 0 ] && docker volume rm -f "${VOLUMES[@]}" >/dev/null || true
  for d in "${DEL_DIRS[@]}"; do
    # Re-check right before deleting
    if [ -e "$d" ] && ! contains_mount "$d" && { ! is_protected "$d" || [[ "$d" == /home/*/* ]]; }; then
      rm -rf --one-file-system -- "$d"; echo "    deleted $d"
    fi
  done
  docker network prune -f >/dev/null
  docker image prune -af >/dev/null

  # Verify: nothing old should be left
  LEFT="$(for fs in $(findmnt -rn -o TARGET -t ext2,ext3,ext4,xfs,btrfs,zfs,f2fs | sort -u); do
    find "$fs" -xdev \( -path /proc -o -path /sys -o -path /var/lib/docker -o -path /data/media -o -path /data/mount \) -prune \
      -o -type f \( -name sonarr.db -o -name radarr.db -o -name prowlarr.db \) -print 2>/dev/null; done | sort -u)"
  if [ -n "$LEFT" ]; then
    warn "Still present (kept for safety - check and remove by hand if you want them gone):"
    printf '%s\n' "$LEFT" | sed 's/^/      - /'
  else
    echo "    Verified: no old Sonarr/Radarr/Prowlarr configs remain."
  fi
else
  echo "    Nothing existing found - clean install."
fi
fi   # end: fresh install (not --upgrade)

# ----------------------------------------------------------------------------
say "Creating folders under /data"
mkdir -p \
  "$STACK_DIR" \
  /data/config/{infinidysk,sonarr,radarr,prowlarr,homepage,embed-proxy,logs} \
  /data/config/silo/{plugins,compat,transcode,catalog-seeds,postgres,redis} \
  "$MOUNT_DIR" \
  /data/media/{movies,tv}
chown -R "$PUID:$PGID" \
  /data/config/{infinidysk,sonarr,radarr,prowlarr,homepage} \
  /data/config/silo/{plugins,compat,transcode,catalog-seeds} \
  /data/media "$STACK_DIR"
[ -d /data/config/infinidysk-2.0 ] && chown -R "$PUID:$PGID" /data/config/infinidysk-2.0
chown "$PUID:$PGID" "$MOUNT_DIR" 2>/dev/null || true   # may already be a live mount
chmod -R u+rwX,g+rwX /data/media

# ----------------------------------------------------------------------------
say "Making /data a shared mount (so InfiniDysk's mount reaches the other containers)"
cat > /etc/systemd/system/data-shared.service <<'EOF'
[Unit]
Description=Make /data a shared mount for Docker FUSE propagation
Before=docker.service
RequiresMountsFor=/data

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'mountpoint -q /data || mount --bind /data /data; mount --make-rshared /data'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
if command -v systemctl >/dev/null && [ -d /run/systemd/system ]; then
  systemctl daemon-reload
  systemctl enable --now data-shared.service >/dev/null
else
  mountpoint -q /data || mount --bind /data /data
  mount --make-rshared /data
  warn "No systemd: /data made shared for this boot only - rerun this script after reboot."
fi
echo "    /data propagation: $(findmnt -no PROPAGATION -T /data)"

# ----------------------------------------------------------------------------
say "Writing $STACK_DIR/.env (secrets are generated once and kept)"
ENV_FILE="$STACK_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<EOF
# ---- General ---------------------------------------------------------------
PUID=$PUID
PGID=$PGID
TZ=$TZ

# ---- Image channels ----------------------------------------------------------
# InfiniDysk 2.x beta (image infinidysk-next): edge | v2.0.0-beta.N | sha-<commit>
INFINIDYSK_TAG=edge
INFINIDYSK_CONFIG=/data/config/infinidysk
# Sonarr/Radarr/Prowlarr (linuxserver): develop | latest
ARR_TAG=develop
# Silo: latest tracks main; pin build-N or a commit SHA to freeze it
SILO_TAG=latest

# ---- Host ports --------------------------------------------------------------
INFINIDYSK_PORT=3000
SONARR_PORT=8989
RADARR_PORT=7878
PROWLARR_PORT=9696
SILO_PORT=8090
SILO_JF_PORT=8096
SILO_ABS_PORT=13378

# ---- InfiniDysk WebDAV login (for WebDAV clients; the mount doesn't need it) --
WEBDAV_USER=webdav
WEBDAV_PASS=$(openssl rand -hex 16)

# ---- Silo --------------------------------------------------------------------
POSTGRES_USER=silo
POSTGRES_DB=silo
POSTGRES_SHM_SIZE=8gb
POSTGRES_PASSWORD=$(openssl rand -hex 24)
# Back up SECRET_KEY separately - losing it makes Silo's encrypted secrets unrecoverable.
SECRET_KEY=$(openssl rand -base64 48 | tr -d '\n')
EOF
else
  echo "    Existing .env kept"
fi
# 1.x image tags don't exist for 2.x
sed -i 's/^INFINIDYSK_TAG=\(dev\|rc\|latest\|lts\)$/INFINIDYSK_TAG=edge/' "$ENV_FILE"
grep -q '^INFINIDYSK_CONFIG=' "$ENV_FILE" || echo "INFINIDYSK_CONFIG=/data/config/infinidysk" >> "$ENV_FILE"
# Dashboard port: keep the one already chosen, else port 80 if free, else 3001
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; IP="${IP:-localhost}"
HP_PORT="$(grep -oP '^HOMEPAGE_PORT=\K.*' "$ENV_FILE" || true)"
if [ -z "$HP_PORT" ]; then
  if [ -z "$(ss -tlnH 'sport = :80' 2>/dev/null)" ]; then HP_PORT=80; else HP_PORT=3001; fi
fi
HP_HOSTS="$IP:$HP_PORT,localhost:$HP_PORT,$(hostname):$HP_PORT"
[ "$HP_PORT" = 80 ] && HP_HOSTS="$IP,localhost,$(hostname),$HP_HOSTS"
# Web SSH terminal: connects to this server's own SSH daemon
SSH_PORT="$( (sshd -T 2>/dev/null || true) | awk '$1=="port"{print $2; exit}')"; SSH_PORT="${SSH_PORT:-22}"
WT_ORIGINS="http://$IP:3004,http://localhost:3004,http://$(hostname):3004"
sed -i '/^# ---- Dashboard/d;/^HOMEPAGE_PORT=/d;/^HOMEPAGE_ALLOWED_HOSTS=/d;/^HOST_IP=/d;/^SSH_PORT=/d;/^SSH_USER=/d;/^WETTY_PORT=/d;/^WETTY_ORIGINS=/d' "$ENV_FILE"
cat >> "$ENV_FILE" <<EOF
# ---- Dashboard (managed by install.sh) ---------------------------------------
HOMEPAGE_PORT=$HP_PORT
HOMEPAGE_ALLOWED_HOSTS=$HP_HOSTS
HOST_IP=$IP
SSH_PORT=$SSH_PORT
SSH_USER=$RUN_USER
WETTY_ORIGINS=$WT_ORIGINS
EOF
chmod 600 "$ENV_FILE"
chown "$PUID:$PGID" "$ENV_FILE"
set -a; . "$ENV_FILE"; set +a

# ----------------------------------------------------------------------------
say "Writing $STACK_DIR/docker-compose.yml"
cat > "$STACK_DIR/docker-compose.yml" <<'EOF'
# Media stack - generated by install.sh. Everything lives under /data and every
# app sees it at the same path, so symlinks resolve in every container.

x-common-env: &common-env
  PUID: ${PUID}
  PGID: ${PGID}
  TZ: ${TZ}

services:

  # InfiniDysk 2.x: Usenet streaming, SABnzbd-compatible API, WebDAV, and its
  # own FUSE mount (replaces rclone). UI, API and WebDAV all on port 3000.
  # Settings set here show as "Set by environment" (locked) in its UI.
  # Health check is built into the image.
  infinidysk:
    image: ghcr.io/infinidysk/infinidysk-next:${INFINIDYSK_TAG:-edge}
    container_name: infinidysk
    restart: unless-stopped
    environment:
      <<: *common-env
      INFINIDYSK__MOUNT__DIR: /data/mount/infinidysk
      INFINIDYSK__WEBDAV__USER: ${WEBDAV_USER}
      INFINIDYSK__WEBDAV__PASSWORD: ${WEBDAV_PASS}
      INFINIDYSK__IMPORTS__STRATEGY: symlinks
      INFINIDYSK__SAB__CATEGORIES: '["tv","movies"]'
      INFINIDYSK__IMPORTS__LIBRARY_DIRS: '[{"path":"/data/media/tv","arr_path":"/data/media/tv"},{"path":"/data/media/movies","arr_path":"/data/media/movies"}]'
    ports:
      - "${INFINIDYSK_PORT:-3000}:3000"
    volumes:
      - ${INFINIDYSK_CONFIG:-/data/config/infinidysk}:/config
      - /data:/data:rshared                                   # mount appears on host + other containers
      - /sys/devices/virtual/bdi:/sys/devices/virtual/bdi:rw  # optional: faster sequential reads
    devices:
      - /dev/fuse:/dev/fuse
    cap_add: [SYS_ADMIN]
    security_opt: [apparmor:unconfined]

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:${ARR_TAG:-develop}
    container_name: prowlarr
    restart: unless-stopped
    environment:
      <<: *common-env
    ports:
      - "${PROWLARR_PORT:-9696}:9696"
    volumes:
      - /data/config/prowlarr:/config

  sonarr:
    image: lscr.io/linuxserver/sonarr:${ARR_TAG:-develop}
    container_name: sonarr
    restart: unless-stopped
    environment:
      <<: *common-env
    ports:
      - "${SONARR_PORT:-8989}:8989"
    volumes:
      - /data/config/sonarr:/config
      - /data:/data:rslave
    depends_on: [infinidysk]

  radarr:
    image: lscr.io/linuxserver/radarr:${ARR_TAG:-develop}
    container_name: radarr
    restart: unless-stopped
    environment:
      <<: *common-env
    ports:
      - "${RADARR_PORT:-7878}:7878"
    volumes:
      - /data/config/radarr:/config
      - /data:/data:rslave
    depends_on: [infinidysk]

  # Dashboard: one page with every app, container status and live stats.
  # Config in /data/config/homepage (services.yaml is rewritten by install.sh).
  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    restart: unless-stopped
    environment:
      HOMEPAGE_ALLOWED_HOSTS: ${HOMEPAGE_ALLOWED_HOSTS}
    ports:
      - "${HOMEPAGE_PORT:-3001}:3000"
    volumes:
      - /data/config/homepage:/app/config
      - /data:/data:ro                                  # disk-space widget
      - /var/run/docker.sock:/var/run/docker.sock:ro    # running/stopped status
      - /sys:/sys:ro                                    # network usage of the host's card

  # Log viewer for the dashboard: pick any app from a dropdown, logs stream live.
  # Small read-only Python app written by install.sh into /data/config/logs.
  logs:
    image: python:3.12-alpine
    container_name: logs
    restart: unless-stopped
    command: ["python", "-u", "/app/app.py"]
    environment:
      PORT: "8080"
    ports:
      - "${LOGS_PORT:-3006}:8080"
    volumes:
      - /data/config/logs:/app:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro

  # Web SSH terminal for the dashboard. It's a normal SSH login to this server
  # (your Linux password), so it needs sshd running with password login allowed.
  wetty:
    image: wettyoss/wetty:latest
    container_name: wetty
    restart: unless-stopped
    environment:
      ALLOWEDORIGINS: ${WETTY_ORIGINS}
    # No port of its own: WeTTY's headers force HTTPS, which breaks plain-HTTP
    # access. Use it through embed-proxy on port 3004, which removes them.
    command:
      - --ssh-host=${HOST_IP}
      - --ssh-port=${SSH_PORT:-22}
      - --ssh-user=${SSH_USER}
      - --base=/wetty
      - --allow-iframe
      - --title=Server

  # Serves InfiniDysk to the dashboard without the "don't embed me" headers,
  # so it can show inside the Home page. Only used by the dashboard frame.
  embed-proxy:
    image: nginx:alpine
    container_name: embed-proxy
    restart: unless-stopped
    ports:
      - "${EMBED_PORT:-3002}:3002"      # InfiniDysk for the dashboard
      - "3004:3004"                      # web SSH terminal for the dashboard
    volumes:
      - /data/config/embed-proxy/default.conf:/etc/nginx/conf.d/default.conf:ro
      - /data/config/embed-proxy/theme:/etc/nginx/embed-theme:ro   # dark.css for the frame
    depends_on: [infinidysk, wetty]

  silo-postgres:
    image: pgvector/pgvector:pg18
    container_name: silo-postgres
    restart: unless-stopped
    shm_size: ${POSTGRES_SHM_SIZE:-8gb}
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-silo}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB:-silo}
    volumes:
      - /data/config/silo/postgres:/var/lib/postgresql
    command: ["postgres", "-c", "listen_addresses=*"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-silo}"]
      interval: 5s
      timeout: 3s
      retries: 5

  silo-redis:
    image: redis:alpine
    container_name: silo-redis
    restart: unless-stopped
    volumes:
      - /data/config/silo/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5

  silo:
    image: ghcr.io/silo-server/silo-server:${SILO_TAG:-latest}
    container_name: silo
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      MODE: integrated
      PORT: "8080"
      JF_PORT: "8096"
      SECRET_KEY: ${SECRET_KEY}
      DATABASE_URL: postgres://${POSTGRES_USER:-silo}:${POSTGRES_PASSWORD}@silo-postgres:5432/${POSTGRES_DB:-silo}?sslmode=disable
      REDIS_URL: redis://silo-redis:6379
      SILO_PLUGIN_CACHE_DIR: /var/lib/silo/plugins
      POSTGRES_TUNE: auto
    ports:
      - "${SILO_PORT:-8090}:8080"
      - "${SILO_JF_PORT:-8096}:8096"
      - "${SILO_ABS_PORT:-13378}:13378"
    volumes:
      - /data:/data:ro,rslave
      - /data/config/silo/plugins:/var/lib/silo/plugins
      - /data/config/silo/compat:/var/lib/silo/compat
      - /data/config/silo/transcode:/tmp/silo-transcode
      - /data/config/silo/catalog-seeds:/catalog-seeds:ro
      - /proc/meminfo:/host/proc/meminfo:ro
      - /proc/stat:/host/proc/stat:ro
      - /proc/loadavg:/host/proc/loadavg:ro
    # GPU passthrough lives in docker-compose.gpu.yml (added via COMPOSE_FILE in .env)
    depends_on:
      silo-postgres:
        condition: service_healthy
      silo-redis:
        condition: service_healthy
      infinidysk:
        condition: service_started
EOF
chown "$PUID:$PGID" "$STACK_DIR/docker-compose.yml"

# ----------------------------------------------------------------------------
say "Detecting Intel Arc GPU for Silo hardware transcoding"
# Find the render node belonging to the Arc card (Intel vendor 0x8086, DG2 /
# Alchemist device IDs 0x56xx - the A380 is 0x56a5). Picking the exact node
# matters when the CPU also has an iGPU, which would otherwise be renderD128.
ARC_NODE=""; ARC_ID=""
for n in /sys/class/drm/renderD*; do
  [ -e "$n/device/vendor" ] || continue
  v="$(cat "$n/device/vendor")"; d="$(cat "$n/device/device")"
  if [ "$v" = "0x8086" ] && [[ "$d" == 0x56* ]]; then
    ARC_NODE="/dev/dri/$(basename "$n")"; ARC_ID="$d"; break
  fi
done
RENDER_GID="$(getent group render | cut -d: -f3 || true)"
RENDER_GID="${RENDER_GID:-$(stat -c %g "${ARC_NODE:-/dev/null}" 2>/dev/null || echo 0)}"

# Keep GPU keys current in .env even when .env already existed
sed -i '/^COMPOSE_FILE=/d;/^GPU_RENDER_NODE=/d;/^RENDER_GID=/d' "$ENV_FILE"

if [ -n "$ARC_NODE" ]; then
  DRIVER="$(basename "$(readlink -f "/sys/class/drm/$(basename "$ARC_NODE")/device/driver")" 2>/dev/null || echo unknown)"
  echo "    Found Intel Arc ($ARC_ID) at $ARC_NODE, kernel driver: $DRIVER, render GID: $RENDER_GID"
  [ "$ARC_ID" = "0x56a5" ] || warn "Not an A380 ID, but it is an Arc (DG2) card - using it anyway."
  cat > "$STACK_DIR/docker-compose.gpu.yml" <<'EOF'
# Intel Arc passthrough for Silo (generated by install.sh).
# The host's Arc render node is mapped to renderD128 inside the container so
# VA-API / Quick Sync use it by default even if an iGPU is also present.
services:
  silo:
    devices:
      - ${GPU_RENDER_NODE}:/dev/dri/renderD128
    group_add:
      - "${RENDER_GID}"
    environment:
      LIBVA_DRIVER_NAME: iHD           # Intel media driver - required for Arc
EOF
  chown "$PUID:$PGID" "$STACK_DIR/docker-compose.gpu.yml"
  cat >> "$ENV_FILE" <<EOF
# ---- GPU (managed by install.sh) ---------------------------------------------
COMPOSE_FILE=docker-compose.yml:docker-compose.gpu.yml
GPU_RENDER_NODE=$ARC_NODE
RENDER_GID=$RENDER_GID
EOF
else
  rm -f "$STACK_DIR/docker-compose.gpu.yml"
  warn "No Intel Arc render node found - Silo will transcode on the CPU."
  warn "Check: the card is seated, BIOS has Resizable BAR on, and the kernel is 6.2+"
  warn "(lspci -k | grep -A3 -i 'VGA\\|Display'). Then re-run this script."
fi
set -a; . "$ENV_FILE"; set +a

# ----------------------------------------------------------------------------
say "Writing dashboard settings (any changed file is saved as .bak first)"
HP=/data/config/homepage
NET_IF="$( { ip route show default 2>/dev/null || true; } | awk '{print $5; exit}')"
[ -n "$NET_IF" ] && [ -e "/sys/class/net/$NET_IF" ] || NET_IF=true
echo "    network card for usage stats: $NET_IF"
put() {  # put <file> < content   - replace a dashboard file, keeping a .bak if it differs
  local f="$HP/$1" tmp; tmp="$(mktemp)"; cat > "$tmp"
  if [ -f "$f" ] && ! cmp -s "$tmp" "$f"; then cp -a "$f" "$f.bak"; fi
  mv "$tmp" "$f"; chmod 644 "$f"
}
put settings.yaml <<'EOF'
title: Media Server
theme: dark
color: slate
headerStyle: clean
target: _blank
statusStyle: dot
layout:
  Automate:
    style: row
    columns: 3
  Watch:
    style: row
    columns: 2      # Silo and InfiniDysk side by side; set 1 to stack them
  Logs:
    style: row
    columns: 1
  Terminal:
    style: row
    columns: 1
EOF
put widgets.yaml <<EOF
- resources:
    label: Server
    cpu: true
    memory: true
    disk: /data
    network: $NET_IF
    uptime: true
- datetime:
    text_size: xl
    format:
      dateStyle: long
      timeStyle: short
EOF
# Make the embedded apps fill the screen
put custom.css <<'EOF'
iframe[name="silo"], iframe[name="infinidysk"] {
  height: calc(100vh - 330px) !important;
  min-height: 520px;
  width: 100%;
}
iframe[name="logs"] {
  height: 55vh !important;
  min-height: 380px;
  width: 100%;
  background: #0b0f14;
}
iframe[name="ssh"] {
  height: 55vh !important;
  min-height: 380px;
  width: 100%;
  background: #000;
}
EOF
# Log viewer app (rewritten each run)
cat > /data/config/logs/app.py <<'LOGS_PY'
#!/usr/bin/env python3
"""Live log viewer for the media stack: pick an app from a dropdown, watch its
logs stream in. Read-only: it only ever makes GET requests to Docker."""
import codecs
import json
import os
import re
import select
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlparse

SOCK = os.environ.get("DOCKER_SOCK", "/var/run/docker.sock")
PORT = int(os.environ.get("PORT", "8080"))
HERE = os.path.dirname(os.path.abspath(__file__))
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
NAME_OK = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
SINCE_OK = re.compile(r"^[0-9]{1,12}(\.[0-9]{1,9})?$")


def docker_open(path):
    """GET from the Docker API over its socket. HTTP/1.0 = plain stream, no chunking."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(SOCK)
    s.sendall(f"GET {path} HTTP/1.0\r\nHost: docker\r\n\r\n".encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            raise IOError("Docker closed the connection")
        buf += chunk
    head, rest = buf.split(b"\r\n\r\n", 1)
    status = int(head.split(b" ", 2)[1])
    s.settimeout(None)
    return s, status, rest


def docker_json(path):
    s, status, body = docker_open(path)
    with s:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            body += chunk
    if status != 200:
        raise IOError(f"Docker said {status}: {body[:200].decode(errors='replace')}")
    return json.loads(body)


def list_containers():
    out = []
    for c in docker_json("/containers/json?all=1"):
        out.append({
            "name": c["Names"][0].lstrip("/"),
            "state": c.get("State", ""),
            "status": c.get("Status", ""),
        })
    out.sort(key=lambda x: (x["state"] != "running", x["name"]))
    return out


class Handler(BaseHTTPRequestHandler):
    server_version = "logs"

    def log_message(self, *args):
        pass

    def send_body(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        try:
            if url.path in ("/", "/index.html"):
                with open(os.path.join(HERE, "index.html"), "rb") as f:
                    self.send_body(200, "text/html; charset=utf-8", f.read())
            elif url.path == "/api/containers":
                self.send_body(200, "application/json", json.dumps(list_containers()).encode())
            elif url.path == "/api/logs":
                self.stream_logs(q)
            else:
                self.send_body(404, "text/plain", b"not found")
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:  # report, don't crash the server
            try:
                self.send_body(502, "text/plain", f"error: {e}".encode())
            except Exception:
                pass

    def stream_logs(self, q):
        name = q.get("name", [""])[0]
        if not NAME_OK.match(name):
            return self.send_body(400, "text/plain", b"bad container name")
        try:
            tail = max(0, min(int(q.get("tail", ["200"])[0]), 20000))
        except ValueError:
            tail = 200
        since = q.get("since", [""])[0]
        path = (f"/containers/{quote(name)}/logs?follow=1&stdout=1&stderr=1"
                f"&timestamps=1&tail={tail}")
        if since and SINCE_OK.match(since):
            path += f"&since={since}"

        tty = docker_json(f"/containers/{quote(name)}/json").get("Config", {}).get("Tty", False)
        sock, status, buf = docker_open(path)
        if status != 200:
            sock.close()
            return self.send_body(502, "text/plain", f"Docker said {status}".encode())

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        decoders = {1: codecs.getincrementaldecoder("utf-8")("replace"),
                    2: codecs.getincrementaldecoder("utf-8")("replace")}
        pending = {1: "", 2: ""}
        out = []

        def take(stream, data):
            pending[stream] += decoders[stream].decode(data)
            *lines, pending[stream] = pending[stream].split("\n")
            for line in lines:
                line = ANSI.sub("", line).rstrip("\r")
                out.append(f"data: {json.dumps({'s': stream, 't': line})}\n\n")

        try:
            while True:
                if tty:
                    if buf:
                        take(1, buf)
                        buf = b""
                else:  # Docker multiplexes stdout/stderr: 8-byte header per frame
                    while len(buf) >= 8:
                        size = int.from_bytes(buf[4:8], "big")
                        if len(buf) < 8 + size:
                            break
                        take(2 if buf[0] == 2 else 1, buf[8:8 + size])
                        buf = buf[8 + size:]
                if out:
                    self.wfile.write("".join(out).encode())
                    self.wfile.flush()
                    out.clear()
                ready, _, _ = select.select([sock], [], [], 15)
                if not ready:  # keep-alive; also notices a closed browser tab
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
                    continue
                chunk = sock.recv(65536)
                if not chunk:  # container stopped / log stream ended
                    self.wfile.write(b"event: end\ndata: {}\n\n")
                    self.wfile.flush()
                    break
                buf += chunk
        finally:
            sock.close()


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    srv.daemon_threads = True
    print(f"log viewer on :{PORT}", flush=True)
    srv.serve_forever()
LOGS_PY
cat > /data/config/logs/index.html <<'LOGS_HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Logs</title>
<style>
  :root {
    --bg: #0b0f14; --panel: #111821; --line: #1f2a36; --text: #c9d4df;
    --muted: #748494; --err: #ff6b6b; --warn: #f4c35a; --dbg: #66778a;
    --accent: #4aa3ff; --ok: #3ddc84;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; height: 100%; background: var(--bg); color: var(--text);
    font: 13px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
  body { display: flex; flex-direction: column; }
  header { display: flex; flex-wrap: wrap; gap: 8px; align-items: center;
    padding: 8px 10px; background: var(--panel); border-bottom: 1px solid var(--line); }
  select, input, button { background: #0b1118; color: var(--text); border: 1px solid var(--line);
    border-radius: 6px; padding: 5px 8px; font: inherit; }
  select:focus, input:focus, button:focus-visible { outline: 1px solid var(--accent); }
  button { cursor: pointer; }
  button[aria-pressed="true"] { border-color: var(--accent); color: #fff; }
  #app { min-width: 190px; font-weight: 600; }
  #filter { flex: 1; min-width: 120px; }
  #status { color: var(--muted); margin-left: auto; white-space: nowrap; display: flex; align-items: center; }
  .dot { width: 8px; height: 8px; border-radius: 50%; margin-right: 6px; background: var(--muted); }
  .dot.live { background: var(--ok); } .dot.stopped { background: var(--err); } .dot.wait { background: var(--warn); }
  main { position: relative; flex: 1; min-height: 0; }
  #log { position: absolute; inset: 0; overflow: auto; padding: 6px 10px; }
  #log > div { white-space: pre; }
  #log.wrap > div { white-space: pre-wrap; word-break: break-word; }
  .ts { color: var(--muted); margin-right: 10px; user-select: none; }
  .l-err { color: var(--err); } .l-warn { color: var(--warn); } .l-dbg { color: var(--dbg); }
  .note { color: var(--muted); font-style: italic; }
  .hidden { display: none; }
  mark { background: #3a4a1a; color: inherit; }
  #jump { position: absolute; right: 18px; bottom: 14px; display: none;
    background: var(--accent); color: #fff; border: 0; box-shadow: 0 2px 10px #0008; }
  #jump.show { display: block; }
  @media (max-width: 600px) { #status { margin-left: 0; width: 100%; } }
</style>
</head>
<body>
<header>
  <select id="app" aria-label="App"></select>
  <select id="tail" aria-label="Lines to load">
    <option value="200">Last 200 lines</option>
    <option value="1000">Last 1,000</option>
    <option value="5000">Last 5,000</option>
  </select>
  <input id="filter" type="search" placeholder="Filter lines…" aria-label="Filter">
  <button id="wrap" aria-pressed="false" title="Wrap long lines">Wrap</button>
  <button id="pause" aria-pressed="false" title="Pause the live feed">Pause</button>
  <button id="clear" title="Clear the window">Clear</button>
  <span id="status"><span class="dot" id="dot"></span><span id="stext">Loading…</span></span>
</header>
<main>
  <div id="log" role="log" aria-live="off"></div>
  <button id="jump">↓ Latest</button>
</main>
<script>
(() => {
  const $ = s => document.querySelector(s);
  const logEl = $('#log'), appSel = $('#app'), tailSel = $('#tail'), filt = $('#filter');
  const dot = $('#dot'), stext = $('#stext'), jump = $('#jump');
  const MAX = 5000;
  const store = {
    get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch (e) {} },
  };

  let es = null, retry = null, paused = false, held = [], queue = [], lastTs = null, count = 0, follow = true;

  function level(t) {
    if (/\b(ERR|ERROR|FATAL|CRIT|CRITICAL|PANIC)\b|\[(Error|Fatal|Crit)\]|level=(error|fatal)|Exception/i.test(t)) return 'l-err';
    if (/\b(WARN|WARNING)\b|\[Warn\]|level=warn/i.test(t)) return 'l-warn';
    if (/\b(DEBUG|TRACE|DBG|TRC)\b|\[(Debug|Trace)\]|level=(debug|trace)/i.test(t)) return 'l-dbg';
    return '';
  }
  function setStatus(kind, text) { dot.className = 'dot ' + kind; stext.textContent = text; }
  function matches(text) { const f = filt.value.trim().toLowerCase(); return !f || text.toLowerCase().includes(f); }

  function makeLine(ev) {
    let t = ev.t, ts = '';
    const m = /^(\d{4}-\d\d-\d\dT[\d:.]+Z)\s?(.*)$/.exec(t);
    if (m) {
      const d = new Date(m[1]);
      if (!isNaN(d)) { ts = d.toLocaleTimeString([], { hour12: false }); lastTs = m[1]; }
      t = m[2];
    }
    const div = document.createElement('div');
    const lv = level(t); if (lv) div.className = lv;
    if (ts) { const s = document.createElement('span'); s.className = 'ts'; s.textContent = ts; div.appendChild(s); }
    const msg = document.createElement('span'); msg.textContent = t; div.appendChild(msg);
    div.dataset.text = t;
    if (!matches(t)) div.classList.add('hidden');
    return div;
  }

  function flush() {
    if (!queue.length) return;
    const frag = document.createDocumentFragment();
    for (const ev of queue) frag.appendChild(makeLine(ev));
    count += queue.length; queue = [];
    logEl.appendChild(frag);
    while (logEl.childElementCount > MAX) logEl.firstElementChild.remove();
    if (follow) logEl.scrollTop = logEl.scrollHeight;
    updateCount();
  }
  let raf = 0;
  function push(ev) {
    if (paused) { held.push(ev); return; }
    queue.push(ev);
    if (!raf) raf = requestAnimationFrame(() => { raf = 0; flush(); });
  }
  function note(text) {
    const d = document.createElement('div'); d.className = 'note'; d.textContent = text; logEl.appendChild(d);
    if (follow) logEl.scrollTop = logEl.scrollHeight;
  }
  function updateCount() {
    if (dot.classList.contains('live')) stext.textContent = `Live · ${appSel.value} · ${count.toLocaleString()} lines`;
  }

  function connect(resume) {
    clearTimeout(retry);
    if (es) { es.close(); es = null; }
    const name = appSel.value; if (!name) return;
    if (!resume) { logEl.textContent = ''; count = 0; lastTs = null; held = []; queue = []; follow = true; jump.classList.remove('show'); }
    let url = `api/logs?name=${encodeURIComponent(name)}&tail=${resume ? 0 : tailSel.value}`;
    if (resume && lastTs) url += `&since=${(Date.parse(lastTs) / 1000 + 0.001).toFixed(3)}`;
    setStatus('wait', `Connecting to ${name}…`);
    es = new EventSource(url);
    es.onopen = () => { setStatus('live', ''); updateCount(); };
    es.onmessage = e => push(JSON.parse(e.data));
    es.addEventListener('end', () => {
      es.close(); es = null; flush();
      note(`— ${name} is not running; showing its last lines —`);
      setStatus('stopped', `${name} stopped`);
    });
    es.onerror = () => {
      if (!es) return;
      es.close(); es = null;
      setStatus('wait', 'Disconnected — retrying…');
      retry = setTimeout(() => connect(true), 3000);
    };
  }

  async function loadApps() {
    let list;
    try { list = await (await fetch('api/containers')).json(); }
    catch (e) { setStatus('stopped', 'Cannot reach Docker'); return; }
    const want = appSel.value || new URLSearchParams(location.search).get('app') || store.get('logs.app');
    const groups = { running: [], other: [] };
    for (const c of list) (c.state === 'running' ? groups.running : groups.other).push(c);
    appSel.textContent = '';
    for (const [label, items] of [['Running', groups.running], ['Stopped', groups.other]]) {
      if (!items.length) continue;
      const og = document.createElement('optgroup'); og.label = label;
      for (const c of items) { const o = document.createElement('option'); o.value = c.name; o.textContent = c.name; o.title = c.status; og.appendChild(o); }
      appSel.appendChild(og);
    }
    const names = list.map(c => c.name);
    const pick = names.includes(want) ? want : (groups.running[0] || list[0] || {}).name;
    const changed = pick !== appSel.dataset.current;
    if (pick) appSel.value = pick;
    appSel.dataset.current = pick || '';
    return changed;
  }

  appSel.addEventListener('change', () => { appSel.dataset.current = appSel.value; store.set('logs.app', appSel.value); connect(false); });
  tailSel.addEventListener('change', () => { store.set('logs.tail', tailSel.value); connect(false); });
  filt.addEventListener('input', () => {
    for (const d of logEl.children) if (d.dataset.text !== undefined) d.classList.toggle('hidden', !matches(d.dataset.text));
  });
  $('#wrap').addEventListener('click', e => {
    const on = logEl.classList.toggle('wrap'); e.currentTarget.setAttribute('aria-pressed', on); store.set('logs.wrap', on ? '1' : '');
  });
  $('#pause').addEventListener('click', e => {
    paused = !paused; e.currentTarget.setAttribute('aria-pressed', paused);
    e.currentTarget.textContent = paused ? `Resume` : 'Pause';
    if (!paused) { const h = held; held = []; h.forEach(push); }
  });
  $('#clear').addEventListener('click', () => { logEl.textContent = ''; count = 0; updateCount(); });
  logEl.addEventListener('scroll', () => {
    follow = logEl.scrollTop + logEl.clientHeight >= logEl.scrollHeight - 30;
    jump.classList.toggle('show', !follow);
  });
  jump.addEventListener('click', () => { follow = true; logEl.scrollTop = logEl.scrollHeight; jump.classList.remove('show'); });

  const savedTail = store.get('logs.tail'); if (savedTail) tailSel.value = savedTail;
  if (store.get('logs.wrap')) { logEl.classList.add('wrap'); $('#wrap').setAttribute('aria-pressed', 'true'); }
  loadApps().then(() => connect(false));
  setInterval(loadApps, 30000);   // pick up new/stopped containers
})();
</script>
</body>
</html>
LOGS_HTML
chmod 644 /data/config/logs/app.py /data/config/logs/index.html

EMBED_PORT="${EMBED_PORT:-3002}"
cat > /data/config/embed-proxy/default.conf <<'EOF'
# Generated by install.sh - InfiniDysk for the dashboard frame, minus the
# headers that forbid embedding. Live updates (websockets/SSE) pass through.
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
server {
  listen 3002;
  location / {
    proxy_pass http://infinidysk:3000;
    proxy_http_version 1.1;
    proxy_set_header Host $http_host;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_buffering off;
    proxy_read_timeout 1h;
    proxy_hide_header X-Frame-Options;
    proxy_hide_header Content-Security-Policy;
    # Add the dashboard's dark theme to InfiniDysk's pages (needs uncompressed HTML)
    proxy_set_header Accept-Encoding "";
    sub_filter '</head>' '<link rel="stylesheet" href="/__embed-theme/dark.css"></head>';
    sub_filter_once on;
  }
  location /__embed-theme/ {
    alias /etc/nginx/embed-theme/;
    types { } default_type text/css;
    add_header Cache-Control "no-cache";
  }
}
# Web SSH terminal (WeTTY) for the dashboard frame, minus embed-blocking headers
server {
  listen 3004;
  location / {
    proxy_pass http://wetty:3000;
    proxy_http_version 1.1;
    proxy_set_header Host $http_host;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_buffering off;
    proxy_read_timeout 1h;
    # WeTTY's defaults block embedding and force HTTPS; this server is plain HTTP
    proxy_hide_header X-Frame-Options;
    proxy_hide_header Content-Security-Policy;
    proxy_hide_header Strict-Transport-Security;
  }
}
EOF
chmod 644 /data/config/embed-proxy/default.conf
mkdir -p /data/config/embed-proxy/theme
# Kept if you've edited it. After editing: docker compose restart embed-proxy
[ -f /data/config/embed-proxy/theme/dark.css ] || cat > /data/config/embed-proxy/theme/dark.css <<'EOF'
/* Darker look for InfiniDysk inside the dashboard only (not on :3000).
   Make it darker or lighter by changing brightness: 1 = original, 0.6 = very dark.
   Then hard-refresh the dashboard (Ctrl+F5). */
:root { color-scheme: dark; }
html { filter: brightness(0.78) contrast(1.08); }
html, body, #root, #app, main { background-color: #05080d !important; }
EOF
chmod -R a+rX /data/config/embed-proxy/theme
[ -f "$HP/docker.yaml" ] || cat > "$HP/docker.yaml" <<'EOF'
local:
  socket: /var/run/docker.sock
EOF
[ -f "$HP/bookmarks.yaml" ] || echo "[]" > "$HP/bookmarks.yaml"

# ----------------------------------------------------------------------------
say "Pulling images and starting the stack (first pull can take a few minutes)"
cd "$STACK_DIR"
docker compose pull
docker compose up -d --remove-orphans

# The first 2.x start after an upgrade imports the 1.x database (up to ~10 min)
say "Waiting for InfiniDysk's mount at $MOUNT_DIR (up to 10 minutes)"
for _ in $(seq 1 120); do
  mountpoint -q "$MOUNT_DIR" && break
  sleep 5
done
if mountpoint -q "$MOUNT_DIR"; then
  echo "    Mounted: $(ls -A "$MOUNT_DIR" | tr '\n' ' ')"
  for c in sonarr radarr silo; do
    if docker exec "$c" test -d "$MOUNT_DIR/.ids" 2>/dev/null; then echo "    $c sees the mount"
    else warn "$c can't see the mount yet - try: docker compose restart $c"; fi
  done
  # Do existing library symlinks (made under 1.x) still resolve?
  TOTAL=0; BROKEN=0
  while IFS= read -r l; do
    TOTAL=$((TOTAL+1)); [ -e "$l" ] || BROKEN=$((BROKEN+1))
  done < <(find /data/media -type l 2>/dev/null | head -n 500)
  if [ "$TOTAL" -eq 0 ]; then echo "    No library symlinks yet."
  elif [ "$BROKEN" -eq 0 ]; then echo "    Library symlinks OK ($TOTAL checked)."
  else warn "$BROKEN of $TOTAL library symlinks don't resolve - see docker compose logs infinidysk"; fi
else
  warn "Mount not up yet - check: docker compose -f $STACK_DIR/docker-compose.yml logs infinidysk"
fi

# ----------------------------------------------------------------------------
say "Connecting the dashboard to Sonarr, Radarr and Prowlarr"
apikey() {  # wait up to 90s for an *arr to write its API key on first start
  local f="/data/config/$1/config.xml" k=""
  for _ in $(seq 1 30); do
    k="$(grep -oP '<ApiKey>\K[^<]+' "$f" 2>/dev/null || true)"; [ -n "$k" ] && break; sleep 3
  done
  printf '%s' "$k"
}
SONARR_KEY="$(apikey sonarr)"; RADARR_KEY="$(apikey radarr)"; PROWLARR_KEY="$(apikey prowlarr)"
check_key() {  # check_key NAME PORT API_PATH KEY - does the app accept this key?
  local code
  [ -n "$4" ] || { warn "$1 API key not found yet - re-run with --update later for its live stats"; return; }
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "X-Api-Key: $4" "http://localhost:$2$3" || true)"
  case "$code" in
    200) echo "    $1 API key OK" ;;
    401) warn "$1 rejected its API key from config.xml - restart it, then re-run with --update" ;;
    *)   warn "$1 didn't answer the key check (HTTP $code) - it may still be starting; re-run with --update later" ;;
  esac
}
check_key Sonarr   "${SONARR_PORT}"   /api/v3/system/status "$SONARR_KEY"
check_key Radarr   "${RADARR_PORT}"   /api/v3/system/status "$RADARR_KEY"
check_key Prowlarr "${PROWLARR_PORT}" /api/v1/system/status "$PROWLARR_KEY"
cat > "$HP/services.yaml" <<EOF
# Generated by install.sh - re-run 'sudo bash install.sh --update' to refresh
# API keys (e.g. after resetting an app). Edit settings.yaml/widgets.yaml freely.
- Automate:
    - Sonarr:
        icon: sonarr.png
        href: http://$IP:${SONARR_PORT}
        description: TV shows
        server: local
        container: sonarr
        widget:
          type: sonarr
          url: http://sonarr:8989
          key: ${SONARR_KEY}
    - Radarr:
        icon: radarr.png
        href: http://$IP:${RADARR_PORT}
        description: Movies
        server: local
        container: radarr
        widget:
          type: radarr
          url: http://radarr:7878
          key: ${RADARR_KEY}
    - Prowlarr:
        icon: prowlarr.png
        href: http://$IP:${PROWLARR_PORT}
        description: Indexers
        server: local
        container: prowlarr
        widget:
          type: prowlarr
          url: http://prowlarr:9696
          key: ${PROWLARR_KEY}

- Watch:
    - Silo:
        icon: mdi-silo
        href: http://$IP:${SILO_PORT}
        description: Media server - click the name to open full screen
        siteMonitor: http://silo:8080
        server: local
        container: silo
        widget:
          type: iframe
          name: silo
          src: http://$IP:${SILO_PORT}
          allowFullscreen: true
          allowPolicy: autoplay; fullscreen; picture-in-picture
    - InfiniDysk:
        icon: mdi-cloud-download-outline
        href: http://$IP:${INFINIDYSK_PORT}
        description: Usenet streaming - click the name to open full screen
        siteMonitor: http://infinidysk:3000/healthz
        server: local
        container: infinidysk
        widget:
          type: iframe
          name: infinidysk
          src: http://$IP:${EMBED_PORT}

- Logs:
    - Logs:
        icon: mdi-text-box-search-outline
        href: http://$IP:${LOGS_PORT:-3006}/
        description: Pick an app from the dropdown - click to open full screen
        server: local
        container: logs
        widget:
          type: iframe
          name: logs
          src: http://$IP:${LOGS_PORT:-3006}/

- Terminal:
    - SSH:
        icon: mdi-console
        href: http://$IP:3004/wetty/
        description: Log in as ${SSH_USER} with your server password - click to open full screen
        server: local
        container: wetty
        widget:
          type: iframe
          name: ssh
          src: http://$IP:3004/wetty/
          allowPolicy: clipboard-read; clipboard-write
EOF
chmod 600 "$HP/services.yaml"    # holds API keys
docker compose restart homepage >/dev/null
DASH="http://$IP"; [ "$HP_PORT" = 80 ] || DASH="http://$IP:$HP_PORT"
BLOCK="$(curl -s -o /dev/null -D - "http://localhost:${INFINIDYSK_PORT}/" 2>/dev/null \
  | grep -iE '^(x-frame-options|content-security-policy):' | tr -d '\r' || true)"
if [ -n "$BLOCK" ]; then
  echo "    InfiniDysk blocks embedding with:"; printf '%s\n' "$BLOCK" | sed 's/^/      /'
  echo "    -> the dashboard uses the embed proxy on port $EMBED_PORT, which removes this"
else
  echo "    InfiniDysk sends no embedding block header"
fi
if [ -n "$(ss -tlnH "sport = :$SSH_PORT" 2>/dev/null)" ]; then
  echo "    SSH server found on port $SSH_PORT - web terminal can log in"
  if (sshd -T 2>/dev/null || true) | grep -qi '^passwordauthentication no'; then
    warn "SSH password login is OFF, so the web terminal can't log in. To allow it:"
    warn "  set 'PasswordAuthentication yes' in /etc/ssh/sshd_config, then: systemctl restart ssh"
  fi
else
  warn "No SSH server on port $SSH_PORT - the web terminal needs one: apt install openssh-server"
fi
if curl -s "http://localhost:${LOGS_PORT:-3006}/api/containers" | grep -q '"name"'; then
  echo "    log viewer OK on port ${LOGS_PORT:-3006}"
else
  warn "log viewer not answering on port ${LOGS_PORT:-3006} - check: docker compose logs logs"
fi
for u in "localhost:3004/wetty/"; do
  c="$(curl -s -o /dev/null -w '%{http_code}' "http://$u" || true)"
  case "$c" in 2*|3*) echo "    web terminal OK at $u";;
    *) warn "web terminal not answering at $u (HTTP $c) - check: docker compose logs wetty embed-proxy";; esac
done
if curl -s -o /dev/null -w '%{http_code}' "http://localhost:$EMBED_PORT/" | grep -qE '^[23]'; then
  echo "    embed proxy OK on port $EMBED_PORT"
else
  warn "embed proxy not answering on port $EMBED_PORT - check: docker compose logs embed-proxy"
fi

# ----------------------------------------------------------------------------
cat <<EOF

=============================================================================
 Stack is running.  Files: $STACK_DIR   Data: /data
=============================================================================
 DASHBOARD   $DASH      <- everything on one page

 InfiniDysk  http://$IP:${INFINIDYSK_PORT}
 Prowlarr    http://$IP:${PROWLARR_PORT}
 Sonarr      http://$IP:${SONARR_PORT}
 Radarr      http://$IP:${RADARR_PORT}
 Silo        http://$IP:${SILO_PORT}   (Jellyfin API :${SILO_JF_PORT})

 Already configured: InfiniDysk 2.x mount at $MOUNT_DIR, WebDAV login,
 symlink imports, categories tv/movies, library folders, all secrets.
EOF
if [ "$UPGRADE" -eq 1 ]; then cat <<EOF

 UPGRADE: sign in to InfiniDysk with your 1.x admin login. Its API key is
 unchanged and it's still host infinidysk port 3000, so Sonarr/Radarr need
 no changes. Open one existing episode/film in Silo to confirm it plays.

 Roll back to 1.x:  cd $STACK_DIR && docker compose stop infinidysk
                    sudo umount -l $MOUNT_DIR
                    cp $BACKUP/docker-compose.yml $BACKUP/.env $STACK_DIR/
                    docker compose up -d --remove-orphans
 (1.x config in /data/config/infinidysk was never changed.)
=============================================================================
EOF
exit 0
fi
if [ "$UPDATE" -eq 1 ]; then
  echo "============================================================================="
  exit 0
fi
cat <<EOF

 Remaining clicks (they need accounts / keys only you have):
 1. InfiniDysk: create admin, add your Usenet provider. Copy the SAB key:
    Settings -> Automation -> Download client -> Connection -> API key.
 2. Prowlarr: add indexers; Settings -> Apps -> add
    http://sonarr:8989 and http://radarr:7878 (their API keys).
 3. Sonarr / Radarr:
    - Root folder: /data/media/tv  |  /data/media/movies
    - Download client SABnzbd: host infinidysk, port 3000,
      InfiniDysk SAB API key, category tv | movies, enable Remove Completed.
 4. InfiniDysk -> Settings: add Sonarr (http://sonarr:8989) and
    Radarr (http://radarr:7878) with their API keys.
 5. Silo: finish onboarding; in transcoding settings choose Quick Sync
    (or VA-API) for the Arc. Add libraries /data/media/movies and
    /data/media/tv, install TMDB/TVDB plugins.

 Back up $STACK_DIR/.env - it holds Silo's SECRET_KEY.
=============================================================================
EOF
