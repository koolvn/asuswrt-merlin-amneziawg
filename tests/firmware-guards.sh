#!/bin/sh
# Run only in a disposable Linux container; see tests/README.md.
[ "${AWG_TEST_ISOLATED:-}" = 1 ] || { echo 'Run in a disposable container with AWG_TEST_ISOLATED=1' >&2; exit 2; }
# Never use container init (PID 1) as a fake reclaimable addon owner.
if [ "$$" -eq 1 ]; then
    sh "$0" "$@"
    exit $?
fi
SRC=${1:-/src}
mkdir -p /tmp/loop-main
cd /tmp/loop-main || exit 1
extract(){
    awk -v name="$1" '$0 ~ "^" name "\\(\\)" {copy=1} copy {print} copy && /^[})]$/ {exit}' "$2"
}
: > functions.sh
for name in lock_transition proc_start_time lock_age_s acquire_lock _acquire_lock_once release_lock _release_lock reclaim_wedged_lock _reclaim_wedged_lock operation_lock_busy _operation_lock_busy run_bounded kill_tree fw_dns_redirect_active fw_dns_redirect_name setup_ipv6_block; do
    extract "$name" "$SRC/addon/amneziawg.sh" >> functions.sh
done
. ./functions.sh
LOCK_STALE_S=1800
log_msg(){ echo "$*" >> /tmp/loop-main/log; }
awg_incident(){ echo "$*" >> /tmp/loop-main/incidents; }
fail(){ echo "FAIL: $*" >&2; exit 1; }
pass(){ echo "PASS: $*"; }
is_live(){
    [ -r "/proc/$1/stat" ] || return 1
    read -r line < "/proc/$1/stat"
    line=${line##*) }
    case "$line" in Z\ *|X\ *) return 1 ;; *) return 0 ;; esac
}
out=$(run_bounded 3 sh -c 'printf "%s\n" "$1"; exit 7' sh 'argument * with spaces')
rc=$?
[ "$rc" = 7 ] && [ "$out" = 'argument * with spaces' ] || fail "return code / stdout / arguments: $rc $out"
pass 'return code, stdout and literal arguments'
run_bounded 2 sh -c 'printf partial; sleep 30' > timeout.out
rc=$?
[ "$rc" = 124 ] && [ ! -s timeout.out ] || fail 'timeout must discard partial stdout and return 124'
[ -s log ] && [ -s incidents ] || fail 'timeout logging'
set -- /tmp/.awg_rb.*
[ ! -e "$1" ] || fail 'timeout temp leaked'
pass 'timeout, empty response, logging and temp cleanup'
cat > nested.sh <<'NESTED'
#!/bin/sh
echo $$ >> /tmp/loop-main/pids
if [ "$1" -gt 0 ]; then
    sh /tmp/loop-main/nested.sh $(($1 - 1)) &
else
    sleep 30 &
    echo $! >> /tmp/loop-main/pids
fi
wait
NESTED
run_bounded 2 sh ./nested.sh 2 >/dev/null
[ "$?" = 124 ] || fail 'tree timeout'
for p in $(cat pids); do is_live "$p" && fail "live descendant: $p"; done
pass 'three generations of child processes removed'
for n in 1 2 3 4 5 6 7 8; do
    (run_bounded 3 sh -c 'usleep 50000; echo "$1"' sh "$n" > "sibling.$n") &
