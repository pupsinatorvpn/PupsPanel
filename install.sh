#!/bin/sh
set -eu
umask 077
export GOMEMLIMIT=48MiB GOGC=50
VERSION=0.8.2
REPO=pupsinatorvpn/PupsPanel
MIRROR=https://download.pupsinator.ru
CORE_VERSION=0.10.1
CORE_FAMILY=Xray-rust
CORE_ASSET_PREFIX=pupspanel-core
PAYLOAD_SHA=b418026456bca5d55ac5749fac21a3dc20dd346f4af29e2efa069a998a04eb2b
error() { echo "PupsPanel: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || error 'Запустите установщик от root на роутере.'
[ -f /etc/openwrt_release ] || error 'Требуется OpenWrt.'
for owned in /etc/pupsinator /etc/pupsinator-rollback /etc/pupspanel-core-rollback /usr/bin/pupsinator-xray /usr/bin/pupsinator-xray.new; do
 [ ! -L "$owned" ] || error 'Обнаружена неожиданная символическая ссылка в файлах приложения.'
done
. /etc/openwrt_release
case "$DISTRIB_RELEASE" in 24.10.*|25.12.*) ;; *) error 'Требуется OpenWrt 24.10 или 25.12.';; esac
if [ "$CORE_FAMILY" = Xray-rust ]; then
 case "$(uname -m)" in aarch64|arm64) ;; *) error 'Проверенная сборка Rust пока только для ARM64.';; esac
fi
case "$(uname -m)" in
 aarch64|arm64) CORE_ARCH=arm64; CORE_SHA=762d92c929d6982c275f2928ff512ae76e43973b4456ef8e3a1ae16af86affe4; CORE_GZIP_SHA=c4509b28a87bc1d8530148d797ebccb7184ee922dc430f08deac27bc71288e05 ;;
 x86_64|amd64) CORE_ARCH=amd64; CORE_SHA=0000000000000000000000000000000000000000000000000000000000000000; CORE_GZIP_SHA=0000000000000000000000000000000000000000000000000000000000000000 ;;
 mips|mipsel|mipsle)
  package_arch=$(apk --print-arch 2>/dev/null || opkg print-architecture 2>/dev/null || true)
  case "$package_arch" in *mipsel*|*mipsle*) CORE_ARCH=mipsel; CORE_SHA=0000000000000000000000000000000000000000000000000000000000000000; CORE_GZIP_SHA=0000000000000000000000000000000000000000000000000000000000000000;; *) error 'Не подтверждена little-endian архитектура MIPS. Установка остановлена.';; esac
 ;;
 *) error 'Архитектура пока не поддерживается. Установка не начата.';;
esac
memory=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
[ "$memory" -ge 110000 ] || error 'Нужно не менее 128 МБ установленной RAM; рекомендуется 256 МБ.'
[ "$memory" -ge 180000 ] || export GOMEMLIMIT=32MiB
if [ "${1:-}" = --check ]; then echo "Поддерживаемая платформа: OpenWrt $DISTRIB_RELEASE / $(uname -m), RAM проверена. Место, зависимости и конфликты проверяются при установке. Установка не выполнялась."; exit 0; fi
if [ -e /tmp/pupsinator/busy ] && [ "${PUPS_IN_APP_UPDATE:-0}" != 1 ]; then error 'Сначала дождитесь завершения текущей операции PupsPanel.'; fi
mkdir /tmp/pupsinator-installer.lock 2>/dev/null || error 'Другая установка уже выполняется.'
if [ ! -e /etc/pupsinator-rollback/active ]; then
 for orphan in /etc/pupsinator-core-stage.*; do [ ! -d "$orphan" ] || rm -rf "$orphan"; done
