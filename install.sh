#!/bin/sh
set -eu
umask 077
export GOMEMLIMIT=48MiB GOGC=50
VERSION=0.6.2
REPO=pupsinatorvpn/pupsinator-router
MIRROR=https://download.pupsinator.ru
CORE_VERSION=26.11.9
PAYLOAD_SHA=90c82ec37ed1603dc19ada09b2e93b9e4b61c25b4ca26a3b71ac0fb3234faa16
error() { echo "Pupsinator: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || error 'Запустите установщик от root на роутере.'
[ -f /etc/openwrt_release ] || error 'Требуется OpenWrt.'
. /etc/openwrt_release
case "$DISTRIB_RELEASE" in 25.12.*) ;; *) error 'Первая сборка предназначена для OpenWrt 25.12.';; esac
case "$(uname -m)" in
 aarch64|arm64) CORE_ARCH=arm64; CORE_SHA=c2d1e66a130556d32089adcf38202fcb6f9027e41fb456cc2cda9a5fabdc093a; CORE_GZIP_SHA=7ed7436f3fa4fdd5edeb8e46aaa0cd9cf06f5db41ff6786740e1c7995ef2fe2f ;;
 x86_64|amd64) CORE_ARCH=amd64; CORE_SHA=e87bce586acdb9136aa5b1f1d9c8db9f1ea1d145b6d86368c7f6f662f9f6a66d; CORE_GZIP_SHA=88f7f98df4112859802db4090b4f961be59831c9d7e60930aa5b640ada86e67d ;;
 mips|mipsel|mipsle)
  package_arch=$(apk --print-arch 2>/dev/null || opkg print-architecture 2>/dev/null || true)
  case "$package_arch" in *mipsel*|*mipsle*) CORE_ARCH=mipsel; CORE_SHA=5058314c99ec5fc4896b5c7bc55e1b3f7752e754c9df95f8244dab3a4dd8e052; CORE_GZIP_SHA=28d74908e11c46f6dd008512ba5ba946cdc02792251defeda69751190eac83c8;; *) error 'Не подтверждена little-endian архитектура MIPS. Установка остановлена.';; esac
 ;;
 *) error 'Архитектура пока не поддерживается. Установка не начата.';;
esac
memory=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
[ "$memory" -ge 110000 ] || error 'Нужно не менее 128 МБ установленной RAM; рекомендуется 256 МБ.'
[ "$memory" -ge 180000 ] || export GOMEMLIMIT=32MiB
if [ "${1:-}" = --check ]; then echo "Поддерживаемая платформа: OpenWrt $DISTRIB_RELEASE / $(uname -m), RAM проверена. Место, зависимости и конфликты проверяются при установке. Установка не выполнялась."; exit 0; fi
if [ -e /tmp/pupsinator/busy ] && [ "${PUPS_IN_APP_UPDATE:-0}" != 1 ]; then error 'Сначала дождитесь завершения текущей операции Pupsinator.'; fi
mkdir /tmp/pupsinator-installer.lock 2>/dev/null || error 'Другая установка уже выполняется.'
if [ ! -e /etc/pupsinator-rollback/active ]; then
 for orphan in /etc/pupsinator-core-stage.*; do [ ! -d "$orphan" ] || rm -rf "$orphan"; done
