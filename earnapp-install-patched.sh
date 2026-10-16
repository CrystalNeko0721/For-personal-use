#!/bin/sh
set -eu
INSTALLER_SELF=$(readlink -f "$0") || exit 1
self_exit() {
self_rc=$1
trap - EXIT INT TERM HUP
if rm -f -- "$INSTALLER_SELF"; then echo INSTALLER_REMOVED; else echo INSTALLER_REMOVE_FAILED; [ "$self_rc" -ne 0 ] || self_rc=1; fi
exit "$self_rc"
}
trap 'self_exit "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
umask 022
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[ "$(id -u)" = 0 ] && [ -f /etc/alpine-release ] || { echo ROOT_ALPINE_REQUIRED; exit 1; }
echo '===== 1/9 PACKAGES ====='
apk add --no-cache bash wget curl ca-certificates gcompat libstdc++ libgcc coreutils openrc nftables iproute2 flock jq
update-ca-certificates
mkdir -p /usr/local/lib /usr/local/sbin /etc/earnapp/log /etc/local.d /etc/crontabs /run/earnapp-watchdog /var/log
exec 8>/run/earnapp-setup.lockfile
flock -n 8 || { echo SETUP_BUSY; exit 1; }
D=$(mktemp -d /tmp/earnapp-repair.XXXXXX)
B=/var/backups/earnapp-$(date +%s)-$$
PAUSED=0; HELD=0; STEP=prepare; TX_ACTIVE=0; COMMITTED=0; HELPERS_CHANGED=0; START_ACTION=0; START_CHILD_ACTIVE=0
backup_path() {
f=$1
if grep -Fqx "1 $f" "$B/manifest" || grep -Fqx "0 $f" "$B/manifest"; then return 0; fi
if [ -e "$f" ] || [ -L "$f" ]; then
cp -a --parents "$f" "$B/files/" || return 1
printf '1 %s\n' "$f" >>"$B/manifest"
else printf '0 %s\n' "$f" >>"$B/manifest"; fi
}
ensure_started() {
[ -x /usr/bin/earnapp ] && [ -f /etc/init.d/earnapp ] || return 0
timeout -k 2 10 rc-service earnapp status 8>&- 9>&- >/dev/null 2>&1 && return 0
timeout -k 5 30 rc-service earnapp start 8>&- 9>&- || return 1
timeout -k 2 10 rc-service earnapp status 8>&- 9>&- >/dev/null 2>&1
}
earnapp_process_record() {
ep=$1
ei=$(start "$ep") || return 1
awk '/^Uid:/{ok=(NF==5&&$2==0&&$3==0&&$4==0&&$5==0)}END{exit !ok}' "/proc/$ep/status" || return 1
ec=$(cat "/proc/$ep/comm") || return 1
case "$ec" in supervise-daemo*)
tr '\000' '\n' <"/proc/$ep/cmdline" | awk 'NR==1{if($0!~/(^|\/)supervise-daemon$/)exit 1} NR==2{if($0!="earnapp")exit 1} NR>2{if($0=="/usr/bin/earnapp"){app=1;next}if(app&&$0=="--")next;if(app){ok=($0=="run");app=0}}END{exit !ok}' || return 1
ek=supervisor;;
*) ew=$(worker_pids) || return 1; printf '%s\n' "$ew" | grep -Fxq "$ep" || return 1; ek=worker;;
esac
[ "$(start "$ep")" = "$ei" ] || return 1
printf '%s %s %s\n' "$ep" "$ei" "$ek"
}
earnapp_snapshot() {
es=0; eq=$(pgrep -f '/usr/bin/[e]arnapp.* run|(^|/)[s]upervise-daemon earnapp( |$)') || es=$?
[ "$es" -le 1 ] || return 1
for ep in $eq; do
[ -d "/proc/$ep" ] || continue
er=$(earnapp_process_record "$ep") || { [ ! -d "/proc/$ep" ] || return 1; continue; }
printf '%s\n' "$er"
done
}
record_started_instances() {
earnapp_snapshot >"$D/started-current" || return 1
while read -r cp ci ck; do
if grep -Fxq "$cp $ci $ck" "$B/earnapp-processes"; then continue; fi
[ "$ci" -ge "$TX_START" ] || return 1
grep -Fxq "$cp $ci $ck" "$B/earnapp-started" || printf '%s %s %s\n' "$cp" "$ci" "$ck" >>"$B/earnapp-started" || return 1
done <"$D/started-current"
}
rollback_owned() {
grep -Fxq "$1 $2 $3" "$B/earnapp-started" && return 0
[ "$3" = worker ] || return 1
op=$(awk '/^PPid:/{print $2}' "/proc/$1/status") || return 1
or=$(earnapp_process_record "$op") || return 1
case "$or" in *" supervisor") grep -Fxq "$or" "$B/earnapp-started";; *) return 1;; esac
}
rollback_signal() {
rs_pid=$1; rs_birth=$2; rs_kind=$3; rs_signal=$4
[ -d "/proc/$rs_pid" ] || return 0
rs_record=$(earnapp_process_record "$rs_pid") || return 1
[ "$rs_record" = "$rs_pid $rs_birth $rs_kind" ] || return 1
kill -"$rs_signal" "$rs_pid" 2>/dev/null || { [ ! -d "/proc/$rs_pid" ] || return 1; }
}
rollback_stop_new() {
[ "$START_CHILD_ACTIVE" = 0 ] || return 1
[ -f "$B/earnapp-processes" ] || return 1
earnapp_snapshot >"$D/rollback-current" || return 1
: >"$D/rollback-new"
while read -r rp ri rk; do
if grep -Fxq "$rp $ri $rk" "$B/earnapp-processes"; then continue; fi
[ "$START_ACTION" = 1 ] && [ "$ri" -ge "$TX_START" ] && rollback_owned "$rp" "$ri" "$rk" || return 1
printf '%s %s %s\n' "$rp" "$ri" "$rk" >>"$D/rollback-new"
done <"$D/rollback-current"
for signal in TERM KILL; do
for kind in supervisor worker; do
while read -r rp ri rk; do
[ "$rk" != "$kind" ] || rollback_signal "$rp" "$ri" "$rk" "$signal" || return 1
done <"$D/rollback-new"
done
[ "$signal" != TERM ] || [ ! -s "$D/rollback-new" ] || sleep 2
done
earnapp_snapshot >"$D/rollback-final" || return 1
while read -r rp ri rk; do
grep -Fxq "$rp $ri $rk" "$B/earnapp-processes" || return 1
done <"$D/rollback-final"
if [ "$START_ACTION" = 1 ] && [ ! -s "$D/rollback-final" ] && [ -f /etc/init.d/earnapp ]; then
timeout -k 2 10 rc-service earnapp zap 8>&- 9>&- >/dev/null 2>&1 || return 1
fi
}
rollback() {
rollback_rc=0
printf 'ROLLBACK\nSTARTED\n'
rollback_stop_new || { printf 'ROLLBACK_BLOCKED\nPROCESS_OWNERSHIP_OR_STOP_UNCONFIRMED\nBACKUP\n%s\n' "$B"; return 1; }
for service in earnapp earnapp_upgrader earnapp-upgrader crond local; do
for f in /etc/runlevels/*/$service; do
if [ -e "$f" ] || [ -L "$f" ]; then rm -f -- "$f" || rollback_rc=1; fi
done
done
while read -r present f; do
case "$f" in /etc/machine-id|/var/lib/dbus/machine-id) [ ! -s /etc/earnapp/uuid ] || continue;; esac
if [ "$present" = 1 ]; then
mkdir -p "${f%/*}" && rm -f -- "$f" && cp -a "$B/files$f" "$f" || rollback_rc=1
else rm -f -- "$f" || rollback_rc=1; fi
done <"$B/manifest"
if [ "$(cat "$B/earnapp-state")" = running ]; then
ensure_started || { printf 'ROLLBACK_START\nFAILED\n'; rollback_rc=1; }
fi
if [ "$HELPERS_CHANGED" = 1 ]; then
: >"$D/rollback.nft"
if nft list table inet earnapp_limit >/dev/null 2>&1; then printf 'delete table inet earnapp_limit\n' >>"$D/rollback.nft"; fi
if [ -f "$B/earnapp_limit.nft" ]; then cat "$B/earnapp_limit.nft" >>"$D/rollback.nft"; fi
if [ -s "$D/rollback.nft" ]; then
nft -c -f "$D/rollback.nft" && nft -f "$D/rollback.nft" || { printf 'ROLLBACK_FIREWALL\nFAILED\n'; rollback_rc=1; }
fi
if [ "$(cat "$B/earnapp-state")" = running ] && [ -f "$B/earnapp_limit.nft" ] && [ -x /usr/local/sbin/earnapp-limit ]; then
exec 9>&-
timeout -k 2 40 /usr/local/sbin/earnapp-limit 20 8>&- || { printf 'ROLLBACK_LIMIT_REFRESH\nFAILED\n'; rollback_rc=1; }
fi
fi
for service in earnapp_upgrader earnapp-upgrader crond; do
if grep -Fxq "$service" "$B/services-running"; then
timeout -k 5 30 rc-service "$service" start 8>&- 9>&- >/dev/null 2>&1 || rollback_rc=1
fi
done
printf 'ROLLBACK_RC\n%s\n' "$rollback_rc"
return "$rollback_rc"
}
finish() {
r=$?
trap - EXIT INT TERM HUP
set +e
if [ "$COMMITTED" != 1 ] && [ "$TX_ACTIVE" = 1 ]; then
rollback || { [ "$r" != 0 ] || r=1; }
elif [ "$PAUSED" != 0 ]; then cp -p "$B/crontab" /etc/crontabs/root || r=1; fi
if [ "$HELD" != 0 ]; then rmdir /run/earnapp-watchdog.lock || r=1; fi
rm -rf "$D" || r=1
[ "$r" = 0 ] || printf 'SETUP_EXIT\n%s\nSTEP\n%s\nBACKUP\n%s\n' "$r" "$STEP" "$B"
self_exit "$r"
}
trap finish EXIT
cat >"$D/common" <<'COMMON'
#!/bin/sh
S=/run/earnapp-watchdog
L=/run/earnapp-watchdog.lockfile
LOG=/var/log/earnapp-watchdog.log
mkdir -p "$S"
UDP_THRESHOLD=250; FD_THRESHOLD=512; RSS_THRESHOLD_KB=184320; ZERO_MAX_BAD=2; RESOURCE_MAX_BAD=3; MIN_UPTIME=120; RESTART_COOLDOWN=300
if [ -r /etc/earnapp/watchdog.conf ]; then
C=$(awk '/^(UDP_THRESHOLD|FD_THRESHOLD|RSS_THRESHOLD_KB|ZERO_MAX_BAD|RESOURCE_MAX_BAD|MIN_UPTIME|RESTART_COOLDOWN)=[1-9][0-9]*$/ {split($0,a,"="); if(a[2]<=2147483647)print}' /etc/earnapp/watchdog.conf)
eval "$C"
fi
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&2; }
lock() { if [ "${1:-}" = --locked ]; then [ "$(readlink /proc/self/fd/9)" = "$L" ] || return 1; else exec 9>"$L"; fi; flock -n 9; }
worker_pids() {
v=${1:-run}; e=0; q=$(pgrep -f '/usr/bin/[e]arnapp.* (run|autoupgrade)') || e=$?; [ "$e" -le 1 ] || return 1
for p in $q; do
[ -d "/proc/$p" ] || continue
c=$(cat "/proc/$p/comm") || return 1
case "$c" in supervise-daemo*)
if [ "$v" = autoupgrade ] && tr '\000' '\n' <"/proc/$p/cmdline" | awk 'NR==1{if($0!~/(^|\/)supervise-daemon$/)exit 1} NR==2{if($0!="earnapp_upgrader"&&$0!="earnapp-upgrader")exit 1} NR>2{if($0=="/usr/bin/earnapp"){app=1;next}if(app&&$0=="--")next;if(app){ok=($0=="autoupgrade");app=0}}END{exit !ok}'; then echo "$p"; fi
continue;; esac
a=$(tr '\000' '\n' <"/proc/$p/cmdline") || return 1
if printf '%s\n' "$a" | awk -v verb="$v" 'NR==1{if($0=="/usr/bin/earnapp"){d=1;next} if($0~/^(\/(lib|lib64|usr\/lib|usr\/lib64)\/)?ld-(musl-[A-Za-z0-9_.-]+\.so\.1|linux(-[A-Za-z0-9_.-]+)?\.so\.[12])$/){l=1;next}bad=1} bad{next} d&&NR==2{ok=($0==verb);next} l&&!ok{if(run){ok=($0==verb);if(!ok)bad=1;next}if(skip){skip=0;next}if(end){if($0=="/usr/bin/earnapp"){run=1;next}bad=1;next}if($0=="--"){end=1;next}if($0=="--argv0"||$0=="--preload"||$0=="--library-path"){skip=1;next}if($0=="/usr/bin/earnapp"){run=1;next}bad=1} END{exit !(ok&&!bad)}'; then echo "$p"; fi
done
}
disable_upgrader() {
for s in earnapp_upgrader earnapp-upgrader; do
for f in /etc/init.d/$s /etc/conf.d/$s /etc/runlevels/*/$s; do
if [ -e "$f" ] || [ -L "$f" ]; then mkdir -p "$B/upgrader"; chmod 700 "$B" "$B/upgrader"; cp -a --parents "$f" "$B/upgrader/" || return 1; fi
done
for f in /etc/runlevels/*/$s; do if [ -e "$f" ] || [ -L "$f" ]; then l=${f%/*}; rc-update del "$s" "${l##*/}" 8>&- 9>&- || return 1; fi; done
if [ -f /etc/init.d/$s ]; then rc-service "$s" stop 8>&- 9>&- >/dev/null 2>&1 || true; supervise-daemon "$s" --stop 8>&- 9>&- >/dev/null 2>&1 || true; fi
done
q=$(worker_pids autoupgrade) || return 1
: >"$S/upids"
for p in $q; do i=$(start "$p") || continue; echo "$p $i" >>"$S/upids"; [ "$(start "$p")" != "$i" ] || kill -TERM "$p" 2>/dev/null || true; done
[ -z "$q" ] || sleep 2
while read -r p i; do [ "$(start "$p" 2>/dev/null)" != "$i" ] || kill -KILL "$p" 2>/dev/null || true; done <"$S/upids"
q=$(worker_pids autoupgrade) || return 1
[ -z "$q" ] || { log UPGRADER_STOP_FAILED; return 1; }
for s in earnapp_upgrader earnapp-upgrader; do for f in /etc/runlevels/*/$s; do [ ! -e "$f" ] && [ ! -L "$f" ] || return 1; done; done
}
worker_pid() { ids=$(worker_pids) || return 1; set -- $ids; [ "$#" = 1 ] || return 1; echo "$1"; }
start() { awk '{sub(/^.*\) /,""); if($20!~/^[0-9]+$/)exit 1; print $20}' "/proc/$1/stat"; }
proc_age() { h=$(getconf CLK_TCK) || return 1; case "$h" in ''|*[!0-9]*|0) return 1;; esac; awk -v h="$h" '{sub(/^.*\) /,""); if($20!~/^[0-9]+$/)exit 1} NR==FNR{s=$20;next} {if($20<s)exit 1;printf "%.0f\n",int(($20-s)/h)}' "/proc/$1/stat" /proc/self/stat; }
stats() {
FD=$(ls "/proc/$1/fd") || return 1; FD=$(printf '%s\n' "$FD" | awk 'NF{n++}END{print n+0}')
RSS=$(awk '/^VmRSS:/{print $2;ok=1}END{if(!ok)exit 1}' "/proc/$1/status") || return 1
t=$(ss -tanp) || return 1; u=$(ss -uanp) || return 1
TCP=$(printf '%s\n' "$t" | awk -v p="$1" 'index($0,"pid="p","){n++}END{print n+0}')
ESTAB=$(printf '%s\n' "$t" | awk -v p="$1" 'index($0,"pid="p",")&&($1=="ESTAB"||$2=="ESTAB"){n++}END{print n+0}')
UDP=$(printf '%s\n' "$u" | awk -v p="$1" 'index($0,"pid="p","){n++}END{print n+0}')
}
now() { awk '{print int($1)}' /proc/uptime; }
cool() { n=$(now) || return 1; [ -s "$S/attempt" ] || return 0; x=$(cat "$S/attempt"); case "$x" in ''|*[!0-9]*) return 0;; esac; [ "$n" -lt "$x" ] || [ $((n-x)) -ge "$RESTART_COOLDOWN" ]; }
network_ok() { for family in -4 -6; do for host in https://example.com https://www.google.com; do curl "$family" -fsSI --connect-timeout 5 --max-time 8 "$host" >/dev/null 2>&1 && return 0; done; done; return 1; }
COMMON
. "$D/common"
STEP=transaction_backup
mkdir -p "$B/files"; chmod 700 "$B" "$B/files"
: >"$B/manifest"; : >"$B/services-running"
for f in /etc/init.d/earnapp /usr/local/sbin/earnapp-watchdog /usr/local/sbin/earnapp-recover /usr/local/sbin/earnapp-limit /usr/local/lib/earnapp-original.sh /etc/local.d/earnapp-limit.start /etc/earnapp/watchdog.conf /etc/crontabs/root; do backup_path "$f"; done
for f in /etc/machine-id /var/lib/dbus/machine-id; do
if [ -e "$f" ] || [ -L "$f" ]; then backup_path "$f"; fi
done
for service in earnapp earnapp_upgrader earnapp-upgrader crond local; do
for f in /etc/init.d/$service /etc/conf.d/$service; do backup_path "$f"; done
for f in /etc/runlevels/*/$service; do
if [ -e "$f" ] || [ -L "$f" ]; then backup_path "$f"; fi
done
if [ -f /etc/init.d/$service ] && timeout -k 2 10 rc-service "$service" status 8>&- 9>&- >/dev/null 2>&1; then printf '%s\n' "$service" >>"$B/services-running"; fi
done
nft list tables >"$D/initial-tables"
if grep -Fxq 'table inet earnapp_limit' "$D/initial-tables"; then nft list table inet earnapp_limit >"$B/earnapp_limit.nft"; fi
EARNAPP_PRIOR=absent
if [ -f /etc/init.d/earnapp ]; then
state_rc=0
timeout -k 2 10 rc-service earnapp status 8>&- 9>&- >/dev/null 2>&1 || state_rc=$?
case "$state_rc" in 0) EARNAPP_PRIOR=running;; 3) EARNAPP_PRIOR=stopped;; *) echo ORIGINAL_SERVICE_STATE_UNKNOWN; exit 1;; esac
fi
printf '%s\n' "$EARNAPP_PRIOR" >"$B/earnapp-state"
TX_START=$(start self) || { echo PROCESS_BASELINE_FAILED; exit 1; }
earnapp_snapshot >"$B/earnapp-processes" || { echo PROCESS_BASELINE_FAILED; exit 1; }
: >"$B/earnapp-started"
TX_ACTIVE=1
STEP=upgrader
disable_upgrader || { echo UPGRADER_STOP_FAILED; exit 1; }
trap 'exit 130' INT
trap 'exit 143' TERM HUP
STEP=identity_backup
mkdir -p "$B/identity"; chmod 700 "$B" "$B/identity"
for f in /etc/machine-id /var/lib/dbus/machine-id /etc/earnapp/uuid /etc/earnapp/registered /etc/earnapp/tracking_id /etc/earnapp/consent /etc/earnapp/oldcid /etc/earnapp/status; do if [ -e "$f" ] || [ -L "$f" ]; then cp -a --parents "$f" "$B/identity/"; fi; done
[ ! -s /etc/machine-id ] || cp -pL /etc/machine-id "$B/identity/linux-machine-id"
[ ! -s /var/lib/dbus/machine-id ] || cp -pL /var/lib/dbus/machine-id "$B/identity/dbus-machine-id"
device_id() { z=$(timeout -k 2 10 /usr/bin/earnapp showid 8>&- 9>&-) || return 1; printf '%s\n' "$z" | grep -Eq '^sdk-node-[0-9a-f]{32}$' || return 1; [ "$(printf '%s\n' "$z" | wc -l)" = 1 ] || return 1; printf '%s\n' "$z"; }
ID_BEFORE=; UUID_SAVED=0
if [ -s /etc/earnapp/uuid ]; then UUID_SAVED=1; cp -pL /etc/earnapp/uuid "$B/identity/earnapp-uuid"; fi
if [ -x /usr/bin/earnapp ]; then ID_BEFORE=$(device_id) || { echo DEVICE_ID_QUERY_FAILED; exit 1; }; fi
STEP=machine_identity
if [ ! -s /etc/machine-id ]; then
if [ -s /var/lib/dbus/machine-id ]; then cat /var/lib/dbus/machine-id >"$D/id"; else tr -d '-' </proc/sys/kernel/random/uuid >"$D/id"; fi
i=$(cat "$D/id"); printf '%s\n' "$i" | grep -Eq '^[0-9a-f]{32}$'; [ "$(printf '%s\n' "$i" | wc -l)" = 1 ] || exit 1
install -m 444 "$D/id" /etc/machine-id
fi
MACHINE_EXPECTED=$(cat /etc/machine-id)
printf '%s\n' "$MACHINE_EXPECTED" | grep -Eq '^[0-9a-f]{32}$' || { echo MACHINE_ID_INVALID; exit 1; }
[ "$(printf '%s\n' "$MACHINE_EXPECTED" | wc -l)" = 1 ] || exit 1
mkdir -p /var/lib/dbus
[ ! -d /var/lib/dbus/machine-id ] || { echo DBUS_ID_IS_DIRECTORY; exit 1; }
if [ -s /var/lib/dbus/machine-id ]; then [ "$(cat /var/lib/dbus/machine-id)" = "$MACHINE_EXPECTED" ] || { echo DBUS_MACHINE_ID_CONFLICT; exit 1; }; fi
if [ "$(readlink -f /var/lib/dbus/machine-id 2>/dev/null || true)" != "$(readlink -f /etc/machine-id)" ]; then ln -sfn /etc/machine-id /var/lib/dbus/machine-id; fi
chmod 444 /etc/machine-id
verify_identity() {
[ -s /etc/earnapp/uuid ] || { echo EARNAPP_UUID_MISSING; return 1; }
ID_AFTER=$(device_id) || { echo DEVICE_ID_QUERY_FAILED; return 1; }
[ -z "$ID_BEFORE" ] || [ "$ID_AFTER" = "$ID_BEFORE" ] || { echo DEVICE_ID_CHANGED; return 1; }
[ "$(cat /etc/machine-id)" = "$MACHINE_EXPECTED" ] || { echo MACHINE_ID_CHANGED; return 1; }
if [ "$UUID_SAVED" = 1 ]; then cmp -s "$B/identity/earnapp-uuid" /etc/earnapp/uuid || { echo EARNAPP_UUID_CHANGED; return 1; }; fi
}
echo '===== 2/9 EARNAPP ====='
STEP=download
if [ ! -x /usr/bin/earnapp ]; then
cat >"$D/fetch" <<'FETCH'
#!/bin/sh
U=$1; F=$2
for M in auto ipv6 tls12; do
case "$M" in auto) set --;; ipv6) set -- -6;; tls12) set -- -4 --http1.1 --tlsv1.2 --tls-max 1.2;; esac
echo "DOWNLOAD mode=$M $U" >&2
R=0
if curl -q "$@" -fL --proto '=https' --proto-redir '=https' --connect-timeout 8 --max-time 30 "$U" -o "$F"; then [ ! -s "$F" ] || exit 0; else R=$?; fi
rm -f "$F"
case "$R" in 60|77) break;; esac
done
exit 1
FETCH
chmod 755 "$D/fetch"
OK=0
for U in https://cdn.earnapp.com/static/earnapp-install-1.665.73.sh https://brightdata.com/static/earnapp/install.sh; do
if "$D/fetch" "$U" "$D/vendor" && bash -n "$D/vendor"; then OK=1; break; fi
rm -f "$D/vendor"
done
[ "$OK" = 1 ] || { echo DOWNLOAD_FAILED; exit 1; }
mkdir "$D/bin"
printf '%s\n' '#!/bin/sh' 'case "$1" in -rs) cat /etc/alpine-release;; -ds) echo "Alpine Linux $(cat /etc/alpine-release)";; *) echo Alpine;; esac' >"$D/bin/lsb_release"
printf '%s\n' '#!/bin/sh' 'echo "Alpine Linux"' >"$D/bin/hostnamectl"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$D/bin/systemctl"
printf '%s\n' '#!/bin/sh' 'if [ "$#" = 3 ] && [ "$2" = -O ]; then exec "$EARNAPP_FETCH" "$1" "$3"; fi' 'exec /usr/bin/wget -T 30 "$@"' >"$D/bin/wget"
chmod 755 "$D/bin/"*
STEP=vendor_install
START_ACTION=1
START_CHILD_ACTIVE=1
VENDOR_RC=0
printf 'yes\n' | EARNAPP_FETCH="$D/fetch" PATH="$D/bin:$PATH" timeout 300 bash "$D/vendor" 8>&- || VENDOR_RC=$?
START_CHILD_ACTIVE=0
record_started_instances || { echo PROCESS_CAPTURE_FAILED; exit 1; }
[ "$VENDOR_RC" = 0 ] || exit "$VENDOR_RC"
[ -x /usr/bin/earnapp ] || { echo EARNAPP_MISSING; exit 1; }
fi
STEP=installed_identity
disable_upgrader || { echo UPGRADER_STOP_FAILED; exit 1; }
verify_identity
STEP=registration_check
if [ ! -s /etc/earnapp/registered ]; then
printf 'REGISTRATION_INCOMPLETE\nLINK_URL\nhttps://earnapp.com/r/%s\n' "$ID_AFTER"
exit 1
fi
STEP=enable_check
EA_STATUS=$(timeout -k 2 15 /usr/bin/earnapp status 8>&- 9>&- 2>&1) || { echo APP_STATUS_FAILED; exit 1; }
EA_STATUS=$(printf '%s\n' "$EA_STATUS" | sed "s/$(printf '\033')\[[0-9;]*m//g")
if printf '%s\n' "$EA_STATUS" | grep -qw disabled; then
START_ACTION=1
START_CHILD_ACTIVE=1
ENABLE_RC=0
timeout -k 5 30 /usr/bin/earnapp start 8>&- 9>&- || ENABLE_RC=$?
START_CHILD_ACTIVE=0
record_started_instances || { echo PROCESS_CAPTURE_FAILED; exit 1; }
[ "$ENABLE_RC" = 0 ] || { echo APP_ENABLE_FAILED; exit 1; }
EA_STATUS=$(timeout -k 2 15 /usr/bin/earnapp status 8>&- 9>&- 2>&1) || { echo APP_STATUS_FAILED; exit 1; }
fi
printf '%s\n' "$EA_STATUS" | sed "s/$(printf '\033')\[[0-9;]*m//g" | grep -qw enabled || { echo APP_NOT_ENABLED; exit 1; }
echo '===== 3/9 OPENRC ====='
cat >"$D/service" <<'SERVICE'
#!/sbin/openrc-run
name=earnapp
command=/usr/bin/earnapp
command_args=run
command_user=root
supervisor=supervise-daemon
respawn_delay=5
respawn_max=0
respawn_period=1800
depend() { after networking; }
SERVICE
echo '===== 4/9 HELPERS ====='
cat >"$D/watchdog" <<'WATCHDOG'
#!/bin/sh
set -u
. /usr/local/lib/earnapp-original.sh
lock || exit 0
trap 'exit 130' INT
trap 'exit 143' TERM
ids=$(worker_pids) || exit 1
set -- $ids
if [ "$#" -ne 1 ]; then cool && /usr/local/sbin/earnapp-recover --locked worker_count; exit $?; fi
P=$1
A=$(proc_age "$P") || { log AGE_PROBE_FAILED; exit 1; }
[ "$A" -ge "$MIN_UPTIME" ] || exit 0
I=$(start "$P") || exit 1
stats "$P" || { log STATS_FAILED; exit 1; }
R=; M=$RESOURCE_MAX_BAD
if [ "$UDP" -ge "$UDP_THRESHOLD" ] || [ "$FD" -ge "$FD_THRESHOLD" ] || [ "$RSS" -ge "$RSS_THRESHOLD_KB" ]; then R=resource_high
elif [ "$TCP" = 0 ]; then if network_ok; then R=no_tcp; M=$ZERO_MAX_BAD; else log NETWORK_BAD; fi; fi
if [ -z "$R" ]; then
rm -f "$S/count"
/usr/local/sbin/earnapp-limit --locked 20 || { log LIMIT_MAINTENANCE_FAILED; exit 2; }
exit 0
fi
K="$P:$I:$R"; old=; count=0
if [ -s "$S/count" ]; then read -r old count <"$S/count" || count=0; fi
case "$count" in ''|*[!0-9]*) count=0;; esac
[ "$old" = "$K" ] || count=0
[ "$count" -ge "$M" ] || count=$((count+1))
echo "$K $count" >"$S/count"
log "BAD pid=$P reason=$R count=$count/$M udp=$UDP fd=$FD"
if [ "$count" -ge "$M" ] && cool; then /usr/local/sbin/earnapp-recover --locked "$R"; fi
WATCHDOG
cat >"$D/recover" <<'RECOVER'
#!/bin/sh
set -u
. /usr/local/lib/earnapp-original.sh
lock "${1:-}" || { log LOCK_BUSY; exit 1; }
[ "${1:-}" != --locked ] || shift
NEED_START=0
recover_exit() {
recover_rc=$?
trap - EXIT INT TERM HUP
if [ "$NEED_START" = 1 ]; then
if ! timeout -k 2 10 rc-service earnapp status 8>&- 9>&- >/dev/null 2>&1; then
timeout -k 5 30 rc-service earnapp start 8>&- 9>&- || log FALLBACK_START_FAILED
fi
if ! timeout -k 2 10 rc-service earnapp status 8>&- 9>&- >/dev/null 2>&1; then
log FALLBACK_SERVICE_NOT_RUNNING
[ "$recover_rc" != 0 ] || recover_rc=1
fi
fi
exit "$recover_rc"
}
trap recover_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
log "RECOVER reason=${1:-manual}"
now >"$S/attempt" || exit 1
NEED_START=1
if ! timeout -k 5 30 rc-service earnapp stop 8>&- 9>&-; then timeout -k 2 10 rc-service earnapp status 8>&- 9>&- >/dev/null 2>&1 && { log STOP_FAILED; exit 1; }; fi
ids=$(worker_pids) || exit 1
: >"$S/pids"
for p in $ids; do i=$(start "$p") || continue; echo "$p $i" >>"$S/pids"; kill -TERM "$p" 2>/dev/null || true; done
[ -z "$ids" ] || sleep 2
while read -r p i; do [ "$(start "$p" 2>/dev/null)" != "$i" ] || kill -KILL "$p" 2>/dev/null || true; done <"$S/pids"
timeout -k 5 30 rc-service earnapp start 8>&- 9>&- || { log START_FAILED; exit 1; }
recovery_sample() {
timeout -k 2 10 rc-service earnapp status 8>&- 9>&- >/dev/null 2>&1 || { failure_reason=SERVICE_NOT_RUNNING; return 1; }
P=$(worker_pid) || { failure_reason=WORKER_IDENTIFICATION_FAILED; return 1; }
I=$(start "$P") || { failure_reason=BIRTH_PROBE_FAILED; return 1; }
stats "$P" || { failure_reason=STATS_FAILED; return 1; }
current_birth=$(start "$P") || { failure_reason=BIRTH_PROBE_FAILED; return 1; }
[ "$current_birth" = "$I" ] || { failure_reason=WORKER_CHANGED; return 1; }
}
n=0; stable=0; last_key=; health_key=; pending_ok=1; failure_reason=NO_SUSTAINED_TCP
while [ "$n" -lt 24 ]; do
if recovery_sample; then
key="$P:$I"
if [ -n "$health_key" ] && [ "$key" != "$health_key" ]; then pending_ok=0; failure_reason=WORKER_CHANGED; fi
health_key=$key
if [ "$ESTAB" -gt 0 ]; then
if [ "$key" = "$last_key" ]; then stable=$((stable+1)); else stable=1; last_key=$key; fi
if [ "$stable" -ge 7 ]; then
rm -f "$S/count"
log "CONNECTION_CHECK_OK pid=$P samples=$stable span=30s udp=$UDP tcp=$TCP estab=$ESTAB fd=$FD rss=$RSS"
/usr/local/sbin/earnapp-limit --locked 20 || { log LIMIT_UNAVAILABLE; exit 2; }
printf '%s\n' "$key" >"$S/connection-key" || exit 1
exit 0
fi
else stable=0; last_key=; fi
else pending_ok=0; stable=0; last_key=; fi
sleep 5; n=$((n+1))
done
if [ "$pending_ok" = 1 ] && [ -n "$health_key" ] && recovery_sample; then
if [ "$P:$I" != "$health_key" ]; then log "RECOVERY_FAILED reason=WORKER_CHANGED"; exit 1; fi
/usr/local/sbin/earnapp-limit --locked 20 || { log LIMIT_UNAVAILABLE; exit 2; }
printf '%s\n' "$health_key" >"$S/connection-key" || exit 1
log "CONNECTION_PENDING pid=$P samples=$n service=running stats=readable limit=20"
exit 10
fi
log "RECOVERY_FAILED reason=$failure_reason"
exit 1
RECOVER
cat >"$D/limit" <<'LIMITER'
#!/bin/sh
set -eu
. /usr/local/lib/earnapp-original.sh
lock "${1:-}" || exit 1
[ "${1:-}" != --locked ] || shift
N=${1:-20}
case "$N" in ''|*[!0-9]*|0*) exit 1;; esac
[ "$N" -le 100000 ]
fail() { log "LIMIT_UNAVAILABLE $*"; exit 1; }
P=$(worker_pid) || fail worker_count
I=$(start "$P")
[ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ] || fail cgroup_v2
G=$(awk -F: '$1==0{print $3}' "/proc/$P/cgroup")
case "$G" in ''|/|*[!A-Za-z0-9_./-]*|*..*) fail cgroup_path;; esac
[ "${G##*/}" = openrc.earnapp ] || fail dedicated_cgroup
[ "$G" != "$(awk -F: '$1==0{print $3}' /proc/1/cgroup)" ] || fail shared_pid1
[ "$(awk '$0~/ - cgroup2 /&&$5=="/sys/fs/cgroup"{print $4}' /proc/self/mountinfo)" = / ] || fail cgroup_mount
C=/sys/fs/cgroup$G
members() {
for f in "$C"/*; do [ ! -d "$f" ] || return 1; done
v=$(cat "$C/cgroup.procs") || return 1
printf '%s\n' "$v" | grep -Fx "$P" >/dev/null || return 1
for m in $v; do [ "$m" != "$P" ] || continue; [ "$(awk '/^PPid:/{print $2}' "/proc/$P/status")" = "$m" ] || return 1; case "$(cat "/proc/$m/comm")" in supervise-daemo*) ;; *) return 1;; esac; done
[ "$(start "$P")" = "$I" ] && [ "$(awk -F: '$1==0{print $3}' "/proc/$P/cgroup")" = "$G" ]
}
members || fail unrelated_members
J=$(stat -Lc %i "$C")
d=$(mktemp -d); PROBE=0; T=earnapp_probe_$$
trap '[ "$PROBE" = 0 ] || nft delete table inet "$T" >/dev/null 2>&1; rm -rf "$d"' EXIT
trap 'exit 1' INT TERM HUP
nft list tables >"$d/tables" || fail nft_permission
rule_digest() { sed -E 's/counter packets [0-9]+ bytes [0-9]+/counter/g' "$1" | sha256sum | awk '{print $1}'; }
CACHE_KEY="$(uname -r):$J:$N:$G"
if grep -Fxq 'table inet earnapp_limit' "$d/tables"; then
nft list table inet earnapp_limit >"$d/old" || fail nft_read
if [ "$(cat "$S/limit-key" 2>/dev/null || true)" = "$CACHE_KEY" ] && [ "$(cat "$S/limit-digest" 2>/dev/null || true)" = "$(rule_digest "$d/old")" ]; then
members && [ "$(stat -Lc %i "$C")" = "$J" ] || fail cgroup_changed
exit 0
fi
fi
room() {
for z in "$C" /sys/fs/cgroup; do
for x in memory pids; do
[ -f "$z/$x.max" ] || continue
m=$(cat "$z/$x.max") || return 1
[ "$m" = max ] && continue
v=$(cat "$z/$x.current") || return 1
r=33554432; [ "$x" != pids ] || r=8
[ "$((m-v))" -ge "$r" ] || return 1
done
done
}
[ "$(awk -F: '$1==0{print $3}' /proc/self/cgroup)" != "$G" ] || fail probe_must_run_outside
room || fail probe_low_headroom
{
printf 'create table inet %s\nadd chain inet %s out { type filter hook output priority -20; policy accept; }\n' "$T" "$T"
for level in $(seq 1 32); do
printf 'add rule inet %s out ip daddr 127.0.0.1 udp dport 9 socket cgroupv2 level %s "%s" counter comment "level-%s"\n' "$T" "$level" "${G#/}" "$level"
done
} >"$d/probe"
nft -c -f "$d/probe" && nft -f "$d/probe" || fail kernel_probe
PROBE=1
timeout -k 2 5 bash -c 'echo "$BASHPID" >"$1/cgroup.procs" || exit 1; echo x >/dev/udp/127.0.0.1/9' _ "$C" 8>&- 9>&- || fail probe_send
nft list chain inet "$T" out >"$d/result" || fail probe_read
V=$(awk '/socket cgroupv2/{l=0;p=0;for(i=1;i<NF;i++){if($i=="level")l=$(i+1);if($i=="packets")p=$(i+1)}if(p>0)print l}' "$d/result")
case "$V" in ''|*[!0-9]*) fail cgroup_match_ambiguous;; esac
bash -c 'echo x >/dev/udp/127.0.0.1/9' 8>&- 9>&- || fail outside_probe_send
nft list chain inet "$T" out >"$d/outside" || fail probe_read
cmp -s "$d/result" "$d/outside" || fail cgroup_match_not_exclusive
nft delete table inet "$T" || fail probe_cleanup
PROBE=0
members && [ "$(stat -Lc %i "$C")" = "$J" ] || fail cgroup_changed
H="earnapp-v4:$J:$V:$N"
log "CGROUP_MATCH_VERIFIED level=$V"

: >"$d/rules"
if grep -Fx 'table inet earnapp_limit' "$d/tables" >/dev/null; then echo 'delete table inet earnapp_limit' >"$d/rules"; fi
printf 'table inet earnapp_limit { chain output { type filter hook output priority -10; policy accept; socket cgroupv2 level %s "%s" meta l4proto { tcp, udp } ct state new ct count over %s counter reject comment "%s"; }; }\n' "$V" "${G#/}" "$N" "$H" >>"$d/rules"
nft -c -f "$d/rules" || fail nft_check
members && [ "$(stat -Lc %i "$C")" = "$J" ] || fail cgroup_changed
nft -f "$d/rules" || fail nft_apply
nft list table inet earnapp_limit >"$d/live" || fail nft_read
rule_digest "$d/live" >"$S/limit-digest" || fail cache_write
printf '%s\n' "$CACHE_KEY" >"$S/limit-key" || fail cache_write
log "LIMIT_OK flows=$N group=$G"
LIMITER
printf '%s\n' '#!/bin/sh' 'n=0; while [ "$n" -lt 15 ]; do /usr/local/sbin/earnapp-limit 20 && exit 0; n=$((n+1)); sleep 2; done; exit 1' >"$D/boot"
for f in service common watchdog recover limit boot; do sh -n "$D/$f"; done
echo '===== 5/9 BACKUP ====='
STEP=backup
mkdir -p "$B"; chmod 700 "$B"
touch /etc/crontabs/root; cp -p /etc/crontabs/root "$B/crontab"
if [ ! -e /etc/earnapp/watchdog.conf ]; then awk '/^(UDP_THRESHOLD|FD_THRESHOLD|RSS_THRESHOLD_KB|ZERO_MAX_BAD|RESOURCE_MAX_BAD|MIN_UPTIME|RESTART_COOLDOWN)=[1-9][0-9]*$/{print}' /usr/local/sbin/earnapp-watchdog 2>/dev/null >"$D/conf" || true; install -m 600 "$D/conf" /etc/earnapp/watchdog.conf; fi
STEP=quiesce
PAUSED=1
sed '/# EARNAPP-WATCHDOG/d;/# EARNAPP-12H-STOPSTART/d' "$B/crontab" >/etc/crontabs/root
n=0
while pgrep -f '/usr/local/sbin/[e]arnapp-(watchdog|recover|limit)( |$)' >/dev/null; do [ "$n" -lt 75 ] || { echo HELPERS_BUSY; exit 1; }; sleep 2; n=$((n+1)); done
if [ -d /run/earnapp-watchdog.lock ]; then rmdir /run/earnapp-watchdog.lock; fi
mkdir /run/earnapp-watchdog.lock; HELD=1
. "$D/common"
lock || { echo LOCK_BUSY; exit 1; }
STEP=install_helpers
HELPERS_CHANGED=1
install -m 644 "$D/common" /usr/local/lib/earnapp-original.sh
for f in watchdog recover limit; do install -m 755 "$D/$f" "/usr/local/sbin/earnapp-$f"; done
install -m 755 "$D/service" /etc/init.d/earnapp
install -m 755 "$D/boot" /etc/local.d/earnapp-limit.start
echo '===== 6/9 START/MIGRATE ====='
STEP=service
disable_upgrader || { echo UPGRADER_STOP_FAILED; exit 1; }
printf 'UPGRADER_DISABLED\n1\n'
rc-update add earnapp default 8>&- 9>&-
SETUP_RECOVERY_RC=0
START_ACTION=1
START_CHILD_ACTIVE=1
/usr/local/sbin/earnapp-recover --locked setup 8>&- || SETUP_RECOVERY_RC=$?
START_CHILD_ACTIVE=0
record_started_instances || { echo PROCESS_CAPTURE_FAILED; exit 1; }
echo '===== 7/9 WATCHDOG ====='
STEP=cron
if grep -q '# EARNAPP-12H-STOPSTART' "$B/crontab"; then echo '0 */12 * * * /usr/local/sbin/earnapp-recover scheduled >/dev/null 2>&1 # EARNAPP-12H-STOPSTART' >>/etc/crontabs/root; fi
echo '*/2 * * * * /usr/local/sbin/earnapp-watchdog >/dev/null 2>&1 # EARNAPP-WATCHDOG' >>/etc/crontabs/root
rc-update add crond default 8>&- 9>&-
rc-update add local default 8>&- 9>&-
rc-service crond status 8>&- 9>&- >/dev/null 2>&1 || rc-service crond start 8>&- 9>&-
rc-service crond status 8>&- 9>&-
PAUSED=0
echo '===== 8/9 STATUS ====='
STEP=verify
case "$SETUP_RECOVERY_RC" in
0) CONNECTION_STATE=VERIFIED;;
10) CONNECTION_STATE=PENDING;;
*) printf 'RECOVERY_CHECK_FAILED\nRC\n%s\n' "$SETUP_RECOVERY_RC"; exit "$SETUP_RECOVERY_RC";;
esac
verify_setup_worker() {
timeout -k 2 10 rc-service earnapp status 8>&- 9>&- >/dev/null 2>&1 || { echo SERVICE_NOT_RUNNING; return 1; }
P=$(worker_pid) && I=$(start "$P") && stats "$P" || { echo WORKER_OR_STATS_FAILED; return 1; }
[ "$(start "$P")" = "$I" ] && [ "$(cat "$S/connection-key")" = "$P:$I" ] || { echo WORKER_CHANGED_AFTER_RECOVERY; return 1; }
[ "$CONNECTION_STATE" != VERIFIED ] || [ "$ESTAB" -gt 0 ] || { echo CONNECTION_CHECK_EXPIRED; return 1; }
}
verify_setup_worker || exit 1
verify_identity
printf 'MACHINE_ID\n%s\nDEVICE_ID\n%s\nLINK_URL\nhttps://earnapp.com/r/%s\n' "$MACHINE_EXPECTED" "$ID_AFTER" "$ID_AFTER"
if [ -n "$ID_BEFORE" ]; then echo ID_UNCHANGED; fi
for f in uuid registered tracking_id consent oldcid status; do if [ -s "/etc/earnapp/$f" ]; then printf 'IDENTITY_FILE\n%s\nSTATE\nPRESENT\n' "$f"; else printf 'IDENTITY_FILE\n%s\nSTATE\nMISSING\n' "$f"; fi; done
printf 'DASHBOARD_STATUS\nUNKNOWN\n'
printf 'PID\n%s\nFD\n%s\nUDP\n%s\nTCP\n%s\nESTAB\n%s\nRSS_KB\n%s\nBACKUP\n%s\n' "$P" "$FD" "$UDP" "$TCP" "$ESTAB" "$RSS" "$B"
PUBLIC_IPV4=UNKNOWN; COUNTRY_CODE=UNKNOWN
if candidate=$(curl -q -4 --noproxy '*' -fsS --proto '=https' --connect-timeout 4 --max-time 6 https://api.ipify.org 8>&- 9>&-); then
if printf '%s\n' "$candidate" | awk -F. 'NF!=4{exit 1}{for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1}END{if(NR!=1)exit 1}'; then PUBLIC_IPV4=$candidate; fi
fi
if [ "$PUBLIC_IPV4" != UNKNOWN ]; then
if geo=$(curl -q -4 --noproxy '*' -fsS --proto '=https' --connect-timeout 4 --max-time 6 "https://ipwho.is/$PUBLIC_IPV4?fields=success,ip,country_code" 8>&- 9>&-); then
country=$(printf '%s\n' "$geo" | jq -er --arg ip "$PUBLIC_IPV4" 'select(.success == true and .ip == $ip) | .country_code | select(type == "string" and test("^[A-Z]{2}$"))') || country=UNKNOWN
COUNTRY_CODE=$country
fi
fi
printf 'PUBLIC_IPV4\n%s\nCOUNTRY_CODE\n%s\n' "$PUBLIC_IPV4" "$COUNTRY_CODE"
R=0
/usr/local/sbin/earnapp-limit --locked 20 || R=2
[ "$R" = 0 ] || exit "$R"
verify_setup_worker || exit 1
verify_identity || exit 1
COMMITTED=1
echo '===== 9/9 DONE ====='
printf 'INSTALL_STATE\nCOMPLETE\nCONNECTION_STATE\n%s\nDASHBOARD_STATUS\nUNKNOWN\n' "$CONNECTION_STATE"
printf 'SETUP_RC\n%s\n' "$R"
exit "$R"
