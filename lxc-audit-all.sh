#!/bin/sh
LC_ALL=C
export LC_ALL
for tool in awk head tr readlink find ls id; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf '缺少命令：%s；未进行检查。\n' "$tool" >&2
        exit 2
    }
done

section() { printf '\n========== %s ==========\n' "$*"; }
query() {
    command -v "$1" >/dev/null 2>&1 || { printf '[未安装] %s\n' "$1"; return; }
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 2 15 "$@" 2>&1
    else
        "$@" 2>&1
    fi
    status=$?
    [ "$status" -eq 0 ] || printf '[查询失败或超时，退出码=%s] %s\n' "$status" "$1"
    return 0
}
limit() {
    awk -v n="$1" 'NR<=n {print} END {if(NR>n) printf "[本节另有 %d 行未显示]\n",NR-n}'
}
show_files() {
    for f in "$@"; do
        [ -f "$f" ] || [ -L "$f" ] || continue
        real=$(readlink -f "$f" 2>/dev/null)
        [ -n "$real" ] || real=$f
        case "$seen_files" in *"|$real|"*) continue ;; esac
        seen_files="$seen_files$real|"
        printf '\n[文件] %s\n' "$f"
        [ ! -L "$f" ] || printf '链接目标: %s\n' "$(readlink "$f" 2>/dev/null)"
        if [ ! -f "$f" ] || [ ! -r "$f" ]; then
            printf '[跳过内容：不可读、目标不是普通文件或链接失效]\n'
            continue
        fi
        head -c 65536 "$f" 2>/dev/null | tr -d '\000' | awk '
            /^[[:space:]]*([#;]|$)/ {next}
            {n++; if(n<=80) printf "%d: %s\n",NR,$0}
            END {if(n>80) print "[后续内容未显示]"}
        '
    done
}
show_links() {
    for link in "$@"; do
        [ -L "$link" ] || continue
        printf '%s -> %s\n' "$link" "$(readlink "$link" 2>/dev/null)"
    done
}
unit_dir() {
    [ -d "$1" ] || return 0
    show_files "$1"/*.service "$1"/*.timer "$1"/*.socket "$1"/*.path "$1"/*.d/*.conf
    show_links "$1"/*.wants/* "$1"/*.requires/*
}
redact() {
    awk '
    {
        line=$0
        esc=sprintf("%c",27)
        gsub(esc "\\[[0-?]*[ -/]*[@-~]", "", line)
        gsub(/[[:cntrl:]]/, " ", line)
        low=tolower(line)
        re="([[:alnum:]_-]*(password|passwd|token|secret|api_key|api-key|apikey|private_key|private-key)[[:alnum:]_-]*|authorization|environment)[[:space:]]*[:=][[:space:]]*"
        pos=0
        if(match(low,re)) pos=RSTART+RLENGTH-1
        if(match(low,/--?(password|passwd|token|secret|api-key|apikey|private-key|authorization)([[:space:]]+|=)/)) {
            p=RSTART+RLENGTH-1; if(!pos || p<pos) pos=p
        }
        if(match(low,/(^|[[:space:]"=])-t[[:space:]]+/)) {
            p=RSTART+RLENGTH-1; if(!pos || p<pos) pos=p
        }
        if(match(low,/:\/\/[^[:space:]\/]+@/)) {
            p=RSTART+2; if(!pos || p<pos) pos=p
        }
        if(pos) line=substr(line,1,pos) "[REDACTED]（本行后续内容已隐藏）"
        print line
    }'
}
main() {
    seen_files='|'
    section '本机全量盘点：无程序名称过滤'
    printf '主机: %s\n时间: %s\n' "$(hostname 2>/dev/null)" "$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null)"
    printf '范围：当前容器可见的进程、服务、自启、计划任务、网络及常见程序目录。\n'
    printf '只读查询；不执行发现的脚本，不联网下载，不停止服务，不修改配置。\n'
    printf '配置预览上限：每文件64KiB、80条有效行；进程命令行上限16KiB。\n'
    printf '匹配常见凭据字段后省略该行余下内容；自动脱敏不能保证覆盖所有秘密。\n'
    [ "$(id -u)" = 0 ] || printf '[注意] 建议用root运行；当前权限可能造成漏项。\n'
    show_files /etc/os-release
    query uname -a

    section '1. 全部可见进程：PID、父进程、UID、内存、路径和参数'
    skip=" $$ "
    parent=$$
    while [ "$parent" -gt 1 ] 2>/dev/null; do
        parent=$(awk '/^PPid:/ {print $2;exit}' "/proc/$parent/status" 2>/dev/null)
        case "$parent" in ''|*[!0-9]*) break ;; esac
        case "$skip" in *" $parent "*) break ;; esac
        [ "$parent" -eq 1 ] && break
        skip="$skip$parent "
    done
    count=0
    for proc in /proc/[0-9]*; do
        [ -d "$proc" ] || continue
        pid=${proc##*/}
        case "$skip" in *" $pid "*) continue ;; esac
        count=$((count+1))
        printf '\nPID=%s\n' "$pid"
        awk '/^(Name|PPid|Uid|VmRSS):/ {print}' "$proc/status" 2>/dev/null
        printf 'EXE: %s\nCWD: %s\n' "$(readlink "$proc/exe" 2>/dev/null)" "$(readlink "$proc/cwd" 2>/dev/null)"
        if [ -r "$proc/cmdline" ]; then
            printf 'CMD: '
            head -c 16384 "$proc/cmdline" 2>/dev/null | tr '\000\n' '  '
            printf '\n'
        else
            printf '[命令行不可读：权限不足或进程已退出]\n'
        fi
    done
    printf '\n进程条目数: %s（不含审计主进程及其父级shell；不是原子快照）\n' "$count"

    section '2. 服务管理器查询'
    if command -v rc-status >/dev/null 2>&1; then query rc-status -a; fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        query systemctl --no-pager --plain list-units --all --type=service,timer,socket,path
        query systemctl --no-pager list-unit-files --type=service,timer,socket,path
    fi

    section '3. OpenRC、SysV、systemd服务及启动配置'
    show_files /etc/init.d/* /etc/conf.d/* /etc/inittab /etc/rc.local /etc/local.d/*.start
    for sd in /etc/systemd/system /etc/systemd/system.control /run/systemd/system \
        /run/systemd/system.control /run/systemd/transient /run/systemd/generator* \
        /usr/local/lib/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
        unit_dir "$sd"
    done

    section '4. 系统开机启动链接'
    show_links /etc/runlevels/*/* /etc/rc[0-6S].d/*
    show_links /etc/systemd/system/*.wants/* /etc/systemd/system/*.requires/* \
        /run/systemd/system/*.wants/* /run/systemd/system/*.requires/*

    section '5. 全用户Cron、周期任务'
    show_files /etc/crontab /etc/anacrontab /etc/crontabs/* /etc/cron.d/* \
        /var/spool/cron/* /var/spool/cron/crontabs/*
    for pf in /etc/periodic/*/* /etc/cron.hourly/* /etc/cron.daily/* /etc/cron.weekly/* /etc/cron.monthly/*; do
        [ -f "$pf" ] || [ -L "$pf" ] || continue
        printf '[周期脚本：仅列出，不执行] '
        ls -ld "$pf" 2>/dev/null
    done

    section '6. 其他进程管理器、登录自启及默认位置的用户服务'
    show_files /etc/supervisord.conf /etc/supervisor/supervisord.conf \
        /etc/supervisor/conf.d/* /etc/supervisor.d/* \
        /etc/sv/*/run /etc/service/*/run /var/service/*/run \
        /etc/profile /etc/profile.d/*.sh /etc/bash.bashrc \
        /etc/user/init.d/* /etc/user/conf.d/*
    unit_dir /etc/systemd/user
    unit_dir /usr/lib/systemd/user
    awk -F: '$6 ~ /^\// && $6 != "/" && !seen[$6]++ {print $6}' /etc/passwd 2>/dev/null |
    while IFS= read -r home; do
        [ -d "$home" ] || continue
        show_files "$home/.profile" "$home/.bash_profile" "$home/.bashrc" "$home/.zshrc" \
            "$home"/.config/rc/init.d/* "$home"/.config/rc/conf.d/*
        show_links "$home"/.config/rc/runlevels/*/*
        unit_dir "$home/.config/systemd/user"
    done

    section '7. 监听端口与当前TCP/UDP套接字：不发起端口扫描'
    if command -v ss >/dev/null 2>&1; then
        query ss -tunap | limit 500
    elif command -v netstat >/dev/null 2>&1; then
        query netstat -tunap | limit 500
    else
        printf '[无ss/netstat；以下为/proc网络表原始十六进制内容]\n'
        show_files /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6
    fi

    section '8. 常见项目目录：只列路径，不读取应用配置或数据库'
    for pd in /opt /srv /var/www /usr/local/bin /usr/local/sbin /root; do
        [ -d "$pd" ] || continue
        printf '\n[目录，最多向下两层] %s\n' "$pd"
        query find "$pd" -xdev -maxdepth 2 -mindepth 1 \
            \( -name .ssh -o -name .cache -o -name .git -o -name .gnupg \) -prune -o -print | limit 300
    done

    section '9. 已安装软件包：也包含未运行的软件，不代表都在提供服务'
    if command -v apk >/dev/null 2>&1; then
        query apk info
    elif command -v dpkg-query >/dev/null 2>&1; then
        query dpkg-query -W '-f=${binary:Package}\t${Version}\n'
    elif command -v rpm >/dev/null 2>&1; then
        query rpm -qa
    else
        printf '[未发现支持的软件包查询工具]\n'
    fi

    section '结束'
    printf '%s\n' \
        '这是资产和启动项清单，不是恶意软件鉴定，也不判定是否违反商家条款。' \
        '程序存在、配置存在、自启链接存在、当前正在运行是不同事实。' \
        '不递归分析脚本调用，不检查二进制内容，不穷举所有磁盘目录。' \
        '权限、非标准目录、隐藏/改名程序及采样期间的变化都可能造成漏项。' \
        '报告可能仍包含敏感参数、IP和路径；请人工检查后再分享。'
}
main | redact
