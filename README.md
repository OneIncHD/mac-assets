# mac-assets

Assets and deployment scripts for One Inc managed Macs.

## Contents

| Path | Description |
| --- | --- |
| `wallpaper/wallpaper.jpg` | Company values wallpaper, 3840×2160 (4K), ~492 KB |
| `scripts/set-wallpaper.sh` | NinjaOne script that downloads and applies the wallpaper |

## Raw wallpaper URL

```
https://raw.githubusercontent.com/OneIncHD/mac-assets/main/wallpaper/wallpaper.jpg
```

`raw.githubusercontent.com` caches branch URLs for about five minutes. To make a
deployment immutable, tag the release and reference the tag instead of `main`:

```
https://raw.githubusercontent.com/OneIncHD/mac-assets/v1/wallpaper/wallpaper.jpg
```

## Pick a deployment method

The two options are not interchangeable — they differ in whether users keep
control of their own wallpaper:

| | Intune profile | NinjaOne / Intune script |
| --- | --- | --- |
| User-visible prompts | **None** | Possible (see below) |
| Users can change wallpaper | **No** — enforced | Yes, it is just a default |
| Needs MDM enrolment | Yes | No |
| Applies at | Login / reboot | Immediately |

There is no middle ground: the `com.apple.desktop` payload has no setting that
applies a *changeable* default. If users must keep control, you have to use the
script and accept the prompt caveats.

Both methods need the image staged on disk first, so the script is required
either way — the profile only points at a local file, it cannot download one.

### Why not package the image as a .pkg?

Intune can deploy a `.pkg`, but it is the worse option here:

* **Line-of-business app** requires the `.pkg` to be signed with a *Developer ID
  Installer* certificate, which needs paid Apple Developer Program membership.
* **macOS app (PKG)** accepts unsigned packages (agent 2308.006+), so no
  certificate is needed — but Intune detects `.pkg` installs by app bundle ID.
  A wallpaper installs a `.jpg`, not a `.app`, so there is nothing to detect:
  the app never reports success and Intune retries it at every check-in.

Either way, updating the wallpaper means rebuilding the package and re-uploading
it, instead of a `git push`. The shell script needs no certificate, no
packaging, and no detection rules.

## Method 1 — Intune configuration profile (silent, enforced)

This is the only way to set the wallpaper with **zero** user-visible dialogs. It
writes a managed preference directly, so nothing sends Apple Events and
`WallpaperImageExtension` is never launched.

**Order matters.** Stage the image before the profile lands, or the desktop goes
grey until the next reboot.

1. **Stage the image** — Intune admin center → **Devices → macOS → Shell
   scripts → Add**
   - Upload `scripts/set-wallpaper.sh`
   - Run script as signed-in user: **No** (it must run as root)
   - Script frequency: every 1 day (it is idempotent — see below)
   - Assign to your Mac group and let it run once
2. **Apply the profile** — **Devices → macOS → Configuration → Create →
   Templates → Custom**
   - Upload `profiles/wallpaper.mobileconfig`
   - Assign to the same group

Note that step 1 leaves the script's own `osascript` apply step in place, which
is what can prompt. If you are going the profile route and want the script to do
nothing but download, set `APPLY_IN_SESSION=0` at the top of the script.

### Known quirk on Apple Silicon

The lock screen shows the company wallpaper, then after login the default macOS
wallpaper appears for 10–15 seconds before the company one takes over. Cosmetic,
but users notice it. Nothing to be done about it short of not using the profile.

## Method 2 — Script only (changeable default)

1. **NinjaOne:** Automation → Scripts → New Script
   - Language `Shell`, OS `Mac`, Architecture `All`, Run As **Root (System)**
   - Paste the contents of `scripts/set-wallpaper.sh`
2. Add it to a policy as a scheduled or login-triggered task.

The script is idempotent — it checksums the local copy and only re-downloads
when the image in this repo changes, so it is safe to run on a schedule.

### What it does

1. Downloads the wallpaper to `/Library/Application Support/One Inc/Wallpaper/`
   and verifies it is really an image, not an HTML error page.
2. Finds the user logged in at the console; if nobody is, it stops there with
   the image already staged for next time.
3. Applies it in that user's GUI session via `osascript`.

Progress goes to stdout (visible in the script output) and to the system log
under the tag `set-wallpaper`:

```
log show --predicate 'eventMessage CONTAINS "set-wallpaper"' --last 1h
```

### Keeping it quiet

The script deliberately does **not** restart `WallpaperAgent` or `Dock`, and
does **not** delete the user's `Index.plist`. All three force macOS to relaunch
`WallpaperImageExtension`, which on Sequoia raises a Gatekeeper dialog:

> "WallpaperImageExtension" differs from previously opened versions. Are you
> sure you want to open it?

None of those steps were necessary — the `osascript` call already takes effect
immediately. Do not add them back.

### Automation permission (important)

Setting the desktop picture via `osascript` goes through Apple Events, which
macOS gates behind TCC. If the script reports *"not authorized to send Apple
events"*, deploy a **PPPC configuration profile** granting the management agent
Automation access to `com.apple.systemevents`. Without it the script fails on
every Mac where the agent has not already been approved — and the approval
prompt is itself user-visible, so the profile is not optional at scale.

## Updating the wallpaper

1. Replace `wallpaper/wallpaper.jpg`, commit, and push to `main`.
2. Machines pick up the new image on the script's next run — no Intune or
   NinjaOne change needed, since the URL is stable.
