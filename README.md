# Strayarr

**Find files your qBittorrent client no longer claims — without touching them.**

A single PowerShell script that compares what qBittorrent thinks it has against
what is actually on disk, and reports the difference. It never deletes anything.

## Why this exists

Orphan scanners generally need to see both the torrent client's API *and* its
download directories. That is easy when they run on the same machine and
impossible when they don't — a manager running on a NAS cannot enumerate
`D:\Downloads` on a Windows box, and mounting the share doesn't help because
qBittorrent reports Windows paths that cannot exist on Linux.

Strayarr sidesteps the problem by running **on the qBittorrent host**, where
both halves are local. Only the result leaves the machine.

## What it does

1. Asks qBittorrent (via its WebUI API on localhost) for every torrent and
   every file each one contains.
2. Walks the download directories you name.
3. Reports files on disk that no torrent claims, largest first.
4. Optionally **moves** them to a dated quarantine folder. Never deletes.

## Requirements

- Windows, with PowerShell 5.1 or PowerShell 7+
- qBittorrent with the WebUI enabled
- Run it on the machine where qBittorrent's files live

**Scope: this is tested on Windows only.** See [Other platforms](#other-platforms)
before running it elsewhere.

## Usage

```powershell
# Report only. Touches nothing.
.\Invoke-OrphanScan.ps1 -ScanPath 'D:\Downloads'

# Several categories at once, non-default WebUI port
.\Invoke-OrphanScan.ps1 -ScanPath 'D:\tv','D:\movies','D:\music' -QbUrl 'http://localhost:9090'

# Preview what quarantining would do
.\Invoke-OrphanScan.ps1 -ScanPath 'D:\Downloads' -Quarantine 'D:\_orphans' -WhatIf

# Actually move them
.\Invoke-OrphanScan.ps1 -ScanPath 'D:\Downloads' -Quarantine 'D:\_orphans'
```

If the script won't run, Windows has flagged it as downloaded:

```powershell
Unblock-File .\Invoke-OrphanScan.ps1
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## Options

| Parameter | Default | What it does |
|---|---|---|
| `-ScanPath` | *(required)* | One or more directories to scan. Use paths as the qBittorrent host sees them. |
| `-QbUrl` | `http://localhost:8080` | qBittorrent WebUI address. |
| `-QbUser` / `-QbPass` | *(empty)* | Only needed if localhost auth isn't bypassed. |
| `-Quarantine` | *(off)* | Move orphans here instead of only reporting. Still never deletes. |
| `-MinAgeHours` | `24` | Ignore files modified recently, so in-flight downloads are never candidates. |
| `-ExcludePattern` | *(none)* | Regexes matched against the full path; matches are never orphans. |
| `-AllowHardlinked` | *(off)* | By default, files with more than one hard link are skipped — they also live elsewhere. |
| `-NoCache` | *(off)* | Ignore the file-list cache and re-fetch everything. |
| `-NtfyUrl` / `-NtfyTopic` / `-NtfyToken` | *(off)* | Push a summary to [ntfy](https://ntfy.sh). |

## Safety model

This tool decides which files are unnecessary. That is a dangerous thing to be
wrong about, so:

- **Default mode reports and touches nothing.**
- **`-Quarantine` moves, it does not delete.** Files go to a dated folder with
  their structure preserved, so restoring is a move back.
- **You delete the quarantine folder yourself**, later, once nothing has broken.
- **Orphans are re-verified against a fresh API query immediately before moving**,
  so a torrent added while you were reading the report is not affected. That
  check ignores the cache, and re-fetches only the torrents that save into a
  folder holding a candidate: a torrent can only claim files beneath its own
  save directory, so the rest cannot change the answer. Quarantining three
  files from one folder no longer waits on every torrent you have.
- **Hard-linked files are skipped by default**, and so are files whose link
  count cannot be determined. More than one link means the file is also in your
  library; an unknown answer must block the move, not permit it.
- **API failures abort; filesystem failures only warn.** A truncated torrent
  list would make real files look unclaimed, which is the one failure that can
  destroy data. An unreadable directory can only hide orphans, which is safe.
- **An empty torrent list is a hard stop.** With nothing expected, every file on
  disk is an orphan — the worst possible outcome from a trivial glitch.

After quarantining, **check qBittorrent for torrents reporting missing files**.
That is the real verification, and if something is wrong, move it back.

## Different paths on the client and on disk

If qBittorrent sees different paths from the machine running this script -- a
container, a mapped drive, a remote mount -- map them:

```powershell
.\Invoke-OrphanScan.ps1 -ScanPath 'D:\Downloads' -PathMap '/data/torrents=D:\Downloads'
```

Multiple mappings are allowed and the longest matching prefix wins. Get this
wrong and the expected set won't match anything on disk, so **every file looks
like an orphan** -- which is why the first run reports rather than acts.

## Other platforms

PowerShell 7 runs on Linux and macOS, and most of this script is portable, but
it has only ever been run on Windows. Three things would need attention:

- **Case sensitivity.** Comparison is case-insensitive, which is right for NTFS
  and wrong for ext4, xfs and btrfs. On a case-sensitive filesystem two files
  differing only in case would be treated as one.
- **Path separators.** Everything is normalised to backslashes, which is fine
  for comparison but assumes the reported and on-disk conventions agree.
- **Hard-link detection.** Uses `fsutil` on Windows and `stat -c %h` elsewhere.
  If neither can answer, the file is **skipped**, never moved.

Docker deployments also need `-PathMap`, since the container's paths are not
the host's.

If you want to run it on another platform, open an issue -- I would rather fix
it against a real setup than guess.

## Things it cannot know

- **Files you staged by hand.** Content you are preparing to upload belongs to
  no torrent yet and will be reported as an orphan. Keep those directories out
  of `-ScanPath`, or use `-ExcludePattern`.
- **Whether an orphan matters.** It only knows nothing claims it.

## Performance

The first run fetches a file list per torrent, so a large client takes a while.
Those lists are then cached on disk, keyed by infohash — a torrent's file list
is fixed by its infohash and cannot change without becoming a different torrent,
so the cache cannot go stale. Later runs are near-instant.

The directory walk is deliberately never cached: its whole purpose is to observe
the filesystem as it is right now.

### A note for anyone tempted to optimise further

An earlier version skipped per-file lookups by treating a completed torrent's
`content_path` as a prefix — "this torrent is complete, so everything under its
folder is accounted for". **That is false**, and it silently hid 25 of 29 real
orphans. A torrent's folder routinely holds files the torrent never contained:
extra episodes, leftovers from an earlier release, samples. Matching is
per-file, exactly, on purpose.

## License

MIT — see [LICENSE](LICENSE).