fi
stage=$(mktemp -d /tmp/pupsinator-install.XXXXXXXX)
core_stage=''
armed=0
owner_busy=0
mkdir -p /tmp/pupsinator
if [ "${PUPS_IN_APP_UPDATE:-0}" != 1 ]; then owner_busy=1; echo "$$" > /tmp/pupsinator/busy; echo upgrade > /tmp/pupsinator/job; fi
finish() {
 code=$?
 if [ "$code" -ne 0 ] && [ "$armed" = 1 ]; then cp /usr/lib/pupsinator/rollback-update.sh "$stage/recover.sh"; /bin/sh "$stage/recover.sh" || true; fi
 case "$stage" in /tmp/pupsinator-install.*) rm -rf "$stage";; esac
 case "$core_stage" in /etc/pupsinator-core-stage.*) rm -rf "$core_stage";; esac
 if [ "$owner_busy" = 1 ]; then echo "$code" > /tmp/pupsinator/job-exit; rm -f /tmp/pupsinator/busy; fi
 rmdir /tmp/pupsinator-installer.lock 2>/dev/null || true
}
trap finish EXIT
if [ -e /tmp/pupsinator/active ]; then
 code=$(curl --proxy socks5h://127.0.0.1:15434 -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 12 https://www.gstatic.com/generate_204 || true)
 [ "$code" = 204 ] || error 'Выбранный VPN-сервер не отвечает ещё до обновления. Выберите рабочий сервер и повторите установку.'
fi
fetch() {
 if command -v curl >/dev/null 2>&1; then
  if curl --proxy socks5h://127.0.0.1:15434 --proto '=https' --proto-redir '=https' -fLsS --connect-timeout 5 --max-time 90 "$1" -o "$2"; then return; fi
  curl --proto '=https' --proto-redir '=https' -fLsS --connect-timeout 8 --max-time 90 "$1" -o "$2"
 else wget -T 90 -O "$2" "$1"; fi
}
release_file() {
 if fetch "$MIRROR/v$VERSION/$1" "$2"; then return; fi
 fetch "https://github.com/$REPO/releases/download/v$VERSION/$1" "$2"
}
if command -v apk >/dev/null 2>&1; then
 apk add curl ca-bundle ucode ucode-mod-fs ucode-mod-uci ucode-mod-digest rpcd-mod-ucode kmod-tun kmod-nft-tproxy ip-full
elif command -v opkg >/dev/null 2>&1; then
 opkg update
 opkg install curl ca-bundle ucode ucode-mod-fs ucode-mod-uci ucode-mod-digest rpcd-mod-ucode kmod-tun kmod-nft-tproxy ip-full
else error 'Не найден пакетный менеджер OpenWrt.'; fi
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
[ "$core_new" != 1 ] || minimum=45056
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
for f in "$stage/filesystem"/usr/lib/pupsinator/*.uc; do case "$f" in */telemetry.uc) continue;; esac; ucode -c -o "$stage/check.ucb" "$f"; done
if [ "$core_new" = 1 ]; then
 release_file "pupsinator-xray-$CORE_ARCH.gz" "$stage/core.gz"
 echo "$CORE_GZIP_SHA  $stage/core.gz" | sha256sum -c -
 core_stage=$(mktemp -d /etc/pupsinator-core-stage.XXXXXXXX)
 gzip -dc "$stage/core.gz" > "$core_stage/xray"
 rm -f "$stage/core.gz"
 chmod 755 "$core_stage/xray"
 echo "$CORE_SHA  $core_stage/xray" | sha256sum -c -
 "$core_stage/xray" version | grep -q "^Xray $CORE_VERSION "
 if [ -s /etc/pupsinator/xray.json ]; then "$core_stage/xray" run -test -config /etc/pupsinator/xray.json; fi
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
if [ -d /etc/pupsinator ]; then echo etc/pupsinator >> "$stage/existing"; fi
[ ! -f /etc/config/dhcp ] || echo etc/config/dhcp >> "$stage/existing"
[ ! -f /etc/crontabs/root ] || echo etc/crontabs/root >> "$stage/existing"
tar -czf "$backup/backup.tgz" -C / -T "$stage/existing"
gzip -t "$backup/backup.tgz"
[ ! -e /tmp/pupsinator/active ] || touch "$backup/was-active"
mkdir -p /usr/lib/pupsinator
cp "$stage/filesystem/usr/lib/pupsinator/rollback-update.sh" /usr/lib/pupsinator/rollback-update.sh
cp "$stage/filesystem/etc/init.d/pupsinator-rollback" /etc/init.d/pupsinator-rollback
chmod 700 /usr/lib/pupsinator/rollback-update.sh
chmod 755 /etc/init.d/pupsinator-rollback
echo "$backup" > /etc/pupsinator-rollback/active
/etc/init.d/pupsinator-rollback enable
armed=1
if [ "$core_new" = 1 ]; then
 [ ! -x /etc/init.d/pupsinator-engine ] || /etc/init.d/pupsinator-engine stop
 if [ -f /usr/bin/pupsinator-xray ]; then mv /usr/bin/pupsinator-xray /usr/bin/pupsinator-xray.previous; fi
 mv "$core_stage/xray" /usr/bin/pupsinator-xray
 chmod 755 /usr/bin/pupsinator-xray