fi
stage=$(mktemp -d /tmp/pupsinator-install.XXXXXXXX)
core_stage=''
backup=''
armed=0
owner_busy=0
health_lock=0
mkdir -p /tmp/pupsinator
if [ "${PUPS_IN_APP_UPDATE:-0}" != 1 ]; then owner_busy=1; echo "$$" > /tmp/pupsinator/busy; echo upgrade > /tmp/pupsinator/job; fi
PUPS_INSTALL_OWNER=$(cat /tmp/pupsinator/busy 2>/dev/null || true)
export PUPS_INSTALL_OWNER
finish() {
 code=$?
 if [ "$health_lock" = 1 ]; then rmdir /tmp/pupsinator/lock 2>/dev/null || true; fi
 if [ "$code" -ne 0 ] && [ "$armed" = 0 ] && [ -n "$backup" ]; then case "$backup" in /etc/pupsinator-rollback/txn.*) rm -rf "$backup";; esac; fi
 if [ "$code" -ne 0 ] && [ "$armed" = 1 ]; then cp /usr/lib/pupsinator/rollback-update.sh "$stage/recover.sh"; /bin/sh "$stage/recover.sh" || true; fi
 [ "$armed" != 1 ] || rm -f /usr/bin/pupsinator-xray.new
 case "$stage" in /tmp/pupsinator-install.*) rm -rf "$stage";; esac
 case "$core_stage" in /etc/pupsinator-core-stage.*) rm -rf "$core_stage";; esac
 if [ "$owner_busy" = 1 ]; then echo "$code" > /tmp/pupsinator/job-exit; rm -f /tmp/pupsinator/busy; fi
 if [ "$owner_busy" = 0 ] && [ -n "$PUPS_INSTALL_OWNER" ]; then
  echo "$PUPS_INSTALL_OWNER" > /tmp/pupsinator/busy
  echo upgrade > /tmp/pupsinator/job
  rm -f /tmp/pupsinator/job-exit
 fi
 rmdir /tmp/pupsinator-installer.lock 2>/dev/null || true
}
trap finish EXIT
vpn_https_ready() {
 deadline=$(($(date +%s)+35))
 for target in https://www.gstatic.com/generate_204 https://cp.cloudflare.com/generate_204 https://www.gstatic.com/generate_204; do
  remaining=$((deadline-$(date +%s)))
  [ "$remaining" -gt 0 ] || break
  [ "$remaining" -le 20 ] || remaining=20
  if code=$(curl --proxy socks5h://127.0.0.1:15434 --proto '=https' -s -o /dev/null -w '%{http_code}' --connect-timeout 15 --max-time "$remaining" "$target") && [ "$code" = 204 ]; then
   return 0
  fi
  sleep 1
 done
 return 1
}
if [ -e /tmp/pupsinator/active ]; then
 vpn_https_ready || error 'Выбранный VPN-сервер не отвечает ещё до обновления. Выберите рабочий сервер и повторите установку.'
fi
fetch() {
 if command -v curl >/dev/null 2>&1; then
  if curl --proxy socks5h://127.0.0.1:15434 --proto '=https' --proto-redir '=https' -fLsS --connect-timeout 15 --max-time 90 "$1" -o "$2"; then return; fi
  curl --proto '=https' --proto-redir '=https' -fLsS --connect-timeout 8 --max-time 90 "$1" -o "$2"
 else wget -T 90 -O "$2" "$1"; fi
}
release_file() {
 if fetch "$MIRROR/v$VERSION/$1" "$2"; then return; fi
 fetch "https://github.com/$REPO/releases/download/v$VERSION/$1" "$2"
}
dependencies='curl ca-bundle ucode ucode-mod-fs ucode-mod-uci ucode-mod-digest rpcd-mod-ucode kmod-tun kmod-nft-tproxy ip-full'
command -v timeout >/dev/null 2>&1 || dependencies="$dependencies coreutils-timeout"
missing=''
if command -v apk >/dev/null 2>&1; then
 for package in $dependencies; do apk info -e "$package" >/dev/null 2>&1 || missing="$missing $package"; done
 [ -z "$missing" ] || apk add $missing
elif command -v opkg >/dev/null 2>&1; then
 for package in $dependencies; do opkg list-installed "$package" | grep -q "^$package - " || missing="$missing $package"; done
 if [ -n "$missing" ]; then opkg update; opkg install $missing; fi
else error 'Не найден apk/opkg.'; fi
command -v nft >/dev/null || error 'Нужен firewall4/nftables.'
if [ ! -f /etc/pupsinator/settings.json ]; then
 if ip rule show | grep -Eq '^(110|111):'; then error 'Таблицы маршрутизации 110/111 заняты другой настройкой. Установка остановлена.'; fi
 if nft list table inet pupsinator >/dev/null 2>&1; then error 'Сетевое пространство pupsinator уже занято.'; fi
fi
[ -x /etc/init.d/rpcd ] && [ -d /www/luci-static ] || error 'Требуется веб-интерфейс LuCI.'
for name in tachyon forkop podkop passwall passwall2; do
 if [ -x "/etc/init.d/$name" ] && "/etc/init.d/$name" status >/dev/null 2>&1; then error "Сначала выключите другой VPN-клиент: $name"; fi
done
core_new=0
if [ ! -x /usr/bin/pupsinator-xray ] || [ "$(sha256sum /usr/bin/pupsinator-xray | awk '{print $1}')" != "$CORE_SHA" ]; then core_new=1; fi
available=$(df -Pk /overlay | awk 'END {print $4}')
minimum=12288
[ "$core_new" != 1 ] || minimum=16384
[ "$available" -ge "$minimum" ] || error "Для безопасной установки нужно $minimum КиБ свободного места. Сейчас $available КиБ."
if [ "${1:-}" = --update-local ] || [ "${1:-}" = --local ]; then
 [ -f "${2:-}" ] || error 'Не найден локальный архив.'
 cp "$2" "$stage/payload.tgz"
else release_file pupsinator-files.tar.gz "$stage/payload.tgz"; fi
echo "$PAYLOAD_SHA  $stage/payload.tgz" | sha256sum -c -
tar -tzf "$stage/payload.tgz" > "$stage/files"
if grep -E '(^/|(^|/)\.\.(/|$))' "$stage/files" >/dev/null; then error 'Некорректные пути архива'; fi
mkdir "$stage/filesystem"
tar -xzf "$stage/payload.tgz" -C "$stage/filesystem"
for f in "$stage/filesystem"/usr/lib/pupsinator/*.sh; do sh -n "$f"; done
for f in "$stage/filesystem"/usr/lib/pupsinator/*.uc; do
 case "$f" in
  */telemetry.uc|*/support.uc|*/coverage.uc) printf "import * as candidate from '%s';\n" "$f" > "$stage/check-module.uc"; ucode -c -o "$stage/check.ucb" "$stage/check-module.uc" ;;
  *) ucode -c -o "$stage/check.ucb" "$f" ;;
 esac
