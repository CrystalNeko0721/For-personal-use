#!/bin/sh
# Unified Alpine/OpenRC install, helper upgrade and service migration. Version 2026.10.18.1
set -u

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd) || exit 1
CONFIG_FILE=${CONFIG_FILE:-$SCRIPT_DIR/config.local.sh}
if [ -f "$CONFIG_FILE" ]; then
  . "$CONFIG_FILE" || exit 1
fi

SDK_BIN=${SDK_BIN:-}
OLD_SVC=${OLD_SVC:-}
OLD_COMMON=${OLD_COMMON:-}
COVER_BIN=${COVER_BIN:-/usr/local/bin/xray}
COVER_ALT=${COVER_ALT:-/usr/local/lib/xray}
COVER_SVC=${COVER_SVC:-xray}
LAUNCHER_BIN=${LAUNCHER_BIN:-/usr/local/lib/xrayrun}
BACKUP_ROOT=${BACKUP_ROOT:-/var/backups}
BACKUP_DIR=${BACKUP_DIR:-}
LAUNCHER=${LAUNCHER:-0}
POST_CLEANUP=${POST_CLEANUP:-1}
CHECK_DELAY=${CHECK_DELAY:-2}
CMD=${1:-}
APPLY=0
if [ "$#" -gt 2 ]; then
  printf '%s\n' 'FAIL: too many arguments' >&2
  exit 1
fi
if [ "$#" -eq 2 ]; then
  if [ "$2" = --apply ]; then APPLY=1
  else printf '%s\n' 'FAIL: the second argument must be --apply' >&2; exit 1; fi
fi

