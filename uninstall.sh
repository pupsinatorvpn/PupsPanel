#!/bin/sh
set -eu
umask 077
[ "$(id -u)" = 0 ] || { echo 'Запустите от root.' >&2; exit 1; }
keep=0
case "${1:-}" in '') ;; --keep-settings) keep=1;; *) echo 'Использование: uninstall.sh [--keep-settings]' >&2; exit 1;; esac
for path in /etc/pupsinator /etc/pupsinator-rollback /etc/pupspanel-core-rollback /usr/lib/pupsinator /www/pupsinator; do
 [ ! -L "$path" ] || { echo 'Неожиданная ссылка: удаление остановлено.' >&2; exit 1; }
done
[ ! -e /tmp/pupsinator/busy ] && [ ! -e /tmp/pupsinator/queued ] && [ ! -e /etc/pupsinator-rollback/active ] || { echo 'Дождитесь завершения операции или восстановления.' >&2; exit 1; }
[ -s /usr/share/pupsinator/runtime-files.txt ] || { echo 'Не найден список файлов установленной сборки.' >&2; exit 1; }
mkdir /tmp/pupsinator-installer.lock 2>/dev/null || exit 1
stage=$(mktemp -d /tmp/pupspanel-remove.XXXXXXXX)
trap 'rm -rf "$stage"; rmdir /tmp/pupsinator-installer.lock 2>/dev/null || true' EXIT
cp /usr/share/pupsinator/runtime-files.txt "$stage/files"
# Validate the complete manifest before stopping services or removing any file.
while IFS= read -r file; do
 case "$file" in ''|*..*|/*) echo 'Некорректный список файлов.' >&2; exit 1;; esac
 case "$file" in
  usr/lib/pupsinator/*|www/pupsinator/*|usr/share/pupsinator/*|usr/share/rpcd/ucode/pupsinator|usr/share/rpcd/acl.d/luci-app-pupsinator.json|usr/share/luci/menu.d/luci-app-pupsinator.json|www/luci-static/resources/view/pupsinator060.js|etc/init.d/pupspanel-engine|etc/init.d/pupspanel-health|etc/init.d/pupspanel-network|etc/init.d/pupspanel-observe|etc/init.d/pupspanel-rollback|usr/bin/pupsinator-lists|etc/pupsinator/*) ;;
  *) echo 'Посторонний путь: удаление остановлено.' >&2; exit 1;;
 esac
done < "$stage/files"
for prefix in pupsinator pupspanel; do
 for service in health observe network; do
  [ ! -x "/etc/init.d/$prefix-$service" ] || "/etc/init.d/$prefix-$service" stop
 done
done
if [ -x /usr/lib/pupsinator/control.sh ]; then /usr/lib/pupsinator/control.sh rollback; fi
for prefix in pupsinator pupspanel; do
 for service in engine health observe network rollback; do
  if [ -x "/etc/init.d/$prefix-$service" ]; then "/etc/init.d/$prefix-$service" stop || true; "/etc/init.d/$prefix-$service" disable || true; fi
 done
done
crontab -l > "$stage/cron" 2>/dev/null || true
sed '/# pupsinator-lists$/d; /# pupsinator-subscription$/d; /# pupsinator-updates$/d; /# pupsinator-auto-upgrade$/d' "$stage/cron" > "$stage/clean-cron"
crontab "$stage/clean-cron"
while IFS= read -r file; do
 case "$file" in *..*|/*) echo 'Некорректный список файлов.' >&2; exit 1;; esac
 case "$file" in
  etc/pupsinator/*) [ "$keep" = 1 ] && continue;;
 esac
 case "$file" in
  usr/lib/pupsinator/*|www/pupsinator/*|usr/share/pupsinator/*|usr/share/rpcd/ucode/pupsinator|usr/share/rpcd/acl.d/luci-app-pupsinator.json|usr/share/luci/menu.d/luci-app-pupsinator.json|www/luci-static/resources/view/pupsinator060.js|etc/init.d/pupspanel-*|etc/init.d/pupsinator-*|usr/bin/pupsinator-lists|etc/pupsinator/*) rm -f "/$file";;
  *) echo 'Посторонний путь: удаление остановлено.' >&2; exit 1;;
 esac
done < "$stage/files"
rm -f /usr/bin/pupsinator-xray /usr/bin/pupsinator-xray.new /usr/bin/pupsinator-xray.previous
for path in /usr/lib/pupsinator /www/pupsinator /usr/share/pupsinator /etc/pupsinator-rollback /etc/pupspanel-core-rollback /tmp/pupsinator; do
 [ ! -e "$path" ] || { [ "$(readlink -f "$path")" = "$path" ] && rm -rf "$path"; }
done
if [ "$keep" = 0 ] && [ -d /etc/pupsinator ]; then [ "$(readlink -f /etc/pupsinator)" = /etc/pupsinator ] && rm -rf /etc/pupsinator; fi
if [ -f /etc/sysupgrade.conf ]; then sed '\|^/etc/pupsinator/$|d; \|^/etc/pupsinator-rollback/$|d; \|^/etc/pupspanel-core-rollback/$|d' /etc/sysupgrade.conf > "$stage/sysupgrade"; cat "$stage/sysupgrade" > /etc/sysupgrade.conf; fi
find /tmp -maxdepth 1 -type f -name 'luci-indexcache.*.json' -exec rm -f {} \;
/etc/init.d/rpcd restart
echo 'PupsPanel и основное ядро удалены. Прямой интернет восстановлен. NodeWatch и его ядро сохранены.'
