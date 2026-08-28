# rtorrent_fast_resume_split.pl

## Usage

    rtorrent_fast_resume_split.pl --session DIR [options]
    rtorrent_fast_resume_split.pl --session DIR --data-dir DIR [options]
    rtorrent_fast_resume_split.pl --session DIR [options] MAPPING_FILE

## Required Arguments

* `-s`, `--session DIR` — rTorrent split-session directory.

---

## Input Modes

* **Default** — Read each torrent's saved directory information from `HASH.torrent.rtorrent`. The script scans all `HASH.torrent` files in `SESSION` automatically.
* `-d`, `--data-dir DIR` — Override session paths with one common parent directory containing the payload data for every torrent in the session.
* `MAPPING_FILE` — Override session paths with per-torrent mappings for mixed or moved storage.
* `-m`, `--mapping FILE` — Alternate way to specify `MAPPING_FILE`.
* `--hash HASH` — Process only `HASH`. May be repeated. Comma-separated hashes are also accepted.
* `--path-mode MODE` — How payload paths are interpreted:
  * `auto` — detect per torrent (default)
  * `directory` — `PATH/name/files` for multi-file
  * `directory-base` — `PATH/files` for multi-file
  * *Note:* Session mode uses a stored `directory_base` directly when available; a stored `directory` is auto-detected unless you force a mode.

### Common Data-Directory Examples

    DATA/Movie.mkv                   single-file torrent
    DATA/Torrent.Name/file1          multi-file torrent
    DATA/Torrent.Name/subdir/file2

### Mapping Formats

    HASH|PATH
    HASH|directory|PATH
    HASH|directory_base|PATH

---

## Behavior

* `-n`, `--dry-run` — Validate and calculate without writing.
* `--priority N` — Force file priority to `N` (`0`, `1`, or `2`). *Default:* preserve existing priority; use `1` if absent.
* `--set-directory` — Update the `.rtorrent` directory field from the resolved payload path. Otherwise, preserve it.
* `--start` — Mark torrents started (`state=1`). Otherwise, preserve existing started/stopped state.
* `--[no-]backup` — Enable or disable sidecar backups. Backups are enabled by default.
* `--backup-dir DIR` — Backup root directory. *Default:* `SESSION.fastresume-backups`. Each run gets a timestamped subdirectory.
* `--strict` — Stop immediately on the first failure.

---

## Output

* `-q`, `--quiet` — Print only failures and final totals.
* `-v`, `--verbose` — Show torrent and per-file calculations.
* `-h`, `--help` — Show this help.

---

## Session Files

* `HASH.torrent`
* `HASH.torrent.libtorrent_resume`
* `HASH.torrent.rtorrent`

---

## Examples

    # Normal case: use the paths already saved in the session.
    rtorrent_fast_resume_split.pl \
        --session /home/user/.session

    # Validate session-derived paths without changing anything.
    rtorrent_fast_resume_split.pl \
        --session /home/user/.session \
        --dry-run

    # All torrents have been moved beneath one common directory.
    rtorrent_fast_resume_split.pl \
        --session /home/user/.session \
        --data-dir /srv/torrents

    # Mixed or moved storage: use HASH|PATH mappings.
    rtorrent_fast_resume_split.pl \
        --session /home/user/.session \
        mappings.txt

---

> **IMPORTANT:** Stop rTorrent before writing session files. This script verifies file existence and exact sizes, but it does **NOT** hash payload data. Use it only when you already trust the data and need to reconstruct lost resume state.