fi
tar -xzf "$stage/payload.tgz" -C /
rm -f /www/pupsinator/assets/corgi-offline-v3.png /www/pupsinator/assets/corgi-dns-v3.png
mkdir -p /etc/pupsinator /tmp/pupsinator
if [ ! -f /etc/pupsinator/settings.json ]; then ucode /usr/lib/pupsinator/app.uc bootstrap; fi
/usr/lib/pupsinator/set-update-schedules.sh
/etc/init.d/pupsinator-health enable
/etc/init.d/pupsinator-health restart
/etc/init.d/pupsinator-network enable
touch /etc/sysupgrade.conf
grep -qx '/etc/pupsinator/' /etc/sysupgrade.conf || echo '/etc/pupsinator/' >> /etc/sysupgrade.conf
grep -qx '/etc/pupsinator-rollback/' /etc/sysupgrade.conf || echo '/etc/pupsinator-rollback/' >> /etc/sysupgrade.conf
if [ -e "$backup/was-active" ]; then
 outer_pid=$(cat /tmp/pupsinator/busy 2>/dev/null || true)
 /usr/lib/pupsinator/control.sh rollback
 rmdir /tmp/pupsinator/lock 2>/dev/null || true
 PUPS_IN_APP_UPDATE=1 /usr/lib/pupsinator/control.sh connect
 if [ "${PUPS_IN_APP_UPDATE:-0}" = 1 ]; then mkdir -p /tmp/pupsinator/lock; echo "$outer_pid" > /tmp/pupsinator/busy; echo upgrade > /tmp/pupsinator/job; fi
 if [ "$owner_busy" = 1 ]; then echo "$$" > /tmp/pupsinator/busy; echo upgrade > /tmp/pupsinator/job; fi
 code=$(curl --proxy socks5h://127.0.0.1:15434 -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 https://www.gstatic.com/generate_204 || true)
 [ "$code" = 204 ] || error 'Новая версия не прошла проверку VPN. Восстанавливаю предыдущую.'
 nslookup example.com 127.0.0.1 >/dev/null 2>&1 || error 'DNS не прошёл проверку. Восстанавливаю предыдущую.'
 touch /etc/pupsinator/enabled
fi
ucode -c -o "$stage/rpc.ucb" /usr/share/rpcd/ucode/pupsinator
/etc/init.d/rpcd reload
sleep 2
if ! ubus call pupsinator monitor >/dev/null 2>&1; then /etc/init.d/rpcd restart; sleep 2; fi
ubus call pupsinator monitor >/dev/null 2>&1 || error 'Интерфейс новой версии не запустился. Восстанавливаю предыдущую.'
[ ! -x /etc/init.d/pupsinator-recover ] || { /etc/init.d/pupsinator-recover disable; rm -f /etc/init.d/pupsinator-recover; }
/etc/init.d/pupsinator-rollback disable
rm -f /etc/pupsinator-rollback/active /usr/bin/pupsinator-xray.previous
case "$backup" in /etc/pupsinator-rollback/txn.*) rm -rf "$backup";; esac
armed=0
find /tmp -maxdepth 1 -type f -name 'luci-indexcache.*.json' -exec rm -f {} \;
echo "Pupsinator $VERSION установлен. Службы → PupsinatorVPN. Настройки сохранены; резервная копия удалена после проверки."