fail(){ printf 'FAIL: %s\n' "$*" >&2; return 1; }
exists(){ [ -e "$1" ] || [ -L "$1" ]; }
valid_name(){
  case "$1" in ''|.|..|-*|*[!A-Za-z0-9_.-]*) fail "invalid service/runlevel name: $1";; *) return 0;; esac
}
valid_path(){
  case "$1" in
    /|*'/../'*|*'/./'*|*/..|*/.|*'//'*) fail "non-canonical path: $1";;
    /*) case "$1" in *[!A-Za-z0-9_./+,@%:=~-]*) fail "path contains unsupported shell characters: $1";; *) return 0;; esac;;
    *) fail "absolute path required: $1";;
  esac
}
need(){ command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }
require_root(){ [ "$(id -u)" = 0 ] || fail 'run --apply as root'; }
service_state(){
  rc-service "$1" status >/dev/null 2>&1
  printf '%s\n' "$?"
}
hash_file(){
  HF_RESULT=$(sha256sum "$1" 2>/dev/null) || return 1
  printf '%s\n' "${HF_RESULT%% *}"
}
sdk_hash(){ hash_file "$SDK_BIN"; }

discover_sdk(){
  if [ -n "$SDK_BIN" ]; then
    [ -f "$SDK_BIN" ] && [ -x "$SDK_BIN" ] || { fail "SDK not executable: $SDK_BIN"; return 1; }
    valid_path "$SDK_BIN"
    return $?
  fi
  for DS_C in /usr/bin/earnapp /usr/local/bin/earnapp /opt/earnapp/earnapp; do
    if [ -f "$DS_C" ] && [ -x "$DS_C" ]; then SDK_BIN=$DS_C; return 0; fi
  done
  fail 'SDK not found; set SDK_BIN to its absolute path'
}
discover_svc(){
  if [ -n "$OLD_SVC" ]; then valid_name "$OLD_SVC"; return $?; fi
  if [ -f /etc/init.d/earnapp ]; then OLD_SVC=earnapp; return 0; fi
  DS_FOUND=
  for DS_FILE in /etc/init.d/*; do
    [ -f "$DS_FILE" ] || continue
    if [ -n "$SDK_BIN" ] && grep -Fq -- "$SDK_BIN" "$DS_FILE"; then
      [ -z "$DS_FOUND" ] || { fail 'multiple services match; set OLD_SVC'; return 1; }
      DS_FOUND=${DS_FILE##*/}
    fi
  done
  [ -n "$DS_FOUND" ] || { fail 'source service not found; set OLD_SVC'; return 1; }
  OLD_SVC=$DS_FOUND
  valid_name "$OLD_SVC"
}
discover_common(){
  if [ -n "$OLD_COMMON" ]; then
    valid_path "$OLD_COMMON" && [ -f "$OLD_COMMON" ] || { fail "common script missing: $OLD_COMMON"; return 1; }
    return 0
  fi
  if [ -f /usr/local/lib/earnapp-original.sh ] &&
     grep -Fq -- /usr/local/lib/earnapp-original.sh "/etc/init.d/$OLD_SVC"; then
    OLD_COMMON=/usr/local/lib/earnapp-original.sh
  fi
}
cover_target(){
  if exists "$COVER_BIN"; then
    exists "$COVER_ALT" && { fail "both executable destinations exist: $COVER_BIN / $COVER_ALT"; return 1; }
    printf '%s\n' "$COVER_ALT"
  else printf '%s\n' "$COVER_BIN"; fi
}
pids_by_exe_hash(){
  PH_HASH=$(sdk_hash) || return 1
  [ -n "$PH_HASH" ] || return 1
  for PH_PROC in /proc/[0-9]*; do
    [ "${PH_PROC##*/}" = "$$" ] && continue
    PH_EXE_HASH=$(hash_file "$PH_PROC/exe") || continue
    [ "$PH_EXE_HASH" = "$PH_HASH" ] && printf '%s\n' "${PH_PROC##*/}"
  done
  return 0
}
pids_by_cgroup(){
  [ -n "$OLD_SVC" ] || return 0
  for PC_PROC in /proc/[0-9]*; do
    [ "${PC_PROC##*/}" = "$$" ] && continue
    awk -F: -v service="$OLD_SVC" '
      {n=split($NF,a,"/"); for(i=1;i<=n;i++)
        if(a[i]==service || a[i]==service ".service") found=1}
      END {exit !found}' "$PC_PROC/cgroup" 2>/dev/null && printf '%s\n' "${PC_PROC##*/}"
  done
  return 0
}
pids_by_cmdline(){
  [ -n "$SDK_BIN" ] || return 0
  for PM_PROC in /proc/[0-9]*; do
    [ "${PM_PROC##*/}" = "$$" ] && continue
    [ -r "$PM_PROC/cmdline" ] || continue
    PM_ARG0=$(tr '\0' '\n' < "$PM_PROC/cmdline" 2>/dev/null | head -n 1)
    [ "$PM_ARG0" = "$SDK_BIN" ] && printf '%s\n' "${PM_PROC##*/}"
  done
  return 0
}
openrc_value() (
  for OV_HELPER in /lib/rc/bin/service_get_value /usr/lib/rc/bin/service_get_value; do
    if [ -x "$OV_HELPER" ]; then RC_SVCNAME=$1 "$OV_HELPER" "$2"; exit $?; fi
  done
  OV_HELPER=$(command -v service_get_value) || exit 1
  RC_SVCNAME=$1 "$OV_HELPER" "$2"
)
service_is_supervised(){
  for SI_FILE in "/etc/init.d/$1" "/etc/conf.d/$1" "$OLD_COMMON" "${NEW_COMMON:-}"; do
    [ -f "$SI_FILE" ] || continue
    if grep -Eq "^[[:space:]]*supervisor=['\"]?supervise-daemon['\"]?[[:space:]]*(#.*)?$" "$SI_FILE"; then return 0; fi
  done
  SI_CHILD=$(openrc_value "$1" child_pid 2>/dev/null) || return 1
  [ -n "$SI_CHILD" ]
}
process_stamp() (
  PS_PID=$1
  case "$PS_PID" in ''|*[!0-9]*) exit 1;; esac
  [ "$PS_PID" -gt 1 ] || exit 1
  PS_STAT=$(cat "/proc/$PS_PID/stat" 2>/dev/null) || exit 1
  PS_FIELDS=${PS_STAT##*) }
  [ "$PS_FIELDS" != "$PS_STAT" ] || exit 1
  set -f
  set -- $PS_FIELDS
  [ "$#" -ge 20 ] || exit 1
  case "$1" in Z|X|x) exit 1;; esac
  PS_PARENT=$2
  shift 19
  case "$PS_PARENT:$1" in *[!0-9:]*) exit 1;; esac
  printf '%s:%s\n' "$PS_PARENT" "$1"
)
mapped_program_matches() (
  MP_PROC=$1; MP_TARGET=$2
  MP_ID=$(stat -Lc '%d %i' "$MP_TARGET" 2>/dev/null) || exit 1
  set -- $MP_ID
  [ "$#" = 2 ] || exit 1
  MP_DEV=$1; MP_INO=$2
  case "$MP_DEV:$MP_INO" in *[!0-9:]*) exit 1;; esac
  MP_MAJOR=$(( ((MP_DEV >> 8) & 4095) | ((MP_DEV >> 32) & 4294963200) ))
  MP_MINOR=$(( (MP_DEV & 255) | ((MP_DEV >> 12) & 4294967040) ))
  MP_DEVICE=$(printf '%x:%x' "$MP_MAJOR" "$MP_MINOR") || exit 1
  awk -v device="$MP_DEVICE" -v inode="$MP_INO" -v target="$MP_TARGET" '
    function hexnorm(s) {s=tolower(s); sub(/^0+/,"",s); return s=="" ? "0" : s}
    BEGIN {split(device,want,":")}
    $2 ~ /x/ && ("i:" $5)==("i:" inode) && $6==target && NF==6 {
      split($4,got,":")
      if (hexnorm(got[1])==hexnorm(want[1]) && hexnorm(got[2])==hexnorm(want[2])) found=1
    }
    END {exit !found}' "$MP_PROC/maps" 2>/dev/null
)
service_worker_pids() (
  SW_SERVICE=$1; SW_TARGET=$2
  SW_HASH=$(hash_file "$SW_TARGET") || exit 1
  SW_CANON=$(readlink -f "$SW_TARGET") || exit 1
  if service_is_supervised "$SW_SERVICE"; then
    SW_CHILD=$(openrc_value "$SW_SERVICE" child_pid 2>/dev/null) &&
    SW_PIDFILE=$(openrc_value "$SW_SERVICE" pidfile 2>/dev/null) || {
      fail "cannot read OpenRC child_pid/pidfile for $SW_SERVICE"; exit 1;
    }
    valid_path "$SW_PIDFILE" || exit 1
    SW_PARENT=$(cat "$SW_PIDFILE" 2>/dev/null) || {
      fail "cannot read supervisor PID for $SW_SERVICE: $SW_PIDFILE"; exit 1;
    }
    case "$SW_CHILD:$SW_PARENT" in *[!0-9:]*|:*|*:) fail "invalid OpenRC process IDs for $SW_SERVICE"; exit 1;; esac
    SW_CHILD_STAMP=$(process_stamp "$SW_CHILD") && SW_PARENT_STAMP=$(process_stamp "$SW_PARENT") || {
      fail "OpenRC worker/supervisor is not live for $SW_SERVICE"; exit 1;
    }
    [ "${SW_CHILD_STAMP%%:*}" = "$SW_PARENT" ] || {
      fail "OpenRC child $SW_CHILD does not belong to supervisor $SW_PARENT"; exit 1;
    }
    SW_SUPERVISOR=$(command -v supervise-daemon) && SW_SUPERVISOR=$(readlink -f "$SW_SUPERVISOR") || {
      fail 'cannot locate supervise-daemon'; exit 1;
    }
    SW_PARENT_EXE=$(readlink "/proc/$SW_PARENT/exe" 2>/dev/null) || exit 1
    [ "${SW_PARENT_EXE% (deleted)}" = "$SW_SUPERVISOR" ] || {
      fail "recorded supervisor $SW_PARENT is not supervise-daemon"; exit 1;
    }
    SW_PROC="/proc/$SW_CHILD"
    SW_EXE=$(readlink "$SW_PROC/exe" 2>/dev/null) || {
      fail "cannot read executable of $SW_SERVICE worker $SW_CHILD"; exit 1;
    }
    SW_MATCH=0
    if [ "${SW_EXE% (deleted)}" = "$SW_CANON" ]; then
      SW_ACTUAL=$(hash_file "$SW_PROC/exe") || exit 1
      [ "$SW_ACTUAL" = "$SW_HASH" ] && SW_MATCH=1
    fi
    if [ "$SW_MATCH" = 0 ] && mapped_program_matches "$SW_PROC" "$SW_CANON"; then SW_MATCH=1; fi
    if [ "$SW_MATCH" != 1 ]; then
      fail "$SW_SERVICE child $SW_CHILD does not execute or map $SW_CANON (kernel executable: $SW_EXE)"
      awk '$2 ~ /x/ && NF>=6 {print "  executable mapping: " $4 " " $5 " " $6; if (++n==12) exit}' "$SW_PROC/maps" >&2 2>/dev/null || true
      exit 1
    fi
    [ "$(openrc_value "$SW_SERVICE" child_pid 2>/dev/null)" = "$SW_CHILD" ] &&
    [ "$(openrc_value "$SW_SERVICE" pidfile 2>/dev/null)" = "$SW_PIDFILE" ] &&
    [ "$(cat "$SW_PIDFILE" 2>/dev/null)" = "$SW_PARENT" ] &&
    [ "$(process_stamp "$SW_CHILD")" = "$SW_CHILD_STAMP" ] &&
    [ "$(process_stamp "$SW_PARENT")" = "$SW_PARENT_STAMP" ] || {
      fail "service process changed during verification: $SW_SERVICE"; exit 1;
    }
    [ "$(hash_file "$SW_TARGET")" = "$SW_HASH" ] || {
      fail "program changed during verification: $SW_TARGET"; exit 1;
    }
    printf '%s\n' "$SW_CHILD"
    exit 0
  fi
  for SW_PROC in /proc/[0-9]*; do
    SW_EXE=$(readlink "$SW_PROC/exe" 2>/dev/null) || continue
    [ "${SW_EXE% (deleted)}" = "$SW_CANON" ] || continue
    SW_ACTUAL=$(hash_file "$SW_PROC/exe") || continue
    [ "$SW_ACTUAL" = "$SW_HASH" ] && printf '%s\n' "${SW_PROC##*/}"
  done
  exit 0
)
running_target_pids(){ service_worker_pids "$COVER_SVC" "$T"; }
worker_pid(){
  if [ -n "${WORKER_PID:-}" ]; then
    case "$WORKER_PID" in *[!0-9]*|'') fail 'WORKER_PID must be numeric'; return 1;; esac
    [ -r "/proc/$WORKER_PID/status" ] || { fail 'WORKER_PID is not running'; return 1; }
    printf '%s\n' "$WORKER_PID"
    return 0
  fi
  WP_CANDIDATES=$(service_worker_pids "$OLD_SVC" "$SDK_BIN") || return 1
  for WP_PID in $WP_CANDIDATES; do
    if tr '\0' '\n' < "/proc/$WP_PID/cmdline" 2>/dev/null | grep -Fxq -- run; then
      printf '%s\n' "$WP_PID"; return 0
    fi
  done
  printf '%s\n' "$WP_CANDIDATES" | head -n 1
}
show_candidates(){
  printf '%s\n' '-- service worker candidates --'
  SC_PIDS=$(service_worker_pids "$OLD_SVC" "$SDK_BIN") || return 1
  [ -n "$SC_PIDS" ] || { printf '%s\n' 'WARN: no matching process'; return 0; }
  for SC_PID in $SC_PIDS; do
    printf 'pid=%s exe=%s\n' "$SC_PID" "$(readlink "/proc/$SC_PID/exe" 2>/dev/null)"
    printf ' argv: '
    tr '\0' ' ' < "/proc/$SC_PID/cmdline" 2>/dev/null || true
    printf '\n'
  done
}
limit_hint(){
  printf '%s\n' 'Check external watchdog, updater and cgroup-limit scripts for references to the old service:'
  for LH_FILE in /usr/local/lib/*limit* /usr/local/sbin/*limit* /etc/init.d/*limit*; do
    [ -f "$LH_FILE" ] && printf '  %s\n' "$LH_FILE"
  done
  return 0
}

cmd_precheck(){
  discover_sdk && discover_svc && discover_common || return 1
  printf '== precheck %s ==\nSDK=%s\nSVC=%s\nCOMMON=%s\n' "$(date -u '+%F %T')" "$SDK_BIN" "$OLD_SVC" "${OLD_COMMON:-none}"
  [ -f "/etc/init.d/$OLD_SVC" ] || { fail 'source init script missing'; return 1; }
  sh -n "/etc/init.d/$OLD_SVC" || return 1
  for PP_TOOL in rc-service rc-update sha256sum awk mktemp stat readlink; do need "$PP_TOOL" || return 1; done
  printf 'target: '
  cover_target || return 1
  rc-service "$OLD_SVC" status || true
  rc-status 2>/dev/null || true
  show_candidates || return 1
  limit_hint
}
cmd_baseline(){
  discover_sdk && discover_svc || return 1
  BL_PID=$(worker_pid) || return 1
  [ -n "$BL_PID" ] || { fail 'no worker'; return 1; }
  need ss || return 1
  BL_DIR=$(mktemp -d /tmp/earnapp-xray-observe-XXXXXXXX) || return 1
  chmod 700 "$BL_DIR" || return 1
  printf '== baseline -> %s (pid=%s) ==\n' "$BL_DIR" "$BL_PID"
  printf '%s\n' "$BL_PID" > "$BL_DIR/pid.txt" || return 1
  {
    date; hostname
    ls -l "/proc/$BL_PID/exe"
    tr '\0' ' ' < "/proc/$BL_PID/cmdline"; printf '\n'
    cat "/proc/$BL_PID/cgroup"
    grep -E '^(Name|Uid|Gid|State|VmRSS):' "/proc/$BL_PID/status"
    cat "/proc/$BL_PID/io" 2>/dev/null || true
  } > "$BL_DIR/identity.txt"
  ss -tnp > "$BL_DIR/sockets-t0.txt" 2>/dev/null || return 1
  sleep 60
  ss -Htn state established > "$BL_DIR/sockets-t60.txt" 2>/dev/null || return 1
  awk -F: '$1==0 {print $3; exit}' "/proc/$BL_PID/cgroup" 2>/dev/null > "$BL_DIR/cgroup-path.txt"
  BL_CG=$(cat "$BL_DIR/cgroup-path.txt")
  if [ -n "$BL_CG" ]; then
    cat "/sys/fs/cgroup$BL_CG/memory.events" > "$BL_DIR/cgroup-mem.txt" 2>/dev/null || true
  fi
  dmesg 2>&1 | tail -n 50 > "$BL_DIR/dmesg.txt"
  sdk_hash > "$BL_DIR/sdk-hash.txt" || return 1
  printf '== done: %s ==\n' "$BL_DIR"
}
cmd_launch_mode(){
  discover_sdk || return 1
  printf '== executable: %s ==\n' "$SDK_BIN"
  head -c 4 "$SDK_BIN" | od -c
  if command -v readelf >/dev/null 2>&1; then
    readelf -h "$SDK_BIN" || return 1
  fi
  sdk_hash
}

replace_literal(){
  SM_FROM=$1 SM_TO=$2 awk '
    function pathchar(c) {return c ~ /^[A-Za-z0-9_.\/+,@%~-]$/}
    BEGIN {from=ENVIRON["SM_FROM"]; to=ENVIRON["SM_TO"]}
    {
      rest=$0; out=""
      while ((i=index(rest,from))>0) {
        left=(i>1 ? substr(rest,i-1,1) : "")
        right=substr(rest,i+length(from),1)
        if ((i==1 || !pathchar(left)) && (right=="" || !pathchar(right))) {
          out=out substr(rest,1,i-1) to; rest=substr(rest,i+length(from))
        } else {out=out substr(rest,1,i); rest=substr(rest,i+1)}
      }
      print out rest
    }' "$3" > "$4"
}
rewrite_file(){
  replace_literal "$SDK_BIN" "$SVC_TARGET" "$1" "$2.first" || return 1
  if [ -n "$NEW_COMMON" ]; then
    replace_literal "$OLD_COMMON" "$NEW_COMMON" "$2.first" "$2" || return 1
    rm -f "$2.first" || return 1
  else mv "$2.first" "$2" || return 1; fi
  sh -n "$2"
}
runlevels_for(){
  for RF_LEVEL in /etc/runlevels/*; do
    [ -d "$RF_LEVEL" ] || continue
    if exists "$RF_LEVEL/$1"; then printf '%s\n' "${RF_LEVEL##*/}"; fi
  done
  return 0
}
set_state(){ printf '%s\n' "$1" > "$B/state"; }
write_manifest(){
  printf '%s\n' 'FORMAT=2' "SDK_BIN=$SDK_BIN" "OLD_SVC=$OLD_SVC" "COVER_SVC=$COVER_SVC" \
    "TARGET=$T" "LAUNCHER=$LAUNCHER" "LAUNCHER_BIN=$LAUNCHER_BIN" "OLD_COMMON=$OLD_COMMON" \
    "NEW_COMMON=$NEW_COMMON" "HAD_CONF=$HAD_CONF" "OLD_RUNNING=$OLD_RUNNING" > "$B/manifest"
}
load_manifest(){
  SDK_BIN=; OLD_SVC=; COVER_SVC=; T=; LAUNCHER=; LAUNCHER_BIN=; OLD_COMMON=; NEW_COMMON=
  HAD_CONF=; OLD_RUNNING=; MF_FORMAT=
  [ -f "$B/manifest" ] && [ ! -L "$B/manifest" ] || { fail "missing manifest: $B"; return 1; }
  while IFS='=' read -r MF_KEY MF_VALUE; do
    case "$MF_KEY" in
      FORMAT) MF_FORMAT=$MF_VALUE;; SDK_BIN) SDK_BIN=$MF_VALUE;; OLD_SVC) OLD_SVC=$MF_VALUE;;
      COVER_SVC) COVER_SVC=$MF_VALUE;; TARGET) T=$MF_VALUE;; LAUNCHER) LAUNCHER=$MF_VALUE;;
      LAUNCHER_BIN) LAUNCHER_BIN=$MF_VALUE;; OLD_COMMON) OLD_COMMON=$MF_VALUE;;
      NEW_COMMON) NEW_COMMON=$MF_VALUE;; HAD_CONF) HAD_CONF=$MF_VALUE;; OLD_RUNNING) OLD_RUNNING=$MF_VALUE;;
      *) fail "unknown manifest key: $MF_KEY"; return 1;;
    esac
  done < "$B/manifest"
  [ "$MF_FORMAT" = 2 ] || { fail 'legacy/unrecognized backup; automatic rollback is unsafe'; return 1; }
  valid_name "$OLD_SVC" && valid_name "$COVER_SVC" || return 1
  [ "$OLD_SVC" != "$COVER_SVC" ] || { fail 'invalid manifest service collision'; return 1; }
  for MF_PATH in "$SDK_BIN" "$T" "$LAUNCHER_BIN"; do valid_path "$MF_PATH" || return 1; done
  [ "$T" != "$SDK_BIN" ] && [ "$T" != "$LAUNCHER_BIN" ] || { fail 'invalid manifest path collision'; return 1; }
  case "$LAUNCHER:$HAD_CONF:$OLD_RUNNING" in [01]:[01]:[01]) :;; *) fail 'incomplete manifest flags'; return 1;; esac
  if [ -n "$NEW_COMMON" ]; then
    valid_path "$OLD_COMMON" && valid_path "$NEW_COMMON" || return 1
    [ "$NEW_COMMON" != "$OLD_COMMON" ] || return 1
  fi
  [ -f "$B/runlevels" ] && [ -f "$B/owned" ] && [ -f "$B/originals" ] || { fail 'incomplete backup'; return 1; }
  while IFS= read -r MF_LEVEL; do valid_name "$MF_LEVEL" || return 1; done < "$B/runlevels"
  return 0
}
find_backup(){
  if [ -n "$BACKUP_DIR" ]; then
    valid_path "$BACKUP_DIR" || return 1
    [ -d "$BACKUP_DIR" ] || { fail 'BACKUP_DIR does not exist'; return 1; }
    printf '%s\n' "$BACKUP_DIR"; return 0
  fi
  FB_RESULT=
  for FB_DIR in "$BACKUP_ROOT"/earnapp-xray-*; do
    [ -d "$FB_DIR" ] && [ -f "$FB_DIR/manifest" ] && [ -f "$FB_DIR/state" ] || continue
    FB_STATE=$(cat "$FB_DIR/state") || continue
    case "$FB_STATE" in active|switching|rollback-failed) FB_RESULT=$FB_DIR;; esac
  done
  [ -n "$FB_RESULT" ] || { fail 'no active v2 backup; set BACKUP_DIR for an exact backup'; return 1; }
  printf '%s\n' "$FB_RESULT"
}
snapshot_original(){
  cp -p "$1" "$B/$2" || return 1
  SO_HASH=$(hash_file "$B/$2") || return 1
  printf '%s %s %s\n' "$SO_HASH" "$2" "$1" >> "$B/originals"
}
owned_record(){
  OR_HASH=$(hash_file "$1") || return 1
  printf '%s %s\n' "$OR_HASH" "$2" >> "$B/owned"
}
check_backup(){
  CB_SDK=0; CB_INIT=0; CB_CONF=0; CB_COMMON=0
  while read -r CB_HASH CB_FILE CB_PATH; do
    case "$CB_FILE" in
      sdk-original) CB_EXPECT=$SDK_BIN; CB_SDK=$((CB_SDK + 1));;
      init-original) CB_EXPECT="/etc/init.d/$OLD_SVC"; CB_INIT=$((CB_INIT + 1));;
      conf-original) CB_EXPECT="/etc/conf.d/$OLD_SVC"; CB_CONF=$((CB_CONF + 1));;
      common-original) CB_EXPECT=$OLD_COMMON; CB_COMMON=$((CB_COMMON + 1));;
      *) fail 'invalid backup record'; return 1;;
    esac
    [ "$CB_PATH" = "$CB_EXPECT" ] || { fail 'backup path mismatch'; return 1; }
    valid_path "$CB_PATH" || return 1
    CB_CURRENT=$(hash_file "$B/$CB_FILE") || { fail "missing backup: $CB_FILE"; return 1; }
    [ "$CB_CURRENT" = "$CB_HASH" ] || { fail "backup checksum mismatch: $CB_FILE"; return 1; }
  done < "$B/originals"
  CB_NEED_COMMON=0
  [ -n "$NEW_COMMON" ] && CB_NEED_COMMON=1
  [ "$CB_SDK:$CB_INIT:$CB_CONF:$CB_COMMON" = "1:1:$HAD_CONF:$CB_NEED_COMMON" ] || {
    fail 'backup record set is incomplete or duplicated'; return 1;
  }
  return 0
}
check_owned(){
  CO_BIN=0; CO_INIT=0; CO_CONF=0; CO_LAUNCHER=0; CO_COMMON=0
  while read -r CO_HASH CO_PATH; do
    valid_path "$CO_PATH" || return 1
    case "$CO_PATH" in
      "$T") CO_BIN=$((CO_BIN + 1));;
      "/etc/init.d/$COVER_SVC") CO_INIT=$((CO_INIT + 1));;
      "/etc/conf.d/$COVER_SVC") CO_CONF=$((CO_CONF + 1));;
      "$LAUNCHER_BIN") CO_LAUNCHER=$((CO_LAUNCHER + 1));;
      "$NEW_COMMON") CO_COMMON=$((CO_COMMON + 1));;
      *) fail "unrecognized owned path: $CO_PATH"; return 1;;
    esac
    if exists "$CO_PATH"; then
      [ ! -L "$CO_PATH" ] && [ -f "$CO_PATH" ] || { fail "owned file replaced by non-regular file: $CO_PATH"; return 1; }
      CO_CURRENT=$(hash_file "$CO_PATH") || return 1
      [ "$CO_CURRENT" = "$CO_HASH" ] || { fail "file changed since deploy; retained: $CO_PATH"; return 1; }
    fi
  done < "$B/owned"
  CO_NEED_COMMON=0
  [ -n "$NEW_COMMON" ] && CO_NEED_COMMON=1
  [ "$CO_BIN:$CO_INIT:$CO_CONF:$CO_LAUNCHER:$CO_COMMON" = "1:1:$HAD_CONF:$LAUNCHER:$CO_NEED_COMMON" ] || {
    fail 'owned record set is incomplete or duplicated'; return 1;
  }
  return 0
}
restore_missing_originals(){
  while read -r RM_HASH RM_FILE RM_PATH; do
    if ! exists "$RM_PATH"; then
      mkdir -p "$(dirname "$RM_PATH")" && cp -p "$B/$RM_FILE" "$RM_PATH" || return 1
    fi
  done < "$B/originals"
  return 0
}
restore_deployment(){
  check_backup && check_owned || return 1
  if [ -f "/etc/init.d/$COVER_SVC" ]; then
    rc-service "$COVER_SVC" stop || { fail 'could not stop replacement service'; return 1; }
    [ "$(service_state "$COVER_SVC")" = 3 ] || { fail 'replacement service is not confirmed stopped'; return 1; }
  elif [ -f "$B/start-attempted" ]; then
    fail 'replacement init is missing after a start attempt; cannot stop safely'; return 1
  fi
  restore_missing_originals || return 1
  RD_LEVELS=$(runlevels_for "$COVER_SVC") || return 1
  for RD_LEVEL in $RD_LEVELS; do rc-update del "$COVER_SVC" "$RD_LEVEL" || return 1; done
  RD_OLD_LEVELS=$(runlevels_for "$OLD_SVC") || return 1
  for RD_LEVEL in $RD_OLD_LEVELS; do
    grep -Fxq -- "$RD_LEVEL" "$B/runlevels" || rc-update del "$OLD_SVC" "$RD_LEVEL" || return 1
  done
  while IFS= read -r RD_LEVEL; do
    if ! exists "/etc/runlevels/$RD_LEVEL/$OLD_SVC"; then rc-update add "$OLD_SVC" "$RD_LEVEL" || return 1; fi
  done < "$B/runlevels"
  if [ "$OLD_RUNNING" = 1 ]; then
    if ! rc-service "$OLD_SVC" status >/dev/null 2>&1; then rc-service "$OLD_SVC" start || return 1; fi
    rc-service "$OLD_SVC" status >/dev/null 2>&1 || { fail 'original service did not start'; return 1; }
  elif rc-service "$OLD_SVC" status >/dev/null 2>&1; then
    rc-service "$OLD_SVC" stop || return 1
  fi
  RD_EXPECTED=3
  [ "$OLD_RUNNING" = 1 ] && RD_EXPECTED=0
  [ "$(service_state "$OLD_SVC")" = "$RD_EXPECTED" ] || { fail 'original service state was not restored'; return 1; }
  while read -r RD_HASH RD_PATH; do
    [ -f "$RD_PATH" ] && rm -f "$RD_PATH" || { exists "$RD_PATH" && return 1; }
  done < "$B/owned"
  set_state rolled-back || return 1
  return 0
}
install_owned(){
  exists "$2" && { fail "destination appeared during deployment: $2"; return 1; }
  mkdir -p "$(dirname "$2")" || return 1
  IO_TMP=$(mktemp "$(dirname "$2")/.svc-migrate-XXXXXXXX") || return 1
  if ! cp -p "$1" "$IO_TMP" || ! chmod "$3" "$IO_TMP"; then rm -f "$IO_TMP"; return 1; fi
  if ! ln "$IO_TMP" "$2"; then rm -f "$IO_TMP"; return 1; fi
  rm -f "$IO_TMP"
}
deployment_exit(){
  DE_RC=$?
  trap - 0 HUP INT TERM
  if [ "$DE_RC" -ne 0 ] && [ "$SWITCHING" = 1 ]; then
    printf '%s\n' 'Deployment failed; restoring the recorded original service.' >&2
    if restore_deployment; then printf '%s\n' 'Original service state restored; deployment was not successful.' >&2
    else set_state rollback-failed || true; printf 'FAIL: automatic recovery incomplete; backup: %s\n' "$B" >&2; fi
  elif [ "$DE_RC" -ne 0 ] && [ -n "$B" ]; then set_state failed || true; fi
  if [ "$LOCKED" = 1 ]; then rmdir "$LOCK_DIR" 2>/dev/null || true; fi
  exit "$DE_RC"
}
cmd_deploy() (
  discover_sdk && discover_svc && discover_common || exit 1
  valid_name "$COVER_SVC" || exit 1
  [ "$OLD_SVC" != "$COVER_SVC" ] || { fail 'source and replacement services must differ'; exit 1; }
  for CD_PATH in "$COVER_BIN" "$COVER_ALT" "$LAUNCHER_BIN" "$BACKUP_ROOT"; do valid_path "$CD_PATH" || exit 1; done
  case "$LAUNCHER" in 0|1) :;; *) fail 'LAUNCHER must be 0 or 1'; exit 1;; esac
  case "$CHECK_DELAY" in ''|*[!0-9]*) fail 'CHECK_DELAY must be seconds (0-60)'; exit 1;; esac
  [ "$CHECK_DELAY" -le 60 ] || exit 1
  for CD_TOOL in rc-service rc-update sha256sum awk mktemp cmp cp ln stat readlink; do need "$CD_TOOL" || exit 1; done
  [ -f "/etc/init.d/$OLD_SVC" ] || { fail 'source init script missing'; exit 1; }
  sh -n "/etc/init.d/$OLD_SVC" || exit 1
  T=$(cover_target) || exit 1
  NEW_COMMON=
  HAD_CONF=0
  [ -f "/etc/conf.d/$OLD_SVC" ] && HAD_CONF=1
  for CD_SERVICE in "$OLD_SVC" "$COVER_SVC"; do
    for CD_CONFIG in "/etc/conf.d/$CD_SERVICE".*; do
      exists "$CD_CONFIG" && { fail "runlevel-specific/inherited configuration needs manual migration: $CD_CONFIG"; exit 1; }
    done
    CD_BASE=${CD_SERVICE%%.*}
    if [ "$CD_BASE" != "$CD_SERVICE" ]; then
      for CD_CONFIG in "/etc/conf.d/$CD_BASE" "/etc/conf.d/$CD_BASE".*; do
        exists "$CD_CONFIG" && { fail "inherited service configuration needs manual migration: $CD_CONFIG"; exit 1; }
      done
    fi
  done
  if [ -n "$OLD_COMMON" ]; then
    if ! grep -Fq -- "$OLD_COMMON" "/etc/init.d/$OLD_SVC" &&
       ! { [ "$HAD_CONF" = 1 ] && grep -Fq -- "$OLD_COMMON" "/etc/conf.d/$OLD_SVC"; }; then
      fail 'OLD_COMMON is not referenced directly by the service; inspect the launch chain first'; exit 1
    fi
    NEW_COMMON="/usr/local/lib/$COVER_SVC-common.sh"
  fi
  SVC_TARGET=$T
  if [ "$LAUNCHER" = 1 ]; then
    SVC_TARGET=$LAUNCHER_BIN
    CD_SUPERVISED=0
    for CD_FILE in "/etc/init.d/$OLD_SVC" "/etc/conf.d/$OLD_SVC" "$OLD_COMMON"; do
      [ -f "$CD_FILE" ] || continue
      if grep -Eq "^[[:space:]]*supervisor=['\"]?supervise-daemon['\"]?[[:space:]]*(#.*)?$" "$CD_FILE"; then CD_SUPERVISED=1; fi
    done
    [ "$CD_SUPERVISED" = 1 ] || { fail 'LAUNCHER=1 requires supervise-daemon; use LAUNCHER=0 for this service'; exit 1; }
    if command -v musl-gcc >/dev/null 2>&1; then COMPILER=musl-gcc
    elif command -v gcc >/dev/null 2>&1; then COMPILER=gcc
    else fail 'no C compiler; use LAUNCHER=0 for direct execution'; exit 1; fi
  fi
  for CD_DEST in "/etc/init.d/$COVER_SVC" "/etc/conf.d/$COVER_SVC" "$T"; do
    exists "$CD_DEST" && { fail "destination exists: $CD_DEST"; exit 1; }
  done
  if [ "$LAUNCHER" = 1 ] && exists "$LAUNCHER_BIN"; then fail "launcher exists: $LAUNCHER_BIN"; exit 1; fi
  if [ -n "$NEW_COMMON" ] && exists "$NEW_COMMON"; then fail "common destination exists: $NEW_COMMON"; exit 1; fi
  [ "$T" != "$SDK_BIN" ] && [ "$T" != "$LAUNCHER_BIN" ] || { fail 'executable path collision'; exit 1; }
  CD_DESTS="$T /etc/init.d/$COVER_SVC /etc/conf.d/$COVER_SVC"
  [ "$LAUNCHER" = 1 ] && CD_DESTS="$CD_DESTS $LAUNCHER_BIN"
  [ -n "$NEW_COMMON" ] && CD_DESTS="$CD_DESTS $NEW_COMMON"
  CD_SEEN=
  for CD_DEST in $CD_DESTS; do
    case "$CD_DEST" in
      "/etc/conf.d/$OLD_SVC"|"/etc/conf.d/$OLD_SVC".*|"/etc/conf.d/$COVER_SVC".*)
        fail "destination conflicts with implicit service configuration: $CD_DEST"; exit 1;;
    esac
    for CD_PREVIOUS in $CD_SEEN; do
      [ "$CD_DEST" != "$CD_PREVIOUS" ] || { fail "planned destinations overlap: $CD_DEST"; exit 1; }
    done
    CD_SEEN="$CD_SEEN $CD_DEST"
  done
  CD_STATUS=$(service_state "$OLD_SVC")
  case "$CD_STATUS" in
    0) OLD_RUNNING=1;; 3) OLD_RUNNING=0;;
    *) fail "source service is in an abnormal/transitional state (status $CD_STATUS); resolve it before migration"; exit 1;;
  esac
  if [ "$OLD_RUNNING" = 1 ] && service_is_supervised "$OLD_SVC"; then
    CD_ORIGINAL_WORKERS=$(service_worker_pids "$OLD_SVC" "$SDK_BIN") || {
      fail 'cannot identify the original supervised worker; no service changes made'; exit 1;
    }
    [ -n "$CD_ORIGINAL_WORKERS" ] || { fail 'original supervised worker is missing'; exit 1; }
  fi
  CD_LEVELS=$(runlevels_for "$OLD_SVC") || exit 1
  for CD_LEVEL in $CD_LEVELS; do valid_name "$CD_LEVEL" || exit 1; done
  if [ -n "${COVER_ARGS:-}" ]; then
    printf '%s\n' 'INFO: COVER_ARGS is ignored; the original service arguments are preserved.'
  fi
  printf 'source=%s replacement=%s executable=%s launcher=%s\n' "$OLD_SVC" "$COVER_SVC" "$T" "$LAUNCHER"
  if [ "$APPLY" != 1 ]; then
    printf '%s\n' '[dry-run] stage and validate files; back up; stop original; install and start replacement; verify status.'
    printf '%s\n' '[dry-run] failure restores original state. Use --apply to execute.'
    exit 0
  fi
  require_root || exit 1
  umask 077
  LOCK_DIR="$BACKUP_ROOT/.svc-migrate.lock"
  LOCKED=0; SWITCHING=0; B=
  mkdir -p "$BACKUP_ROOT" || exit 1
  mkdir "$LOCK_DIR" || { fail "another operation or stale lock: $LOCK_DIR"; exit 1; }
  LOCKED=1
  trap deployment_exit 0
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  B=$(mktemp -d "$BACKUP_ROOT/earnapp-xray-$(date -u +%Y%m%d-%H%M%S)-XXXXXXXX") || exit 1
  mkdir "$B/staged" || exit 1
  : > "$B/owned"; : > "$B/originals"; : > "$B/runlevels"
  for CD_LEVEL in $CD_LEVELS; do printf '%s\n' "$CD_LEVEL" >> "$B/runlevels" || exit 1; done
  snapshot_original "$SDK_BIN" sdk-original && snapshot_original "/etc/init.d/$OLD_SVC" init-original || exit 1
  if [ "$HAD_CONF" = 1 ]; then snapshot_original "/etc/conf.d/$OLD_SVC" conf-original || exit 1; fi
  if [ -n "$NEW_COMMON" ]; then snapshot_original "$OLD_COMMON" common-original || exit 1; fi
  write_manifest && set_state prepared || exit 1
  cp -p "$B/sdk-original" "$B/staged/binary" || exit 1
  if [ "$LAUNCHER" = 1 ]; then
    cat > "$B/staged/launcher.c" <<EOF
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
  (void)argc;
  argv[0] = "$COVER_BIN";
  execv("$T", argv);
  perror("execv");
  return 127;
}
EOF
    "$COMPILER" -static -O2 -Wall -Wextra -o "$B/staged/launcher" "$B/staged/launcher.c" || exit 1
  fi
  rewrite_file "$B/init-original" "$B/staged/init" || exit 1
  if [ "${SUITE_INSTALL:-0}" = 1 ]; then
    awk -v label="$COVER_SVC" '
      /^[[:space:]]*name=/{print "name=\"" label "\""; named=1; next}
      /^[[:space:]]*description=/{print "description=\"Managed node service\""; next}
      {print} END{if(!named)print "name=\"" label "\""}' "$B/staged/init" > "$B/staged/init.named" || exit 1
    mv "$B/staged/init.named" "$B/staged/init" || exit 1
    sh -n "$B/staged/init" || exit 1
  fi
  CD_CHANGED=0
  cmp -s "$B/init-original" "$B/staged/init" || CD_CHANGED=1
  if [ "$HAD_CONF" = 1 ]; then
    rewrite_file "$B/conf-original" "$B/staged/conf" || exit 1
    cmp -s "$B/conf-original" "$B/staged/conf" || CD_CHANGED=1
  fi
  if [ -n "$NEW_COMMON" ]; then
    replace_literal "$SDK_BIN" "$SVC_TARGET" "$B/common-original" "$B/staged/common" || exit 1
    sh -n "$B/staged/common" || exit 1
    cmp -s "$B/common-original" "$B/staged/common" || CD_CHANGED=1
  fi
  [ "$CD_CHANGED" = 1 ] || { fail 'SDK path was not found in the launch chain; no service changes made'; exit 1; }
  CD_REFERENCE=0
  for CD_FILE in "$B/staged/init" "$B/staged/conf" "$B/staged/common"; do
    [ -f "$CD_FILE" ] && grep -Fq -- "$SVC_TARGET" "$CD_FILE" && CD_REFERENCE=1
  done
  [ "$CD_REFERENCE" = 1 ] || { fail 'generated service does not reference the replacement executable'; exit 1; }
  owned_record "$B/staged/binary" "$T" && owned_record "$B/staged/init" "/etc/init.d/$COVER_SVC" || exit 1
  if [ "$HAD_CONF" = 1 ]; then owned_record "$B/staged/conf" "/etc/conf.d/$COVER_SVC" || exit 1; fi
  if [ "$LAUNCHER" = 1 ]; then owned_record "$B/staged/launcher" "$LAUNCHER_BIN" || exit 1; fi
  if [ -n "$NEW_COMMON" ]; then owned_record "$B/staged/common" "$NEW_COMMON" || exit 1; fi
  printf 'backup: %s\n' "$B"
  if [ "${SUITE_INSTALL:-0}" = 1 ]; then
    [ "${DEPLOY_REPORT:-}" = "$(dirname "$BACKUP_ROOT")/migration.ref" ] || { fail 'invalid suite deployment report'; exit 1; }
    exists "$DEPLOY_REPORT" && { fail 'deployment report already exists'; exit 1; }
    [ "$(cat "$(dirname "$BACKUP_ROOT")/migration.phase")" = staging ] || { fail 'invalid suite deployment phase'; exit 1; }
    printf '%s\n' "$B" > "$DEPLOY_REPORT" || exit 1
    printf '%s\n' recorded > "$(dirname "$BACKUP_ROOT")/migration.phase" || exit 1
  fi
  set_state switching || exit 1
  SWITCHING=1
  if [ "$OLD_RUNNING" = 1 ]; then rc-service "$OLD_SVC" stop || exit 1; fi
  [ "$(service_state "$OLD_SVC")" = 3 ] || { fail 'original service is not confirmed stopped'; exit 1; }
  install_owned "$B/staged/binary" "$T" 755 || exit 1
  if [ "$LAUNCHER" = 1 ]; then install_owned "$B/staged/launcher" "$LAUNCHER_BIN" 755 || exit 1; fi
  if [ -n "$NEW_COMMON" ]; then install_owned "$B/staged/common" "$NEW_COMMON" 755 || exit 1; fi
  if [ "$HAD_CONF" = 1 ]; then
    install_owned "$B/staged/conf" "/etc/conf.d/$COVER_SVC" "$(stat -c '%a' "$B/conf-original")" || exit 1
  fi
  install_owned "$B/staged/init" "/etc/init.d/$COVER_SVC" 755 || exit 1
  for CD_LEVEL in $CD_LEVELS; do
    rc-update del "$OLD_SVC" "$CD_LEVEL" && rc-update add "$COVER_SVC" "$CD_LEVEL" || exit 1
  done
  : > "$B/start-attempted" || exit 1
  rc-service "$COVER_SVC" start || exit 1
  sleep "$CHECK_DELAY"
  rc-service "$COVER_SVC" status || { fail 'replacement service did not remain started'; exit 1; }
  [ "$(service_state "$OLD_SVC")" = 3 ] || { fail 'original service state changed during migration'; exit 1; }
  CD_WORKERS=$(running_target_pids) || exit 1
  [ -n "$CD_WORKERS" ] || { fail 'service reports started but no matching replacement worker is running'; exit 1; }
  check_owned && set_state active || exit 1
  SWITCHING=0
  printf '== deployed; backup: %s ==\n' "$B"
  limit_hint
)
cmd_accept(){
  B=$(find_backup) || return 1
  load_manifest && check_backup && check_owned || return 1
  printf '== accept %s ==\nbackup: %s\nprogram: %s\n' "$(date -u '+%F %T')" "$B" "$T"
  [ "$(cat "$B/state")" = active ] || { fail 'backup is not marked active'; return 1; }
  rc-service "$COVER_SVC" status || return 1
  if rc-service "$OLD_SVC" status >/dev/null 2>&1; then fail 'both services are running'; return 1; fi
  AP_PIDS=$(running_target_pids) || return 1
  [ -n "$AP_PIDS" ] || { fail 'service reports started but no matching running executable was found'; return 1; }
  for AP_PID in $AP_PIDS; do
    AP_PROC="/proc/$AP_PID"
    AP_EXE=$(readlink "$AP_PROC/exe" 2>/dev/null) || continue
    printf 'pid=%s exe=%s\nargv: ' "${AP_PROC##*/}" "$AP_EXE"
    tr '\0' ' ' < "$AP_PROC/cmdline" 2>/dev/null || true
    printf '\n'
    grep -E '^(Name|State|VmRSS):' "$AP_PROC/status" 2>/dev/null || true
    cat "$AP_PROC/cgroup" 2>/dev/null || true
  done
  printf '%s\n' 'PASS: service state and worker program match the recorded deployment.'
}
cmd_rollback() (
  B=$(find_backup) || exit 1
  load_manifest && check_backup && check_owned || exit 1
  if [ "$(cat "$B/state")" = rolled-back ]; then printf '%s\n' 'Already rolled back.'; exit 0; fi
  if [ "$APPLY" != 1 ]; then
    printf '[dry-run] stop %s; restore original state of %s; remove only recorded unmodified files from %s\n' "$COVER_SVC" "$OLD_SVC" "$B"
    exit 0
  fi
  require_root && need rc-service && need rc-update || exit 1
  LOCK_DIR="$(dirname "$B")/.svc-migrate.lock"
  mkdir "$LOCK_DIR" || { fail "another operation or stale lock: $LOCK_DIR"; exit 1; }
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' 0
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if ! restore_deployment; then
    set_state rollback-failed || true
    fail "rollback incomplete; files and backup retained: $B"
    exit 1
  fi
  printf '== rolled back using %s ==\n' "$B"
  limit_hint
)