done
wait
for n in 1 2 3 4 5 6 7 8; do [ "$(cat "sibling.$n")" = "$n" ] || fail "sibling $n"; done
set -- /tmp/.awg_rb.*
[ ! -e "$1" ] || fail 'sibling temp leaked'
pass 'concurrent sibling calls keep independent output'
(
    mktemp(){ return 1; }
    run_bounded 1 echo forbidden > unavailable
    [ "$?" = 124 ] && [ ! -s unavailable ] || fail 'mktemp failure'
) || exit 1
pass 'unavailable temporary storage returns 124'
(
    pidof(){ return 1; }
    nv(){ [ "$2" = "$unreadable" ] && return 124; echo "$value"; }
    value=0; unreadable=''
    fw_dns_redirect_active && fail 'disabled owner reported active'
    [ -z "$(fw_dns_redirect_name)" ] || fail 'disabled owner named'
    for unreadable in dnsfilter_enable_x dns_director_enable dnspriv_enable; do
        fw_dns_redirect_active || fail "unknown owner $unreadable must be active"
        case "$(fw_dns_redirect_name)" in "unknown DNS owner (nvram get $unreadable timed out)") ;; *) fail 'unknown owner name' ;; esac
    done
    unreadable=''; value=1
    fw_dns_redirect_active || fail 'enabled owner inactive'
    case "$(fw_dns_redirect_name)" in 'firmware DNSFilter '*) ;; *) fail 'enabled owner name' ;; esac
) || exit 1
pass 'DNS owner timeouts fail safe for each flag'
(
    nv(){ printf '%s' "$value"; return "$result"; }
    ip6tables(){ echo "$*" >> ip6; [ "$1" != -C ]; }
    IFACE=awg0
    value=disabled; result=0; : > ip6
    setup_ipv6_block
    [ ! -s ip6 ] || fail 'confirmed-disabled IPv6 modified'
    value=''; result=124
    setup_ipv6_block
    [ "$(grep -c '^-I' ip6)" = 2 ] || fail 'timeout missing IPv6 rejects'
) || exit 1
pass 'IPv6 timeout installs both rejects'

# Cancellation hits the supervisor itself. Its traps must clean children and stdout;
# the enclosing shell's independent EXIT handler must remain intact.
cat > cancelled.sh <<'CANCEL'
#!/bin/sh
. /tmp/loop-main/functions.sh
log_msg(){ :; }
awg_incident(){ :; }
trap 'echo parent > /tmp/loop-main/parent-trap' EXIT
run_bounded 2 sh -c 'echo "$PPID" > /tmp/loop-main/supervisor; echo $$ > /tmp/loop-main/cancel-child; sleep 30'
CANCEL
sh ./cancelled.sh & caller=$!
while [ ! -s supervisor ] || [ ! -s cancel-child ]; do usleep 10000; done
kill -TERM "$(cat supervisor)"
wait "$caller" 2>/dev/null
[ "$?" = 143 ] || fail 'cancelled supervisor exit code'
is_live "$(cat cancel-child)" && fail 'cancelled child survived'
[ "$(cat parent-trap)" = parent ] || fail 'caller trap overwritten'
set -- /tmp/.awg_rb.*
[ ! -e "$1" ] || fail 'cancelled capture leaked'
pass 'cancellation cleans descendants/capture and preserves caller trap'

LOCKDIR=/tmp/loop-main/lock
acquire_lock || fail 'initial lock'
read -r owner_pid owner_start owner_since < "$LOCKDIR/owner"
[ "$owner_pid" = "$$" ] || fail 'wrong owner pid'
[ "$owner_start" = "$(proc_start_time "$$")" ] || fail 'wrong process identity'
reclaim_wedged_lock "$$" test && fail 'fresh lock reclaimed'
[ -d "$LOCKDIR" ] || fail 'fresh lock missing'
# Simulate a long-lived downloading process: its actual age is irrelevant to this
# just-acquired lock; the persisted acquisition uptime controls the decision.
(
    proc_age_s(){ echo 1900; }
    reclaim_wedged_lock "$$" test && fail 'process age used as lock age'
    exit 0
) || exit 1
release_lock || fail 'release own lock'
pass 'owner identity and acquisition time are recorded; fresh lock survives'

# A recycled numeric PID must not cause ANY signal to the new process.
acquire_lock || fail 'recycled-PID fixture'
printf '%s %s 0\n' "$$" 1 > "$LOCKDIR/owner"
(
    kill_tree(){ fail 'signalled reused PID'; }
    reclaim_wedged_lock "$$" test || fail 'recycled-PID stale lock not retired'
) || exit 1
[ ! -d "$LOCKDIR" ] || fail 'recycled-PID stale lock retained'
pass 'reused PID retires stale lock without signalling the new process'

