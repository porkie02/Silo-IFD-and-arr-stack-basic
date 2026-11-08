# Usenet media stack in one script

One script that sets up a complete self-hosted media server with Docker:

- **[InfiniDysk](https://github.com/infinidysk/infinidysk) 2.x** streams from Usenet and mounts the library as a normal folder, so nothing is downloaded up front.
- **[Sonarr](https://sonarr.tv) / [Radarr](https://radarr.video) / [Prowlarr](https://prowlarr.com)** find and organise TV shows and films.
- **[Silo](https://github.com/Silo-Server)** is the media server you watch from (web, Android/Android TV, iOS/tvOS, or any Jellyfin client).
- **A dashboard** ([Homepage](https://gethomepage.dev)) shows everything on one page: live stats, Silo and InfiniDysk embedded, a log viewer for every app, and an SSH terminal.

Everything lives under one folder, `/data`. The script creates the folders, generates passwords and keys, writes the Docker Compose file, starts everything, and checks that it works.

### Screenshots

The dashboard: server stats, live Sonarr/Radarr/Prowlarr counts, and Silo and InfiniDysk embedded side by side.

![Dashboard with server stats, app tiles, and Silo and InfiniDysk embedded](docs/screenshots/dashboard.png)

Further down: live logs for any app (picked from the dropdown) and an SSH terminal in the browser.

![Log viewer showing Sonarr logs, and the SSH terminal below it](docs/screenshots/logs-and-terminal.png)

> [!WARNING]
> This tracks **bleeding-edge** releases: InfiniDysk 2.x is in **beta**, Sonarr/Radarr/Prowlarr use the **develop** branch, and Silo is **pre-release**. Expect rough edges. You can switch channels later (see [Choosing versions](#choosing-versions)).

---

## Contents

- [What you get](#what-you-get)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Install modes](#install-modes)
- [What a fresh install removes](#what-a-fresh-install-removes)
- [Finishing setup](#finishing-setup)
- [The dashboard](#the-dashboard)
- [Folder layout](#folder-layout)
- [Choosing versions](#choosing-versions)
- [Hardware transcoding](#hardware-transcoding)
- [Security](#security)
- [Troubleshooting](#troubleshooting)

---

## What you get

| App | Address | What it's for |
|---|---|---|
| **Dashboard** | `http://SERVER` (or `:3001` if port 80 is taken) | Everything on one page |
| Silo | `http://SERVER:8090` | Watch your library |
| Silo – Jellyfin-compatible API | `SERVER:8096` | Infuse, Findroid and other Jellyfin apps |
| Silo – Audiobookshelf-compatible API | `SERVER:13378` | Audiobook apps |
| InfiniDysk | `http://SERVER:3000` | Usenet streaming, SABnzbd-compatible API, WebDAV |
| Sonarr | `http://SERVER:8989` | TV shows |
| Radarr | `http://SERVER:7878` | Films |
| Prowlarr | `http://SERVER:9696` | Indexers |
| Log viewer | `http://SERVER:3006` | Live logs for any app (also on the dashboard) |

`SERVER` is your server's IP address. The script prints the real addresses when it finishes.

Ports 3002 and 3004 are used internally by the dashboard to embed InfiniDysk and the SSH terminal.

## Requirements

- **Linux** with **systemd**. Tested on Debian/Ubuntu; other distros mostly work, but the automatic `fuse3` install only runs on Debian/Ubuntu.
- **[Docker Engine](https://docs.docker.com/engine/install/)** with the **Compose v2** plugin (`docker compose`).
- **FUSE** (`/dev/fuse`). The script installs `fuse3` on Debian/Ubuntu if it's missing.
- `openssl`, `curl`, `ss` (iproute2) and GNU `grep`. These are standard on Debian/Ubuntu.
- **sudo / root** to run the script.
- A **Usenet provider** and at least one **indexer**. You add these in the apps after installing.
- Optional: an **Intel Arc** GPU for hardware transcoding, and **OpenSSH server** for the dashboard terminal.

## Quick start

```bash
curl -fsSLO https://raw.githubusercontent.com/porkie02/Silo-IFD-and-arr-stack-basic/main/install.sh
less install.sh          # read it first, it runs as root
sudo bash install.sh
```

Or clone the repo:

```bash
git clone https://github.com/porkie02/Silo-IFD-and-arr-stack-basic.git
cd Silo-IFD-and-arr-stack-basic
sudo bash install.sh
```

Download the script first rather than piping it to `bash`, because it may need to ask you questions.

If anything is already installed, the script lists exactly what it would delete and waits for you to type `WIPE`. Anything else cancels it, and nothing is touched.

When it finishes, it prints the dashboard address and the few remaining setup steps, covered in [Finishing setup](#finishing-setup).

## Install modes

| Command | Use it when | Wipes anything? |
|---|---|---|
| `sudo bash install.sh` | Fresh install | **Yes**, after listing it and asking you to type `WIPE` |
| `sudo bash install.sh --wipe-yes` | Fresh install with no prompt (automation) | **Yes**, without asking |
| `sudo bash install.sh --update` | Already running this stack and you want the latest script's changes, new images, refreshed dashboard | No |
| `sudo bash install.sh --upgrade` | Running an older version of this stack with **InfiniDysk 1.x + rclone**, moving to 2.x | No |

`--update` and `--upgrade` back up your current `docker-compose.yml` and `.env` into `/data/stack/backup-…` first.

### Which user owns the files

The apps run as, and the files are owned by, a normal (non-root) user. The script chooses one in this order:

1. `RUN_USER=name` if you pass it: `sudo RUN_USER=alice bash install.sh`
2. The owner of an existing stack, so updates never change ownership
3. Whoever ran `sudo`
4. Your login name
5. Otherwise it asks, listing the user accounts on the machine

It won't run the apps as `root`.

### Upgrading from InfiniDysk 1.x

`--upgrade` follows [InfiniDysk's own upgrade guide](https://www.infinidysk.com/v2/upgrade/):

- Removes the rclone container. 2.x mounts the library itself.
- **Copies** the 1.x settings to `/data/config/infinidysk-2.0` and runs 2.x on the copy. The original is never changed.
- Keeps the mount at the same path, `/data/mount/infinidysk`, so the symlinks already in your library keep working. The script tests up to 500 of them.
- Prints the exact commands to roll back to 1.x.

Sign in to InfiniDysk with your 1.x admin login afterwards. The first start can take up to 10 minutes while it imports the 1.x database.

## What a fresh install removes

A fresh install gives you a clean slate. **Read the list it shows you before typing `WIPE`.** It removes:

- **Every Docker container on the machine**, not just media apps, plus their Docker volumes and their config folders on disk.
- **Natively installed media apps** (apt/systemd): Sonarr, Radarr, Prowlarr, Lidarr, Readarr, Whisparr, Bazarr, Jellyfin, Jellyseerr, Overseerr, Emby and Plex. It stops them, uninstalls them and deletes their data.
- **Leftover \*arr configs** found anywhere on local disks (by their `sonarr.db`, `radarr.db` etc. files).
- A previous run's `/data/config`, `/data/cache` and `/data/stack`.
- Unused Docker images and networks.

It never deletes:

- **`/data/media`**, your library.
- **Any folder containing media files** (mkv, mp4, avi, iso, flac, mp3, epub and similar).
- System folders, anything that is a separate disk or mount point, home folders themselves, or their top-level folders (Documents, Downloads…). The one exception: a folder that is itself an old \*arr config, such as `~/sonarr` with a `sonarr.db` inside, is removed.

Folders it keeps for safety are listed, so you can remove them by hand if you want. Afterwards it checks again that no old \*arr configs remain.

**If you have other Docker containers you want to keep, don't run a fresh install on that machine.**

## Finishing setup

These steps need accounts and keys only you have:

1. **InfiniDysk** (`:3000`): create the admin account and add your Usenet provider. Copy the SABnzbd API key from *Settings → Automation → Download client → Connection*.
2. **Prowlarr** (`:9696`): add your indexers. Under *Settings → Apps*, add `http://sonarr:8989` and `http://radarr:7878` with their API keys.
3. **Sonarr / Radarr** (`:8989` / `:7878`):
   - Root folder: `/data/media/tv` (Sonarr), `/data/media/movies` (Radarr).
   - *Download Clients → Add → SABnzbd*: host `infinidysk`, port `3000`, the InfiniDysk API key, category `tv` / `movies`. Enable **Remove Completed**.
4. **InfiniDysk → Settings**: add Sonarr (`http://sonarr:8989`) and Radarr (`http://radarr:7878`) with their API keys.
5. **Silo** (`:8090`): finish onboarding, add libraries `/data/media/movies` and `/data/media/tv`, and install the TMDB/TVDB metadata plugins. If you have an Arc GPU, choose Quick Sync (or VA-API) for transcoding.

These are already done by the script: InfiniDysk's mount path, symlink imports, `tv`/`movies` categories, library folders, the WebDAV login, and all database passwords and secret keys.

> [!IMPORTANT]
> Back up `/data/stack/.env`. It holds Silo's `SECRET_KEY`, and losing it makes Silo's encrypted settings unrecoverable.

## The dashboard

The dashboard is on port 80 if it's free (`http://SERVER`), otherwise port 3001. The Home page shows:

- **Server bar:** CPU, memory, free space on `/data`, network upload/download, uptime and the clock.
- **Sonarr, Radarr, Prowlarr tiles** with live counts (queued, wanted, missing) and a running/stopped dot. Their API keys are filled in automatically.
- **Silo and InfiniDysk embedded** side by side. Click a name to open that app full-screen.
- **Logs:** pick any app from a dropdown and its logs stream in live, colour-coded (errors red, warnings amber), with a filter box, a line-count picker, pause and wrap.
- **SSH terminal:** a real SSH login to the server in the browser ([WeTTY](https://github.com/butlerx/wetty)), using your normal Linux password. This needs `openssh-server` with password login allowed; the script checks and tells you if it isn't.

To customise the dashboard, edit `settings.yaml` and `widgets.yaml` in `/data/config/homepage`. A re-run saves your old copy as `.bak`. `services.yaml` is regenerated on every run, which refreshes API keys if you reset an app.

The embedded InfiniDysk gets a darker theme on the dashboard only. Adjust it in `/data/config/embed-proxy/theme/dark.css`, then run `docker compose restart embed-proxy`.

## Folder layout

```
/data
├── stack/                    docker-compose.yml, .env (secrets), backups
├── config/
│   ├── infinidysk/           InfiniDysk settings and database
│   ├── sonarr/ radarr/ prowlarr/
│   ├── silo/                 Silo plugins, transcode cache, Postgres, Redis
│   ├── homepage/             dashboard settings
│   ├── logs/                 log viewer app
│   └── embed-proxy/          lets the dashboard embed InfiniDysk and the terminal
├── mount/infinidysk/         InfiniDysk's live library mount (don't write here)
└── media/
    ├── movies/               Radarr root folder, Silo movie library
    └── tv/                   Sonarr root folder, Silo TV library
```

Every container sees `/data` at the same path, so the symlinks Sonarr and Radarr create resolve everywhere. The script makes `/data` a shared mount (via a small `data-shared.service` systemd unit) so InfiniDysk's mount reaches the other containers.

## Choosing versions

Edit `/data/stack/.env`, then apply it:

```bash
cd /data/stack && docker compose pull && docker compose up -d
```

| Setting | Default | Options |
|---|---|---|
| `INFINIDYSK_TAG` | `edge` | `edge` (latest 2.x), `v2.0.0-beta.N`, `sha-<commit>` |
| `ARR_TAG` | `develop` | `develop`, `latest` |
| `SILO_TAG` | `latest` (tracks `main`) | `build-N` or a commit SHA to pin |

Ports can be changed the same way (`SONARR_PORT`, `SILO_PORT`…).

> [!NOTE]
> Moving the \*arrs from `develop` back to `latest` isn't always possible after a database migration. Back up `/data/config` first.

## Hardware transcoding

If an **Intel Arc** GPU is present (detected by its PCI ID), the script passes it to Silo. It picks the Arc even when the CPU also has integrated graphics. Then choose Quick Sync (or VA-API) in Silo's transcoding settings. With no Arc found, Silo transcodes on the CPU.

If your Arc isn't detected, check that the kernel is 6.2 or newer and that Resizable BAR is enabled in the BIOS (`lspci -k | grep -A3 -i 'VGA\|Display'`).

## Security

The dashboard, log viewer and app pages are plain HTTP and meant for your **home network only**.

- The dashboard and log viewer have **no login**. Anyone on your network can open them.
- **Don't port-forward** any of these ports on your router, especially the terminal (3004), which would put an SSH login prompt on the internet. For remote access, use a VPN (WireGuard, Tailscale) or a reverse proxy with TLS and authentication.
- The dashboard and log viewer read Docker's status through a read-only mount of the Docker socket. Neither changes anything, but access to that socket is powerful, so keep them off the internet.
- The SSH terminal uses your real SSH login, so use a strong password.

## Troubleshooting

**The library mount is empty in Sonarr/Radarr/Silo, but `ls /data/mount/infinidysk` works on the host.**
`/data` isn't a shared mount. Run `sudo systemctl restart data-shared.service`, then `cd /data/stack && docker compose up -d --force-recreate`.

**`Transport endpoint is not connected` on `/data/mount/infinidysk`.**
InfiniDysk stopped with the mount still attached. Run `sudo umount -l /data/mount/infinidysk && cd /data/stack && docker compose restart infinidysk`.

**The dashboard terminal says it can't log in.**
Install an SSH server (`sudo apt install openssh-server`) and make sure `PasswordAuthentication yes` is set in `/etc/ssh/sshd_config`, then `sudo systemctl restart ssh`.

**An embedded app shows "refused to connect".**
Check the embed proxy: `cd /data/stack && docker compose logs embed-proxy`. The end of the install output also reports whether the log viewer, terminal and proxy are answering.

**Something else.**
Use the log viewer on the dashboard, or `cd /data/stack && docker compose logs --tail 50 <app>`.

---

Not affiliated with any of the projects it installs. Thanks to InfiniDysk, Silo, the Servarr team, Homepage, WeTTY and LinuxServer.io.
