#!/usr/bin/env bash
# MediaEmeet HOST READ-ONLY REPORT. Prints a markdown report about the server so the install plan can be made from facts, not assumptions.
#
# GUARANTEES (checked by scripts/ops/test-host-report.sh):
#   * READ-ONLY: it writes nothing except ONE temp file made with mktemp (removed on exit). No file under the application, /etc, /var, a home
#     directory or the database is created, changed, touched or locked (git is run with GIT_OPTIONAL_LOCKS=0, so even `git status` does not refresh the index).
#   * NO NETWORK: it runs no curl/wget/git fetch/ssh/dig/ping. (`ss`, `ufw status`, `timedatectl` only read local state.)
#   * NO SECRETS: it never prints the value of any .env key except a short allow-list of non-secret identifiers (see ALLOW below); never the
#     contents of any backup, key, token or credentials file (existence, mode, owner, size and age only); never a password hash or a remote URL.
#   * It does not need root. Where root is needed (sudoers contents, postgres, crontabs of other users) it says "skipped: needs root" and continues.
#
# Usage:  bash host-readonly-report.sh [--app-hint /path] [--out FILE]      (no other arguments; FILE is created by the redirect of YOUR shell, not by this script)
# Test hook: MM_REPORT_ROOT=/fake/root makes every absolute FILE path (not commands) resolve under /fake/root.
set -u
export LC_ALL=C GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 PAGER=cat
R="${MM_REPORT_ROOT:-}"; R="${R%/}"; HINT=""
while [ $# -gt 0 ]; do case "$1" in --app-hint) HINT="${2:-}"; shift 2;; --help|-h) sed -n 2,14p "$0"; exit 0;; *) echo "unknown option $1 (this script takes only --app-hint)" >&2; exit 2;; esac; done
# ALLOW: .env keys whose VALUE may be printed. Identifiers and switches, never passwords/keys/tokens. Everything else: key name only.
ALLOW='APP_ENV APP_DEBUG APP_URL MAIL_MAILER'
TMP="$(mktemp)" || { echo "cannot create a temp file" >&2; exit 1; }; trap 'rm -f "$TMP"' EXIT
exec 3>&1 1>"$TMP"        # everything below goes to the temp file; the finished report is printed at the end with its hash

P() { printf '%s\n' "$*"; }
sec() { printf '\n## %s\n\n' "$1"; }
fence() { printf '```\n'; cat; printf '```\n'; }
run() { timeout 10 "$@" 2>&1 | head -n "${LINES_MAX:-60}"; }                      # bounded, never fails the script
have() { command -v "$1" >/dev/null 2>&1; }
note() { P "_NOTE: $*_"; }
meta() { stat -c '%A %U:%G %s bytes, modified %y' -- "$1" 2>/dev/null | sed 's/\.[0-9]* / /; s/ +0000//'; }   # metadata only
age_days() { local m now; m="$(stat -c %Y -- "$1" 2>/dev/null)" || return 1; now="$(date +%s)"; echo $(( (now - m) / 86400 )); }
redact_url() { sed -E 's#(//)[^/@ ]*@#\1<redacted>@#g'; }
envval() { # $1 file $2 key -> last assignment, quotes/CR stripped, userinfo of URLs removed, max 120 chars
  sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?$2[[:space:]]*=[[:space:]]*(.*)$/\2/p" "$1" 2>/dev/null | tail -n1 | tr -d '\r' | sed -E "s/^[\"']//; s/[\"']?[[:space:]]*(#.*)?$//" | redact_url | cut -c1-120; }

P "# MediaEmeet host read-only report"
P
P "Generated (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)  |  run as: $(id -un) (uid $(id -u))  |  report script sha256: $(sha256sum < "$0" | cut -c1-64)"
P "This report is read-only and contains no secret values. See the header of scripts/ops/host-readonly-report.sh for the exact guarantees."
[ -n "$R" ] && P "_TEST MODE: file paths are resolved under ${R}_"
IS_ROOT=0; [ "$(id -u)" = 0 ] && IS_ROOT=1

sec "1. Operating system"
{ [ -r "$R/etc/os-release" ] && grep -E '^(PRETTY_NAME|VERSION_ID|ID)=' "$R/etc/os-release"; echo "kernel: $(uname -srm 2>/dev/null)"; echo "hostname: $(hostname 2>/dev/null)"; echo "uptime: $(uptime -p 2>/dev/null)"; } | fence

sec "2. PHP versions and PHP-FPM units"
{ echo "php CLI: $(have php && php -v 2>/dev/null | head -n1 || echo 'not on PATH')"
  echo "installed php config dirs: $(ls "$R/etc/php" 2>/dev/null | tr '\n' ' ')"
  echo "php binaries: $(ls "$R"/usr/bin/php* 2>/dev/null | sed "s#^$R##" | tr '\n' ' ')"
  echo "-- fpm units (systemd):"; have systemctl && { timeout 10 systemctl list-unit-files --no-legend --no-pager 'php*fpm*' 2>&1 | head -n 20; timeout 10 systemctl list-units --all --no-legend --no-pager 'php*fpm*' 2>&1 | head -n 20; } || echo "systemctl not available"
  echo "-- fpm pools (user/group/listen only):"
  for f in "$R"/etc/php/*/fpm/pool.d/*.conf; do [ -f "$f" ] || continue; echo "${f#$R}: $(grep -E '^[[:space:]]*(user|group|listen|listen.owner|listen.group)[[:space:]]*=' "$f" 2>/dev/null | tr -s ' ' | tr '\n' ';')"; done; } | fence

sec "3. Web server and the virtual host for app.mediaemeet.com"
DOCROOTS=""
{ for s in nginx apache2 httpd caddy; do have systemctl && echo "$s: $(timeout 5 systemctl is-active "$s" 2>&1 | head -n1) / enabled: $(timeout 5 systemctl is-enabled "$s" 2>&1 | head -n1)"; done
  echo "-- vhost files that mention app.mediaemeet.com (directives server_name, root, listen, fastcgi_pass, DocumentRoot, SetHandler only):"
  found=0
  for f in "$R"/etc/nginx/sites-enabled/* "$R"/etc/nginx/conf.d/*.conf "$R"/etc/nginx/nginx.conf "$R"/etc/apache2/sites-enabled/* "$R"/etc/httpd/conf.d/*.conf; do
    [ -f "$f" ] || continue; grep -qi 'app\.mediaemeet\.com' "$f" 2>/dev/null || continue; found=1
    echo "[${f#$R}] ($(meta "$f"))"
    grep -E -i '^[[:space:]]*(server_name|root|listen|fastcgi_pass|DocumentRoot|ServerName|ServerAlias|SetHandler|ProxyPassMatch)[[:space:]]' "$f" | sed -E 's/;[[:space:]]*$//; s/^[[:space:]]+//'
  done; [ $found = 0 ] && echo "(no vhost file mentioning app.mediaemeet.com was found; Caddy, Plesk/cPanel or a file outside the usual folders is possible)"; } | fence
for f in "$R"/etc/nginx/sites-enabled/* "$R"/etc/nginx/conf.d/*.conf "$R"/etc/apache2/sites-enabled/* "$R"/etc/httpd/conf.d/*.conf; do
  [ -f "$f" ] && grep -qi 'app\.mediaemeet\.com' "$f" 2>/dev/null && DOCROOTS="$DOCROOTS $(grep -E -i '^[[:space:]]*(root|DocumentRoot)[[:space:]]' "$f" | awk '{print $2}' | tr -d ';"')"; done

sec "4. Application path candidates"
CANDS=""; add() { case " $CANDS " in *" $1 "*) ;; *) CANDS="$CANDS $1";; esac; }
[ -n "$HINT" ] && add "${HINT%/}"
for d in $DOCROOTS; do d="${d%/}"; add "${d%/public}"; done
for base in /var/www /srv /home /opt /var/lib/mediaemeet-agent; do for a in "$R$base"/*/artisan "$R$base"/*/*/artisan "$R$base"/artisan; do [ -f "$a" ] && add "$(dirname "${a#$R}")"; done; done
{ if [ -z "$CANDS" ]; then echo "(no Laravel application found: no directory with an 'artisan' file under /var/www, /srv, /home, /opt)"; else
  for c in $CANDS; do d="$R$c"; printf '%s  exists=%s artisan=%s .git=%s .env=%s public/index.php=%s symlink=%s\n' "$c" "$([ -d "$d" ] && echo y || echo n)" "$([ -f "$d/artisan" ] && echo y || echo n)" "$([ -e "$d/.git" ] && echo y || echo n)" "$([ -f "$d/.env" ] && echo y || echo n)" "$([ -f "$d/public/index.php" ] && echo y || echo n)" "$([ -L "$d" ] && readlink "$d" || echo no)"; done; fi
  echo "web docroot(s) from vhost:$DOCROOTS"; } | fence
APPS=""; for c in $CANDS; do [ -f "$R$c/artisan" ] && APPS="$APPS $c"; done

sec "5. Live checkout state (git, read-only)"
if ! have git; then note "git not installed"; elif [ -z "$APPS" ]; then note "no application path found"; else
  for c in $APPS; do d="$R$c"; { echo "path: $c"
    if [ -e "$d/.git" ]; then
      g() { git -c safe.directory='*' -C "$d" "$@" 2>&1; }
      echo "HEAD: $(g rev-parse HEAD | head -n1)"; echo "branch: $(g rev-parse --abbrev-ref HEAD | head -n1)"
      echo "last commit: $(g log -1 --format='%cI %s' | cut -c1-100)"
      echo "git status --porcelain: $(g status --porcelain --untracked-files=normal | grep -c .) changed/untracked path(s)"
      echo "stash entries: $(g stash list | grep -c .)"
      echo "release marker file RELEASE: $([ -f "$d/RELEASE" ] && head -c 60 "$d/RELEASE" | tr -d '\n' || echo none)"
    else echo "not a git checkout (no .git): releases here may be unpacked archives or symlinked release directories"; fi
    [ -d "$d/releases" ] && echo "releases/ dir present: $(ls "$d/releases" | wc -l) entries"; [ -L "$d/current" ] && echo "current -> $(readlink "$d/current")"
    echo "owner/mode of path: $(meta "$d")"; } | fence; done; fi

sec "6. Application .env (key NAMES only; values only for the allow-list)"
if [ -z "$APPS" ]; then note "no application path found"; else for c in $APPS; do e="$R$c/.env"; { echo "file: $c/.env"
  if [ ! -f "$e" ]; then echo "(absent)"; elif [ ! -r "$e" ]; then echo "present but not readable by $(id -un): $(meta "$e")"; else
    echo "metadata: $(meta "$e")"; echo "key count: $(grep -c -E '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' "$e")"
    echo "-- key names:"; sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\2/p' "$e" | sort -u | tr '\n' ' '; echo
    echo "-- allow-listed values:"; for k in $ALLOW; do grep -q -E "^[[:space:]]*(export[[:space:]]+)?$k[[:space:]]*=" "$e" && echo "$k=$(envval "$e" "$k")" || echo "$k=<unset>"; done
    echo "-- distribution/mail-distribution keys present (names only; a name here means the flag is SET, its value is deliberately not printed): $(sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_]*DISTRIBUTION[A-Za-z_]*)[[:space:]]*=.*/\2/p' "$e" | sort -u | tr '\n' ' ')"
    echo "-- secret-named keys present (names only): $(sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_]*(PASSWORD|SECRET|TOKEN|KEY)[A-Za-z_]*)[[:space:]]*=.*/\2/p' "$e" | sort -u | tr '\n' ' ')"
  fi; } | fence; done; fi

sec "7. Database roles, attributes and size (via sudo -u postgres, only if available without a password)"
if have sudo && have psql && timeout 10 sudo -n -u postgres true >/dev/null 2>&1; then
  PSQ() { timeout 15 sudo -n -u postgres psql -X -At -F ' | ' -c "$1" 2>&1 | head -n 40; }
  { echo "-- roles: name | superuser | createrole | createdb | login | bypassrls | replication  (NO password data is queried)"
    PSQ "select rolname, rolsuper, rolcreaterole, rolcreatedb, rolcanlogin, rolbypassrls, rolreplication from pg_roles where rolname !~ '^pg_' order by 1"
    echo "-- role memberships (member -> granted role)"
    PSQ "select r.rolname || ' -> ' || g.rolname from pg_auth_members m join pg_roles r on r.oid=m.member join pg_roles g on g.oid=m.roleid where r.rolname !~ '^pg_' order by 1"
    echo "-- databases: name | owner | size"
    PSQ "select datname, pg_get_userbyid(datdba), pg_size_pretty(pg_database_size(datname)) from pg_database where not datistemplate order by 1"; } | fence
else note "skipped: needs 'sudo -n -u postgres' without a password (not available to $(id -un)); ask InterServer or run as root. Nothing was attempted against the database."; fi

sec "8. Disk space"
{ df -hP "$R/" 2>&1 | head -n 5; for c in $APPS; do [ -d "$R$c" ] && df -hP "$R$c" 2>&1 | tail -n 1; done; echo "inodes:"; df -iP "$R/" 2>&1 | tail -n 1; } | fence

sec "9. Cron and systemd units mentioning mm / mediaemeet"
PAT='mediaemeet|(^|[^a-z0-9])mm[-_.]|mm-agent|deploy-agent'
{ echo "-- /etc/cron*:"; grep -rIlE "$PAT" "$R"/etc/cron.d "$R"/etc/crontab "$R"/etc/cron.daily "$R"/etc/cron.hourly "$R"/etc/cron.weekly "$R"/etc/cron.monthly 2>/dev/null | sed "s#^$R##"
  for f in $(grep -rIlE "$PAT" "$R"/etc/cron.d "$R"/etc/crontab 2>/dev/null); do echo "[${f#$R}]"; grep -E "$PAT" "$f" | grep -vE '^[[:space:]]*#' | head -n 10 | redact_url; done
  echo "-- user crontabs:"; if [ -d "$R/var/spool/cron/crontabs" ] && [ ! -r "$R/var/spool/cron/crontabs" ]; then echo "skipped: needs root"; else for f in "$R"/var/spool/cron/crontabs/* "$R"/var/spool/cron/*; do [ -f "$f" ] && echo "$(basename "$f"): $(grep -cE "$PAT" "$f") matching line(s); schedule lines: $(grep -E "$PAT" "$f" | grep -vE '^[[:space:]]*#' | head -n 5 | cut -c1-140 | redact_url | tr '\n' '|')"; done; fi
  echo "-- systemd unit files:"; grep -rIlE "$PAT" "$R"/etc/systemd/system "$R"/lib/systemd/system "$R"/usr/lib/systemd/system 2>/dev/null | sed "s#^$R##" | head -n 30
  have systemctl && { echo "-- systemd units/timers (name state):"; timeout 10 systemctl list-units --all --no-legend --no-pager 2>/dev/null | grep -iE "$PAT" | awk '{print $1, $3, $4}' | head -n 20; timeout 10 systemctl list-timers --all --no-legend --no-pager 2>/dev/null | grep -iE "$PAT" | head -n 10; }; } | fence

sec "10. Queue workers"
{ echo "-- processes (artisan queue:work/horizon):"; ps -eo user,pid,etime,args 2>/dev/null | grep -E 'queue:work|queue:listen|horizon' | grep -v grep | cut -c1-160 | head -n 10
  echo "-- units:"; have systemctl && timeout 10 systemctl list-units --all --no-legend --no-pager 2>/dev/null | grep -iE 'queue|horizon|worker|supervisor' | awk '{print $1, $3, $4}' | head -n 10
  echo "-- supervisor programs:"; ls "$R/etc/supervisor/conf.d" 2>/dev/null; } | fence
note "if the three blocks above are empty the application has no queue worker (queued jobs, if any, are not running)."

sec "11. Existing backups (names, ages, sizes; contents are never read)"
BK=""; for d in /var/backups /var/backups/mediaemeet /var/lib/mediaemeet-agent/backups /root/backups /backup /backups /home/*/backups /home/*/mm-backups /srv/backups; do for x in $R$d; do [ -d "$x" ] && BK="$BK ${x#$R}"; done; done
{ if [ -z "$BK" ]; then echo "(no backup directory found in the usual places)"; else for d in $BK; do x="$R$d"
  if [ ! -r "$x" ]; then echo "$d: exists but is not readable by $(id -un) ($(meta "$x")); skipped: needs root"; continue; fi
  echo "[$d] $(meta "$x") ; $(find "$x" -maxdepth 2 -type f 2>/dev/null | wc -l) file(s)"
  find "$x" -maxdepth 2 -type f -printf '%T@ %s %p\n' 2>/dev/null | sort -rn | head -n 8 | while read -r t s p; do echo "  $(basename "$p")  age=$(( ($(date +%s) - ${t%.*}) / 86400 ))d  size=$s  mode=$(stat -c %A "$p")"; done; done; fi
  echo "-- off-server / recipient / rehearsal settings (existence, mode, owner ONLY):"
  for f in /var/lib/mediaemeet-agent/.mm-owner.env /var/lib/mediaemeet-agent/.mm-backup-recipient /var/lib/mediaemeet-agent/.mm-backup-offsite.conf /var/lib/mediaemeet-agent/.mm-rehearsal.env /home/*/.mm-owner.env /home/*/.mm-backup-recipient /home/*/.mm-backup-offsite.conf /home/*/.mm-rehearsal.env /home/*/.mm-approved-shas /root/.mm-owner.env /root/.mm-backup-offsite.conf /root/.config/rclone/rclone.conf /home/*/.config/rclone/rclone.conf; do for x in $R$f; do [ -e "$x" ] && echo "present: ${x#$R}  ($(stat -c '%A %U:%G %s bytes' "$x" 2>/dev/null))"; done; done
  echo "-- tools: age=$(have age && echo yes || echo no) pg_dump=$(have pg_dump && echo yes || echo no) rclone=$(have rclone && echo yes || echo no) rsync=$(have rsync && echo yes || echo no)"; } | fence
note "an offsite setting that is 'present' proves a file exists, not that off-server copies arrive. Restore rehearsal evidence must come from scripts/backup.sh logs, not from this report."

sec "12. Users, groups and sudo for deployment"
{ for u in deploy mmdeploy mm-exec www-data postgres; do l="$(grep -E "^$u:" "$R/etc/passwd" 2>/dev/null)"; [ -n "$l" ] && echo "user $u: uid=$(echo "$l" | cut -d: -f3) home=$(echo "$l" | cut -d: -f6) shell=$(echo "$l" | cut -d: -f7) groups=$(grep -E "(^|[:,])$u(,|$)" "$R/etc/group" 2>/dev/null | cut -d: -f1 | tr '\n' ',')" || echo "user $u: absent"; done
  echo "-- sudoers.d file names:"; if [ -d "$R/etc/sudoers.d" ]; then for f in "$R"/etc/sudoers.d/*; do [ -f "$f" ] && echo "${f#$R}  $(stat -c '%A %U:%G %s bytes' "$f")"; done; else echo "(no /etc/sudoers.d)"; fi
  SUDO_READ=0; for f in "$R/etc/sudoers" "$R"/etc/sudoers.d/*; do [ -f "$f" ] && [ -r "$f" ] && SUDO_READ=1; done
  if [ "$SUDO_READ" = 1 ]; then echo "-- sudoers lines granting the deploy identities (comment lines dropped):"; grep -hE '^[^#]*\b(deploy|mmdeploy|mm-exec)\b' "$R"/etc/sudoers "$R"/etc/sudoers.d/* 2>/dev/null | cut -c1-240 | head -n 20
  else echo "sudoers contents: skipped: needs root"; fi
  echo "-- command paths: $(for t in php composer npm npx node git systemctl age psql pg_dump; do printf '%s=%s ' "$t" "$(command -v "$t" 2>/dev/null || echo -)"; done)"
  echo "-- ssh: authorized_keys for deploy (count only): $(grep -c . "$R/home/deploy/.ssh/authorized_keys" 2>/dev/null || echo n/a)"
  echo "-- sshd effective hardening (from config files; no secrets): $(grep -hE '^[[:space:]]*(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|AllowUsers|Port)[[:space:]]' "$R"/etc/ssh/sshd_config "$R"/etc/ssh/sshd_config.d/*.conf 2>/dev/null | tr -s ' ' | tr '\n' ';')"; } | fence

sec "13. Firewall summary"
{ if have ufw; then echo "ufw: $(timeout 5 ufw status 2>&1 | head -n 1)"; timeout 5 ufw status 2>&1 | sed -n '2,25p'; else echo "ufw: not installed"; fi
  have nft && echo "nftables: $(timeout 5 nft list ruleset 2>&1 | head -n 1 | cut -c1-100) ; rule lines: $(timeout 5 nft list ruleset 2>/dev/null | grep -c .)"
  have iptables && echo "iptables: $(timeout 5 iptables -S 2>&1 | head -n 1 | cut -c1-100) ; rules: $(timeout 5 iptables -S 2>/dev/null | grep -c .)"
  have firewall-cmd && echo "firewalld: $(timeout 5 firewall-cmd --state 2>&1 | head -n 1)"; } | fence
note "InterServer VPS firewalls are often provider-side (control panel) and invisible here."

sec "14. Listening ports"
{ if have ss; then timeout 5 ss -ltnH 2>&1 | awk '{print $4, $1}' | sort -u | head -n 40; else echo "ss not available"; fi; } | fence

sec "15. Time"
{ if have timedatectl; then timeout 5 timedatectl show -p Timezone -p NTPSynchronized -p NTP -p TimeUSec 2>&1 | head -n 6; else echo "timedatectl not available"; fi
  echo "/etc/timezone: $(cat "$R/etc/timezone" 2>/dev/null || echo n/a)"; echo "date: $(date -u +%FT%TZ)"
  for s in chrony chronyd systemd-timesyncd ntp ntpd; do have systemctl && timeout 5 systemctl is-active "$s" 2>/dev/null | grep -q '^active' && echo "time service active: $s"; done; } | fence

P
P "---"
P "Report ends. The next line is the SHA-256 of every byte of this report ABOVE that line (including its final newline). Verify with: head -n -1 report.md | sha256sum"
exec 1>&3 3>&-
cat "$TMP"; printf 'report-sha256: %s\n' "$(sha256sum < "$TMP" | cut -c1-64)"
