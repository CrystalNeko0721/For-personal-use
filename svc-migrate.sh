#!/bin/sh
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
running_target_pids(){
  RT_HASH=$(hash_file "$T") || return 1
  RT_CANON=$(readlink -f "$T") || return 1
  for RT_PROC in /proc/[0-9]*; do
    RT_EXE=$(readlink "$RT_PROC/exe" 2>/dev/null) || continue
    [ "${RT_EXE% (deleted)}" = "$RT_CANON" ] || continue
    RT_ACTUAL=$(hash_file "$RT_PROC/exe") || continue
    [ "$RT_ACTUAL" = "$RT_HASH" ] && printf '%s\n' "${RT_PROC##*/}"
  done
  return 0
}
worker_pid(){
  if [ -n "${WORKER_PID:-}" ]; then
    case "$WORKER_PID" in *[!0-9]*|'') fail 'WORKER_PID must be numeric'; return 1;; esac
    [ -r "/proc/$WORKER_PID/status" ] || { fail 'WORKER_PID is not running'; return 1; }
    printf '%s\n' "$WORKER_PID"
    return 0
  fi
  WP_CANDIDATES=$(pids_by_exe_hash) || return 1
  for WP_PID in $WP_CANDIDATES; do
    if tr '\0' '\n' < "/proc/$WP_PID/cmdline" 2>/dev/null | grep -Fxq -- run; then
      printf '%s\n' "$WP_PID"; return 0
    fi
  done
  printf '%s\n' "$WP_CANDIDATES" | head -n 1
}
show_candidates(){
  printf '%s\n' '-- executable-matched candidates --'
  SC_PIDS=$(pids_by_exe_hash) || return 1
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
  for PP_TOOL in rc-service rc-update sha256sum awk mktemp; do need "$PP_TOOL" || return 1; done
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
  for CD_TOOL in rc-service rc-update sha256sum awk mktemp cmp cp ln stat; do need "$CD_TOOL" || exit 1; done
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
  printf '== accept %s ==\nbackup: %s\n' "$(date -u '+%F %T')" "$B"
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
  printf '%s\n' 'PASS: service state and running executable match the recorded deployment.'
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
  printf 'usage: sh %s <precheck|baseline|launch-mode|deploy|accept|rollback|cleanup> [--apply]\n' "$0"
  printf '%s\n' 'Optional config: config.local.sh beside this script, or CONFIG_FILE=/absolute/path.'
  printf '%s\n' 'Default LAUNCHER=0 runs directly; LAUNCHER=1 requires a compiler and supervise-daemon.'
  printf '%s\n' 'BACKUP_DIR selects an exact v2 backup for rollback.'
  printf '%s\n' 'POST_CLEANUP=0 disables automatic housekeeping after successful deploy/rollback.'
}

case "$POST_CLEANUP" in 0|1) :;; *) fail 'POST_CLEANUP must be 0 or 1'; exit 1;; esac
case "$CMD" in
  precheck) cmd_precheck;;
  baseline) cmd_baseline;;
  launch-mode) cmd_launch_mode;;
  deploy) cmd_deploy;;
  accept) cmd_accept;;
  rollback) cmd_rollback;;
  cleanup) cmd_cleanup;;
  -h|--help|help) usage;;
  *) usage; exit 1;;
esac
RC=$?
if [ "$RC" -ne 0 ]; then exit "$RC"; fi
case "$CMD" in
  deploy|rollback|cleanup)
    if [ "$APPLY" = 1 ]; then
      printf '%s\n' '== SUCCESS =='
      if [ "$POST_CLEANUP" = 1 ] || [ "$CMD" = cleanup ]; then maintenance_cleanup; fi
    else printf '%s\n' '== SUCCESS (dry-run) =='; fi;;
  *) printf '%s\n' '== SUCCESS ==';;
esac
exit 0
