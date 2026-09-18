# mac-assets

Assets and deployment scripts for One Inc managed Macs.

## Contents

| Path | Description |
| --- | --- |
| `wallpaper/wallpaper.jpg` | Company values wallpaper, 3840×2160 (4K), ~492 KB |
| `scripts/set-wallpaper.sh` | NinjaOne script that downloads and applies the wallpaper |

## Raw wallpaper URL

```
https://raw.githubusercontent.com/oneinc/mac-assets/main/wallpaper/wallpaper.jpg
```

`raw.githubusercontent.com` caches branch URLs for about five minutes. To make a
deployment immutable, tag the release and reference the tag instead of `main`:

```
https://raw.githubusercontent.com/oneinc/mac-assets/v1/wallpaper/wallpaper.jpg
```

## Deploying with NinjaOne

1. **Automation → Scripts → New Script**
   - Language: `Shell`
   - Operating System: `Mac`
   - Architecture: `All`
   - Run As: **Root (System)**
   - Paste the contents of `scripts/set-wallpaper.sh`
2. Add it to a policy as a scheduled or login-triggered task, or run it ad hoc
   against a device group.

The script is idempotent — it checksums the local copy and only re-downloads
when the image in this repo changes, so it is safe to run on a schedule.

### What it does

1. Finds the user currently logged in at the console (exits cleanly if nobody is).
2. Downloads the wallpaper to `/Library/Application Support/One Inc/Wallpaper/`
   and verifies it is really an image, not an HTML error page.
3. Applies it in that user's GUI session via `osascript`, falling back to
   clearing the macOS 14+ wallpaper store and retrying.
4. Restarts `WallpaperAgent` and `Dock` so the change appears without a logout.

Progress is written to stdout (visible in NinjaOne's script output) and to the
system log under the tag `set-wallpaper`:

```
log show --predicate 'process == "logger"' --last 1h | grep set-wallpaper
```

### Automation permission (important)

Setting the desktop picture from a background agent goes through Apple Events,
which macOS gates behind TCC. If the script reports *"not authorized to send
Apple events"*, deploy a **PPPC configuration profile** granting the NinjaOne
agent Automation access to `com.apple.systemevents`. Without it the script will
fail on every Mac where the agent has not already been approved.

### Alternative: enforce it with a configuration profile

If you want the wallpaper **locked** so users cannot change it, a profile is a
better fit than a script. Deploy a custom profile with the `com.apple.desktop`
payload:

| Key | Type | Value |
| --- | --- | --- |
| `override-picture-path` | String | `/Library/Application Support/One Inc/Wallpaper/wallpaper.jpg` |

Still run the script (or a NinjaOne file deployment) first, so the image exists
locally before the profile points at it.

## Updating the wallpaper

1. Replace `wallpaper/wallpaper.jpg`, commit, and push to `main`.
2. Machines pick up the new image on the script's next run — no NinjaOne change
   needed, since the URL is stable.
