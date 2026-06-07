# screenrec-compress

Batch-compress MP4 screen recordings with ffmpeg. Keeps on-screen text readable
and meeting audio clear while significantly reducing file size.

## Usage

```bash
# compress all .mp4 files in a directory
compress.sh /path/to/recordings

# current directory
compress.sh

# see what would be processed without doing anything
compress.sh --dry-run /path/to/recordings

# reprocess files that already have a compressed version
compress.sh --force /path/to/recordings
```

Output files are written alongside the originals with a ` - compressed.mp4`
suffix, so you can verify quality before deleting the originals. The script is
idempotent — safe to re-run; it skips files that already have a compressed
version.

## Requirements

- ffmpeg (macOS: `brew install ffmpeg`)

## Encoding settings

| Setting | Value | Rationale |
|---|---|---|
| Codec | HEVC / libx265 | 20–40% smaller than H.264 at equivalent quality |
| CRF | 26 | Good balance for readable UI text |
| Frame rate | VFR | Reduces size on static sections |
| Audio | AAC 96k mono | Clear for voice, smaller files |

**Faster but larger:** swap `libx265` for `libx264`, add `-tune stillimage`, and
set CRF to 20. Encodes faster but files are typically 20–40% larger.

## Automatic compression with launchd (macOS)

To have new recordings compressed automatically when files are added to a
directory, use the included launchd plist. This is the recommended setup if the
drive is physically connected to a Mac that stays on (e.g. a home server).

**Why launchd over a Python file watcher?** `WatchPaths` fires on any change in
the directory; `compress.sh` handles the coarseness by scanning and skipping
already-done files. No long-running process to keep alive.

### Setup

1. **Install ffmpeg** on the machine that will run the agent:
   ```bash
   brew install ffmpeg
   ```

2. **Edit the plist** — open `com.user.screenrec-compress.plist` and replace
   the four `YOUR_*` placeholders with real paths.

3. **Copy the plist** to your LaunchAgents folder:
   ```bash
   cp com.user.screenrec-compress.plist ~/Library/LaunchAgents/
   ```

4. **Load the agent:**
   ```bash
   launchctl load ~/Library/LaunchAgents/com.user.screenrec-compress.plist
   ```

5. **Check the log** after dropping a file into the watched directory:
   ```bash
   tail -f ~/Library/Logs/screenrec-compress.log
   ```

### Unloading

```bash
launchctl unload ~/Library/LaunchAgents/com.user.screenrec-compress.plist
```

### Notes

- The agent runs as your user, not root — it has access to anything your user
  can access, including mounted volumes.
- launchd runs agents with a minimal environment (no PATH). The plist sets
  `PATH` explicitly to include `/opt/homebrew/bin` where Homebrew installs
  ffmpeg. If you installed ffmpeg elsewhere, update that line.
- Logs from both stdout and stderr go to the same file for simplicity.