# Source this module; the caller owns U_D and installs Alpine dependencies.
# Return 20 means the SDK remains installed and needs browser registration.
# Vendor installation has side effects outside this module's rollback control.
suite_bootstrap(){
  SDK_BIN=${SDK_BIN:-/usr/bin/earnapp}
  if [ -f "$SDK_BIN" ] && [ -x "$SDK_BIN" ]; then return 0; fi
  (
    sb_fail(){ printf '%s\n' "$*" >&2; return 1; }
    [ "$(id -u)" = 0 ] || { sb_fail BOOTSTRAP_ROOT_REQUIRED; exit 1; }
    [ -f /etc/alpine-release ] || { sb_fail BOOTSTRAP_ALPINE_REQUIRED; exit 1; }
    [ "$SDK_BIN" = /usr/bin/earnapp ] || { sb_fail BOOTSTRAP_STANDARD_SDK_PATH_REQUIRED; exit 1; }
    [ ! -e "$SDK_BIN" ] && [ ! -L "$SDK_BIN" ] || { sb_fail BOOTSTRAP_SDK_PATH_OCCUPIED; exit 1; }
    case "${U_D:-}" in /*) :;; *) sb_fail BOOTSTRAP_TEMP_DIRECTORY_REQUIRED; exit 1;; esac
    [ -d "$U_D" ] && [ ! -L "$U_D" ] || { sb_fail BOOTSTRAP_TEMP_DIRECTORY_REQUIRED; exit 1; }
    for SB_TOOL in bash curl sha256sum timeout mktemp install stat cmp readlink; do
      command -v "$SB_TOOL" >/dev/null 2>&1 || { sb_fail "BOOTSTRAP_DEPENDENCY_MISSING $SB_TOOL"; exit 1; }
    done
    umask 077
    SB_DIR=$(mktemp -d "$U_D/bootstrap-XXXXXXXX") || exit 1
    mkdir "$SB_DIR/bin" "$SB_DIR/identity" || exit 1
    cat > "$SB_DIR/fetch" <<'BOOTSTRAP_FETCH'
#!/bin/sh
url=$1; file=$2
case "$url" in https://*) :;; *) exit 1;; esac
for mode in auto ipv6 tls12; do
  case "$mode" in auto) set --;; ipv6) set -- -6;; tls12) set -- -4 --http1.1 --tlsv1.2 --tls-max 1.2;; esac
  result=0
  if curl -q "$@" -fL --proto '=https' --proto-redir '=https' --connect-timeout 8 --max-time 30 "$url" -o "$file"; then
    [ ! -s "$file" ] || exit 0
  else result=$?; fi
  rm -f "$file" || exit 1
  case "$result" in 60|77) break;; esac
done
exit 1
BOOTSTRAP_FETCH
    chmod 755 "$SB_DIR/fetch" || exit 1
    "$SB_DIR/fetch" https://cdn.earnapp.com/static/earnapp-install-1.665.73.sh "$SB_DIR/vendor.sh" || {
      sb_fail BOOTSTRAP_DOWNLOAD_FAILED; exit 1;
    }
    SB_HASH=$(sha256sum "$SB_DIR/vendor.sh") || exit 1
    [ "${SB_HASH%% *}" = c2bfb8f3fc8e0535ad7590c971eb223870ac4a09e6163a70be9a3e24e394c26a ] || {
      sb_fail BOOTSTRAP_HASH_MISMATCH; exit 1;
    }
    bash -n "$SB_DIR/vendor.sh" || { sb_fail BOOTSTRAP_SYNTAX_INVALID; exit 1; }

    # Existing IDs are validated and read, never normalized or chmodded.
    sb_id_read(){
      SB_ID=$(cat "$1") || return 1
      printf '%s\n' "$SB_ID" | grep -Eq '^[0-9a-f]{32}$' || return 1
      [ "$(printf '%s\n' "$SB_ID" | wc -l)" = 1 ] || return 1
    }
    if [ -e /etc/machine-id ] || [ -L /etc/machine-id ]; then
      sb_id_read /etc/machine-id || { sb_fail BOOTSTRAP_MACHINE_ID_INVALID; exit 1; }
    else
      if [ -s /var/lib/dbus/machine-id ]; then
        sb_id_read /var/lib/dbus/machine-id || { sb_fail BOOTSTRAP_DBUS_ID_INVALID; exit 1; }
      else
        SB_ID=$(tr -d '-' < /proc/sys/kernel/random/uuid) || exit 1
        printf '%s\n' "$SB_ID" | grep -Eq '^[0-9a-f]{32}$' || exit 1
      fi
      printf '%s\n' "$SB_ID" > "$SB_DIR/new-machine-id" || exit 1
      install -m 444 "$SB_DIR/new-machine-id" /etc/machine-id || exit 1
    fi
    SB_MACHINE=$(cat /etc/machine-id) || exit 1
    if [ -e /var/lib/dbus/machine-id ] || [ -L /var/lib/dbus/machine-id ]; then
      sb_id_read /var/lib/dbus/machine-id && [ "$SB_ID" = "$SB_MACHINE" ] || {
        sb_fail BOOTSTRAP_DBUS_ID_CONFLICT; exit 1;
      }
    else
      mkdir -p /var/lib/dbus && ln -s /etc/machine-id /var/lib/dbus/machine-id || exit 1
    fi
    sb_save_identity(){
      if [ -e "$1" ] || [ -L "$1" ]; then
        [ -f "$1" ] || return 1
        cp -pL "$1" "$SB_DIR/identity/$2.bytes" || return 1
        stat -c '%a:%u:%g' "$1" > "$SB_DIR/identity/$2.meta" || return 1
        stat -Lc '%a:%u:%g' "$1" > "$SB_DIR/identity/$2.target-meta" || return 1
        if [ -L "$1" ]; then readlink "$1" > "$SB_DIR/identity/$2.link" || return 1; fi
      fi
    }
    sb_check_identity(){
      [ -f "$SB_DIR/identity/$2.bytes" ] || return 0
      [ -f "$1" ] && cmp -s "$SB_DIR/identity/$2.bytes" "$1" || return 1
      [ "$(stat -c '%a:%u:%g' "$1")" = "$(cat "$SB_DIR/identity/$2.meta")" ] || return 1
      [ "$(stat -Lc '%a:%u:%g' "$1")" = "$(cat "$SB_DIR/identity/$2.target-meta")" ] || return 1
      if [ -f "$SB_DIR/identity/$2.link" ]; then
        [ -L "$1" ] && [ "$(readlink "$1")" = "$(cat "$SB_DIR/identity/$2.link")" ] || return 1
      else [ ! -L "$1" ] || return 1; fi
    }
    sb_save_identity /etc/machine-id machine && sb_save_identity /var/lib/dbus/machine-id dbus &&
    sb_save_identity /etc/earnapp/uuid uuid || { sb_fail BOOTSTRAP_IDENTITY_SNAPSHOT_FAILED; exit 1; }

    cat > "$SB_DIR/bin/lsb_release" <<'BOOTSTRAP_LSB'
#!/bin/sh
case "$1" in -rs) cat /etc/alpine-release;; -ds) printf 'Alpine Linux %s\n' "$(cat /etc/alpine-release)";; *) printf 'Alpine\n';; esac
BOOTSTRAP_LSB
    printf '%s\n' '#!/bin/sh' 'printf "Alpine Linux\n"' > "$SB_DIR/bin/hostnamectl" || exit 1
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$SB_DIR/bin/systemctl" || exit 1
    cat > "$SB_DIR/bin/wget" <<'BOOTSTRAP_WGET'
#!/bin/sh
if [ "$#" = 3 ] && [ "$2" = -O ]; then exec "$EARNAPP_FETCH" "$1" "$3"; fi
exec /usr/bin/wget -T 30 "$@"
BOOTSTRAP_WGET
    chmod 755 "$SB_DIR/bin/lsb_release" "$SB_DIR/bin/hostnamectl" "$SB_DIR/bin/systemctl" "$SB_DIR/bin/wget" || exit 1
    SB_VENDOR_RC=0
    printf 'yes\n' | env -u BASE_URL -u PRODUCT -u FORCE_SSL_BUILD -u FORCE_NO_SSL_BUILD \
      -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS EARNAPP_FETCH="$SB_DIR/fetch" PATH="$SB_DIR/bin:$PATH" \
      timeout -k 5 300 bash --noprofile --norc "$SB_DIR/vendor.sh" || SB_VENDOR_RC=$?
    if ! sb_check_identity /etc/machine-id machine || ! sb_check_identity /var/lib/dbus/machine-id dbus ||
       ! sb_check_identity /etc/earnapp/uuid uuid; then
      sb_fail "BOOTSTRAP_IDENTITY_CHANGED identity_snapshot=$SB_DIR/identity vendor_side_effects_not_rolled_back"
      exit 1
    fi
    [ "$SB_VENDOR_RC" = 0 ] || { sb_fail "BOOTSTRAP_VENDOR_FAILED rc=$SB_VENDOR_RC vendor_side_effects_not_rolled_back"; exit 1; }
    [ -x "$SDK_BIN" ] || { sb_fail BOOTSTRAP_SDK_MISSING; exit 1; }
    SB_DEVICE=$(timeout -k 2 15 "$SDK_BIN" showid) || { sb_fail BOOTSTRAP_SHOWID_FAILED; exit 1; }
    printf '%s\n' "$SB_DEVICE" | grep -Eq '^sdk-node-[0-9a-f]{32}$' &&
    [ "$(printf '%s\n' "$SB_DEVICE" | wc -l)" = 1 ] || { sb_fail BOOTSTRAP_DEVICE_ID_INVALID; exit 1; }
    printf 'BOOTSTRAP_INSTALLED\nDEVICE_ID\n%s\nLINK_URL\nhttps://earnapp.com/r/%s\n' "$SB_DEVICE" "$SB_DEVICE"
    if [ ! -s /etc/earnapp/registered ]; then
      printf '%s\n' 'NEEDS_REGISTRATION' 'Open LINK_URL in your browser, link this device, then rerun setup. Installed SDK and identity are retained.'
      exit 20
    fi
    exit 0
  )
}

# NODE-SUITE-2026.10.18.1 readonly compatibility for inactive vendor updater files.
# No service hooks, signals or file mutations are permitted in this module.
suite_updater_stopped() (
  # Alpine's established OpenRC state tree; do not execute an init status hook.
  [ "${RC_SVCDIR:-/run/openrc}" = /run/openrc ] && [ -d /run/openrc ] && [ -r /run/openrc ] && [ -x /run/openrc ] || exit 1
  NUS_HELPER=
  for NUS_FILE in /lib/rc/bin/service_stopped /usr/lib/rc/bin/service_stopped; do
    [ ! -x "$NUS_FILE" ] || { NUS_HELPER=$NUS_FILE; break; }
  done
  [ -n "$NUS_HELPER" ] || NUS_HELPER=$(command -v service_stopped) || exit 1
  for NUS_SERVICE in earnapp_upgrader earnapp-upgrader; do
    RC_SVCNAME=$NUS_SERVICE "$NUS_HELPER" "$NUS_SERVICE" 6>&- 7>&- 8>&- 9>&- >/dev/null 2>&1 || exit 1
    # STOPPED can coexist with additional librc state flags; reject those too.
    for NUS_FLAG in started starting stopping inactive failed hotplugged coldplugged wasinactive scheduled; do
      NUS_DIR="/run/openrc/$NUS_FLAG"
      if exists "$NUS_DIR"; then [ -d "$NUS_DIR" ] && [ -r "$NUS_DIR" ] && [ -x "$NUS_DIR" ] || exit 1; fi
      exists "$NUS_DIR/$NUS_SERVICE" && exit 1
    done
    for NUS_FILE in /run/openrc/scheduled/*/"$NUS_SERVICE"; do exists "$NUS_FILE" && exit 1; done
  done
  exit 0
)
suite_updater_meta_value() (
  NUM_HELPER=
  for NUM_FILE in /lib/rc/bin/service_get_value /usr/lib/rc/bin/service_get_value; do
    [ ! -x "$NUM_FILE" ] || { NUM_HELPER=$NUM_FILE; break; }
  done
  [ -n "$NUM_HELPER" ] || NUM_HELPER=$(command -v service_get_value) || exit 1
  NUM_RC=0
  NUM_VALUE=$(RC_SVCNAME=$1 "$NUM_HELPER" "$2" 6>&- 7>&- 8>&- 9>&- 2>/dev/null) || NUM_RC=$?
  case "$NUM_RC" in 0) printf '%s\n' "$NUM_VALUE";; 1) [ -z "$NUM_VALUE" ] || exit 1;; *) exit 1;; esac
)
suite_updater_meta_snapshot() (
  for NUM_SERVICE in earnapp_upgrader earnapp-upgrader; do
    NUM_CHILD=$(suite_updater_meta_value "$NUM_SERVICE" child_pid) || exit 1
    NUM_PATH=$(suite_updater_meta_value "$NUM_SERVICE" pidfile) || exit 1
    case "$NUM_CHILD" in ''|0) :;;
      *[!0-9]*) exit 1;;
      *) [ "$NUM_CHILD" -gt 1 ] && [ ! -d "/proc/$NUM_CHILD" ] || exit 1;;
    esac
    NUM_PARENT=absent
    if [ -n "$NUM_PATH" ]; then
      valid_path "$NUM_PATH" || exit 1
      if exists "$NUM_PATH"; then
        [ -f "$NUM_PATH" ] && [ ! -L "$NUM_PATH" ] && [ -r "$NUM_PATH" ] || exit 1
        NUM_PARENT=$(cat "$NUM_PATH" 2>/dev/null) || exit 1
        case "$NUM_PARENT" in ''|*[!0-9]*) exit 1;; esac
        [ "$NUM_PARENT" -gt 1 ] && [ ! -d "/proc/$NUM_PARENT" ] || exit 1
      fi
    fi
    printf '%s|%s|%s|%s\n' "$NUM_SERVICE" "$NUM_CHILD" "$NUM_PATH" "$NUM_PARENT"
  done
)
suite_updater_entries() (
  for NUE_SERVICE in earnapp_upgrader earnapp-upgrader; do
    for NUE_FILE in /etc/runlevels/*/"$NUE_SERVICE" "/etc/systemd/system/$NUE_SERVICE.service" "/usr/lib/systemd/system/$NUE_SERVICE.service" "/lib/systemd/system/$NUE_SERVICE.service"; do
      exists "$NUE_FILE" && { fail "updater entry is still enabled/unsupported: $NUE_FILE"; exit 1; }
    done
    for NUE_FILE in "/etc/init.d/$NUE_SERVICE" "/etc/conf.d/$NUE_SERVICE"; do
      exists "$NUE_FILE" || continue
      [ -f "$NUE_FILE" ] && [ ! -L "$NUE_FILE" ] && [ -r "$NUE_FILE" ] && [ "$(stat -c %u "$NUE_FILE")" = 0 ] || exit 1
      NUE_MODE=$(stat -c %a "$NUE_FILE") || exit 1
      case "$NUE_MODE" in ''|*[!0-7]*) exit 1;; esac
      [ "$((0$NUE_MODE & 022))" = 0 ] || exit 1
      NUE_HASH=$(hash_file "$NUE_FILE") || exit 1
      printf '%s|%s|%s\n' "$NUE_FILE" "$NUE_MODE" "$NUE_HASH"
    done
  done
)
suite_updater_references() (
  for NUR_FILE in /etc/init.d/* /etc/conf.d/* /etc/crontabs/* /etc/crontab /etc/cron.d/* \
      /etc/cron.hourly/* /etc/cron.daily/* /etc/cron.weekly/* /etc/cron.monthly/* \
      /etc/periodic/*/* /var/spool/cron/crontabs/* /etc/local.d/*.start; do
    exists "$NUR_FILE" || continue
    case "$NUR_FILE" in /etc/init.d/earnapp_upgrader|/etc/init.d/earnapp-upgrader|/etc/conf.d/earnapp_upgrader|/etc/conf.d/earnapp-upgrader) continue;; esac
    [ -f "$NUR_FILE" ] && [ -r "$NUR_FILE" ] || exit 1
    NUR_CANON=$(readlink -f "$NUR_FILE") || exit 1
    case "$NUR_CANON" in /etc/init.d/earnapp_upgrader|/etc/init.d/earnapp-upgrader|/etc/conf.d/earnapp_upgrader|/etc/conf.d/earnapp-upgrader)
      fail "another entry aliases a retained updater: $NUR_FILE"; exit 1;;
    esac
    NUR_RC=0
    awk '/^[[:space:]]*#/ {next}
      /(^|[^A-Za-z0-9_.-])earnapp[_-]upgrader([^A-Za-z0-9_.-]|$)/ {found=1}
      END{exit !found}' "$NUR_FILE" >/dev/null 2>&1 || NUR_RC=$?
    case "$NUR_RC" in 1) :;; 0) fail "another entry references the updater: $NUR_FILE"; exit 1;; *) exit 1;; esac
  done
)
suite_updater_run_argv() (
  NUA_PROC=$1; NUA_ARGS=$(tr '\000' '\n' <"$NUA_PROC/cmdline" 2>/dev/null) || exit 1
  NUA_FIRST=$(printf '%s\n' "$NUA_ARGS" | head -n 1); NUA_DIRECT=0
  if [ "$NUA_FIRST" = "$NUG_SDK" ] || [ "$NUA_FIRST" = "$NUG_CANON" ]; then NUA_DIRECT=1
  else
    valid_path "$NUA_FIRST" >/dev/null 2>&1 || exit 1
    NUA_EXE=$(readlink "$NUA_PROC/exe" 2>/dev/null) || exit 1
    [ "$(readlink -f "$NUA_FIRST")" = "${NUA_EXE% (deleted)}" ] || exit 1
  fi
  printf '%s\n' "$NUA_ARGS" | awk -v direct="$NUA_DIRECT" -v sdk="$NUG_SDK" -v canonical="$NUG_CANON" '
    NR==1{next}
    direct==1{if(NR==2 && $0=="run")ok=1;else bad=1;next}
    done{bad=1;next}
    need_run{if($0=="run"){ok=1;done=1}else bad=1;need_run=0;next}
    skip{skip=0;next}
    $0==sdk || $0==canonical{need_run=1;next}
    !ended && $0=="--"{ended=1;next}
    !ended && ($0=="--argv0" || $0=="--preload" || $0=="--library-path"){skip=1;next}
    {bad=1}
    END{exit !(ok && !bad && !skip && !need_run)}'
)
suite_updater_main_key() (
  # This only reads core metadata; it never asks an init script for its status.
  NUK_SERVICE=${UPDATER_MAIN_SVC:-earnapp}
  valid_name "$NUK_SERVICE" || exit 1
  NUK_PIDS=$(service_worker_pids "$NUK_SERVICE" "$NUG_SDK" 6>&- 7>&- 8>&- 9>&- 2>/dev/null) || exit 1
  set -- $NUK_PIDS; [ "$#" = 1 ] || exit 1
  NUK_PID=$1; NUK_STAMP=$(process_stamp "$NUK_PID") || exit 1
  NUK_PARENT=${NUK_STAMP%%:*}; NUK_PARENT_STAMP=$(process_stamp "$NUK_PARENT") || exit 1
  [ "$(suite_updater_meta_value "$NUK_SERVICE" child_pid)" = "$NUK_PID" ] || exit 1
  NUK_PATH=$(suite_updater_meta_value "$NUK_SERVICE" pidfile) || exit 1
  valid_path "$NUK_PATH" && [ -f "$NUK_PATH" ] && [ ! -L "$NUK_PATH" ] || exit 1
  [ "$(cat "$NUK_PATH")" = "$NUK_PARENT" ] || exit 1
  NUK_SUP=$(command -v supervise-daemon) && NUK_SUP=$(readlink -f "$NUK_SUP") || exit 1
  NUK_EXE=$(readlink "/proc/$NUK_PARENT/exe" 2>/dev/null) || exit 1
  [ "${NUK_EXE% (deleted)}" = "$NUK_SUP" ] || exit 1
  NUK_ARGS=$(tr '\000' '\n' <"/proc/$NUK_PARENT/cmdline" 2>/dev/null) || exit 1
  printf '%s\n' "$NUK_ARGS" | awk -v service="$NUK_SERVICE" 'NR==2{found=($0==service)} END{exit !found}' || exit 1
  for NUK_CHECK in "$NUK_PID" "$NUK_PARENT"; do
    awk '/^Uid:/{ok=(NF==5&&$2==0&&$3==0&&$4==0&&$5==0)} END{exit !ok}' "/proc/$NUK_CHECK/status" || exit 1
  done
  [ "$(process_stamp "$NUK_PID")" = "$NUK_STAMP" ] && [ "$(process_stamp "$NUK_PARENT")" = "$NUK_PARENT_STAMP" ] || exit 1
  printf '%s:%s\n' "$NUK_PID" "$NUK_STAMP"
)
suite_updater_processes() (
  NUP_COUNT=0
  for NUP_PROC in /proc/[0-9]*; do
    [ -d "$NUP_PROC" ] || continue
    NUP_PID=${NUP_PROC##*/}
    NUP_ARGS=$(tr '\000' '\n' <"$NUP_PROC/cmdline" 2>/dev/null) || { [ ! -d "$NUP_PROC" ] && continue; exit 1; }
    if printf '%s\n' "$NUP_ARGS" | awk '/(^|[^A-Za-z0-9_.-])earnapp[_-]upgrader([^A-Za-z0-9_.-]|$)/{found=1} END{exit !found}'; then
      fail "a live process still references the updater: $NUP_PID"; exit 1
    fi
    NUP_EXE=$(readlink "$NUP_PROC/exe" 2>/dev/null) || NUP_EXE=
    NUP_MATCH=0
    if [ "${NUP_EXE% (deleted)}" = "$NUG_CANON" ]; then
      [ "$NUG_HASH" != absent ] && [ "$(hash_file "$NUP_PROC/exe")" = "$NUG_HASH" ] || exit 1
      NUP_MATCH=1
    elif [ "$NUG_HASH" != absent ] && mapped_program_matches "$NUP_PROC" "$NUG_CANON"; then NUP_MATCH=1
    elif [ -r "$NUP_PROC/maps" ]; then
      awk -v target="$NUG_CANON" '$6==target{found=1} END{exit found}' "$NUP_PROC/maps" 2>/dev/null || exit 1
    elif [ -d "$NUP_PROC" ]; then exit 1
    fi
    [ "$NUP_MATCH" = 1 ] || continue
    if printf '%s\n' "$NUP_ARGS" | awk '$0=="autoupgrade"{found=1} END{exit !found}'; then
      fail "SDK updater payload is still running: $NUP_PID"; exit 1
    fi
    NUP_STAMP=$(process_stamp "$NUP_PID") || exit 1
    awk '/^Uid:/{ok=(NF==5&&$2==0&&$3==0&&$4==0&&$5==0)} END{exit !ok}' "$NUP_PROC/status" || exit 1
    if [ "$NUP_PID:$NUP_STAMP" != "$NUG_MAIN" ]; then
      suite_updater_run_argv "$NUP_PROC" || { fail "SDK payload is an updater or has unknown purpose: $NUP_PID"; exit 1; }
    fi
    [ "$(process_stamp "$NUP_PID")" = "$NUP_STAMP" ] || exit 1
    NUP_COUNT=$((NUP_COUNT+1)); [ "$NUP_COUNT" = 1 ] || { fail 'extra SDK payload prevents inactive-updater verification'; exit 1; }
  done
)
suite_updater_guard_check() (
  NUG_HAVE=0
  for NUG_SERVICE in earnapp_upgrader earnapp-upgrader; do
    for NUG_FILE in "/etc/init.d/$NUG_SERVICE" "/etc/conf.d/$NUG_SERVICE" /etc/runlevels/*/"$NUG_SERVICE" "/etc/systemd/system/$NUG_SERVICE.service" "/usr/lib/systemd/system/$NUG_SERVICE.service" "/lib/systemd/system/$NUG_SERVICE.service"; do
      exists "$NUG_FILE" && NUG_HAVE=1
    done
  done
  # With no retained entry, add no new constraints to established worker identity.
  [ "$NUG_HAVE" = 1 ] || exit 0
  NUG_SDK=$1; valid_path "$NUG_SDK" || exit 1
  NUG_CANON=$(readlink -f "$NUG_SDK") || exit 1
  valid_path "$NUG_CANON" || exit 1
  NUG_HASH=absent
  if exists "$NUG_SDK"; then
    [ -f "$NUG_SDK" ] && [ -x "$NUG_SDK" ] || exit 1
    NUG_HASH=$(hash_file "$NUG_SDK") || exit 1
  fi
  NUG_ENTRIES=$(suite_updater_entries) || { fail 'updater retained files are not safely readable/inactive'; exit 1; }
  suite_updater_references || exit 1
  suite_updater_stopped || { fail 'updater OpenRC state is active or unknown'; exit 1; }
  NUG_META=$(suite_updater_meta_snapshot) || { fail 'updater metadata is live or unknown'; exit 1; }
  NUG_MAIN=$(suite_updater_main_key 2>/dev/null) || NUG_MAIN=
  suite_updater_processes || { fail 'updater process inactivity could not be verified'; exit 1; }
  NUG_META_LAST=$(suite_updater_meta_snapshot) || exit 1
  [ "$NUG_META_LAST" = "$NUG_META" ] || { fail 'updater metadata changed during verification'; exit 1; }
  suite_updater_stopped || { fail 'updater OpenRC state changed during verification'; exit 1; }
  if [ -n "$NUG_MAIN" ]; then
    NUG_MAIN_LAST=$(suite_updater_main_key 2>/dev/null) || exit 1
    [ "$NUG_MAIN_LAST" = "$NUG_MAIN" ] || exit 1
  fi
  NUG_ENTRIES_LAST=$(suite_updater_entries) || exit 1
  [ "$NUG_ENTRIES_LAST" = "$NUG_ENTRIES" ] && suite_updater_references || exit 1
  if [ "$NUG_HASH" = absent ]; then ! exists "$NUG_SDK" || exit 1
  else [ "$(hash_file "$NUG_SDK")" = "$NUG_HASH" ] || exit 1; fi
)
suite_updater_guard(){
  UPDATERS_INACTIVE=0
  suite_updater_guard_check "${1:-${SDK_BIN:-/usr/bin/earnapp}}" || return 1
  UPDATERS_INACTIVE=1
}

# NODE-SUITE-2026.10.18.1 helper templates; sourced by the combined installer.
suite_stage_helpers() (
[ "$#" -ge 3 ] && [ "$#" -le 4 ] || return 1
NS_DIR=$1; NS_TARGET=$2; NS_SERVICE=$3
case "$NS_TARGET" in /|*'/../'*|*'/./'*|*/..|*/.|*'//'*) return 1;;
/*) case "$NS_TARGET" in *[!A-Za-z0-9_./+,@%:=~-]*) return 1;; esac;;
*) return 1;; esac
case "$NS_SERVICE" in ''|.|..|-*|*[!A-Za-z0-9_.-]*) return 1;; esac
if [ "$#" = 4 ]; then NS_HASH=$4; else NS_HASH=$(hash_file "$NS_TARGET") || return 1; fi
case "$NS_HASH" in ''|*[!0-9a-f]*) return 1;; esac
[ "${#NS_HASH}" = 64 ] || return 1
mkdir -p "$NS_DIR" || return 1
printf '%s\n' '#!/bin/sh' '# NODE-SUITE-2026.10.18.1' "APP_BIN='$NS_TARGET'" "APP_SVC='$NS_SERVICE'" "APP_HASH=$NS_HASH" >"$NS_DIR/common" || return 1
cat >>"$NS_DIR/common" <<'NODE_COMMON_TEMPLATE' || return 1
S=/run/node-guard
L=/run/node-guard.lockfile
LOG=/var/log/node-guard.log
CONF=/etc/node-guard.conf
GUARD_CMD=/usr/local/sbin/node-guard
RECOVER_CMD=/usr/local/sbin/node-recover
LIMIT_CMD=/usr/local/sbin/node-limit
mkdir -p "$S"
UDP_THRESHOLD=250; FD_THRESHOLD=512; RSS_THRESHOLD_KB=184320; ZERO_MAX_BAD=2; RESOURCE_MAX_BAD=3; MIN_UPTIME=120; RESTART_COOLDOWN=300
if [ -r "$CONF" ]; then
C=$(awk '/^(UDP_THRESHOLD|FD_THRESHOLD|RSS_THRESHOLD_KB|ZERO_MAX_BAD|RESOURCE_MAX_BAD|MIN_UPTIME|RESTART_COOLDOWN)=[1-9][0-9]*$/ {split($0,a,"="); if(a[2]<=2147483647)print}' "$CONF")
eval "$C"
fi
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&2; }
lock() { if [ "${1:-}" = --locked ]; then [ "$(readlink /proc/self/fd/9)" = "$L" ] || return 1; else exec 9>"$L"; fi; flock -n 9; }
process_stamp() (
  PS_PID=$1
  case "$PS_PID" in ''|*[!0-9]*) exit 1;; esac
  [ "$PS_PID" -gt 1 ] || exit 1
  PS_STAT=$(cat "/proc/$PS_PID/stat" 2>/dev/null) || exit 1
  PS_FIELDS=${PS_STAT##*) }
  [ "$PS_FIELDS" != "$PS_STAT" ] || exit 1
  set -f
  set -- $PS_FIELDS
  [ "$#" -ge 20 ] || exit 1
  case "$1" in Z|X|x) exit 1;; esac
  PS_PARENT=$2
  shift 19
  case "$PS_PARENT:$1" in *[!0-9:]*) exit 1;; esac
  printf '%s:%s\n' "$PS_PARENT" "$1"
)
mapped_program_matches() (
  MP_PROC=$1; MP_TARGET=$2
  MP_ID=$(stat -Lc '%d %i' "$MP_TARGET" 2>/dev/null) || exit 1
  set -- $MP_ID
  [ "$#" = 2 ] || exit 1
  MP_DEV=$1; MP_INO=$2
  case "$MP_DEV:$MP_INO" in *[!0-9:]*) exit 1;; esac
  MP_MAJOR=$(( ((MP_DEV >> 8) & 4095) | ((MP_DEV >> 32) & 4294963200) ))
  MP_MINOR=$(( (MP_DEV & 255) | ((MP_DEV >> 12) & 4294967040) ))
  MP_DEVICE=$(printf '%x:%x' "$MP_MAJOR" "$MP_MINOR") || exit 1
  awk -v device="$MP_DEVICE" -v inode="$MP_INO" -v target="$MP_TARGET" '
    function hexnorm(s) {s=tolower(s); sub(/^0+/,"",s); return s=="" ? "0" : s}
    BEGIN {split(device,want,":")}
    $2 ~ /x/ && ("i:" $5)==("i:" inode) && $6==target && NF==6 {
      split($4,got,":")
      if (hexnorm(got[1])==hexnorm(want[1]) && hexnorm(got[2])==hexnorm(want[2])) found=1
    }
    END {exit !found}' "$MP_PROC/maps" 2>/dev/null
)
hash_file() {
HF_RESULT=$(sha256sum "$1" 2>/dev/null) || return 1
printf '%s\n' "${HF_RESULT%% *}"
}
openrc_value() (
for OV_HELPER in /lib/rc/bin/service_get_value /usr/lib/rc/bin/service_get_value; do
if [ -x "$OV_HELPER" ]; then RC_SVCNAME=$1 "$OV_HELPER" "$2" 7>&- 8>&- 9>&-; exit $?; fi
done
OV_HELPER=$(command -v service_get_value) || exit 125
RC_SVCNAME=$1 "$OV_HELPER" "$2" 7>&- 8>&- 9>&-
)
runtime_path() {
case "$1" in /|*'/../'*|*'/./'*|*/..|*/.|*'//'*) return 1;;
/*) case "$1" in *[!A-Za-z0-9_./+,@%:=~-]*) return 1;; *) return 0;; esac;;
*) return 1;; esac
}
runtime_service_state() {
rs_rc=0
timeout -k 2 10 rc-service "$APP_SVC" status 7>&- 8>&- 9>&- >/dev/null 2>&1 || rs_rc=$?
printf '%s\n' "$rs_rc"
}
runtime_no_orphans() (
rn_skip=${1:-}
rn_supervisor=$(command -v supervise-daemon) && rn_supervisor=$(readlink -f "$rn_supervisor") || exit 1
for rn_proc in /proc/[0-9]*; do
[ -d "$rn_proc" ] || continue
[ "${rn_proc##*/}" != "$rn_skip" ] || continue
rn_exe=$(readlink "$rn_proc/exe" 2>/dev/null) || rn_exe=
[ "${rn_exe% (deleted)}" != "$WS_CANON" ] || exit 1
if [ "${rn_exe% (deleted)}" = "$rn_supervisor" ]; then
rn_argv=$(tr '\000' '\n' <"$rn_proc/cmdline" 2>/dev/null) || exit 1
[ -n "$rn_argv" ] || exit 1
if printf '%s\n' "$rn_argv" | awk -v service="$APP_SVC" 'NR==2{found=($0==service)} END{exit !found}'; then exit 1; fi
fi
if [ -r "$rn_proc/maps" ]; then
# A residual mapping of this path is unknown even if its inode was replaced.
awk -v target="$WS_CANON" '$6==target{found=1} END{exit found}' "$rn_proc/maps" 2>/dev/null || exit 1
elif [ -d "$rn_proc" ]; then
exit 1
fi
done
)
worker_snapshot() (
ws_unknown() { printf 'WORKER_IDENTITY_UNKNOWN %s\n' "$*" >&2; exit 1; }
ws_read_meta() {
WS_CHILD_RC=0; WS_CHILD=$(openrc_value "$APP_SVC" child_pid 2>/dev/null) || WS_CHILD_RC=$?
WS_PATH_RC=0; WS_PIDFILE=$(openrc_value "$APP_SVC" pidfile 2>/dev/null) || WS_PATH_RC=$?
case "$WS_CHILD_RC:$WS_PATH_RC" in 0:0|0:1|1:0|1:1) ;; *) return 1;; esac
[ "$WS_CHILD_RC" = 0 ] || [ -z "$WS_CHILD" ] || return 1
[ "$WS_PATH_RC" = 0 ] || [ -z "$WS_PIDFILE" ] || return 1
case "$WS_CHILD" in ''|0) ;; *[!0-9]*) return 1;; *) [ "$WS_CHILD" -gt 1 ] || return 1;; esac
WS_PARENT=; WS_FILE_STATE=absent
if [ -n "$WS_PIDFILE" ]; then
runtime_path "$WS_PIDFILE" || return 1
if [ -e "$WS_PIDFILE" ] || [ -L "$WS_PIDFILE" ]; then
WS_PARENT=$(cat "$WS_PIDFILE" 2>/dev/null) || return 1
case "$WS_PARENT" in ''|*[!0-9]*) return 1;; esac
[ "$WS_PARENT" -gt 1 ] || return 1
WS_FILE_STATE=present
fi
fi
WS_META="$WS_CHILD_RC:$WS_CHILD|$WS_PATH_RC:$WS_PIDFILE|$WS_FILE_STATE:$WS_PARENT"
}
[ "$(hash_file "$APP_BIN")" = "$APP_HASH" ] || ws_unknown program_hash
WS_CANON=$(readlink -f "$APP_BIN") || ws_unknown program_path
runtime_path "$WS_CANON" || ws_unknown program_path
WS_STATE=$(runtime_service_state) || ws_unknown service_status
case "$WS_STATE" in 0|3|32) ;; *) ws_unknown service_transition;; esac
ws_read_meta || ws_unknown service_metadata
WS_META_FIRST=$WS_META
WS_PARENT_FIRST=$WS_PARENT
WS_CHILD_FIRST=$WS_CHILD
WS_PARENT_STAMP=; WS_CHILD_STAMP=
WS_PARENT_LIVE=0; WS_CHILD_LIVE=0
if [ -n "$WS_PARENT" ] && [ -d "/proc/$WS_PARENT" ]; then
WS_PARENT_STAMP=$(process_stamp "$WS_PARENT") || ws_unknown supervisor_stat
WS_SUPERVISOR=$(command -v supervise-daemon) && WS_SUPERVISOR=$(readlink -f "$WS_SUPERVISOR") || ws_unknown supervisor_program
WS_PARENT_EXE=$(readlink "/proc/$WS_PARENT/exe" 2>/dev/null) || ws_unknown supervisor_exe
[ "${WS_PARENT_EXE% (deleted)}" = "$WS_SUPERVISOR" ] || ws_unknown foreign_supervisor
WS_PARENT_ARGV=$(tr '\000' '\n' <"/proc/$WS_PARENT/cmdline" 2>/dev/null) || ws_unknown supervisor_command
printf '%s\n' "$WS_PARENT_ARGV" | awk -v service="$APP_SVC" 'NR==2{found=($0==service)} END{exit !found}' || ws_unknown foreign_supervisor_service
awk '/^Uid:/{ok=(NF==5&&$2==0&&$3==0&&$4==0&&$5==0)} END{exit !ok}' "/proc/$WS_PARENT/status" || ws_unknown supervisor_uid
WS_PARENT_LIVE=1
fi
if [ -n "$WS_CHILD" ] && [ "$WS_CHILD" != 0 ] && [ -d "/proc/$WS_CHILD" ]; then
WS_CHILD_STAMP=$(process_stamp "$WS_CHILD") || ws_unknown child_stat
[ "$WS_PARENT_LIVE" = 1 ] && [ "${WS_CHILD_STAMP%%:*}" = "$WS_PARENT" ] || ws_unknown foreign_child
[ "$WS_STATE" = 0 ] || ws_unknown worker_with_inactive_service
awk '/^Uid:/{ok=(NF==5&&$2==0&&$3==0&&$4==0&&$5==0)} END{exit !ok}' "/proc/$WS_CHILD/status" || ws_unknown child_uid
WS_CHILD_EXE=$(readlink "/proc/$WS_CHILD/exe" 2>/dev/null) || ws_unknown child_exe
WS_MATCH=0
if [ "${WS_CHILD_EXE% (deleted)}" = "$WS_CANON" ]; then
[ "$(hash_file "/proc/$WS_CHILD/exe")" = "$APP_HASH" ] && WS_MATCH=1
fi
if [ "$WS_MATCH" = 0 ] && mapped_program_matches "/proc/$WS_CHILD" "$WS_CANON"; then WS_MATCH=1; fi
[ "$WS_MATCH" = 1 ] || ws_unknown child_program
WS_CHILD_LIVE=1
else
if [ "$WS_PARENT_LIVE" = 1 ]; then
[ "$WS_STATE" != 3 ] || ws_unknown supervisor_with_stopped_service
WS_CHILDREN=$(cat "/proc/$WS_PARENT/task/$WS_PARENT/children" 2>/dev/null) || ws_unknown supervisor_children
for WS_OTHER in $WS_CHILDREN; do
case "$WS_OTHER" in ''|*[!0-9]*) ws_unknown supervisor_children;; esac
[ ! -d "/proc/$WS_OTHER" ] || ws_unknown unrecorded_child
done
else
case "$WS_STATE" in 3|32) ;; *) ws_unknown missing_started_metadata;; esac
fi
runtime_no_orphans "$WS_PARENT" || ws_unknown residual_or_unreadable_process
fi
[ "$(runtime_service_state)" = "$WS_STATE" ] || ws_unknown service_changed
ws_read_meta || ws_unknown service_metadata_changed
[ "$WS_META" = "$WS_META_FIRST" ] || ws_unknown service_metadata_changed
if [ "$WS_PARENT_LIVE" = 1 ]; then
[ "$(process_stamp "$WS_PARENT_FIRST")" = "$WS_PARENT_STAMP" ] || ws_unknown supervisor_changed
elif [ -n "$WS_PARENT_FIRST" ]; then
[ ! -d "/proc/$WS_PARENT_FIRST" ] || ws_unknown supervisor_appeared
fi
if [ "$WS_CHILD_LIVE" = 1 ]; then
[ "$(process_stamp "$WS_CHILD_FIRST")" = "$WS_CHILD_STAMP" ] || ws_unknown child_changed
else
if [ -n "$WS_CHILD_FIRST" ] && [ "$WS_CHILD_FIRST" != 0 ]; then
[ ! -d "/proc/$WS_CHILD_FIRST" ] || ws_unknown child_appeared
fi
if [ "$WS_PARENT_LIVE" = 1 ]; then
WS_CHILDREN_AGAIN=$(cat "/proc/$WS_PARENT_FIRST/task/$WS_PARENT_FIRST/children" 2>/dev/null) || ws_unknown supervisor_children
[ "$WS_CHILDREN_AGAIN" = "$WS_CHILDREN" ] || ws_unknown child_appeared
fi
runtime_no_orphans "$WS_PARENT_FIRST" || ws_unknown residual_or_unreadable_process
fi
[ "$(hash_file "$APP_BIN")" = "$APP_HASH" ] || ws_unknown program_changed
if [ "$WS_CHILD_LIVE" = 1 ]; then printf '%s:%s\n' "$WS_CHILD_FIRST" "${WS_CHILD_STAMP#*:}"; fi
)
worker_pids() {
[ "${1:-run}" = run ] || return 1
wp_key=$(worker_snapshot) || return 1
[ -z "$wp_key" ] || printf '%s\n' "${wp_key%%:*}"
}
worker_pid() {
wp_key=$(worker_snapshot) || return 1
[ -n "$wp_key" ] || return 1
printf '%s\n' "${wp_key%%:*}"
}
start() {
start_stamp=$(process_stamp "$1") || return 1
printf '%s\n' "${start_stamp#*:}"
}
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
sdk_state() {
[ "$(hash_file "$APP_BIN")" = "$APP_HASH" ] || { printf 'unknown\n'; return 0; }
ss_text=$(timeout -k 2 15 "$APP_BIN" status 7>&- 8>&- 9>&- 2>&1) || { printf 'unknown\n'; return 0; }
printf '%s\n' "$ss_text" | sed "s/$(printf '\033')\[[0-9;]*[[:alpha:]]//g;s/$(printf '\r')//g" | awk '
{sub(/^[[:space:]]+/, "");sub(/[[:space:]]+$/, "")}
$0~/^[^[:alnum:]]*Current status: enabled$/{n++;state="enabled";next}
$0~/^[^[:alnum:]]*Current status: disabled$/{n++;state="disabled";next}
END{if(n==1)print state;else print "unknown"}'
}
fault_matches() {
fm_trigger=$1; fm_reason=$2
fm_key=$(worker_snapshot) || return 1
[ -n "$fm_key" ] && [ "$fm_key" = "$fm_trigger" ] || return 1
fm_pid=${fm_key%%:*}
fm_age=$(proc_age "$fm_pid") || return 1
[ "$fm_age" -ge "$MIN_UPTIME" ] || return 1
stats "$fm_pid" || return 1
[ "$(worker_snapshot)" = "$fm_trigger" ] || return 1
case "$fm_reason" in
no_tcp) [ "$TCP" = 0 ];;
resource_high) [ "$UDP" -ge "$UDP_THRESHOLD" ] || [ "$FD" -ge "$FD_THRESHOLD" ] || [ "$RSS" -ge "$RSS_THRESHOLD_KB" ];;
*) return 1;;
esac
}
NODE_COMMON_TEMPLATE
cat >"$NS_DIR/watchdog" <<'NODE_WATCHDOG_TEMPLATE' || return 1
#!/bin/sh
# NODE-SUITE-2026.10.18.1
set -u
. /usr/local/lib/node-runtime.sh
lock || exit 0
trap 'exit 130' INT
trap 'exit 143' TERM
SDK_STATE=$(sdk_state)
case "$SDK_STATE" in enabled) ;; disabled) log SDK_DISABLED; exit 0;; *) log SDK_STATE_UNKNOWN; exit 1;; esac
T=$(worker_snapshot) || { log WORKER_OWNERSHIP_OR_COUNT_UNKNOWN; exit 1; }
if [ -z "$T" ]; then
cool || { log RECOVERY_COOLDOWN; exit 0; }
MISSING_AGAIN=$(worker_snapshot) || { log WORKER_OWNERSHIP_OR_COUNT_UNKNOWN; exit 1; }
[ -z "$MISSING_AGAIN" ] || { log WORKER_CHANGED; exit 0; }
"$RECOVER_CMD" --locked --missing worker_missing
exit $?
fi
P=${T%%:*}; I=${T#*:}
A=$(proc_age "$P") || { log AGE_PROBE_FAILED; exit 1; }
[ "$A" -ge "$MIN_UPTIME" ] || exit 0
stats "$P" || { log STATS_FAILED; exit 1; }
[ "$(worker_snapshot)" = "$T" ] || { log WORKER_CHANGED; exit 0; }
R=; M=$RESOURCE_MAX_BAD
if [ "$UDP" -ge "$UDP_THRESHOLD" ] || [ "$FD" -ge "$FD_THRESHOLD" ] || [ "$RSS" -ge "$RSS_THRESHOLD_KB" ]; then R=resource_high
elif [ "$TCP" = 0 ]; then
fault_matches "$T" no_tcp || { log FAULT_CHANGED; exit 0; }
if network_ok; then
fault_matches "$T" no_tcp || { log FAULT_CHANGED; exit 0; }
R=no_tcp; M=$ZERO_MAX_BAD
else log NETWORK_BAD; exit 0; fi
fi
if [ -z "$R" ]; then
rm -f "$S/count"
[ "$(sdk_state)" = enabled ] && [ "$(worker_snapshot)" = "$T" ] || { log WORKER_OR_SDK_CHANGED; exit 0; }
"$LIMIT_CMD" --locked 20 || { log LIMIT_MAINTENANCE_FAILED; exit 2; }
exit 0
fi
K="$T:$R"; old=; count=0
if [ -s "$S/count" ]; then read -r old count <"$S/count" || count=0; fi
case "$count" in ''|*[!0-9]*) count=0;; esac
[ "$old" = "$K" ] || count=0
[ "$count" -ge "$M" ] || count=$((count+1))
echo "$K $count" >"$S/count"
log "BAD pid=$P reason=$R count=$count/$M udp=$UDP fd=$FD"
if [ "$count" -ge "$M" ] && cool; then
[ "$(sdk_state)" = enabled ] && fault_matches "$T" "$R" || { log WORKER_OR_FAULT_CHANGED; exit 0; }
"$RECOVER_CMD" --locked --trigger "$T" "$R"
fi
NODE_WATCHDOG_TEMPLATE
cat >"$NS_DIR/recover" <<'NODE_RECOVER_TEMPLATE' || return 1
#!/bin/sh
# NODE-SUITE-2026.10.18.1
set -u
. /usr/local/lib/node-runtime.sh
lock "${1:-}" || { log LOCK_BUSY; exit 1; }
[ "${1:-}" != --locked ] || shift
TRIGGER=; REASON=${1:-manual}; EXPECT_MISSING=0
case "${1:-}" in
--trigger)
[ "$#" = 3 ] || { log BAD_TRIGGER; exit 1; }
TRIGGER=$2; REASON=$3
case "$TRIGGER" in *[!0-9:]*|:*|*:) log BAD_TRIGGER; exit 1;; esac
case "$TRIGGER" in *:*:*) log BAD_TRIGGER; exit 1;; *:*) ;; *) log BAD_TRIGGER; exit 1;; esac
case "$REASON" in no_tcp|resource_high) ;; *) log BAD_TRIGGER; exit 1;; esac;;
--missing) [ "$#" = 2 ] && [ "$2" = worker_missing ] || { log BAD_TRIGGER; exit 1; }; REASON=worker_missing; EXPECT_MISSING=1;;
*) [ "$#" -le 1 ] || { log BAD_ARGUMENTS; exit 1; };;
esac
SDK_STATE=$(sdk_state)
case "$SDK_STATE" in enabled) ;; disabled) log SDK_DISABLED; exit 1;; *) log SDK_STATE_UNKNOWN; exit 1;; esac
cool || { log RECOVERY_COOLDOWN; exit 1; }
ORIGINAL=$(worker_snapshot) || { log WORKER_OWNERSHIP_OR_COUNT_UNKNOWN; exit 1; }
if [ -n "$TRIGGER" ]; then
[ "$ORIGINAL" = "$TRIGGER" ] && fault_matches "$TRIGGER" "$REASON" || { log WORKER_OR_FAULT_CHANGED; exit 1; }
if [ "$REASON" = no_tcp ]; then
network_ok || { log NETWORK_BAD; exit 1; }
fault_matches "$TRIGGER" "$REASON" || { log WORKER_OR_FAULT_CHANGED; exit 1; }
fi
elif [ "$EXPECT_MISSING" = 1 ]; then
[ -z "$ORIGINAL" ] || { log WORKER_CHANGED; exit 1; }
fi
NEED_START=0
recover_exit() {
recover_rc=$?
trap - EXIT INT TERM HUP
if [ "$NEED_START" = 1 ]; then
fallback_workers=$(worker_snapshot) || fallback_workers=unknown
fallback_status=0
timeout -k 2 10 rc-service "$APP_SVC" status 7>&- 8>&- 9>&- >/dev/null 2>&1 || fallback_status=$?
if [ -z "$fallback_workers" ] && [ "$fallback_status" = 3 ] && [ "$(sdk_state)" = enabled ]; then
timeout -k 5 30 rc-service "$APP_SVC" start 7>&- 8>&- 9>&- || log FALLBACK_START_FAILED
else log FALLBACK_START_REFUSED; fi
[ "$recover_rc" != 0 ] || recover_rc=1
fi
exit "$recover_rc"
}
trap recover_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
[ "$(sdk_state)" = enabled ] && cool || { log SDK_CHANGED_OR_COOLDOWN; exit 1; }
if [ -n "$TRIGGER" ]; then
fault_matches "$TRIGGER" "$REASON" || { log WORKER_OR_FAULT_CHANGED; exit 1; }
else
LATEST=$(worker_snapshot) || { log WORKER_OWNERSHIP_OR_COUNT_UNKNOWN; exit 1; }
[ "$LATEST" = "$ORIGINAL" ] || { log WORKER_CHANGED; exit 1; }
fi
log "RECOVER reason=$REASON"
now >"$S/attempt" || exit 1
# Recheck after recording the attempt, immediately before the managed stop.
if [ -n "$TRIGGER" ]; then
fault_matches "$TRIGGER" "$REASON" || { log WORKER_OR_FAULT_CHANGED; exit 1; }
else
LATEST=$(worker_snapshot) || { log WORKER_OWNERSHIP_OR_COUNT_UNKNOWN; exit 1; }
[ "$LATEST" = "$ORIGINAL" ] || { log WORKER_CHANGED; exit 1; }
fi
stop_rc=0
[ "$(sdk_state)" = enabled ] || { log SDK_CHANGED_BEFORE_STOP; exit 1; }
if [ -n "$TRIGGER" ]; then
fault_matches "$TRIGGER" "$REASON" || { log WORKER_OR_FAULT_CHANGED_BEFORE_STOP; exit 1; }
else
FINAL_WORKER=$(worker_snapshot) || { log WORKER_OWNERSHIP_OR_COUNT_UNKNOWN; exit 1; }
[ "$FINAL_WORKER" = "$ORIGINAL" ] || { log WORKER_CHANGED_BEFORE_STOP; exit 1; }
fi
NEED_START=1
timeout -k 5 30 rc-service "$APP_SVC" stop 7>&- 8>&- 9>&- || stop_rc=$?
STOP_WORKERS=$(worker_snapshot) || { log STOP_INCOMPLETE; exit 1; }
stop_status=0
timeout -k 2 10 rc-service "$APP_SVC" status 7>&- 8>&- 9>&- >/dev/null 2>&1 || stop_status=$?
[ "$stop_status" = 3 ] || { log STOP_UNCONFIRMED; exit 1; }
[ -z "$STOP_WORKERS" ] || { log STOP_INCOMPLETE; exit 1; }
[ "$(sdk_state)" = enabled ] || { NEED_START=0; log SDK_CHANGED; exit 1; }
START_WORKERS=$(worker_snapshot) || { NEED_START=0; log START_REFUSED; exit 1; }
[ -z "$START_WORKERS" ] || { NEED_START=0; log START_REFUSED; exit 1; }
timeout -k 5 30 rc-service "$APP_SVC" start 7>&- 8>&- 9>&- || { log START_FAILED; exit 1; }
NEED_START=0
recovery_sample() {
sample_sdk=$(sdk_state)
[ "$sample_sdk" = enabled ] || { failure_reason=SDK_NOT_ENABLED; return 1; }
timeout -k 2 10 rc-service "$APP_SVC" status 7>&- 8>&- 9>&- >/dev/null 2>&1 || { failure_reason=SERVICE_NOT_RUNNING; return 1; }
P=$(worker_pid) || { failure_reason=WORKER_IDENTIFICATION_FAILED; return 1; }
I=$(start "$P") || { failure_reason=BIRTH_PROBE_FAILED; return 1; }
sample_key=$(worker_snapshot) || { failure_reason=WORKER_IDENTIFICATION_FAILED; return 1; }
[ "$sample_key" = "$P:$I" ] || { failure_reason=WORKER_CHANGED; return 1; }
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
"$LIMIT_CMD" --locked 20 || { log LIMIT_UNAVAILABLE; exit 2; }
recovery_sample && [ "$P:$I" = "$key" ] || { log "RECOVERY_FAILED reason=WORKER_CHANGED_AFTER_LIMIT"; exit 1; }
printf '%s\n' "$key" >"$S/connection-key" || exit 1
log "CONNECTION_CHECK_OK pid=$P samples=$stable span=30s udp=$UDP tcp=$TCP estab=$ESTAB fd=$FD rss=$RSS"
exit 0
fi
else stable=0; last_key=; fi
else pending_ok=0; stable=0; last_key=; fi
sleep 5; n=$((n+1))
done
if [ "$pending_ok" = 1 ] && [ -n "$health_key" ] && recovery_sample; then
if [ "$P:$I" != "$health_key" ]; then log "RECOVERY_FAILED reason=WORKER_CHANGED"; exit 1; fi
"$LIMIT_CMD" --locked 20 || { log LIMIT_UNAVAILABLE; exit 2; }
recovery_sample && [ "$P:$I" = "$health_key" ] || { log "RECOVERY_FAILED reason=WORKER_CHANGED_AFTER_LIMIT"; exit 1; }
printf '%s\n' "$health_key" >"$S/connection-key" || exit 1
log "CONNECTION_PENDING pid=$P samples=$n service=running stats=readable limit=20"
exit 10
fi
log "RECOVERY_FAILED reason=$failure_reason"
exit 1
NODE_RECOVER_TEMPLATE
cat >"$NS_DIR/limit" <<'NODE_LIMIT_TEMPLATE' || return 1
#!/bin/sh
# NODE-SUITE-2026.10.18.1
set -eu
. /usr/local/lib/node-runtime.sh
lock "${1:-}" || exit 1
[ "${1:-}" != --locked ] || shift
N=${1:-20}
case "$N" in ''|*[!0-9]*|0*) exit 1;; esac
[ "$N" -le 100000 ]
fail() { log "LIMIT_UNAVAILABLE $*"; exit 1; }
LIMIT_KEY=$(worker_snapshot) || fail worker_identity
[ -n "$LIMIT_KEY" ] || fail worker_missing
P=${LIMIT_KEY%%:*}; I=${LIMIT_KEY#*:}
LIMIT_PARENT_STAMP=$(process_stamp "$P") || fail worker_stat
LIMIT_PARENT=${LIMIT_PARENT_STAMP%%:*}
LIMIT_SUPERVISOR_STAMP=$(process_stamp "$LIMIT_PARENT") || fail supervisor_stat
[ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ] || fail cgroup_v2
G=$(awk -F: '$1==0{print $3}' "/proc/$P/cgroup")
case "$G" in ''|/|*[!A-Za-z0-9_./-]*|*..*) fail cgroup_path;; esac
[ "${G##*/}" = openrc.$APP_SVC ] || fail dedicated_cgroup
[ "$G" != "$(awk -F: '$1==0{print $3}' /proc/1/cgroup)" ] || fail shared_pid1
[ "$(awk '$0~/ - cgroup2 /&&$5=="/sys/fs/cgroup"{print $4}' /proc/self/mountinfo)" = / ] || fail cgroup_mount
C=/sys/fs/cgroup$G
members() {
[ "$(worker_snapshot)" = "$LIMIT_KEY" ] || return 1
for f in "$C"/*; do [ ! -d "$f" ] || return 1; done
v=$(cat "$C/cgroup.procs") || return 1
printf '%s\n' "$v" | grep -Fx "$P" >/dev/null || return 1
for m in $v; do [ "$m" = "$P" ] || [ "$m" = "$LIMIT_PARENT" ] || return 1; done
[ "$(process_stamp "$LIMIT_PARENT")" = "$LIMIT_SUPERVISOR_STAMP" ] || return 1
[ "$(start "$P")" = "$I" ] && [ "$(awk -F: '$1==0{print $3}' "/proc/$P/cgroup")" = "$G" ]
}
members || fail unrelated_members
J=$(stat -Lc %i "$C")
d=$(mktemp -d); PROBE=0; T=node_probe_$$
trap '[ "$PROBE" = 0 ] || nft delete table inet "$T" >/dev/null 2>&1; rm -rf "$d"' EXIT
trap 'exit 1' INT TERM HUP
nft list tables >"$d/tables" || fail nft_permission
rule_digest() { sed -E 's/counter packets [0-9]+ bytes [0-9]+/counter/g' "$1" | sha256sum | awk '{print $1}'; }
CACHE_KEY="node-limit-v5:$(uname -r):$J:$N:$G"
if grep -Fxq 'table inet node_limit' "$d/tables"; then
nft list table inet node_limit >"$d/old" || fail nft_read
if [ "$(cat "$S/limit-key" 2>/dev/null || true)" = "$CACHE_KEY" ] && [ "$(cat "$S/limit-digest" 2>/dev/null || true)" = "$(rule_digest "$d/old")" ]; then
members && [ "$(stat -Lc %i "$C")" = "$J" ] || fail cgroup_changed
exit 0
fi
fi
room_uint() {
case "${1:-}" in ''|*[!0-9]*) return 1;; esac
# Normalize decimal strings before any signed-64-bit shell arithmetic.
printf '%s\n' "$1" | LC_ALL=C awk '{
n=$0; sub(/^0+/,"",n); if(n=="")n="0"
if(length(n)>19 || (length(n)==19 && ("x" n)>"x9223372036854775807"))exit 1
print n
}'
}
room_file_uint() {
room_value=$(cat "$1" 2>/dev/null) || return 1
room_uint "$room_value"
}
room_clean_cache() {
[ "$(room_file_uint "$1/memory.min")" = 0 ] || return 1
[ "$(room_file_uint "$1/memory.low")" = 0 ] || return 1
room_values=$(LC_ALL=C awk '
function uint(n) {
if(n !~ /^[0-9]+$/)return ""
sub(/^0+/,"",n); if(n=="")n="0"
if(length(n)>19 || (length(n)==19 && ("x" n)>"x9223372036854775807"))return ""
return n
}
{
if(NF!=2 || $1 !~ /^[a-z_][a-z0-9_]*$/ || seen[$1]++){bad=1; exit}
n=uint($2); if(n==""){bad=1; exit}
value[$1]=n
}
END {
if(bad || !seen["file"] || !seen["inactive_file"] || !seen["file_dirty"] || !seen["file_writeback"])exit 1
print value["file"],value["inactive_file"],value["file_dirty"],value["file_writeback"]
}' "$1/memory.stat" 2>/dev/null) || return 1
set -- $room_values
[ "$#" -eq 4 ] || return 1
room_cache=$1
[ "$room_cache" -le "$2" ] || room_cache=$2
# Saturating deductions avoid overflow and give no credit to dirty/writeback pages.
for room_used in "$3" "$4"; do
if [ "$room_cache" -le "$room_used" ]; then room_cache=0; else room_cache=$((room_cache-room_used)); fi
done
printf '%s\n' "$room_cache"
}
room() {
for z in "$C" /sys/fs/cgroup; do
for x in memory pids; do
[ -f "$z/$x.max" ] || continue
m=$(cat "$z/$x.max" 2>/dev/null) || return 1
[ "$m" = max ] && continue
m=$(room_uint "$m") || return 1
v=$(room_file_uint "$z/$x.current") || return 1
[ "$m" -ge "$v" ] || return 1
r=33554432; [ "$x" != pids ] || r=8
room_free=$((m-v))
if [ "$room_free" -lt "$r" ]; then
[ "$x" = memory ] || return 1
# This is only a conservative estimate; no reclaim or cache-control writes occur.
room_credit=$(room_clean_cache "$z") || return 1
[ "$room_credit" -le "$v" ] || room_credit=$v
[ "$room_credit" -ge "$((r-room_free))" ] || return 1
fi
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
timeout -k 2 5 bash -c 'echo "$BASHPID" >"$1/cgroup.procs" || exit 1; echo x >/dev/udp/127.0.0.1/9' _ "$C" 7>&- 8>&- 9>&- || fail probe_send
nft list chain inet "$T" out >"$d/result" || fail probe_read
V=$(awk '/socket cgroupv2/{l=0;p=0;for(i=1;i<NF;i++){if($i=="level")l=$(i+1);if($i=="packets")p=$(i+1)}if(p>0)print l}' "$d/result")
case "$V" in ''|*[!0-9]*) fail cgroup_match_ambiguous;; esac
bash -c 'echo x >/dev/udp/127.0.0.1/9' 7>&- 8>&- 9>&- || fail outside_probe_send
nft list chain inet "$T" out >"$d/outside" || fail probe_read
cmp -s "$d/result" "$d/outside" || fail cgroup_match_not_exclusive
nft delete table inet "$T" || fail probe_cleanup
PROBE=0
members && [ "$(stat -Lc %i "$C")" = "$J" ] || fail cgroup_changed
H="node-limit-v5:$J:$V:$N"
log "CGROUP_MATCH_VERIFIED level=$V"

: >"$d/rules"
if grep -Fx 'table inet node_limit' "$d/tables" >/dev/null; then echo 'delete table inet node_limit' >"$d/rules"; fi
printf 'table inet node_limit { chain output { type filter hook output priority -10; policy accept; socket cgroupv2 level %s "%s" meta l4proto { tcp, udp } ct state new ct count over %s counter reject comment "%s"; }; }\n' "$V" "${G#/}" "$N" "$H" >>"$d/rules"
nft -c -f "$d/rules" || fail nft_check
members && [ "$(stat -Lc %i "$C")" = "$J" ] || fail cgroup_changed
nft -f "$d/rules" || fail nft_apply
nft list table inet node_limit >"$d/live" || fail nft_read
rule_digest "$d/live" >"$S/limit-digest" || fail cache_write
printf '%s\n' "$CACHE_KEY" >"$S/limit-key" || fail cache_write
log "LIMIT_OK flows=$N group=$G"
NODE_LIMIT_TEMPLATE
cat >"$NS_DIR/boot" <<'NODE_BOOT_TEMPLATE' || return 1
#!/bin/sh
# NODE-SUITE-2026.10.18.1
n=0; while [ "$n" -lt 15 ]; do /usr/local/sbin/node-limit 20 && exit 0; n=$((n+1)); sleep 2; done; exit 1
NODE_BOOT_TEMPLATE
for NS_FILE in common watchdog recover limit boot; do sh -n "$NS_DIR/$NS_FILE" || return 1; done
chmod 644 "$NS_DIR/common" || return 1
chmod 755 "$NS_DIR/watchdog" "$NS_DIR/recover" "$NS_DIR/limit" "$NS_DIR/boot"
)

# NODE-SUITE-2026.10.18.1 source foundation; never runs an unvalidated source hook.
suite_source_plain_file(){
  valid_path "$1" || return 1
  [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ] && [ "$(stat -c %u "$1")" = 0 ] || return 1
  NSP_MODE=$(stat -c %a "$1") || return 1
  case "$NSP_MODE" in ''|*[!0-7]*) return 1;; esac
  [ "$((0$NSP_MODE & 022))" = 0 ]
}
suite_source_init_valid(){
  suite_source_plain_file "$1" && [ -x "$1" ] || return 1
  awk -v sdk="$SDK_BIN" -v service="$OLD_SVC" '
    function trim(s){sub(/^[[:space:]]+/,"",s);sub(/[[:space:]]+$/,"",s);return s}
    function literal(s, q){
      s=trim(s);q=substr(s,1,1)
      if(q=="\"" || q==sprintf("%c",39)){
        if(length(s)<2 || substr(s,length(s),1)!=q)return "!invalid"
        s=substr(s,2,length(s)-2)
      } else if(s ~ /[[:space:]]/)return "!invalid"
      if(s ~ /[^A-Za-z0-9 _.,:\/+=@%~-]/)return "!invalid"
      return s
    }
    NR==1{if($0!="#!/sbin/openrc-run")bad=1;next}
    {
      s=trim($0)
      if(s=="" || s ~ /^#/)next
      if(dep){
        if(s=="}"){dep=0;next}
        if(s ~ /^(need net|after networking);?$/)next
        bad=1;next
      }
      if(s ~ /^depend[[:space:]]*\(\)[[:space:]]*\{[[:space:]]*(need net|after networking);?[[:space:]]*\}$/){if(seen_dep++)bad=1;next}
      if(s ~ /^depend[[:space:]]*\(\)[[:space:]]*\{[[:space:]]*$/){if(seen_dep++)bad=1;dep=1;next}
      k=s;sub(/=.*/,"",k)
      if(k==s || k !~ /^[a-z_]+$/ || seen[k]++){bad=1;next}
      v=s;sub(/^[^=]*=/,"",v);v=literal(v)
      if(v=="!invalid"){bad=1;next}
      if(k=="command"){if(v!=sdk)bad=1;next}
      if(k=="command_args"){if(v!="run")bad=1;next}
      if(k=="command_user"){if(v!="root")bad=1;next}
      if(k=="supervisor"){if(v!="supervise-daemon")bad=1;next}
      if(k=="name"){if(v!=service)bad=1;next}
      if(k=="description")next
      if(k=="respawn_delay" || k=="respawn_max" || k=="respawn_period"){
        if(v !~ /^[0-9]+$/ || v+0>2147483647)bad=1;next
      }
      bad=1
    }
    END{exit bad || dep || !seen["command"] || !seen["command_args"] || !seen["command_user"] || !seen["supervisor"]}' "$1" && sh -n "$1"
}
suite_source_config_valid(){
  for NSC_FILE in "/etc/conf.d/$OLD_SVC".*; do
    exists "$NSC_FILE" && { fail "source runlevel-specific configuration retained: $NSC_FILE"; return 1; }
  done
  [ ! -e "/etc/conf.d/$OLD_SVC" ] && [ ! -L "/etc/conf.d/$OLD_SVC" ] && return 0
  suite_source_plain_file "/etc/conf.d/$OLD_SVC" &&
    awk '/^[[:space:]]*$/ || /^[[:space:]]*#/ {next} {bad=1} END{exit bad}' "/etc/conf.d/$OLD_SVC"
}
suite_source_references(){
  if command -v suite_updater_guard >/dev/null 2>&1; then
    UPDATER_MAIN_SVC=$OLD_SVC
    suite_updater_guard "$SDK_BIN" || return 1
  else
    for NSR_SVC in earnapp_upgrader earnapp-upgrader; do
      for NSR_FILE in "/etc/init.d/$NSR_SVC" "/etc/conf.d/$NSR_SVC" /etc/runlevels/*/"$NSR_SVC" \
        "/etc/systemd/system/$NSR_SVC.service" "/usr/lib/systemd/system/$NSR_SVC.service" "/lib/systemd/system/$NSR_SVC.service"; do
        exists "$NSR_FILE" && { fail "vendor updater retained for review: $NSR_FILE"; return 1; }
      done
    done
  fi
  for NSR_FILE in /etc/init.d/* /etc/conf.d/* /etc/crontabs/*; do
    exists "$NSR_FILE" || continue
    [ "$NSR_FILE" != "/etc/init.d/$OLD_SVC" ] && [ "$NSR_FILE" != "/etc/conf.d/$OLD_SVC" ] || continue
    if [ "${UPDATERS_INACTIVE:-0}" = 1 ]; then
      case "$NSR_FILE" in
        /etc/init.d/earnapp_upgrader|/etc/init.d/earnapp-upgrader|/etc/conf.d/earnapp_upgrader|/etc/conf.d/earnapp-upgrader) continue;;
      esac
    fi
    [ -f "$NSR_FILE" ] && [ -r "$NSR_FILE" ] || { fail "cannot inspect possible SDK hook: $NSR_FILE"; return 1; }
    NSR_RC=0; grep -F -e "$SDK_BIN" -e "$NSP_CANON" "$NSR_FILE" >/dev/null 2>&1 || NSR_RC=$?
    case "$NSR_RC" in
      0) fail "another service/cron references the SDK; retained: $NSR_FILE"; return 1;;
      1) :;; *) fail "cannot inspect possible SDK hook: $NSR_FILE"; return 1;;
    esac
  done
}
suite_source_program() (
  NSP_PROC=$1
  NSP_EXE=$(readlink "$NSP_PROC/exe" 2>/dev/null) || NSP_EXE=
  if [ "${NSP_EXE% (deleted)}" = "$NSP_CANON" ]; then
    [ "$(hash_file "$NSP_PROC/exe")" = "$NSP_HASH" ] && exit 0
    exit 2
  fi
  if mapped_program_matches "$NSP_PROC" "$NSP_CANON"; then exit 0; fi
  if [ -r "$NSP_PROC/maps" ]; then
    # A changed/deleted/non-executable mapping is uncertainty, not absence.
    awk -v target="$NSP_CANON" '$6==target{found=1} END{exit found}' "$NSP_PROC/maps" 2>/dev/null || exit 2
    exit 1
  fi
  [ ! -d "$NSP_PROC" ] && exit 1
  exit 2
)
suite_source_run_argv() (
  NSA_PROC=$1
  NSA_ARGS=$(tr '\000' '\n' <"$NSA_PROC/cmdline" 2>/dev/null) || exit 1
  NSA_FIRST=$(printf '%s\n' "$NSA_ARGS" | head -n 1)
  NSA_DIRECT=0
  if [ "$NSA_FIRST" = "$SDK_BIN" ] || [ "$NSA_FIRST" = "$NSP_CANON" ]; then NSA_DIRECT=1
  else
    valid_path "$NSA_FIRST" >/dev/null 2>&1 || exit 1
    NSA_EXE=$(readlink "$NSA_PROC/exe" 2>/dev/null) || exit 1
    [ "$(readlink -f "$NSA_FIRST")" = "${NSA_EXE% (deleted)}" ] || exit 1
  fi
  printf '%s\n' "$NSA_ARGS" | awk -v direct="$NSA_DIRECT" -v sdk="$SDK_BIN" -v canonical="$NSP_CANON" '
    NR==1{next}
    direct==1{if(NR==2 && $0=="run")ok=1;else bad=1;next}
    done{bad=1;next}
    need_run{if($0=="run"){ok=1;done=1}else bad=1;need_run=0;next}
    skip{skip=0;next}
    $0==sdk || $0==canonical{need_run=1;next}
    !ended && $0=="--"{ended=1;next}
    !ended && ($0=="--argv0" || $0=="--preload" || $0=="--library-path"){skip=1;next}
    {bad=1}
    END{exit !(ok && !bad && !skip && !need_run)}'
)
suite_source_scan() (
  NSS_ALLOWED_PARENT=${1:-}
  NSS_SUP=$(command -v supervise-daemon) && NSS_SUP=$(readlink -f "$NSS_SUP") || exit 1
  NSS_COUNT=0; NSS_RESULT=
  for NSS_PROC in /proc/[0-9]*; do
    [ -d "$NSS_PROC" ] || continue
    NSS_PID=${NSS_PROC##*/}
    NSS_EXE=$(readlink "$NSS_PROC/exe" 2>/dev/null) || NSS_EXE=
    if [ "${NSS_EXE% (deleted)}" = "$NSS_SUP" ] && [ "$NSS_PID" != "$NSS_ALLOWED_PARENT" ]; then
      NSS_ARGS=$(tr '\000' '\n' <"$NSS_PROC/cmdline" 2>/dev/null) || exit 1
      [ -n "$NSS_ARGS" ] || exit 1
      if printf '%s\n' "$NSS_ARGS" | awk -v sdk="$SDK_BIN" -v canonical="$NSP_CANON" -v service="$OLD_SVC" '
        NR==2 && ($0==service || $0=="earnapp_upgrader" || $0=="earnapp-upgrader"){found=1}
        $0==sdk || $0==canonical{found=1} END{exit !found}'; then
        fail "a live supervisor still owns/references the source SDK: $NSS_PID"; exit 1
      fi
    fi
    NSS_MATCH=0; suite_source_program "$NSS_PROC" || NSS_MATCH=$?
    case "$NSS_MATCH" in 1) continue;; 0) :;; *) fail "source process identity is unreadable/changed: $NSS_PID"; exit 1;; esac
    NSS_STAMP=$(process_stamp "$NSS_PID") || exit 1
    awk '/^Uid:/{ok=(NF==5&&$2==0&&$3==0&&$4==0&&$5==0)} END{exit !ok}' "$NSS_PROC/status" || exit 1
    suite_source_run_argv "$NSS_PROC" || { fail "SDK process does not have a verified run invocation: $NSS_PID"; exit 1; }
    [ "$(process_stamp "$NSS_PID")" = "$NSS_STAMP" ] || exit 1
    NSS_COUNT=$((NSS_COUNT+1)); [ "$NSS_COUNT" = 1 ] || { fail 'multiple SDK workers; source preparation refused'; exit 1; }
    NSS_RESULT="$NSS_PID:${NSS_STAMP#*:}:${NSS_STAMP%%:*}"
  done
  [ "$(hash_file "$SDK_BIN")" = "$NSP_HASH" ] || exit 1
  [ -z "$NSS_RESULT" ] || printf '%s\n' "$NSS_RESULT"
)
suite_source_meta_value() (
  NSG_HELPER=
  for NSG_FILE in /lib/rc/bin/service_get_value /usr/lib/rc/bin/service_get_value; do
    [ ! -x "$NSG_FILE" ] || { NSG_HELPER=$NSG_FILE; break; }
  done
  [ -n "$NSG_HELPER" ] || NSG_HELPER=$(command -v service_get_value) || exit 1
  NSG_RC=0
  NSG_VALUE=$(RC_SVCNAME=$OLD_SVC "$NSG_HELPER" "$1" 6>&- 7>&- 8>&- 9>&- 2>/dev/null) || NSG_RC=$?
  case "$NSG_RC" in
    0) printf '%s\n' "$NSG_VALUE";;
    1) [ -z "$NSG_VALUE" ] || exit 1;;
    *) exit 1;;
  esac
)
suite_source_meta_guard() (
  NSM_EXPECTED=${1:-}
  NSM_CHILD=$(suite_source_meta_value child_pid) || exit 1
  if [ -n "$NSM_CHILD" ]; then
    case "$NSM_CHILD" in *[!0-9]*) exit 1;; esac
    [ "$NSM_CHILD" -gt 1 ] || exit 1
    if [ -d "/proc/$NSM_CHILD" ]; then [ "$NSM_CHILD" = "$NSM_EXPECTED" ] || exit 1; fi
  fi
  NSM_PATH=$(suite_source_meta_value pidfile) || exit 1
  [ -n "$NSM_PATH" ] || exit 0
  valid_path "$NSM_PATH" || exit 1
  [ -e "$NSM_PATH" ] || [ -L "$NSM_PATH" ] || exit 0
  NSM_PARENT=$(cat "$NSM_PATH" 2>/dev/null) || exit 1
  case "$NSM_PARENT" in ''|*[!0-9]*) exit 1;; esac
  [ "$NSM_PARENT" -gt 1 ] || exit 1
  [ ! -d "/proc/$NSM_PARENT" ]
)
suite_source_static_guard(){
  [ "$(hash_file "$NSP_INIT")" = "$NSP_INIT_HASH" ] || { fail 'source init changed before execution'; return 1; }
  if [ "$NSP_CONF_HASH" = absent ]; then
    [ ! -e "/etc/conf.d/$OLD_SVC" ] && [ ! -L "/etc/conf.d/$OLD_SVC" ] || return 1
  else [ "$(hash_file "/etc/conf.d/$OLD_SVC")" = "$NSP_CONF_HASH" ] || return 1; fi
  suite_source_config_valid
}
suite_source_status(){
  suite_source_static_guard || return 1
  service_state "$OLD_SVC" 6>&- 7>&- 8>&- 9>&-
}
suite_source_live_key() (
  [ "$(suite_source_status)" = 0 ] || exit 1
  NSV_PIDS=$(service_worker_pids "$OLD_SVC" "$SDK_BIN" 6>&- 7>&- 8>&- 9>&-) || exit 1
  set -- $NSV_PIDS
  [ "$#" = 1 ] || exit 1
  NSV_PID=$1; NSV_STAMP=$(process_stamp "$NSV_PID") || exit 1
  NSV_PARENT=${NSV_STAMP%%:*}
  NSV_ARGS=$(tr '\000' '\n' <"/proc/$NSV_PARENT/cmdline" 2>/dev/null) || exit 1
  printf '%s\n' "$NSV_ARGS" | awk -v service="$OLD_SVC" 'NR==2{found=($0==service)} END{exit !found}' || exit 1
  NSV_SCAN=$(suite_source_scan "$NSV_PARENT") || exit 1
  [ "$NSV_SCAN" = "$NSV_PID:${NSV_STAMP#*:}:$NSV_PARENT" ] || exit 1
  [ "$(process_stamp "$NSV_PID")" = "$NSV_STAMP" ] && [ "$(suite_source_status)" = 0 ] || exit 1
  printf '%s:%s\n' "$NSV_PID" "${NSV_STAMP#*:}"
)
suite_source_poll(){
  NSP_POLL=0
  while [ "$NSP_POLL" -lt 10 ]; do
    NSP_READY=$(suite_source_live_key 2>>"$U_B/source-preparation.log") && return 0
    NSP_POLL=$((NSP_POLL+1)); [ "$NSP_POLL" = 10 ] || sleep 1
  done
  return 1
}
suite_prepare_source(){
  SOURCE_PREPARED=0; SOURCE_ACTION=; NSP_READY=
  [ -n "${U_D:-}" ] && [ -d "$U_D" ] && [ -n "${U_B:-}" ] && [ -d "$U_B" ] || { fail 'source foundation directories are missing'; return 1; }
  [ "${OLD_SVC:-}" = earnapp ] || { fail 'source foundation only supports the vendor source service'; return 1; }
  valid_path "$SDK_BIN" && [ -f "$SDK_BIN" ] && [ -x "$SDK_BIN" ] || return 1
  [ "$(od -An -tx1 -N4 "$SDK_BIN" | tr -d ' \n')" = 7f454c46 ] || { fail 'source SDK must be an ELF executable'; return 1; }
  NSP_HASH=$(hash_file "$SDK_BIN") && NSP_CANON=$(readlink -f "$SDK_BIN") || return 1
  valid_path "$NSP_CANON" || return 1
  NSP_INIT="/etc/init.d/$OLD_SVC"; NSP_INIT_HASH=; NSP_NEW_INIT=1
  NSP_CONF_HASH=absent
  suite_source_config_valid || { fail 'source configuration contains unsupported hooks/settings'; return 1; }
  [ ! -f "/etc/conf.d/$OLD_SVC" ] || NSP_CONF_HASH=$(hash_file "/etc/conf.d/$OLD_SVC") || return 1
  if exists "$NSP_INIT"; then
    suite_source_init_valid "$NSP_INIT" || { fail "unknown source init retained without execution: $NSP_INIT"; return 1; }
    NSP_INIT_HASH=$(hash_file "$NSP_INIT") || return 1
    NSP_NEW_INIT=0
  fi
  suite_source_references || return 1
  if [ "$NSP_NEW_INIT" = 0 ]; then
    NSP_STATE=$(suite_source_status) || return 1
    case "$NSP_STATE" in
      0)
        NSP_READY=$(suite_source_live_key) || { fail 'existing source supervision is not verifiable; retained'; return 1; }
        SOURCE_PREPARED=1; SOURCE_ACTION=kept
        printf 'SOURCE_PREPARED\nkept %s worker=%s\n' "$OLD_SVC" "$NSP_READY"
        return 0;;
      3) :;; *) fail "source service is transitional/crashed (status $NSP_STATE); retained"; return 1;;
    esac
  fi
  NSP_ORIGINAL=$(suite_source_scan) || return 1
  NSP_ORPHAN=
  if [ -n "$NSP_ORIGINAL" ]; then
    NSP_ORPHAN=${NSP_ORIGINAL%%:*}; NSP_REST=${NSP_ORIGINAL#*:}; NSP_BIRTH=${NSP_REST%%:*}; NSP_PARENT=${NSP_REST##*:}
    [ "$NSP_PARENT" = 1 ] || { fail 'only a verified parent-1 run orphan can be normalized'; return 1; }
  fi
  suite_source_meta_guard "$NSP_ORPHAN" || { fail 'live/unknown OpenRC ownership prevents source preparation'; return 1; }
  [ ! -e "$U_B/source-preparation.record" ] || { fail 'source foundation record already exists; use a separate foundation directory'; return 1; }
  printf '%s\n' 'FORMAT=1' "SDK=$SDK_BIN" "CANONICAL=$NSP_CANON" "HASH=$NSP_HASH" "SERVICE=$OLD_SVC" \
    "ORIGINAL_INIT_HASH=${NSP_INIT_HASH:-absent}" "ORIGINAL_CONFIG_HASH=$NSP_CONF_HASH" "ORIGINAL_WORKER=${NSP_ORIGINAL:-absent}" >"$U_B/source-preparation.record" || return 1
  chmod 600 "$U_B/source-preparation.record" || return 1
  printf '%s\n' prepared >"$U_B/source-preparation.state" || return 1
  if [ -n "$NSP_ORPHAN" ]; then
    NSP_RECHECK=$(suite_source_scan) || return 1
    [ "$NSP_RECHECK" = "$NSP_ORIGINAL" ] && suite_source_meta_guard "$NSP_ORPHAN" && suite_source_references || return 1
    [ "$(process_stamp "$NSP_ORPHAN")" = "1:$NSP_BIRTH" ] || { fail 'orphan PID/start time changed before TERM'; return 1; }
    printf '%s\n' term-attempted >"$U_B/source-preparation.state" || return 1
    kill -TERM "$NSP_ORPHAN" || { fail 'verified orphan did not accept TERM'; return 1; }
    NSP_WAIT=0
    while [ -d "/proc/$NSP_ORPHAN" ] && [ "$NSP_WAIT" -lt 5 ]; do
      [ "$(process_stamp "$NSP_ORPHAN")" = "1:$NSP_BIRTH" ] || { fail 'orphan PID changed/exited without a clean process disappearance; retained for review'; return 1; }
      sleep 1; NSP_WAIT=$((NSP_WAIT+1))
    done
    [ ! -d "/proc/$NSP_ORPHAN" ] || { fail 'verified orphan remains after bounded TERM; no stronger signal was sent'; return 1; }
    NSP_RECHECK=$(suite_source_scan) || { fail 'SDK identity is unknown after TERM; no further signals sent'; return 1; }
    [ -z "$NSP_RECHECK" ] && suite_source_meta_guard || { fail 'SDK worker/supervisor appeared after TERM; no further signals sent'; return 1; }
    printf '%s\n' orphan-stopped >"$U_B/source-preparation.state" || return 1
    SOURCE_ACTION=adopted
  else SOURCE_ACTION=started; fi
  suite_source_references || return 1
  if [ "$NSP_NEW_INIT" = 1 ]; then
    cat >"$U_D/source-init" <<EOF
#!/sbin/openrc-run
name="$OLD_SVC"
description="Managed node source service"
command="$SDK_BIN"
command_args="run"
command_user="root"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
respawn_period=1800
depend() { need net; }
EOF
    chmod 755 "$U_D/source-init" && suite_source_init_valid "$U_D/source-init" || return 1
    suite_atomic source-init "$U_D/source-init" 755 || return 1
    NSP_INIT_HASH=$(hash_file "$NSP_INIT") || return 1
    printf '%s\n' init-installed >"$U_B/source-preparation.state" || return 1
    rc-update add "$OLD_SVC" default 6>&- 7>&- 8>&- 9>&- || return 1
  fi
  NSP_STATE=$(suite_source_status) || return 1
  if [ "$NSP_STATE" != 3 ]; then
    case "$NSP_STATE" in 0|32) :;; *) fail 'source state changed before canonical start'; return 1;; esac
    # Only the statically verified init is used to clear a stale service flag.
    NSP_RECHECK=$(suite_source_scan) || return 1
    [ -z "$NSP_RECHECK" ] && suite_source_meta_guard && suite_source_static_guard || return 1
    timeout -k 2 10 rc-service "$OLD_SVC" zap 6>&- 7>&- 8>&- 9>&- || return 1
    [ "$(suite_source_status)" = 3 ] || return 1
  fi
  NSP_ATTEMPT=0
  while [ "$NSP_ATTEMPT" -lt 2 ]; do
    NSP_ATTEMPT=$((NSP_ATTEMPT+1))
    suite_source_static_guard && [ "$(hash_file "$SDK_BIN")" = "$NSP_HASH" ] || return 1
    printf '%s\n' start-attempted >"$U_B/source-preparation.state" || return 1
    NSP_START_RC=0
    timeout -k 5 30 rc-service "$OLD_SVC" start 6>&- 7>&- 8>&- 9>&- >>"$U_B/source-preparation.log" 2>&1 || NSP_START_RC=$?
    printf 'START_ATTEMPT=%s RC=%s\n' "$NSP_ATTEMPT" "$NSP_START_RC" >>"$U_B/source-preparation.log"
    if suite_source_poll; then
      SOURCE_PREPARED=1
      printf '%s\n' "READY_WORKER=$NSP_READY" >>"$U_B/source-preparation.record"
      printf '%s\n' ready >"$U_B/source-preparation.state"
      printf 'SOURCE_PREPARED\n%s %s worker=%s\nFOUNDATION\n%s\n' "$SOURCE_ACTION" "$OLD_SVC" "$NSP_READY" "$U_B"
      return 0
    fi
    [ "$(suite_source_status)" = 3 ] || break
    NSP_REMAINDER=$(suite_source_scan) || break
    [ -z "$NSP_REMAINDER" ] && suite_source_meta_guard || break
  done
  printf '%s\n' start-failed >"$U_B/source-preparation.state"
  fail "canonical source start could not be verified; known init and foundation diagnostics retained: $U_B"
  return 1
}

