# screenrec-compress

Batch-compress MP4 screen recordings with ffmpeg. Keeps on-screen text readable
and meeting audio clear while significantly reducing file size.

## Usage

```bash
# compress all .mp4 files in a directory
compress.sh /path/to/recordings

# compress a single file
compress.sh /path/to/recording.mp4

# current directory
compress.sh

# see what would be processed without doing anything
compress.sh --dry-run /path/to/recordings

# reprocess files that already have a compressed version
compress.sh --force /path/to/recordings

# use Apple hardware encoder (~5x faster, ~3x larger files)
compress.sh --encoder videotoolbox /path/to/recordings

# software encoder with faster preset (default is slow)
compress.sh --encoder libx265:fast /path/to/recordings

# show live encoding progress
compress.sh --progress /path/to/recording.mp4
```

Output files are written alongside the originals with a ` - compressed.mp4`
suffix, so you can verify quality before deleting the originals. The script is
idempotent — safe to re-run; it skips files that already have a compressed
version.

In directory mode, the script re-scans after each file completes to pick up
any new files that arrived during encoding. A lockfile prevents concurrent
instances — only one runs at a time.

## Requirements

- ffmpeg (macOS: `brew install ffmpeg`)

## Encoding settings

| Setting | Value | Rationale |
|---|---|---|
| Codec | HEVC / libx265 | 20–40% smaller than H.264 at equivalent quality |
| CRF | 24 | Good balance for sharp UI text; 26+ can blur fine fonts |
| Tag | hvc1 | Required for QuickTime / Apple device playback |
| Frame rate | VFR | Reduces size on static sections |
| Audio | AAC 96k mono | Clear for voice, smaller files |

**Faster encoding:** use `--encoder videotoolbox` to use Apple's hardware HEVC
encoder. ~5x faster than software but produces ~3x larger files. Good enough
quality for most screen recordings; use the default `libx265` when file size
or text sharpness matters.

## Automatic compression with launchd (macOS)

Two launchd plist templates are included — pick whichever trigger fits how
the drive is used. Both are recommended only if the drive is physically
connected to a Mac that stays on (e.g. a home server).

| Template | Trigger | Trade-off |
|---|---|---|
| `com.user.screenrec-compress-watch.plist` | Fires on any change in the watched directory (`WatchPaths`) | Compresses almost immediately, but competes with you for CPU/disk while the machine is in use. |
| `com.user.screenrec-compress-nightly.plist` | Fires once nightly at a fixed time (`StartCalendarInterval`, default 3:00am–7:00am via `--until`) | Keeps compression off-hours so it doesn't slow you down, but new files wait until the next scheduled run. |

**Why launchd over a Python file watcher?** No long-running process to keep
alive — `compress.sh` handles the coarseness of both triggers by scanning
the directory and skipping already-done files on every run.

### Setup

1. **Install ffmpeg and flock** on the machine that will run the agent.
   Both templates point `compress.sh` at a directory, and directory mode
   requires `flock` as a lockfile so overlapping runs can't process the
   same files:
   ```bash
   brew install ffmpeg flock
   ```

2. **Copy the plist you want** to your LaunchAgents folder (rename to
   `com.user.screenrec-compress.plist` if you'd rather not manage the
   `-watch`/`-nightly` suffix — the filename doesn't need to match the
   `Label` inside):
   ```bash
   cp com.user.screenrec-compress-watch.plist ~/Library/LaunchAgents/
   # or
   cp com.user.screenrec-compress-nightly.plist ~/Library/LaunchAgents/
   ```

3. **Edit the copy** — open the file under `~/Library/LaunchAgents/` and
   replace the `YOUR_*` placeholders with real paths (for the nightly
   template, also adjust `Hour`/`Minute` and the `--until` argument
   together if 3:00am–7:00am isn't the window you want). Editing the copy
   — not the one in this repo — keeps the checked-in file a generic
   template instead of picking up your machine-specific paths.

4. **Load the agent** (use whichever filename you copied):
   ```bash
   launchctl load ~/Library/LaunchAgents/com.user.screenrec-compress-watch.plist
   # or
   launchctl load ~/Library/LaunchAgents/com.user.screenrec-compress-nightly.plist
   ```

5. **Check the log.** Each template writes to its own log
   (`screenrec-compress-watch.log` / `screenrec-compress-nightly.log`), so
   the two don't interleave. launchd only creates the log file the first
   time the agent actually runs, and macOS `tail -f` errors out (rather than
   waiting) if the file doesn't exist yet — so `touch` it first if you want
   to leave `tail -f` running before that first run (a new file added to
   the watched folder for `-watch`, or the scheduled time for `-nightly`):
   ```bash
   touch ~/Library/Logs/screenrec-compress-watch.log
   tail -f ~/Library/Logs/screenrec-compress-watch.log
   # or
   touch ~/Library/Logs/screenrec-compress-nightly.log
   tail -f ~/Library/Logs/screenrec-compress-nightly.log
   ```

### Unloading

```bash
launchctl unload ~/Library/LaunchAgents/com.user.screenrec-compress-watch.plist
# or
launchctl unload ~/Library/LaunchAgents/com.user.screenrec-compress-nightly.plist
```

### Notes

- The agent runs as your user, not root — it has access to anything your user
  can access, including mounted volumes.
- launchd runs agents with a minimal environment (no PATH). The plist sets
  `PATH` explicitly to include `/opt/homebrew/bin` where Homebrew installs
  ffmpeg. If you installed ffmpeg elsewhere, update that line.
- Logs from both stdout and stderr go to the same file for simplicity.
