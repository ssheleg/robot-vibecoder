#!/usr/bin/env bash
# installer/install-from-release.sh — установка робота ЧУЖИМ человеком.
#
# Ни git, ни SSH-ключей, ни аккаунта у автора: скачать подписанный релиз по
# HTTPS, ПРОВЕРИТЬ ПОДПИСЬ, распаковать, запустить установщик.
#
# ГДЕ КОРЕНЬ ДОВЕРИЯ. Публичный ключ автора берётся из того же публичного
# репозитория по HTTPS (TLS GitHub) — это trust-on-first-use, и мы говорим
# об этом прямо, а не делаем вид, что подпись самодостаточна. Кто хочет
# строже: сверить отпечаток ключа с опубликованным автором вне GitHub.
# ПОСЛЕ первой установки ключ лежит локально, и все обновления проверяются
# уже им — подменить их удалённо нельзя.
#
# Запуск на чистом Raspberry Pi OS (64-bit):
#   curl -fsSL https://raw.githubusercontent.com/ssheleg/robot-vibecoder/main/install.sh | bash
# или, если файл уже рядом:
#   bash install-from-release.sh
#
# Refs: docs/DISTRIBUTION.md

set -euo pipefail

PUBLIC_REPO="${ROBOT_PUBLIC_REPO:-ssheleg/robot-vibecoder}"
RAW="https://raw.githubusercontent.com/$PUBLIC_REPO/main"
CHANNEL="${ROBOT_CHANNEL:-stable}"
TARGET="${ROBOT_TARGET_DIR:-$HOME/rpi-ai-assistant}"
# Preflight: пройти ВСЕ проверки (железо, манифест, загрузка, подпись) и
# остановиться перед первым изменением системы. Нужен и человеку («подойдёт
# ли мне?»), и тестам: у установщика есть побочные эффекты ВНЕ целевой папки
# (файл доверия, переключение источника обновлений), и прогон «понарошку» с
# подменённой целью их бы не удержал.
DRY_RUN="${ROBOT_INSTALL_DRY_RUN:-0}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log()  { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[install] СТОП:\033[0m %s\n' "$*" >&2; exit 1; }

log "1/7 проверяю железо"
ARCH="$(uname -m)"
RAM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)"
log "    $MODEL, $ARCH, ${RAM_MB} МБ ОЗУ"
[ "$ARCH" = "aarch64" ] || die "нужна 64-битная Raspberry Pi OS (сейчас $ARCH).
   Перезапиши карту 64-битным образом — 32-битный этот агент не поддерживает."
case "$MODEL" in
  *Zero*) die "Raspberry Pi Zero не поддерживается: мозгу с памятью нужно ~1 ГБ,
   а у Zero 512 МБ. Нужна Pi 4 или Pi 5 (минимум 2 ГБ, лучше 4)." ;;
esac
[ "${RAM_MB:-0}" -ge 1800 ] || die "нужно минимум ~2 ГБ ОЗУ, у устройства ${RAM_MB} МБ."

log "2/7 инструменты"
for t in curl tar python3 ssh-keygen; do
  command -v "$t" >/dev/null 2>&1 || die "нет $t — поставь: sudo apt install -y $t"
done

log "3/7 манифест канала $CHANNEL"
curl -fsSL --max-time 30 "$RAW/channels/$CHANNEL.json" -o "$WORK/manifest.json" \
  || die "канал недоступен — проверь интернет"
VERSION="$(python3 -c "import json;print(json.load(open('$WORK/manifest.json'))['version'])")"
URL="$(python3 -c "import json;print(json.load(open('$WORK/manifest.json'))['url'])")"
SIG_URL="$(python3 -c "import json;print(json.load(open('$WORK/manifest.json'))['sig_url'])")"
SHA="$(python3 -c "import json;print(json.load(open('$WORK/manifest.json'))['sha256'])")"
log "    версия $VERSION"