done
# Reviewed panel updates can preserve the running engine when the core
# and every file outside the reviewed UI/control set match.
keep_engine=0
running_pid=''
installed_version=$(tr -d '\r\n' </etc/pupsinator/version 2>/dev/null || true)
keep_transition=0
case "$installed_version:$VERSION" in 0.8.0:0.8.2|0.8.1:0.8.2) keep_transition=1 ;; esac
if [ "$keep_transition" = 1 ] && [ "$core_new" = 0 ] && [ -e /tmp/pupsinator/active ]; then
 running_pid=$(cat /tmp/pupsinator/engine-ready 2>/dev/null || true)
 case "$running_pid" in ''|*[!0-9]*) ;; *) if kill -0 "$running_pid" 2>/dev/null; then keep_engine=1; fi ;; esac
 for service in engine health network observe rollback; do
  [ ! -e "/etc/init.d/pupsinator-$service" ] || keep_engine=0
 done
 while IFS= read -r file; do
  case "$file" in
   */|etc/pupsinator/version|usr/lib/pupsinator/control.sh|usr/lib/pupsinator/engine-sync.sh|usr/lib/pupsinator/health.sh|usr/lib/pupsinator/probe-once.sh|usr/share/rpcd/ucode/pupsinator|www/luci-static/resources/view/pupsinator060.js|www/pupsinator/console.html|www/pupsinator/console.js|www/pupsinator/console.css|www/pupsinator/ping-modes.js) continue ;;
  esac
  if ! cmp -s "$stage/filesystem/$file" "/$file"; then keep_engine=0; break; fi
 done < "$stage/files"
fi
if [ "${PUPS_REQUIRE_KEEP_ENGINE:-0}" = 1 ] && [ "$keep_engine" != 1 ]; then
 error 'Условия обновления без перезапуска VPN не выполнены. Изменения не применены.'
fi
if [ "$core_new" = 1 ]; then
 local_core=''
 case "${1:-}" in --local|--update-local) local_core="$(dirname "$2")/$CORE_ASSET_PREFIX-$CORE_ARCH.gz";; esac
 if [ -n "$local_core" ] && [ -f "$local_core" ]; then cp "$local_core" "$stage/core.gz"; else release_file "$CORE_ASSET_PREFIX-$CORE_ARCH.gz" "$stage/core.gz"; fi
 echo "$CORE_GZIP_SHA  $stage/core.gz" | sha256sum -c -
 gzip -t "$stage/core.gz"
 actual=$(gzip -dc "$stage/core.gz" | sha256sum | awk '{print $1}')
 [ "$actual" = "$CORE_SHA" ] || error 'Контрольная сумма ядра не совпала.'
 core_bytes=$(gzip -dc "$stage/core.gz" | wc -c | tr -d '[:space:]')
 [ "$core_bytes" -gt 0 ] && [ "$core_bytes" -le 134217728 ] || error 'Некорректный размер ядра.'