# Legacy PID-only records do not authorize signals to an unidentified live owner.
mkdir "$LOCKDIR"; echo $$ > "$LOCKDIR/pid"
reclaim_wedged_lock "$$" test && fail 'legacy live owner reaped'
[ -d "$LOCKDIR" ] || fail 'legacy lock removed'
rm -rf "$LOCKDIR"
pass 'live legacy PID-only owner is preserved'

# Force the original race with two reclaimers and a competing acquire. All three
# directory mutations must share the guard; only the original generation is removed.
cat > holder.sh <<'HOLDER'
#!/bin/sh
. /tmp/loop-main/functions.sh
LOCKDIR=/tmp/loop-main/lock
acquire_lock || exit 1
echo ready > /tmp/loop-main/holder-ready
sleep 30
HOLDER
sh ./holder.sh & holder=$!
while [ ! -f holder-ready ]; do usleep 10000; done
read -r p st since < "$LOCKDIR/owner"
printf '%s %s 0\n' "$p" "$st" > "$LOCKDIR/owner"
LOCK_STALE_S=-1
(
    kill_tree(){ sleep 1; kill -9 "$1"; }
    reclaim_wedged_lock "$holder" first
) & first=$!
usleep 100000
reclaim_wedged_lock "$holder" second & second=$!
(
    acquire_lock || exit 1
    echo "$AWG_LOCK_PID" > /tmp/loop-main/new-owner
    sleep 1
    [ "$(cat "$LOCKDIR/pid")" = "$AWG_LOCK_PID" ] || exit 1
    release_lock
) & fresh=$!
wait "$first" || fail 'first reclaim'
wait "$second" 2>/dev/null
wait "$fresh" || fail 'new lock lost during competing reclaim'
wait "$holder" 2>/dev/null
[ -s new-owner ] || fail 'new acquisition never finished'
pass 'concurrent reclaim/acquire preserves new ownership'

# A held transition guard means watchdog must stand down, and a killed guard
# holder must release its kernel lock without manual filesystem cleanup.
(
    flock -x 9 || exit 1
    echo ready > /tmp/loop-main/guard-ready
    sleep 30
) 9>"${LOCKDIR}.guard" & guard=$!
while [ ! -f guard-ready ]; do usleep 10000; done
operation_lock_busy || fail 'contended guard treated as idle'
kill_tree "$guard"; wait "$guard" 2>/dev/null
acquire_lock || fail 'guard stayed locked after process death'
release_lock || fail 'guard recovery release'
pass 'guard contention fails safe and kernel releases dead holder'

# Missing optional flock preserves ordinary operation but disables forced live reap.
(
    which(){ return 1; }
    acquire_lock || fail 'lock without flock'
    reclaim_wedged_lock "$AWG_LOCK_PID" test && fail 'unsafe reap without flock'
    release_lock || fail 'unlock without flock'
) || exit 1
pass 'legacy firmware without flock keeps normal acquire/release'

