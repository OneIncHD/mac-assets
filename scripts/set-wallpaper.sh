#!/bin/bash
#
# set-wallpaper.sh — download the company wallpaper and apply it for the
# currently logged-in user.
#
# Deploy as a root-level Mac script via Intune (Devices > macOS > Shell
# scripts) or NinjaOne (Run As: Root).
# Safe to run repeatedly: the image is only re-downloaded when it changes.
#
# Exit codes: 0 = applied (or already current), 1 = failure.

set -u

#-------------------------------------------------------------------------------
# Config
#-------------------------------------------------------------------------------

# Raw GitHub URL of the wallpaper. Pin to a tag or commit SHA instead of a
# branch if you want deployments to be immutable.
WALLPAPER_URL="https://raw.githubusercontent.com/OneIncHD/mac-assets/main/wallpaper/wallpaper.jpg"

# Where the image lives on disk. Must be outside any user's home directory so
# every account on the Mac can read it.
INSTALL_DIR="/Library/Application Support/One Inc/Wallpaper"
INSTALL_PATH="${INSTALL_DIR}/wallpaper.jpg"

# 1 = also apply the wallpaper in the logged-in user's session via osascript.
# 0 = download and stage only, touching nothing in the GUI. Use 0 when a
#     configuration profile is enforcing the wallpaper, so the script can never
#     put a dialog in front of a user.
APPLY_IN_SESSION=1

LOG_TAG="set-wallpaper"

#-------------------------------------------------------------------------------
# Helpers
#-------------------------------------------------------------------------------

log() {
    echo "[${LOG_TAG}] $*"
    /usr/bin/logger -t "$LOG_TAG" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

#-------------------------------------------------------------------------------
# Download the wallpaper
#
# Done before checking for a logged-in user, so a Mac sitting at the login
# window still gets the image staged locally for the next run.
#-------------------------------------------------------------------------------

/bin/mkdir -p "$INSTALL_DIR" || die "Could not create ${INSTALL_DIR}"

tmp_file=$(/usr/bin/mktemp /tmp/wallpaper.XXXXXX) || die "Could not create temp file"
trap '/bin/rm -f "$tmp_file"' EXIT

log "Downloading ${WALLPAPER_URL}"
if ! /usr/bin/curl -fsSL --connect-timeout 15 --max-time 120 \
        -o "$tmp_file" "$WALLPAPER_URL"; then
    die "Download failed"
fi

# Sanity-check that we got an image and not an HTML error page.
if ! /usr/bin/file -b --mime-type "$tmp_file" | /usr/bin/grep -q '^image/'; then
    die "Downloaded file is not an image (got: $(/usr/bin/file -b "$tmp_file"))"
fi

new_sum=$(/usr/bin/shasum -a 256 "$tmp_file" | /usr/bin/awk '{print $1}')
old_sum=""
[ -f "$INSTALL_PATH" ] && old_sum=$(/usr/bin/shasum -a 256 "$INSTALL_PATH" | /usr/bin/awk '{print $1}')

if [ "$new_sum" = "$old_sum" ]; then
    log "Local copy already up to date (${new_sum})"
else
    /bin/mv "$tmp_file" "$INSTALL_PATH" || die "Could not install image to ${INSTALL_PATH}"
    log "Installed new image (${new_sum})"
fi

# Readable by everyone, traversable directories.
/bin/chmod 644 "$INSTALL_PATH"
/usr/sbin/chown root:wheel "$INSTALL_PATH"
/bin/chmod -R a+rX "$INSTALL_DIR"

#-------------------------------------------------------------------------------
# Identify the console user
#-------------------------------------------------------------------------------

if [ "$APPLY_IN_SESSION" -ne 1 ]; then
    log "Image staged; APPLY_IN_SESSION=0 so leaving the GUI session alone."
    exit 0
fi

console_user=$(/usr/bin/stat -f%Su /dev/console)

case "$console_user" in
    ""|root|loginwindow|_mbsetupuser)
        log "Image staged, but no user is logged in at the console (found '${console_user:-none}'). Skipping apply."
        exit 0
        ;;
esac

console_uid=$(/usr/bin/id -u "$console_user") || die "Could not resolve UID for $console_user"
log "Console user: ${console_user} (uid ${console_uid})"

#-------------------------------------------------------------------------------
# Apply it in the user's GUI session
#
# Deliberately quiet. Everything that could put a dialog or a visible glitch in
# front of the user has been removed:
#
#   * No `killall WallpaperAgent`. Forcing the agent to restart makes macOS
#     relaunch WallpaperImageExtension, which on Sequoia can raise a Gatekeeper
#     "differs from previously opened versions" prompt. The AppleScript below
#     already takes effect immediately, so the restart was only ever cosmetic.
#   * No `killall Dock`. Same relaunch risk, plus a visible UI flash.
#   * No deleting of the user's wallpaper store. Destroying Index.plist to force
#     a re-read is exactly the kind of disturbance that triggers the prompt, and
#     it throws away the user's other desktop settings as a side effect.
#
# If the AppleScript fails we report it upstream and leave the session alone.
#-------------------------------------------------------------------------------

log "Applying wallpaper for ${console_user}"

if output=$(/bin/launchctl asuser "$console_uid" /usr/bin/sudo -u "$console_user" \
        /usr/bin/osascript \
        -e "tell application \"System Events\" to tell every desktop to set picture to POSIX file \"${INSTALL_PATH}\"" \
        2>&1); then
    log "Wallpaper applied"
else
    log "Could not apply wallpaper: ${output}"
    case "$output" in
        *"not authorized"*|*"-1743"*|*"1743"*)
            die "The management agent lacks Automation access to System Events. Deploy the PPPC profile (see README) — the image is staged at ${INSTALL_PATH} and will apply on the next run once approved."
            ;;
    esac
    die "AppleScript failed. Image is staged at ${INSTALL_PATH}."
fi

log "Done"
exit 0