# Unified installation/upgrade transaction. Loaded after the service engine.
SUITE_VERSION=2026.10.18.1
SUITE_REGISTRY=/var/lib/node-suite/current

suite_path(){
  case "$1" in
    old-common) printf '%s\n' /usr/local/lib/earnapp-original.sh;;
    old-watchdog) printf '%s\n' /usr/local/sbin/earnapp-watchdog;;
    old-recover) printf '%s\n' /usr/local/sbin/earnapp-recover;;
    old-limit) printf '%s\n' /usr/local/sbin/earnapp-limit;;
    old-boot) printf '%s\n' /etc/local.d/earnapp-limit.start;;
    old-config) printf '%s\n' /etc/earnapp/watchdog.conf;;
    common) printf '%s\n' /usr/local/lib/node-runtime.sh;;
    watchdog) printf '%s\n' /usr/local/sbin/node-guard;;
    recover) printf '%s\n' /usr/local/sbin/node-recover;;
    limit) printf '%s\n' /usr/local/sbin/node-limit;;
    boot) printf '%s\n' /etc/local.d/node-limit.start;;
    config) printf '%s\n' /etc/node-guard.conf;;
    cron) printf '%s\n' /etc/crontabs/root;;
    registry) printf '%s\n' "$SUITE_REGISTRY";;
    source-init) printf '%s\n' /etc/init.d/earnapp;;
    source-conf) printf '%s\n' /etc/conf.d/earnapp;;
    *) fail "unknown suite file: $1";;
  esac
}
suite_tags(){ printf '%s\n' old-common old-watchdog old-recover old-limit old-boot old-config common watchdog recover limit boot config cron registry source-init source-conf; }
suite_regular(){
  valid_path "$1" || return 1
  SP_PARENT=$1
  while [ "$SP_PARENT" != / ]; do
    [ ! -L "$SP_PARENT" ] || { fail "symlink is not an upgrade target: $SP_PARENT"; return 1; }
    SP_PARENT=${SP_PARENT%/*}; [ -n "$SP_PARENT" ] || SP_PARENT=/
  done
  exists "$1" || return 0
  [ -f "$1" ] && [ -r "$1" ] && [ "$(stat -c %u "$1")" = 0 ] || {
    fail "expected a readable root-owned regular file: $1"; return 1;
  }
}
suite_legacy_hash(){
  case "$1:$2" in
    old-common:7d0e354f186b180f8df2f97c5804ec5b4a516f4bb935f207918b83b9dda9fa46|old-common:6a80401689c0d2bb16f403f7845a326fafdd4a58fbc07b22eec8419fc69744cb|\
    old-watchdog:4e6eeafaa13f510c08451e883260d9541125a2cfbd900dd9edab6e432e1b5fff|old-watchdog:c6bb5c971fabe055e674f473c1e9565bb5c4de8e9c07e3f3574b50e496aa6257|old-watchdog:9d5f4cec8a674fdb33a0af28db64d86a813cbc8abbef3f14bd2f50f24b8e35a8|\
    old-recover:963d1976b6a2070a0b05f966987cdee89487daf9dcb1d73de91ab89159e359a1|old-recover:e4f8536786ceb6ef2abcb48c7984ded0b021fbfd7196789005002850391e8026|old-recover:046471e99f57ebe1a7bb7616aaf1692eb5faab20d6a9e6a3dc87e683b8441529|old-recover:715316864c15540ea5e1d88f8d753863731991cdf9ded153cf38a184f63e34d8|\
    old-limit:dd738eb46331a49230b7977fca80183e7858ef829ad844ac550faeb3a3e38485|old-limit:971f4288ed4bc4757ffb9ccba3b91e0bcfc7ad8b9b46f050fe99871efca9e3e6|old-limit:1582c02ebe633d0bf98a468a1ea5fa8b5bf6bc6d4adcc4cf1ebfb1b6cf4a75c5|\
    old-boot:eff856125ffadef714d4b7bf5188f09c7d60568dfd2cfe7b6cb0b2a041d7f806|old-boot:6c44ca2d867d72ae2c7b3285d2b5037057cfe6fc764f8714da408dd5576b4947) return 0;;
    *) return 1;;
  esac
}
suite_has_legacy(){
  for SH_TAG in old-common old-watchdog old-recover old-limit old-boot; do
    SH_PATH=$(suite_path "$SH_TAG") || return 1
    if exists "$SH_PATH"; then return 0; fi
  done
  return 1
}
suite_config_valid(){
  [ ! -e "$1" ] || awk '
    /^[[:space:]]*$/ || /^[[:space:]]*#/ {next}
    /^(UDP_THRESHOLD|FD_THRESHOLD|RSS_THRESHOLD_KB|ZERO_MAX_BAD|RESOURCE_MAX_BAD|MIN_UPTIME|RESTART_COOLDOWN)=[1-9][0-9]*$/ {
      split($0,a,"="); if(a[2]<=2147483647 && !seen[a[1]]++)next
    }
    {bad=1} END{exit bad}' "$1"
}
suite_emit_config(){
  # Numeric data only: never source any retired helper or configuration.
  set --
  for SC_FILE in /usr/local/lib/earnapp-original.sh /usr/local/sbin/earnapp-watchdog /etc/earnapp/watchdog.conf /etc/node-guard.conf; do
    [ ! -f "$SC_FILE" ] || set -- "$@" "$SC_FILE"
  done
  [ "$#" -gt 0 ] || { printf '%s\n' '# Defaults are defined in node-runtime.sh.'; return 0; }
  awk '
    BEGIN{n=split("UDP_THRESHOLD FD_THRESHOLD RSS_THRESHOLD_KB ZERO_MAX_BAD RESOURCE_MAX_BAD MIN_UPTIME RESTART_COOLDOWN",keys," ");for(i=1;i<=n;i++)known[keys[i]]=1}
    /^[[:space:]]*#/ {next}
    {count=split($0,part,";");for(j=1;j<=count;j++){
      s=part[j];sub(/^[[:space:]]+/,"",s);sub(/[[:space:]]+$/, "",s)
      k=s;sub(/=.*/,"",k)
      if(known[k]){v=s;sub(/^[^=]*=/,"",v);if(v !~ /^[1-9][0-9]*$/ || v+0>2147483647)bad=1;else value[k]=v}
    }}
    END{if(bad)exit 1;for(i=1;i<=n;i++)if(keys[i] in value)print keys[i] "=" value[keys[i]]}' "$@"
}
suite_cron_filter(){
  # check preserves bytes; paused omits the exact recognized entries.
  awk -v mode="$1" '
    function managed(s) {
      return s=="*/2 * * * * /usr/local/sbin/earnapp-watchdog >/dev/null 2>&1 # EARNAPP-WATCHDOG" ||
        s=="0 */12 * * * /usr/local/sbin/earnapp-recover scheduled >/dev/null 2>&1 # EARNAPP-12H-STOPSTART" ||
        s=="*/2 * * * * /usr/local/sbin/node-guard >/dev/null 2>&1 # NODE-GUARD" ||
        s=="0 */12 * * * /usr/local/sbin/node-recover scheduled >/dev/null 2>&1 # NODE-RECOVERY"
    }
    managed($0){if(mode=="check")print;next}
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {print;next}
    {s=tolower($0);if(index(s,"earnapp") || index(s,"node-guard") || index(s,"node-recover") || index(s,"node-limit"))bad=1;print}
    END{exit bad}' "$2"
}
suite_read_current(){
  suite_regular "$SUITE_REGISTRY" || return 1
  [ -s "$SUITE_REGISTRY" ] || return 1
  U_PREVIOUS=$(cat "$SUITE_REGISTRY") || return 1
  valid_path "$U_PREVIOUS" && [ -d "$U_PREVIOUS" ] && [ ! -L "$U_PREVIOUS" ] || return 1
  [ -f "$U_PREVIOUS/settings" ] && [ -f "$U_PREVIOUS/owned" ] && [ "$(cat "$U_PREVIOUS/state")" = active ] || return 1
  suite_regular "$U_PREVIOUS/settings" && suite_regular "$U_PREVIOUS/owned" || return 1
  U_CURRENT_VERSION=; U_TARGET=; U_SERVICE=; U_APP_HASH=; SR_SEEN=' '; SR_COUNT=0
  while IFS='=' read -r SR_KEY SR_VAL; do
    case "$SR_SEEN" in *" $SR_KEY "*) return 1;; esac
    SR_SEEN="$SR_SEEN$SR_KEY "; SR_COUNT=$((SR_COUNT+1))
    case "$SR_KEY" in
      VERSION) U_CURRENT_VERSION=$SR_VAL;; TARGET) U_TARGET=$SR_VAL;; SERVICE) U_SERVICE=$SR_VAL;;
      HASH) U_APP_HASH=$SR_VAL;;
      SOURCE|MODE) :;; *) fail 'invalid suite settings'; return 1;;
    esac
  done < "$U_PREVIOUS/settings"
  [ "$SR_COUNT" = 6 ] && [ -n "$U_CURRENT_VERSION" ] && valid_path "$U_TARGET" && valid_name "$U_SERVICE" || return 1
  case "$U_APP_HASH" in ''|*[!0-9a-f]*) return 1;; esac
  [ "${#U_APP_HASH}" = 64 ] && [ "$(hash_file "$U_TARGET")" = "$U_APP_HASH" ] || { fail 'installed program changed'; return 1; }
  suite_check_owned "$U_PREVIOUS" || return 1
}
suite_check_owned(){
  SCO_SEEN=' '; SCO_COUNT=0
  while read -r SCO_TAG SCO_HASH SCO_EXTRA; do
    [ -z "$SCO_EXTRA" ] || return 1
    case "$SCO_TAG" in common|watchdog|recover|limit|boot) :;; *) return 1;; esac
    case "$SCO_SEEN" in *" $SCO_TAG "*) return 1;; esac
    SCO_SEEN="$SCO_SEEN$SCO_TAG "; SCO_COUNT=$((SCO_COUNT+1))
    SCO_PATH=$(suite_path "$SCO_TAG") || return 1
    suite_regular "$SCO_PATH" && [ -f "$SCO_PATH" ] || return 1
    SCO_MODE=755; [ "$SCO_TAG" != common ] || SCO_MODE=644
    [ "$(stat -c %a "$SCO_PATH")" = "$SCO_MODE" ] || { fail "managed file mode changed: $SCO_PATH"; return 1; }
    [ "$(hash_file "$SCO_PATH")" = "$SCO_HASH" ] || { fail "managed file changed: $SCO_PATH"; return 1; }
  done < "$1/owned"
  [ "$SCO_COUNT" = 5 ] || { fail 'incomplete helper ownership record'; return 1; }
}
suite_table_owned(){
  STO_TEXT=$(nft list table inet "$1" 2>/dev/null) || return 1
  printf '%s\n' "$STO_TEXT" | awk -v table="$1" -v service="$2" -v prefix="$3" '
    {s=$0;sub(/^[[:space:]]+/,"",s);sub(/[[:space:]]+$/, "",s)}
    s=="" || s=="}" {next}
    s=="table inet " table " {" {t++;next}
    s=="chain output {" {c++;next}
    s ~ /^type filter hook output priority .*; policy accept;$/ {h++;next}
    index(s,"socket cgroupv2 level ")==1 && index(s,"openrc." service "\"") && index(s,"ct count over ") && index(s,"comment \"" prefix) {r++;next}
    {bad=1} END{exit bad || t!=1 || c!=1 || h!=1 || r!=1}'
}
suite_preflight(){
  require_root && [ -f /etc/alpine-release ] || { fail 'ROOT_ALPINE_REQUIRED'; return 1; }
  for SP_TOOL in awk sha256sum stat readlink rc-service rc-update mktemp cmp; do need "$SP_TOOL" || return 1; done
  U_MODE=legacy; U_PREVIOUS=; U_TARGET=; U_SERVICE=$COVER_SVC; U_PREPARE_SOURCE=0
  valid_name "$COVER_SVC" && valid_path "$BACKUP_ROOT" || return 1
  [ "$COVER_SVC" != earnapp ] && [ "$LAUNCHER" = 0 ] || { fail 'unified install requires a different service name and LAUNCHER=0'; return 1; }
  for SP_TAG in $(suite_tags); do
    SP_PATH=$(suite_path "$SP_TAG") || return 1
    suite_regular "$SP_PATH" || return 1
  done
  if exists "$SUITE_REGISTRY"; then
    suite_read_current || { fail 'existing suite registry or owned files need review'; return 1; }
    [ "$COVER_SVC" = "$U_SERVICE" ] || { fail 'COVER_SVC differs from the installed suite'; return 1; }
    U_MODE=managed
  else
    for SP_TAG in common watchdog recover limit boot config; do
      SP_PATH=$(suite_path "$SP_TAG") || return 1
      exists "$SP_PATH" && { fail "unowned destination exists: $SP_PATH"; return 1; }
    done
    for SP_PATH in "$COVER_BIN" "$COVER_ALT"; do valid_path "$SP_PATH" || return 1; done
    U_TARGET=$(cover_target) || return 1
    exists "/etc/init.d/$COVER_SVC" && { fail "service destination exists: /etc/init.d/$COVER_SVC"; return 1; }
    exists "/etc/conf.d/$COVER_SVC" && { fail "configuration destination exists: /etc/conf.d/$COVER_SVC"; return 1; }
  fi
  for SP_TAG in old-common old-watchdog old-recover old-limit old-boot; do
    SP_PATH=$(suite_path "$SP_TAG") || return 1
    if [ -f "$SP_PATH" ]; then
      SP_HASH=$(hash_file "$SP_PATH") || return 1
      suite_legacy_hash "$SP_TAG" "$SP_HASH" || { fail "unknown/custom legacy helper retained: $SP_PATH ($SP_HASH)"; return 1; }
      sh -n "$SP_PATH" || return 1
    fi
  done
  for SP_CONFIG in /etc/earnapp/watchdog.conf /etc/node-guard.conf; do
    suite_config_valid "$SP_CONFIG" || { fail "unsupported or duplicate numeric configuration: $SP_CONFIG"; return 1; }
  done
  suite_emit_config >/dev/null || { fail 'legacy thresholds are not supported literal numbers'; return 1; }
  for SP_CRON in /etc/crontabs/*; do
    exists "$SP_CRON" || continue
    suite_regular "$SP_CRON" || return 1
    suite_cron_filter check "$SP_CRON" >/dev/null || { fail "custom managed cron retained: $SP_CRON"; return 1; }
    if [ "$SP_CRON" != /etc/crontabs/root ] && grep -Eiq 'earnapp|node-(guard|recover|limit)' "$SP_CRON"; then
      fail "managed entries outside root crontab: $SP_CRON"; return 1
    fi
  done
  if command -v nft >/dev/null 2>&1; then
    SP_TABLES=$(nft list tables) || { fail 'cannot read nft tables'; return 1; }
    if printf '%s\n' "$SP_TABLES" | grep -Fxq 'table inet node_limit'; then
      [ "$U_MODE" = managed ] && suite_table_owned node_limit "$COVER_SVC" node-limit- || { fail 'unowned/custom node_limit table retained'; return 1; }
    fi
    if printf '%s\n' "$SP_TABLES" | grep -Fxq 'table inet earnapp_limit'; then
      suite_table_owned earnapp_limit earnapp earnapp- || { fail 'custom earnapp_limit rules retained'; return 1; }
    fi
  fi
  if [ "$U_MODE" = managed ]; then
    UPDATER_MAIN_SVC=$U_SERVICE
    suite_updater_guard "$U_TARGET" || return 1
    return 0
  fi
  if ! discover_sdk >/dev/null 2>&1; then
    [ -z "$SDK_BIN" ] || ! exists "$SDK_BIN" || { fail 'SDK destination is occupied'; return 1; }
    SDK_BIN=${SDK_BIN:-/usr/bin/earnapp}; U_MODE=fresh; U_PREPARE_SOURCE=1
  elif [ ! -f /etc/init.d/earnapp ]; then
    U_MODE=prepared; U_PREPARE_SOURCE=1
  else
    OLD_SVC=earnapp
    (APPLY=0; cmd_deploy) || return 1
  fi
  UPDATER_MAIN_SVC=earnapp
  suite_updater_guard "$SDK_BIN" || return 1
  if [ "$U_PREPARE_SOURCE" = 1 ] && suite_has_legacy; then
    fail 'helpers exist without a usable SDK/source service; retained for review'; return 1
  fi
  printf 'suite mode=%s target=%s service=%s\n' "$U_MODE" "$U_TARGET" "$COVER_SVC"
}
suite_snapshot(){
  : > "$U_B/files.manifest"; : > "$U_B/allowed"
  mkdir "$U_B/files" || return 1
  for SS_TAG in $(suite_tags); do
    SS_PATH=$(suite_path "$SS_TAG") || return 1
    if [ -f "$SS_PATH" ]; then
      cp -p "$SS_PATH" "$U_B/files/$SS_TAG" || return 1
      SS_HASH=$(hash_file "$U_B/files/$SS_TAG") && SS_MODE=$(stat -c %a "$SS_PATH") || return 1
      printf '%s 1 %s %s\n' "$SS_TAG" "$SS_HASH" "$SS_MODE" >> "$U_B/files.manifest"
      printf '%s %s %s\n' "$SS_TAG" "$SS_HASH" "$SS_MODE" >> "$U_B/allowed"
    else
      printf '%s 0 - -\n' "$SS_TAG" >> "$U_B/files.manifest"
      printf '%s - -\n' "$SS_TAG" >> "$U_B/allowed"
    fi
  done
  for SS_SERVICE in earnapp crond local; do
    runlevels_for "$SS_SERVICE" > "$U_B/$SS_SERVICE.runlevels" || return 1
    service_state "$SS_SERVICE" > "$U_B/$SS_SERVICE.status" || return 1
  done
  SS_TABLES=$(nft list tables) || return 1
  for SS_TABLE in earnapp_limit node_limit; do
    if printf '%s\n' "$SS_TABLES" | grep -Fxq "table inet $SS_TABLE"; then
      nft list table inet "$SS_TABLE" > "$U_B/$SS_TABLE.nft" || return 1
    fi
  done
  SS_PROGRAM_HASH=$(hash_file "$SDK_BIN") || return 1
  printf '%s\n' "VERSION=$SUITE_VERSION" "MODE=$U_MODE" "SOURCE=$SDK_BIN" "TARGET=$U_TARGET" "SERVICE=$COVER_SVC" "HASH=$SS_PROGRAM_HASH" > "$U_B/settings" || return 1
  printf '%s\n' prepared > "$U_B/state" || return 1
  printf '%s\n' not-started > "$U_B/migration.phase" || return 1
  suite_seal_backup
}
suite_meta_names(){ printf '%s\n' settings files.manifest earnapp.runlevels earnapp.status crond.runlevels crond.status local.runlevels local.status earnapp_limit.nft node_limit.nft; }
suite_seal_backup(){
  : > "$U_B/metadata"
  for SM_FILE in $(suite_meta_names); do
    if [ -f "$U_B/$SM_FILE" ]; then
      SM_HASH=$(hash_file "$U_B/$SM_FILE") || return 1
      printf '%s %s\n' "$SM_FILE" "$SM_HASH" >> "$U_B/metadata" || return 1
    else
      case "$SM_FILE" in earnapp_limit.nft|node_limit.nft) printf '%s -\n' "$SM_FILE" >> "$U_B/metadata";; *) return 1;; esac
    fi
  done
}
suite_current_allowed(){
  SA_PATH=$(suite_path "$1") || return 1
  suite_regular "$SA_PATH" || return 1
  SA_HASH=-; SA_MODE=-
  if [ -f "$SA_PATH" ]; then SA_HASH=$(hash_file "$SA_PATH") && SA_MODE=$(stat -c %a "$SA_PATH") || return 1; fi
  grep -Fxq "$1 $SA_HASH $SA_MODE" "$U_B/allowed" || { fail "file changed during/after installation: $SA_PATH"; return 1; }
}
suite_atomic(){
  SA_DEST=$(suite_path "$1") || return 1
  suite_current_allowed "$1" || return 1
  SA_NEW_HASH=$(hash_file "$2") || return 1
  printf '%s %s %s\n' "$1" "$SA_NEW_HASH" "$3" >> "$U_B/allowed" || return 1
  mkdir -p "$(dirname "$SA_DEST")" || return 1
  SA_TEMP=$(mktemp "$(dirname "$SA_DEST")/.node-suite-XXXXXXXX") || return 1
  if ! cp -p "$2" "$SA_TEMP" || ! chmod "$3" "$SA_TEMP" || ! mv -f "$SA_TEMP" "$SA_DEST"; then
    rm -f "$SA_TEMP"; return 1
  fi
}
suite_remove(){
  suite_current_allowed "$1" || return 1
  SD_PATH=$(suite_path "$1") || return 1
  printf '%s - -\n' "$1" >> "$U_B/allowed" || return 1
  rm -f "$SD_PATH"
}
suite_wait_helpers(){
  SW_N=0
  while :; do
    SW_BUSY=0
    for SW_PROC in /proc/[0-9]*; do
      [ -r "$SW_PROC/cmdline" ] || continue
      if tr '\000' '\n' < "$SW_PROC/cmdline" 2>/dev/null | awk '
        $0=="/usr/local/sbin/earnapp-watchdog" || $0=="/usr/local/sbin/earnapp-recover" || $0=="/usr/local/sbin/earnapp-limit" ||
        $0=="/usr/local/sbin/node-guard" || $0=="/usr/local/sbin/node-recover" || $0=="/usr/local/sbin/node-limit" {found=1}
        END{exit !found}'; then SW_BUSY=1; break; fi
    done
    [ "$SW_BUSY" = 1 ] || return 0
    [ "$SW_N" -lt 75 ] || { fail 'old helper is still running; the upgrade was cancelled'; return 1; }
    [ "$((SW_N % 15))" != 0 ] || printf '%s\n' 'Waiting for an existing helper to finish...'
    sleep 2; SW_N=$((SW_N+1))
  done
}
suite_pause(){
  printf '%s\n' '#!/bin/sh' '# Temporary node-suite transaction pause.' 'exit 0' > "$U_D/paused"
  if [ -f "$U_B/files/cron" ]; then suite_cron_filter paused "$U_B/files/cron" > "$U_D/cron.paused" || return 1
  else : > "$U_D/cron.paused"; fi
  suite_atomic cron "$U_D/cron.paused" 600 || return 1
  # Atomic replacements also neutralize a cron command already cached before its reload.
  for SP_TAG in old-watchdog old-recover old-limit old-boot watchdog recover limit boot; do
    SP_PATH=$(suite_path "$SP_TAG") || return 1
    [ ! -f "$SP_PATH" ] || suite_atomic "$SP_TAG" "$U_D/paused" 755 || return 1
  done
  suite_wait_helpers || return 1
  exec 7>/run/earnapp-watchdog.lockfile
  flock -n 7 || { fail 'legacy helper lock is busy'; return 1; }
  exec 9>/run/node-guard.lockfile
  flock -n 9 || { fail 'new helper lock is busy'; return 1; }
}
suite_identity(){
  SI_VALUE=$(timeout -k 2 15 "$1" showid 6>&- 7>&- 8>&- 9>&- 2>/dev/null) || return 1
  printf '%s\n' "$SI_VALUE" | awk 'NR==1 && /^sdk-node-[0-9a-f]+$/ && length($0)==41{ok=1} END{exit !(ok && NR==1)}' || return 1
  printf '%s\n' "$SI_VALUE"
}
suite_verify_runtime() (
  exec 6>&-
  . /usr/local/lib/node-runtime.sh || exit 1
  SV_KEY=$(worker_snapshot) || { fail 'managed worker identity is not confirmed'; exit 1; }
  [ -n "$SV_KEY" ] || { fail 'managed worker is missing'; exit 1; }
  [ "$(sdk_state)" = enabled ] || { fail 'SDK is not enabled'; exit 1; }
  SV_PID=${SV_KEY%%:*}
  stats "$SV_PID" || { fail 'worker statistics could not be read'; exit 1; }
  [ "$(worker_snapshot)" = "$SV_KEY" ] || { fail 'worker changed during verification'; exit 1; }
  printf 'worker=%s tcp=%s established=%s udp=%s fd=%s rss_kb=%s\n' "$SV_KEY" "$TCP" "$ESTAB" "$UDP" "$FD" "$RSS"
  if [ "$ESTAB" -gt 0 ]; then printf '%s\n' 'CONNECTION_STATE=ESTABLISHED'
  else printf '%s\n' 'CONNECTION_STATE=PENDING'; fi
)
suite_migration_backup(){
  suite_regular "$1/migration.phase" && [ -f "$1/migration.phase" ] || { fail 'migration phase is missing'; return 2; }
  SMB_PHASE=$(cat "$1/migration.phase") || return 2
  case "$SMB_PHASE" in
    not-started)
      ! exists "$1/migration.ref" && ! exists "$1/migration" || { fail 'unexpected migration record before staging'; return 2; }
      return 1;;
    staging)
      # The engine publishes recorded before its first service mutation.
      # An interrupted staging copy must not leave the old helper entries paused.
      return 1;;
    recorded|complete) :;;
    *) fail 'invalid migration phase'; return 2;;
  esac
  suite_regular "$1/migration.ref" && [ -s "$1/migration.ref" ] || { fail 'recorded migration reference is missing'; return 2; }
  SMB_FOUND=
  for SMB_DIR in "$1"/migration/earnapp-xray-*; do
    exists "$SMB_DIR" || continue
    [ -d "$SMB_DIR" ] && [ ! -L "$SMB_DIR" ] && [ -f "$SMB_DIR/manifest" ] || { fail 'migration record is damaged'; return 2; }
    [ -z "$SMB_FOUND" ] || { fail 'multiple migration records in one transaction'; return 2; }
    SMB_FOUND=$SMB_DIR
  done
  [ -n "$SMB_FOUND" ] && [ "$(cat "$1/migration.ref")" = "$SMB_FOUND" ] || { fail 'recorded migration backup is missing'; return 2; }
  printf '%s\n' "$SMB_FOUND"
}
suite_validate_backup(){
  valid_path "$U_B" && [ -d "$U_B/files" ] && [ -f "$U_B/files.manifest" ] && [ -f "$U_B/allowed" ] && [ -f "$U_B/metadata" ] || return 1
  SV_META_SEEN=' '; SV_META_COUNT=0
  while read -r SV_META SV_DIGEST SV_EXTRA; do
    [ -z "$SV_EXTRA" ] || return 1
    suite_meta_names | grep -Fxq "$SV_META" || return 1
    case "$SV_META_SEEN" in *" $SV_META "*) return 1;; esac
    SV_META_SEEN="$SV_META_SEEN$SV_META "; SV_META_COUNT=$((SV_META_COUNT+1))
    if [ "$SV_DIGEST" = - ]; then
      case "$SV_META" in earnapp_limit.nft|node_limit.nft) ! exists "$U_B/$SV_META" || return 1;; *) return 1;; esac
    else
      [ -f "$U_B/$SV_META" ] && [ ! -L "$U_B/$SV_META" ] && [ "$(hash_file "$U_B/$SV_META")" = "$SV_DIGEST" ] || { fail "backup metadata is missing or changed: $SV_META"; return 1; }
    fi
  done < "$U_B/metadata"
  [ "$SV_META_COUNT" = 10 ] || return 1
  for SV_SERVICE in earnapp crond local; do
    case "$(cat "$U_B/$SV_SERVICE.status")" in 0|1|3) :;; *) return 1;; esac
    while IFS= read -r SV_LEVEL; do valid_name "$SV_LEVEL" || return 1; done < "$U_B/$SV_SERVICE.runlevels" || return 1
  done
  SV_SEEN=' '; SV_COUNT=0
  while read -r SV_TAG SV_PRESENT SV_HASH SV_MODE SV_EXTRA; do
    [ -z "$SV_EXTRA" ] || return 1
    suite_path "$SV_TAG" >/dev/null || return 1
    case "$SV_SEEN" in *" $SV_TAG "*) return 1;; esac
    SV_SEEN="$SV_SEEN$SV_TAG "; SV_COUNT=$((SV_COUNT+1))
    case "$SV_PRESENT" in
      0) [ "$SV_HASH:$SV_MODE" = -:- ] || return 1;;
      1) [ -f "$U_B/files/$SV_TAG" ] && [ ! -L "$U_B/files/$SV_TAG" ] && [ "$(hash_file "$U_B/files/$SV_TAG")" = "$SV_HASH" ] || return 1
        case "$SV_MODE" in ''|*[!0-7]*) return 1;; esac;;
      *) return 1;;
    esac
  done < "$U_B/files.manifest"
  [ "$SV_COUNT" = 16 ] || return 1
  for SV_TAG in $(suite_tags); do suite_current_allowed "$SV_TAG" || return 1; done
  SV_MIG_RC=0; SV_MIG=$(suite_migration_backup "$U_B") || SV_MIG_RC=$?
  [ "$SV_MIG_RC" -le 1 ] || return 1
  if [ "$(cat "$U_B/state")" = active ] && ! grep -Fxq 'MODE=managed' "$U_B/settings"; then
    [ "$(cat "$U_B/migration.phase")" = complete ] && [ "$SV_MIG_RC" = 0 ] || { fail 'completed installation has no complete migration record'; return 1; }
  fi
  if [ "$SV_MIG_RC" = 0 ]; then
    (B=$SV_MIG; load_manifest && check_backup && check_owned) || return 1
  fi
}
suite_restore_tag(){
  SRT_ROW=$(awk -v tag="$1" '$1==tag {print}' "$U_B/files.manifest") || return 1
  set -- $SRT_ROW
  [ "$#" = 4 ] || return 1
  SRT_TAG=$1; SRT_PRESENT=$2; SRT_MODE=$4
  if [ "$SRT_PRESENT" = 1 ]; then suite_atomic "$SRT_TAG" "$U_B/files/$SRT_TAG" "$SRT_MODE"
  else suite_remove "$SRT_TAG"; fi
}
suite_validate_live_tables(){
  SRT_TABLES=$(nft list tables) || return 1
  SRT_SERVICE=$(awk -F= '$1=="SERVICE"{print $2}' "$U_B/settings") || return 1
  valid_name "$SRT_SERVICE" || return 1
  if printf '%s\n' "$SRT_TABLES" | grep -Fxq 'table inet node_limit'; then
    suite_table_owned node_limit "$SRT_SERVICE" node-limit- || { fail 'custom node_limit rules retained during restore'; return 1; }
  fi
  if printf '%s\n' "$SRT_TABLES" | grep -Fxq 'table inet earnapp_limit'; then
    suite_table_owned earnapp_limit earnapp earnapp- || { fail 'custom earnapp_limit rules retained during restore'; return 1; }
  fi
  return 0
}
suite_restore_transaction(){
  suite_validate_backup || { fail "suite backup/file ownership validation failed: $U_B"; return 1; }
  SRT_MIG_RC=0; SRT_MIGRATION=$(suite_migration_backup "$U_B") || SRT_MIG_RC=$?
  [ "$SRT_MIG_RC" -le 1 ] || return 1
  suite_validate_live_tables || return 1
  if [ -n "$SRT_MIGRATION" ]; then
    SRT_STATE=$(cat "$SRT_MIGRATION/state") || return 1
    case "$SRT_STATE" in
      active|switching|rollback-failed)
        (BACKUP_DIR=$SRT_MIGRATION; APPLY=1; cmd_rollback) 6>&- 7>&- 8>&- 9>&- || return 1;;
      rolled-back|failed|prepared) :;; *) return 1;;
    esac
  fi
  for SRT_TAG in $(suite_tags); do
    case "$SRT_TAG" in cron|registry) continue;; esac
    suite_restore_tag "$SRT_TAG" || return 1
  done
  # Reparse saved cgroup paths after the original service has recreated its cgroup.
  : > "$U_D/restore.nft"
  SRT_TABLES=$(nft list tables) || return 1
  for SRT_TABLE in earnapp_limit node_limit; do
    if printf '%s\n' "$SRT_TABLES" | grep -Fxq "table inet $SRT_TABLE"; then
      printf 'delete table inet %s\n' "$SRT_TABLE" >> "$U_D/restore.nft"
    fi
    [ ! -f "$U_B/$SRT_TABLE.nft" ] || cat "$U_B/$SRT_TABLE.nft" >> "$U_D/restore.nft" || return 1
  done
  if [ -s "$U_D/restore.nft" ]; then nft -c -f "$U_D/restore.nft" && nft -f "$U_D/restore.nft" || return 1; fi
  for SRT_SERVICE in earnapp crond local; do
    SRT_LEVELS=$(runlevels_for "$SRT_SERVICE") || return 1
    for SRT_LEVEL in $SRT_LEVELS; do
      grep -Fxq "$SRT_LEVEL" "$U_B/$SRT_SERVICE.runlevels" || rc-update del "$SRT_SERVICE" "$SRT_LEVEL" 6>&- 7>&- 8>&- 9>&- || return 1
    done
    while IFS= read -r SRT_LEVEL; do
      valid_name "$SRT_LEVEL" || return 1
      exists "/etc/runlevels/$SRT_LEVEL/$SRT_SERVICE" || rc-update add "$SRT_SERVICE" "$SRT_LEVEL" 6>&- 7>&- 8>&- 9>&- || return 1
    done < "$U_B/$SRT_SERVICE.runlevels"
  done
  if [ "$(cat "$U_B/crond.status")" = 3 ] && [ "$(service_state crond)" = 0 ]; then
    rc-service crond stop 6>&- 7>&- 8>&- 9>&- || return 1
  fi
  suite_restore_tag registry && suite_restore_tag cron || return 1
  printf '%s\n' rolled-back > "$U_B/state"
  printf 'SUITE_RESTORED\n%s\n' "$U_B"
}
suite_exit(){
  UE_RC=$?
  trap - 0 HUP INT TERM
  if [ "$UE_RC" -ne 0 ] && [ "$U_TX" = 1 ]; then
    printf '%s\n' 'Suite installation failed; restoring the recorded configuration.' >&2
    if ! suite_restore_transaction; then
      printf '%s\n' rollback-failed > "$U_B/state"
      printf 'FAIL: recovery needs review; backup retained: %s\n' "$U_B" >&2
    fi
  fi
  UE_KEEP=0
  if [ "$UE_RC" -ne 0 ]; then
    for UE_BOOT in "$U_D"/bootstrap-*; do [ ! -d "$UE_BOOT/identity" ] || UE_KEEP=1; done
    if [ -n "${U_FOUNDATION:-}" ]; then
      UE_KEEP=1
      printf 'Source preparation record retained: %s\n' "$U_FOUNDATION" >&2
    fi
  fi
  if [ "$UE_KEEP" = 1 ]; then
    printf 'Diagnostic/identity snapshot retained: %s\n' "$U_D" >&2
  else [ -z "$U_D" ] || rm -rf "$U_D"; fi
  [ "${U_DIR_LOCKED:-0}" = 0 ] || rmdir /run/node-suite.setup.lock 2>/dev/null || true
  exit "$UE_RC"
}
cmd_suite_install() (
  suite_preflight || exit 1
  if [ "$APPLY" != 1 ]; then
    printf '%s\n' '[dry-run] install if absent; upgrade recognized helpers; migrate service; verify worker/limiter; publish cron.'
    printf '%s\n' '[dry-run] use install --apply to execute the complete transaction.'
    exit 0
  fi
  if [ "$U_MODE" = managed ] && [ "$U_CURRENT_VERSION" = "$SUITE_VERSION" ] && cmd_suite_status >/dev/null 2>&1; then
    suite_verify_runtime || exit 1
    printf 'ALREADY_CURRENT\n%s\n' "$SUITE_VERSION"
    exit 0
  fi
  U_TX=0; U_B=; U_D=; U_DIR_LOCKED=0; U_FOUNDATION=
  umask 077
  U_D=$(mktemp -d /tmp/node-suite-XXXXXXXX) || exit 1
  trap suite_exit 0
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mkdir /run/node-suite.setup.lock || { fail 'another suite operation or stale setup lock exists'; exit 1; }
  U_DIR_LOCKED=1
  for US_TOOL in bash curl timeout nft ss flock getconf; do
    if ! command -v "$US_TOOL" >/dev/null 2>&1; then
      apk add --no-cache bash wget curl ca-certificates gcompat libstdc++ libgcc coreutils openrc nftables iproute2 flock || exit 1
      break
    fi
  done
  exec 8>/run/node-suite.lockfile
  flock -n 8 || { fail 'another suite installation is running'; exit 1; }
  exec 6>/run/earnapp-setup.lockfile
  flock -n 6 || { fail 'the legacy installer is still running'; exit 1; }
  if [ "$U_MODE" = managed ]; then SDK_BIN=$U_TARGET; fi
  if [ "$U_MODE" = fresh ]; then
    apk add --no-cache bash wget curl ca-certificates gcompat libstdc++ libgcc coreutils openrc nftables iproute2 flock || exit 1
    suite_bootstrap 6>&- 7>&- 8>&- 9>&-; US_BOOT_RC=$?
    [ "$US_BOOT_RC" = 0 ] || exit "$US_BOOT_RC"
  fi
  UPDATER_MAIN_SVC=earnapp
  [ "$U_MODE" != managed ] || UPDATER_MAIN_SVC=$U_SERVICE
  suite_updater_guard "$SDK_BIN" || exit 1
  # Recheck destination/rules after installing any missing utilities or vendor SDK.
  US_TABLES=$(nft list tables) || exit 1
  if [ "$U_MODE" != managed ] && printf '%s\n' "$US_TABLES" | grep -Fxq 'table inet node_limit'; then
    fail 'node_limit appeared before installation'; exit 1
  fi
  US_ID_BEFORE=$(suite_identity "$SDK_BIN") || { fail 'cannot read the existing device identity'; exit 1; }
  if [ -s /etc/earnapp/uuid ]; then cp -p /etc/earnapp/uuid "$U_D/uuid" || exit 1; fi
  mkdir -p "$BACKUP_ROOT" || exit 1
  if [ "$U_PREPARE_SOURCE" = 1 ]; then
    # Vendor installation/source adoption is a separate foundation phase.
    # The migration baseline is the verified running OpenRC source it produces.
    U_B=$(mktemp -d "$BACKUP_ROOT/node-source-$(date -u +%Y%m%d-%H%M%S)-XXXXXXXX") || exit 1
    U_FOUNDATION=$U_B
    suite_snapshot && suite_validate_backup || exit 1
    OLD_SVC=earnapp
    suite_prepare_source 6>&- 7>&- 8>&- 9>&- || {
      fail "source preparation is incomplete; SDK and foundation records retained: $U_FOUNDATION"; exit 1;
    }
    [ "$SOURCE_PREPARED" = 1 ] || exit 1
    [ "$(suite_identity "$SDK_BIN")" = "$US_ID_BEFORE" ] || { fail 'device ID changed during source preparation'; exit 1; }
    [ ! -f "$U_D/uuid" ] || cmp -s "$U_D/uuid" /etc/earnapp/uuid || { fail 'device UUID changed during source preparation'; exit 1; }
    U_PREPARE_SOURCE=0
  fi
  U_B=$(mktemp -d "$BACKUP_ROOT/node-suite-$(date -u +%Y%m%d-%H%M%S)-XXXXXXXX") || exit 1
  suite_snapshot || exit 1
  [ -z "$U_FOUNDATION" ] || printf '%s\n' "$U_FOUNDATION" > "$U_B/source-foundation.ref" || exit 1
  suite_emit_config > "$U_D/config" || exit 1
  mkdir "$U_D/staged" || exit 1
  US_PROGRAM_HASH=$(hash_file "$SDK_BIN") || exit 1
  suite_stage_helpers "$U_D/staged" "$U_TARGET" "$COVER_SVC" "$US_PROGRAM_HASH" || exit 1
  for US_FILE in common watchdog recover limit boot; do sh -n "$U_D/staged/$US_FILE" || exit 1; done
  suite_validate_backup || { fail 'new suite backup validation failed before installation'; exit 1; }
  U_TX=1
  printf 'suite backup: %s\n' "$U_B"
  suite_pause || exit 1
  if [ "$U_MODE" != managed ]; then
    printf '%s\n' staging > "$U_B/migration.phase" || exit 1
    (BACKUP_ROOT="$U_B/migration"; COVER_BIN=$U_TARGET; COVER_ALT=$U_TARGET; OLD_SVC=earnapp; SUITE_INSTALL=1; DEPLOY_REPORT="$U_B/migration.ref"; APPLY=1; cmd_deploy) 6>&- 7>&- 8>&- 9>&- || exit 1
    printf '%s\n' complete > "$U_B/migration.phase" || exit 1
  fi
  : > "$U_B/owned"
  for US_TAG in common watchdog recover limit boot; do
    US_MODE=755; [ "$US_TAG" != common ] || US_MODE=644
    suite_atomic "$US_TAG" "$U_D/staged/$US_TAG" "$US_MODE" || exit 1
    US_HELPER_HASH=$(hash_file "$U_D/staged/$US_TAG") || exit 1
    printf '%s %s\n' "$US_TAG" "$US_HELPER_HASH" >> "$U_B/owned" || exit 1
  done
  suite_atomic config "$U_D/config" 600 || exit 1
  suite_verify_runtime || exit 1
  /usr/local/sbin/node-limit --locked 20 6>&- || { fail 'new limiter verification failed'; exit 1; }
  suite_verify_runtime || exit 1
  US_ID_AFTER=$(suite_identity "$U_TARGET") || exit 1
  [ "$US_ID_AFTER" = "$US_ID_BEFORE" ] || { fail 'device ID changed'; exit 1; }
  [ ! -f "$U_D/uuid" ] || cmp -s "$U_D/uuid" /etc/earnapp/uuid || { fail 'device UUID changed'; exit 1; }
  if printf '%s\n' "$US_TABLES" | grep -Fxq 'table inet earnapp_limit'; then
    suite_table_owned earnapp_limit earnapp earnapp- || exit 1
    nft delete table inet earnapp_limit || exit 1
  fi
  for US_TAG in old-common old-watchdog old-recover old-limit old-boot old-config source-init source-conf; do suite_remove "$US_TAG" || exit 1; done
  cp "$U_D/cron.paused" "$U_D/cron.final" || exit 1
  if [ -f "$U_B/files/cron" ] && grep -Eq '# (EARNAPP-12H-STOPSTART|NODE-RECOVERY)$' "$U_B/files/cron"; then
    printf '%s\n' '0 */12 * * * /usr/local/sbin/node-recover scheduled >/dev/null 2>&1 # NODE-RECOVERY' >> "$U_D/cron.final"
  fi
  printf '%s\n' '*/2 * * * * /usr/local/sbin/node-guard >/dev/null 2>&1 # NODE-GUARD' >> "$U_D/cron.final"
  rc-update add crond default 6>&- 7>&- 8>&- 9>&- && rc-update add local default 6>&- 7>&- 8>&- 9>&- || exit 1
  [ "$(service_state crond)" = 0 ] || rc-service crond start 6>&- 7>&- 8>&- 9>&- || exit 1
  suite_atomic cron "$U_D/cron.final" 600 || exit 1
  printf '%s\n' "$U_B" > "$U_D/registry"
  suite_atomic registry "$U_D/registry" 600 || exit 1
  suite_check_owned "$U_B" && suite_verify_runtime || exit 1
  printf '%s\n' active > "$U_B/state" || exit 1
  U_TX=0
  printf 'INSTALL_STATE=COMPLETE\nVERSION=%s\nSERVICE=%s\nPROGRAM=%s\nDEVICE_ID=%s\nBACKUP=%s\n' "$SUITE_VERSION" "$COVER_SVC" "$U_TARGET" "$US_ID_AFTER" "$U_B"
  printf '%s\n' 'Watchdog: every 2 minutes. Connection limit: 20 flows.' 'Effective numeric overrides:'
  cat /etc/node-guard.conf
)
cmd_suite_status() (
  suite_read_current || { fail 'no verified active unified installation'; exit 1; }
  printf 'VERSION=%s\nSERVICE=%s\nPROGRAM=%s\nBACKUP=%s\n' "$U_CURRENT_VERSION" "$U_SERVICE" "$U_TARGET" "$U_PREVIOUS"
  suite_verify_runtime || exit 1
  suite_table_owned node_limit "$U_SERVICE" node-limit- || { fail 'managed limiter rules are missing or changed'; exit 1; }
  [ -f /etc/crontabs/root ] && grep -Fxq '*/2 * * * * /usr/local/sbin/node-guard >/dev/null 2>&1 # NODE-GUARD' /etc/crontabs/root || { fail 'watchdog schedule is missing'; exit 1; }
  [ "$(service_state crond)" = 0 ] || { fail 'cron daemon is not running'; exit 1; }
  exists /etc/runlevels/default/crond && exists /etc/runlevels/default/local || { fail 'cron/limiter boot activation is missing'; exit 1; }
  printf '%s\n' 'PASS: helper files, worker, limiter and schedule are present.'
)
cmd_suite_restore() (
  require_root || exit 1
  if [ -n "$BACKUP_DIR" ]; then U_B=$BACKUP_DIR
  else U_B=$(cat "$SUITE_REGISTRY" 2>/dev/null) || { fail 'set BACKUP_DIR to an exact suite backup'; exit 1; }; fi
  suite_validate_backup || { fail 'backup validation failed'; exit 1; }
  [ "$(cat "$U_B/state")" != rolled-back ] || { printf '%s\n' 'Already restored.'; exit 0; }
  suite_validate_live_tables || exit 1
  if [ "$APPLY" != 1 ]; then printf '[dry-run] restore files, cron, rules and service using %s\n' "$U_B"; exit 0; fi
  U_D=$(mktemp -d /tmp/node-suite-restore-XXXXXXXX) || exit 1
  U_RESTORE_PHASE=prepare
  trap 'SRC=$?; trap - 0; if [ "$SRC" -ne 0 ] && [ "$U_RESTORE_PHASE" = quiesce ]; then suite_resume_pause || printf "FAIL: paused entry restoration needs review: %s\n" "$U_D" >&2; fi; if [ "$SRC" = 0 ]; then rm -rf "$U_D"; else printf "Restore diagnostic files retained: %s\n" "$U_D" >&2; fi; exit "$SRC"' 0
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  exec 8>/run/node-suite.lockfile
  flock -n 8 || { fail 'another suite operation is running'; exit 1; }
  exec 6>/run/earnapp-setup.lockfile
  flock -n 6 || { fail 'the legacy installer is still running'; exit 1; }
  suite_save_pause || exit 1
  U_RESTORE_PHASE=quiesce
  suite_pause || exit 1
  U_RESTORE_PHASE=restore
  suite_restore_transaction || { printf '%s\n' rollback-failed > "$U_B/state"; exit 1; }
)
suite_save_pause(){
  mkdir "$U_D/resume" || return 1
  : > "$U_D/resume.manifest"
  for SRP_TAG in cron old-watchdog old-recover old-limit old-boot watchdog recover limit boot; do
    SRP_PATH=$(suite_path "$SRP_TAG") || return 1
    suite_current_allowed "$SRP_TAG" || return 1
    if [ -f "$SRP_PATH" ]; then
      cp -p "$SRP_PATH" "$U_D/resume/$SRP_TAG" || return 1
      printf '%s %s\n' "$SRP_TAG" "$(stat -c %a "$SRP_PATH")" >> "$U_D/resume.manifest"
    fi
  done
}
suite_resume_pause(){
  while read -r SRP_TAG SRP_MODE; do
    suite_atomic "$SRP_TAG" "$U_D/resume/$SRP_TAG" "$SRP_MODE" || return 1
  done < "$U_D/resume.manifest"
}

