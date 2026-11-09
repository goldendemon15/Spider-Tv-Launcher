#!/usr/bin/env bash
# spider-front.sh — keep Spider on screen while this computer is attached.
#
# WHAT THIS IS NOT
#   It does not make Spider the HOME app. This firmware resolves HOME by
#   intent-filter priority: com.google.android.apps.tv.launcherx declares 2,
#   while a non-privileged app's priority is capped at 0, so HOME still opens
#   launcherx regardless of ROLE_HOME or the stored preferred activity.
#   ./spider.sh status prints that evidence; ./spider.sh verify exits 1.
#
# WHAT IT DOES
#   It sends one small shell script to the TV and leaves it running there, over
#   a single adb session. That script polls mCurrentFocus and starts
#   com.spidertv.launcher/.SpiderHomeActivity whenever launcherx has focus, so
#   polling costs no per-poll adb process or Wi-Fi round trip.
#
#   It is still a focus bounce, not ownership:
#     - needs this computer awake and connected (a dead adb session is retried);
#     - a TV reboot or Wi-Fi drop ends the session; it reconnects when an adb
#       endpoint exists again. This TV leaves wireless debugging off after a
#       clean reboot, so the shim waits (quietly) until the toggle is back on;
#     - each HOME press shows launcherx briefly before Spider comes back;
#     - anything you open on launcherx is taken away within INTERVAL seconds,
#       so the stock home is unusable while this runs.
#
#   Stop with Ctrl-C: the adb session is killed and the remote loop is killed
#   through /data/local/tmp/spider-front.pid, so no interceptor is left behind.
#
# USAGE
#   ./spider-front.sh                 # 2 second poll, on the TV
#   INTERVAL=5 ./spider-front.sh      # slower
#   SERIAL=<transport> ./spider-front.sh
#   ADB=/path/to/adb ./spider-front.sh

set -uo pipefail

SPIDER=com.spidertv.launcher
SPIDER_ACT="$SPIDER/.SpiderHomeActivity"
LAUNCHER=com.google.android.apps.tv.launcherx
PIDFILE=/data/local/tmp/spider-front.pid
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INTERVAL="${INTERVAL:-2}"
case "$INTERVAL" in
    ''|*[!0-9.]*) INTERVAL=2 ;;
esac
if ! awk -v v="$INTERVAL" 'BEGIN{exit !(v >= 0.5)}' 2>/dev/null; then
    INTERVAL=2
fi

find_adb() {
    if [ -n "${ADB:-}" ] && command -v "$ADB" >/dev/null 2>&1; then
        printf '%s\n' "$ADB"; return 0
    fi
    if command -v adb >/dev/null 2>&1; then
        command -v adb; return 0
    fi
    local c
    for c in "$HERE/tools/platform-tools/adb.exe" "$HERE/tools/platform-tools/adb" \
             "$HERE/platform-tools/adb.exe" "$HERE/platform-tools/adb" \
             "$HERE/tools/platform-tools-r34/adb.exe" "$HERE/tools/platform-tools-r34/adb" \
             "$HERE/platform-tools-r34/adb.exe" "$HERE/platform-tools-r34/adb"; do
        [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}
if ! ADB="$(find_adb)"; then
    echo "spider-front: no adb found. Set ADB=/path/to/adb." >&2
    exit 1
fi

pick_device() {
    "$ADB" devices 2>/dev/null | tr -d '\r' | awk 'NR>1 && $2=="device"{print $1; exit}'
}

# The script that actually runs on the TV. Local values are substituted here;
# device-side expansions are escaped.
build_device_script() {
    cat <<EOF
s=$PIDFILE
if [ -f "\$s" ]; then kill "\$(cat "\$s")" 2>/dev/null; fi
echo \$\$ > "\$s"
while :; do
    f=\$(dumpsys window 2>/dev/null | grep mCurrentFocus | head -1)
    case "\$f" in
        *$LAUNCHER*)
            echo "\$(date +%H:%M:%S 2>/dev/null) launcherx focused -> Spider"
            am start -n $SPIDER_ACT >/dev/null 2>&1 || echo "am start failed"
            ;;
    esac
    sleep $INTERVAL
done
EOF
}
DEVICE_SCRIPT="$(build_device_script)"

S="$(pick_device)"
if [ -z "$S" ]; then
    echo "spider-front: no device answered. Wake the TV, check wireless debugging," >&2
    echo "              then run ./spider.sh status to confirm the transport." >&2
    exit 1
fi
if ! "$ADB" -s "$S" shell pm list packages 2>/dev/null | tr -d '\r' | grep -qx "package:$SPIDER"; then
    echo "spider-front: $SPIDER is not installed on $S. Run ./spider.sh install first." >&2
    exit 1
fi

stopped=0
child=""
dev_serial=""

stop() {
    stopped=1
    if [ -n "${child:-}" ]; then
        kill "$child" 2>/dev/null || true
    fi
    if [ -n "${dev_serial:-}" ]; then
        timeout 2 "$ADB" -s "$dev_serial" shell \
            "kill \$(cat $PIDFILE) 2>/dev/null; rm -f $PIDFILE" >/dev/null 2>&1 || true
    fi
    printf '\nspider-front: stopped; remote loop killed. Nothing was changed on the TV; HOME still resolves to %s.\n' "$LAUNCHER"
    exit 0
}
trap stop INT TERM

# Sleep in a child and wait on it: a signal interrupts wait cleanly instead of
# making bash print "Terminated  sleep ...".
pause() { sleep "$INTERVAL" & local p=$!; wait "$p"; }

printf '==> spider-front on %s\n' "$S"
printf '    %s -> %s every %ss, loop runs on the TV over one adb session\n' "$LAUNCHER" "$SPIDER" "$INTERVAL"
printf '    Needs this computer awake and connected; HOME still resolves to %s.\n\n' "$LAUNCHER"

misses=0
while :; do
    s="${SERIAL:-$(pick_device)}"
    if [ -z "$s" ]; then
        misses=$((misses + 1))
        if [ "$misses" -eq 1 ]; then
            echo "waiting for a device — is the TV awake and wireless debugging on?" >&2
        fi
        pause
        continue
    fi
    misses=0
    dev_serial="$s"

    printf '%s\n' "$DEVICE_SCRIPT" | "$ADB" -s "$s" shell sh -s &
    child=$!
    wait "$child"; rc=$?
    child=""
    [ "$stopped" = 1 ] && break
    printf 'session ended (rc=%s); reconnecting in %ss\n' "$rc" "$INTERVAL" >&2
    pause
done