log "4/7 ключ автора (корень доверия — HTTPS этого репозитория)"
curl -fsSL --max-time 30 "$RAW/allowed_signers" -o "$WORK/allowed_signers" \
  || die "не скачался файл доверия"
log "    отпечаток: $(ssh-keygen -lf <(awk '{print $3, $4}' "$WORK/allowed_signers") 2>/dev/null | awk '{print $2}' || echo '(не прочитан)')"

log "5/7 скачиваю сборку"
curl -fsSL --max-time 600 "$URL" -o "$WORK/bundle.tar.gz" || die "загрузка не удалась"
curl -fsSL --max-time 60 "$SIG_URL" -o "$WORK/bundle.tar.gz.sig" || die "подпись не скачалась"

log "6/7 ПРОВЕРЯЮ ПОДПИСЬ (без неё ничего не распаковываю)"
ACTUAL="$(python3 -c "
import hashlib,sys
h=hashlib.sha256()
with open('$WORK/bundle.tar.gz','rb') as f:
    for b in iter(lambda: f.read(1<<20), b''): h.update(b)
print(h.hexdigest())")"
[ "$ACTUAL" = "$SHA" ] || die "sha256 не совпал — файл повреждён или подменён"
ssh-keygen -Y verify -f "$WORK/allowed_signers" -I releases@robot-vibecoder \
  -n robot-vibecoder-release -s "$WORK/bundle.tar.gz.sig" \
  < "$WORK/bundle.tar.gz" >/dev/null 2>&1 \
  || die "ПОДПИСЬ НЕ СОШЛАСЬ. Сборка не от автора проекта либо повреждена.
   Ничего не установлено — это правильное поведение, а не сбой."
log "    подпись верна ✓"

if [ "$DRY_RUN" = "1" ]; then
  log "preflight пройден: железо подходит, сборка $VERSION скачана, ПОДПИСЬ ВЕРНА"
  log "система не изменена (ROBOT_INSTALL_DRY_RUN=1). Убери флаг, чтобы поставить."
  exit 0
fi

log "7/7 распаковка и установка"
tar -xzf "$WORK/bundle.tar.gz" -C "$WORK"
# maxdepth 3: архив несёт префикс `robot-vibecoder/`, значит путь — это
# WORK/robot-vibecoder/scripts/deploy.sh (три уровня). С maxdepth 2 установщик
# доходил до конца, проверял подпись и падал на последнем шаге — поймано
# живым прогоном на устройстве 2026-08-30.
SRC="$(find "$WORK" -maxdepth 3 -name deploy.sh -path '*/scripts/*' -print -quit)"
[ -n "$SRC" ] || die "в архиве нет scripts/deploy.sh"
SRC="$(dirname "$(dirname "$SRC")")"
[ -e "$TARGET" ] && mv "$TARGET" "$TARGET.pre-install.$(date +%s)"
mv "$SRC" "$TARGET"

# Файл доверия — чтобы БУДУЩИЕ обновления проверялись локально.
sudo install -d -m 0755 /etc/robot-vibecoder
sudo install -m 0644 "$WORK/allowed_signers" /etc/robot-vibecoder/allowed_signers

# Устройство, поставленное из релиза, обновляется КАНАЛОМ, а не git.
mkdir -p "$HOME/.config/robot-vibecoder"
python3 - "$HOME/.config/robot-vibecoder/settings.local.json" <<'PYSRC'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text()) if p.is_file() else {}
d.setdefault("update", {})["source"] = "channel"
p.write_text(json.dumps(d, ensure_ascii=False, indent=2))
PYSRC

log "готово: $VERSION в $TARGET"
cat <<'EOF'

Дальше — один раз ввести СВОИ ключи (они остаются только у тебя):
  cd ~/rpi-ai-assistant && bash installer/install.sh

Понадобится: ключ OpenRouter (мозг) и токен Telegram-бота.
Обновления дальше приходят сами — устройство проверяет канал и подпись.
EOF