maintenance_cleanup(){
  history -c >/dev/null 2>&1 || true
  rm -f ~/.ash_history ~/.bash_history ~/.zsh_history ~/.sh_history ~/.history \
    /root/.ash_history /root/.bash_history /root/.zsh_history /root/.sh_history /root/.history
  apk cache clean 2>/dev/null || true
  rm -rf /var/cache/apk/* 2>/dev/null || true
  find /tmp /var/tmp -xdev -type f -mtime +1 -delete 2>/dev/null || true
  command -v journalctl >/dev/null 2>&1 && journalctl --vacuum-time=7d >/dev/null 2>&1 || true
  HISTFILE=/dev/null
  HISTSIZE=0
  export HISTFILE HISTSIZE
  if [ -t 0 ] && [ -t 1 ] && [ -x /bin/ash ]; then exec /bin/ash; fi
  return 0
}
cmd_cleanup(){
  if [ "$APPLY" != 1 ]; then
    printf '%s\n' '[dry-run] remove shell history files, package caches and old temporary files; vacuum archived journal entries to 7 days.'
    return 0
  fi
  require_root || return 1
  return 0
}
usage(){
  printf 'usage: sh %s <install|status|restore|precheck|baseline|launch-mode|deploy|accept|rollback|cleanup> [--apply]\n' "$0"
  printf '%s\n' 'install --apply handles fresh installation and helper/service upgrades; status verifies it; restore --apply restores the complete suite.'
  printf '%s\n' 'Optional config: config.local.sh beside this script, or CONFIG_FILE=/absolute/path.'
  printf '%s\n' 'Default LAUNCHER=0 runs directly; LAUNCHER=1 requires a compiler and supervise-daemon.'
  printf '%s\n' 'BACKUP_DIR selects a node-suite backup for restore, or a v2 service backup for rollback.'
  printf '%s\n' 'POST_CLEANUP=0 disables housekeeping after a successful install, restore, deploy or rollback.'
}

case "$POST_CLEANUP" in 0|1) :;; *) fail 'POST_CLEANUP must be 0 or 1'; exit 1;; esac
case "$CMD" in
  precheck) cmd_precheck;;
  baseline) cmd_baseline;;
  launch-mode) cmd_launch_mode;;
  install|upgrade|setup) cmd_suite_install;;
  status) cmd_suite_status;;
  restore) cmd_suite_restore;;
  deploy)
    DEPLOY_HELPERS=0
    for DEPLOY_TAG in old-watchdog old-recover old-limit old-boot; do
      DEPLOY_PATH=$(suite_path "$DEPLOY_TAG") || exit 1
      exists "$DEPLOY_PATH" && DEPLOY_HELPERS=1
    done
    if [ "$DEPLOY_HELPERS" = 1 ]; then fail 'legacy helpers detected; use install --apply for the complete upgrade'; exit 1; fi
    cmd_deploy;;
  accept) cmd_accept;;
  rollback) cmd_rollback;;
  cleanup) cmd_cleanup;;
  -h|--help|help) usage;;
  *) usage; exit 1;;
esac
RC=$?
if [ "$RC" -ne 0 ]; then exit "$RC"; fi
case "$CMD" in
  install|upgrade|setup|restore|deploy|rollback|cleanup)
    if [ "$APPLY" = 1 ]; then
      printf '%s\n' '== SUCCESS =='
      if [ "$POST_CLEANUP" = 1 ] || [ "$CMD" = cleanup ]; then maintenance_cleanup; fi
    else printf '%s\n' '== SUCCESS (dry-run) =='; fi;;
  *) printf '%s\n' '== SUCCESS ==';;
esac
exit 0