fi
mkdir -p /etc/pupsinator-rollback
[ ! -e /etc/pupsinator-rollback/active ] || error 'Не завершено предыдущее обновление. Сначала выполните восстановление.'
backup=$(mktemp -d /etc/pupsinator-rollback/txn.XXXXXXXX)
[ -d /etc/pupsinator ] || touch "$backup/root-was-missing"
[ -f /usr/bin/pupsinator-xray ] || touch "$backup/core-was-missing"
: > "$stage/existing"
: > "$backup/new-files"
while IFS= read -r file; do
 case "$file" in */) continue;; esac
 if [ -e "/$file" ]; then echo "$file" >> "$stage/existing"; else echo "$file" >> "$backup/new-files"; fi
done < "$stage/files"
# Immutable community generations are not changed by a panel/core update.
# Save all mutable configuration and the cache pointer, not duplicate rule bodies.
if [ -d /etc/pupsinator ]; then
 for file in /etc/pupsinator/* /etc/pupsinator/.[!.]*; do
  [ -e "$file" ] || [ -L "$file" ] || continue
  [ "$file" = /etc/pupsinator/lists ] || echo "${file#/}" >> "$stage/existing"
 done
 if [ -L /etc/pupsinator/lists/current ]; then echo etc/pupsinator/lists/current >> "$stage/existing"; fi
 for file in /etc/pupsinator/lists/*; do [ ! -f "$file" ] || echo "${file#/}" >> "$stage/existing"; done
fi
[ ! -f /etc/config/dhcp ] || echo etc/config/dhcp >> "$stage/existing"
[ ! -f /etc/crontabs/root ] || echo etc/crontabs/root >> "$stage/existing"
for prefix in pupsinator pupspanel; do
 for service in engine health network observe rollback; do
  file="/etc/init.d/$prefix-$service"
  [ ! -f "$file" ] || echo "${file#/}" >> "$stage/existing"
  for file in /etc/rc.d/*"$prefix-$service"; do [ ! -L "$file" ] || echo "${file#/}" >> "$stage/existing"; done
 done
done
tar -czf "$backup/backup.tgz" -C / -T "$stage/existing"
gzip -t "$backup/backup.tgz"
[ ! -e /tmp/pupsinator/active ] || touch "$backup/was-active"
mkdir -p /usr/lib/pupsinator
cp "$stage/filesystem/usr/lib/pupsinator/rollback-update.sh" /usr/lib/pupsinator/rollback-update.sh
cp "$stage/filesystem/usr/lib/pupsinator/core-archive.sh" /usr/lib/pupsinator/core-archive.sh
chmod 700 /usr/lib/pupsinator/core-archive.sh
cp "$stage/filesystem/etc/init.d/pupspanel-rollback" /etc/init.d/pupspanel-rollback
chmod 700 /usr/lib/pupsinator/rollback-update.sh
chmod 755 /etc/init.d/pupspanel-rollback
echo "$backup" > /etc/pupsinator-rollback/active
/etc/init.d/pupspanel-rollback enable
armed=1
if [ "$core_new" = 1 ]; then
 if [ -f /usr/bin/pupsinator-xray ]; then
  if [ -s /etc/pupspanel-core-rollback/go-xray.gz.sha256 ] && [ "$(sha256sum /usr/bin/pupsinator-xray | awk '{print $1}')" = "$(cat /etc/pupspanel-core-rollback/go-xray.gz.sha256)" ] && /usr/lib/pupsinator/core-archive.sh verify /etc/pupspanel-core-rollback/go-xray.gz >/dev/null 2>&1; then
   for suffix in '' .sha256 .bytes .version .metadata.sha256; do ln "/etc/pupspanel-core-rollback/go-xray.gz$suffix" "$backup/core.previous.gz$suffix"; done
  else
   case "$(/usr/bin/pupsinator-xray version | head -n 1)" in
    'Xray-rust '*) /usr/lib/pupsinator/core-archive.sh save-link "$backup/core.previous.gz";;
    *) /usr/lib/pupsinator/core-archive.sh save "$backup/core.previous.gz";;
   esac
  fi
  # A temporary hard link makes rollback independent of free flash. It shares
  # the existing inode, is never executed, and is removed after qualification.
  [ ! -L "$backup/core.previous.bin" ] || error 'Unsafe transaction hard link'
  [ -f "$backup/core.previous.bin" ] || ln /usr/bin/pupsinator-xray "$backup/core.previous.bin"
  [ "$(sha256sum "$backup/core.previous.bin" | awk '{print $1}')" = "$(cat "$backup/core.previous.gz.sha256")" ] || error 'Ядро изменилось при создании резервной копии.'
  touch "$backup/core-saved"
  if /usr/bin/pupsinator-xray version | grep -q '^Xray '; then
   mkdir -p /etc/pupspanel-core-rollback
   chmod 700 /etc/pupspanel-core-rollback
   if ! /usr/lib/pupsinator/core-archive.sh verify /etc/pupspanel-core-rollback/go-xray.gz >/dev/null 2>&1; then
    for suffix in '' .sha256 .bytes .version .metadata.sha256; do
     rm -f "/etc/pupspanel-core-rollback/go-xray.gz$suffix.new"
     ln "$backup/core.previous.gz$suffix" "/etc/pupspanel-core-rollback/go-xray.gz$suffix.new"
     mv "/etc/pupspanel-core-rollback/go-xray.gz$suffix.new" "/etc/pupspanel-core-rollback/go-xray.gz$suffix"
    done
    /usr/lib/pupsinator/core-archive.sh verify /etc/pupspanel-core-rollback/go-xray.gz
   fi
  fi
 fi
 available=$(df -Pk /overlay | awk 'END {print $4}')
 needed=$(((core_bytes+1023)/1024+4096))
 filesystem=$(awk '$2 == "/overlay" {print $3; exit}' /proc/mounts)
 case "$filesystem" in ubifs|jffs2)
  compressed=$(wc -c < "$stage/core.gz")
  estimate=$(((compressed*3/2+1023)/1024+4096))
  [ "$estimate" -ge "$needed" ] || needed=$estimate
 ;; esac
 [ "$available" -ge "$needed" ] || error 'Недостаточно места для атомарной замены: прежнее ядро сохранено.'
 rm -f /usr/bin/pupsinator-xray.new
 gzip -dc "$stage/core.gz" > /usr/bin/pupsinator-xray.new
 echo "$CORE_SHA  /usr/bin/pupsinator-xray.new" | sha256sum -c -
 chmod 755 /usr/bin/pupsinator-xray.new
 case "$(/usr/bin/pupsinator-xray.new version | head -n 1)" in "$CORE_FAMILY $CORE_VERSION "*) ;; *) error 'Неожиданная версия ядра.';; esac
 if [ -s /etc/pupsinator/xray.json ]; then /usr/bin/pupsinator-xray.new run -test -config /etc/pupsinator/xray.json; fi
 for service in pupsinator-engine pupspanel-engine; do [ ! -x "/etc/init.d/$service" ] || "/etc/init.d/$service" stop; done
 attempts=0
 while [ -n "$(pidof pupsinator-xray 2>/dev/null || true)" ] && [ "$attempts" -lt 15 ]; do sleep 1; attempts=$((attempts+1)); done
 [ -z "$(pidof pupsinator-xray 2>/dev/null || true)" ] || error 'Не удалось остановить прежнее ядро.'
 mv /usr/bin/pupsinator-xray.new /usr/bin/pupsinator-xray
 # Wait for UBIFS to release the unlinked old ELF before a possible atomic restore.
 sync
 rm -f "$stage/core.gz"
fi
tar -xzf "$stage/payload.tgz" -C /
# Migrate legacy procd names after a recoverable snapshot, before enabling new ones.
for service in engine health network observe rollback; do
 file="/etc/init.d/pupsinator-$service"
 if [ -x "$file" ]; then "$file" stop || true; "$file" disable || true; rm -f "$file"; fi
 for link in /etc/rc.d/*"pupsinator-$service"; do [ ! -L "$link" ] || rm -f "$link"; done
done

rm -f /www/pupsinator/assets/corgi-offline-v3.png /www/pupsinator/assets/corgi-dns-v3.png
mkdir -p /etc/pupsinator /tmp/pupsinator
if [ ! -f /etc/pupsinator/settings.json ]; then ucode /usr/lib/pupsinator/app.uc bootstrap; fi
if [ "$keep_engine" = 0 ]; then
 /usr/lib/pupsinator/set-update-schedules.sh
 /etc/init.d/pupspanel-health enable
 /etc/init.d/pupspanel-health restart
 /etc/init.d/pupspanel-network enable
else
 if [ "${PUPS_IN_APP_UPDATE:-0}" != 1 ]; then
  attempts=0
  until mkdir /tmp/pupsinator/lock 2>/dev/null; do
   attempts=$((attempts+1)); [ "$attempts" -lt 15 ] || error 'Не удалось дождаться завершения проверки серверов.'
   sleep 1
  done
  health_lock=1
 fi
 /etc/init.d/pupspanel-health restart
 if [ "$health_lock" = 1 ]; then rmdir /tmp/pupsinator/lock; health_lock=0; fi
fi
touch /etc/sysupgrade.conf
grep -qx '/etc/pupsinator/' /etc/sysupgrade.conf || echo '/etc/pupsinator/' >> /etc/sysupgrade.conf
grep -qx '/etc/pupsinator-rollback/' /etc/sysupgrade.conf || echo '/etc/pupsinator-rollback/' >> /etc/sysupgrade.conf
grep -qx '/etc/pupspanel-core-rollback/' /etc/sysupgrade.conf || echo '/etc/pupspanel-core-rollback/' >> /etc/sysupgrade.conf
if [ -e "$backup/was-active" ]; then
 if [ "$keep_engine" = 1 ]; then
  [ "$running_pid" = "$(cat /tmp/pupsinator/engine-ready 2>/dev/null || true)" ] && kill -0 "$running_pid" 2>/dev/null || error 'Процесс VPN изменился при обновлении панели.'
  echo 'Панель обновлена без перезапуска VPN. Проверяем связь.'
 else
  outer_pid=$(cat /tmp/pupsinator/busy 2>/dev/null || true)
  /usr/lib/pupsinator/control.sh rollback
  rmdir /tmp/pupsinator/lock 2>/dev/null || true
  PUPS_IN_APP_UPDATE=1 /usr/lib/pupsinator/control.sh connect
  if [ "${PUPS_IN_APP_UPDATE:-0}" = 1 ]; then mkdir -p /tmp/pupsinator/lock; echo "$outer_pid" > /tmp/pupsinator/busy; echo upgrade > /tmp/pupsinator/job; fi
  if [ "$owner_busy" = 1 ]; then echo "$$" > /tmp/pupsinator/busy; echo upgrade > /tmp/pupsinator/job; fi
 fi
 vpn_https_ready || error 'Новая версия не прошла проверку VPN. Восстанавливаю предыдущую.'
 dns_ready=0
 # dnsmasq can briefly refuse forwarding while its upstream is being started.
 # Accept only an actual successful lookup, with a bounded startup window.
 for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if timeout 8 nslookup example.com 127.0.0.1 > "$stage/dns-check.log" 2>&1; then dns_ready=1; break; fi
  sleep 2
 done
 if [ "$dns_ready" != 1 ]; then cat "$stage/dns-check.log" >&2; error 'DNS не прошёл проверку. Восстанавливаю предыдущую.'; fi
 touch /etc/pupsinator/enabled
fi
ucode -c -o "$stage/rpc.ucb" /usr/share/rpcd/ucode/pupsinator
/etc/init.d/rpcd reload
sleep 2
if ! ubus call pupsinator monitor >/dev/null 2>&1; then /etc/init.d/rpcd restart; sleep 2; fi
ubus call pupsinator monitor >/dev/null 2>&1 || error 'Интерфейс новой версии не запустился. Восстанавливаю предыдущую.'
[ ! -x /etc/init.d/pupspanel-recover ] || { /etc/init.d/pupspanel-recover disable; rm -f /etc/init.d/pupspanel-recover; }
/etc/init.d/pupspanel-rollback disable
rm -f /etc/pupsinator-rollback/active /usr/bin/pupsinator-xray.previous
case "$backup" in /etc/pupsinator-rollback/txn.*) rm -rf "$backup";; esac
armed=0
find /tmp -maxdepth 1 -type f -name 'luci-indexcache.*.json' -exec rm -f {} \;
echo "PupsPanel $VERSION установлен. Службы → PupsPanel. Настройки сохранены; резервная копия удалена после проверки."