# Exercise complete Stop and Watchdog bodies with all router effects mocked.
for role in client server; do
    (
        LOCKDIR="/tmp/loop-main/$role-lock"
        STARTING_FLAG=/tmp/loop-main/starting
        STOPPING_FLAG=/tmp/loop-main/stopping
        PF_OVERRIDE=/tmp/loop-main/profile
        FAILOVER_STATE=/tmp/loop-main/failover
        RUNNING_CONF_SIG=/tmp/loop-main/conf-sig
        DNSRELOAD_SIG=/tmp/loop-main/dns-sig
        IFACE=looptest0
        RT_TABLE=300
        for name in do_analyze_stop update_status srv_update_status conn_record_stop ipt_drain cleanup_ipv6_block get_lan_net cleanup_firewall get_endpoint restore_rp_filter reload_dnsmasq srv_cleanup_firewall wait_for_pid_exit ip pidof; do
            eval "$name(){ :; }"
        done
        awg_cru(){ return 124; }
        if [ "$role" = client ]; then
            extract do_stop "$SRC/addon/amneziawg.sh" > lifecycle.sh
            extract do_watchdog "$SRC/addon/amneziawg.sh" >> lifecycle.sh
            . ./lifecycle.sh
            do_start(){ fail 'watchdog restarted deliberately stopped client'; }
            do_stop user || fail 'client Stop'
            [ -f "${LOCKDIR}.stopped" ] || fail 'client stop intent absent'
            do_watchdog || fail 'stopped client watchdog'
        else
            extract do_srv_stop "$SRC/addon/amneziawg_server.sh" > lifecycle.sh
            extract do_srv_watchdog "$SRC/addon/amneziawg_server.sh" >> lifecycle.sh
            . ./lifecycle.sh
            do_srv_start(){ fail 'watchdog restarted deliberately stopped server'; }
            do_srv_stop user || fail 'server Stop'
            [ -f "${LOCKDIR}.stopped" ] || fail 'server stop intent absent'
            do_srv_watchdog || fail 'stopped server watchdog'
        fi
        [ ! -d "$LOCKDIR" ] || fail 'Stop retained operation lock'
    ) || exit 1
done
pass 'client/server Stop survives cron timeout; watchdog cannot restart either role'

# An already-running watchdog can reach Start after Stop won the lock. Start must
# re-check the intent under the lock; a subsequent explicit Start clears it.
for role in client server; do
    (
        LOCKDIR="/tmp/loop-main/$role-start-lock"
        STARTING_FLAG=/tmp/loop-main/start-flag
        update_status(){ :; }
        srv_update_status(){ :; }
        ctf_active(){ return 1; }
        get_setting(){ :; }
        ip(){ echo 'inet 192.0.2.1'; }
        is_running(){ calls=$((calls + 1)); [ "$calls" -gt 1 ]; }
        if [ "$role" = client ]; then
            extract do_start "$SRC/addon/amneziawg.sh" > start.sh
            start_fn=do_start
        else
            extract do_srv_start "$SRC/addon/amneziawg_server.sh" > start.sh
            start_fn=do_srv_start
        fi
        . ./start.sh
        touch "${LOCKDIR}.stopped"
        calls=0; AWG_WATCHDOG=1
        "$start_fn" || fail 'in-flight watchdog Start'
        [ -f "${LOCKDIR}.stopped" ] || fail 'in-flight watchdog cleared Stop'
        [ ! -d "$LOCKDIR" ] || fail 'in-flight watchdog retained lock'
        calls=0; AWG_WATCHDOG=0
        "$start_fn" || fail 'explicit Start'
        [ ! -f "${LOCKDIR}.stopped" ] || fail 'explicit Start retained Stop'
        [ ! -d "$LOCKDIR" ] || fail 'explicit Start retained lock'
    ) || exit 1
done
pass 'in-flight watchdog honors Stop under lock; explicit Start clears it for both roles'


# Run the nested rc_service settling function with slow unavailable reads.
awk '/^        _rc_settle\(\)/{copy=1} copy{print} copy && /^        }$/{exit}' "$SRC/addon/amneziawg.sh" > settle.sh
. ./settle.sh
(
    nv(){ sleep 2; return 124; }
    dnsreload_deferred(){ return 1; }
    _rcbudget=3
    read -r up rest < /proc/uptime; start=${up%%.*}
    _rc_settle
    read -r up rest < /proc/uptime; elapsed=$((${up%%.*} - start))
    [ "$_rcbudget" -le 0 ] && [ "$elapsed" -le 5 ] || fail "settle budget: $_rcbudget elapsed=$elapsed"
) || exit 1
pass 'rc_service timeout consumes elapsed seconds'
echo 'All firmware guard checks passed.'
