#!/bin/bash
#
# set-wallpaper.sh — download the company wallpaper and apply it for the
# currently logged-in user.
#
# Deploy via NinjaOne as a Mac script, Run As: Root (System).
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
#-------------------------------------------------------------------------------

apply_via_applescript() {
    /bin/launchctl asuser "$console_uid" /usr/bin/sudo -u "$console_user" \
        /usr/bin/osascript -e "tell application \"System Events\" to tell every desktop to set picture to POSIX file \"${INSTALL_PATH}\"" \
        2>&1
}

log "Applying wallpaper for ${console_user}"
if output=$(apply_via_applescript); then
    log "Wallpaper applied"
else
    log "AppleScript attempt failed: ${output}"
    log "Resetting the wallpaper store and retrying"

    # macOS 14+ keeps wallpaper state here. Clearing it and restarting the
    # agent forces macOS to re-read the setting.
    user_home=$(/usr/bin/dscl . -read "/Users/${console_user}" NFSHomeDirectory \
        | /usr/bin/awk '{print $2}')
    store="${user_home}/Library/Application Support/com.apple.wallpaper/Store"
    [ -d "$store" ] && /bin/rm -f "${store}/Index.plist"

    /usr/bin/killall -u "$console_user" WallpaperAgent 2>/dev/null
    /bin/sleep 3

    if output=$(apply_via_applescript); then
        log "Wallpaper applied on retry"
    else
        die "Could not apply wallpaper: ${output}. If this says 'not authorized to send Apple events', grant the NinjaOne agent Automation access to System Events via a PPPC configuration profile."
    fi
fi

# Nudge the UI so the change shows without a logout.
/usr/bin/killall -u "$console_user" WallpaperAgent 2>/dev/null
/usr/bin/killall -u "$console_user" Dock 2>/dev/null

log "Done"
exit 0
