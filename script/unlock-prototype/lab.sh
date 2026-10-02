#!/bin/bash
# HUMAN ONLY. Never run on Roshan's in-use Mac. Fixed prototype paths; no shipping-host operations.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root='/Library/Application Support/FarsideUnlockPrototype'
daemon=/Library/LaunchDaemons/com.roshan.Farside.UnlockPrototype.daemon.plist
agent=/Library/LaunchAgents/com.roshan.Farside.UnlockPrototype.agent.plist
label=com.roshan.Farside.UnlockPrototype.agent
[[ $EUID == 0 ]] || { echo 'Run with sudo on the test Mac.'; exit 1; }
case "${1:-}" in
install)
    command -v python3 >/dev/null || { echo 'Python 3 is required by the verified cleanup helper; refusing install.'; exit 1; }
    [[ $# == 3 && "$2" =~ ^[0-9]+$ && "$2" -ge 501 ]] || { echo 'Usage: sudo lab.sh install DISPOSABLE_UID ARTIFACT_DIRECTORY'; exit 1; }
    [[ -t 0 && -r /dev/tty ]] || { echo 'TTY required.'; exit 1; }
    read -r -p 'On a disposable test Mac with saved work, type TEST-MAC to install: ' answer </dev/tty
    [[ "$answer" == TEST-MAC ]] || exit 1
    # Do not install over leftovers: uninstall and prove cleanup first.
    [[ ! -e "$root" && ! -L "$root" && ! -e "$daemon" && ! -L "$daemon" && ! -e "$agent" && ! -L "$agent" ]] || { echo 'Prototype paths exist. Run uninstall first.'; exit 1; }
    test_user=$(id -nu "$2")
    [[ $(id -u "$test_user") == "$2" ]] || exit 1
    membership=$(dsmemberutil checkmembership -U "$test_user" -G admin)
    case "$membership" in
        *'is not a member'*) ;;
        *'is a member'*) echo 'Use a disposable standard account, not an administrator.'; exit 1;;
        *) echo 'Cannot verify standard-account status; refusing install.'; exit 1;;
    esac
    artifacts=$(cd "$3" && pwd)
    requirement='anchor apple generic and certificate leaf[subject.OU] = "39HM2X8GS6"'
    for pair in 'UnlockDaemon:daemon' 'UnlockControl:control' 'UnlockAgent.app:agent'; do
        file=${pair%%:*}; role=${pair##*:}
        codesign --verify --strict --deep -R "$requirement and identifier \"com.roshan.Farside.UnlockPrototype.$role\"" "$artifacts/$file"
    done
    install -d -o root -g wheel -m 755 "$root"
    install -o root -g wheel -m 755 "$artifacts/UnlockDaemon" "$root/UnlockDaemon"
    install -o root -g wheel -m 755 "$artifacts/UnlockControl" "$root/UnlockControl"
    cp -R "$artifacts/UnlockAgent.app" "$root/UnlockAgent.app"
    chown -R root:wheel "$root/UnlockAgent.app"
    chmod -R go-w "$root/UnlockAgent.app"
    # Verify the installed root-owned copies too, before granting any launchd execution.
    for pair in 'UnlockDaemon:daemon' 'UnlockControl:control' 'UnlockAgent.app:agent'; do
        file=${pair%%:*}; role=${pair##*:}
        codesign --verify --strict --deep -R "$requirement and identifier \"com.roshan.Farside.UnlockPrototype.$role\"" "$root/$file"
    done
    # No password, token or account name is persisted.
    /usr/libexec/PlistBuddy -c 'Add :Enabled bool true' -c "Add :DisposableUID integer $2" "$root/config.plist"
    chown root:wheel "$root/config.plist"; chmod 644 "$root/config.plist"
    install -o root -g wheel -m 644 "$here/plists/daemon.plist" "$daemon"
    install -o root -g wheel -m 644 "$here/plists/agent.plist" "$agent"
    launchctl bootstrap system "$daemon"
    echo "Installed. Bootstrap Aqua only while logged in locally as the disposable UID $2:"
    echo "sudo launchctl bootstrap gui/$2 '$agent'"
    echo 'LoginWindow loads the global agent on the next deliberate logout; see the test document.'
    ;;
disable)
    [[ -f "$root/config.plist" && ! -L "$root/config.plist" ]] || exit 1
    /usr/libexec/PlistBuddy -c 'Set :Enabled false' "$root/config.plist"
    echo 'Prototype operations disabled. Uninstall to stop all prototype jobs.'
    ;;
uninstall)
    # Disable first; never depend on bootstrap domain still existing after logout.
    if [[ -f "$root/config.plist" && ! -L "$root/config.plist" ]]; then
        /usr/libexec/PlistBuddy -c 'Set :Enabled false' "$root/config.plist" || true
    fi
    # Enumerate every loaded prototype agent, including inactive Aqua and LoginWindow sessions.
    # bootout uses each exact service target, never an entire domain.
    domains=$(python3 "$here/domains.py")
    if [[ -f "$root/sessions.plist" && ! -L "$root/sessions.plist" ]]; then
        asids=$(python3 -c 'import plistlib,sys; print(" ".join("login/"+str(x) for x in plistlib.load(open(sys.argv[1],"rb"))["ASIDs"]))' "$root/sessions.plist")
        domains="$domains $asids"
    fi
    # Explicit disposable GUI domain, plus current GUI domain, covers common launchctl output changes.
    if [[ -f "$root/config.plist" && ! -L "$root/config.plist" ]]; then
        uid=$(/usr/libexec/PlistBuddy -c 'Print :DisposableUID' "$root/config.plist" 2>/dev/null || true)
        [[ "$uid" =~ ^[0-9]+$ ]] && domains="$domains gui/$uid"
    fi
    # Ask launchctl to unload the exact service visible in every surviving prototype process domain.
    for pid in $(pgrep -x UnlockAgent || true); do
        path=$(ps -p "$pid" -o comm=)
        case "$path" in "$root/UnlockAgent.app/Contents/MacOS/UnlockAgent") launchctl bootout "pid/$pid/$label" 2>/dev/null || true;; esac
    done
    for domain in $domains; do launchctl bootout "$domain/$label" 2>/dev/null || true; done
    launchctl bootout "system/com.roshan.Farside.UnlockPrototype.daemon" 2>/dev/null || true
    rm -f "$daemon" "$agent"
    # No KeepAlive job is present; removing the plist prevents any future session load.
    # Kill only remaining executables from this unique prototype directory, across GUI sessions.
    # Do not match arguments, user names, Farside Host, or all processes from a UID.
    for pid in $(pgrep -x UnlockAgent || true) $(pgrep -x UnlockDaemon || true); do
        path=$(ps -p "$pid" -o comm=)
        case "$path" in "$root/UnlockDaemon"|"$root/UnlockAgent.app/Contents/MacOS/UnlockAgent") kill -TERM "$pid";; esac
    done
    # Do not remove the session manifest until every known stopped or running job is absent.
    for domain in $domains; do
        if launchctl print "$domain/$label" >/dev/null 2>&1; then
            echo "LEFTOVER loaded agent job: $domain/$label. Files disabled; retry uninstall."; exit 1
        fi
    done
    rm -rf "$root"
    echo 'Files removed. Run verify-clean, then remove prototype-only TCC rows and captured test PNGs manually.'
    ;;
verify-clean)
    failed=0
    for path in "$root" "$daemon" "$agent"; do
        if [[ -e "$path" || -L "$path" ]]; then echo "LEFTOVER: $path"; failed=1; fi
    done
    if launchctl print system/com.roshan.Farside.UnlockPrototype.daemon >/dev/null 2>&1; then echo 'LEFTOVER daemon job'; failed=1; fi
    domains=$(python3 "$here/domains.py")
    for domain in $domains; do
        if launchctl print "$domain/$label" >/dev/null 2>&1; then echo "LEFTOVER loaded agent job: $domain/$label"; failed=1; fi
    done
    # Unique names used only by this prototype; an unrelated same-name process produces a conservative failure.
    if pgrep -x UnlockDaemon >/dev/null || pgrep -x UnlockAgent >/dev/null; then echo 'LEFTOVER prototype process: do not call cleanup complete.'; failed=1; fi
    [[ $failed == 0 ]] && echo 'PASS: no prototype files, daemon job, or agent/daemon processes.'
    exit "$failed"
    ;;
*) echo 'Usage: sudo lab.sh install UID ARTIFACT_DIRECTORY | disable | uninstall | verify-clean'; exit 1;;
esac
