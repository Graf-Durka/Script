#grok:render type="render_inline_citation">
<argument name="citation_id">6</argument
</grok:
#!/bin/bash
# audio_service.sh - Кастомный будильник с обновлением из GitHub

# Конфигурация
STEALTH_DIR="$HOME/.audio_service"
LOG_FILE="$STEALTH_DIR/audio_service.log"
LOCK_FILE="/tmp/audio_service_$(id -u).lock"
TXT_FILE="$STEALTH_DIR/alarm.txt"
AUDIO_FILE="$STEALTH_DIR/alarm.wav"
PLAYED_FLAG="$STEALTH_DIR/played.flag"
GITHUB_BASE="https://raw.githubusercontent.com/Graf-Durka/Script/main"
SCRIPT_URL="$GITHUB_BASE/audio_service.sh"
TXT_URL="$GITHUB_BASE/alarm.txt"
AUDIO_URL="$GITHUB_BASE/alarm.wav"

# Создаем директорию и лог-файл
mkdir -p "$STEALTH_DIR"
touch "$LOG_FILE"

# Функция логирования
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Функция проверки блокировки
check_lock() {
    if [ -e "$LOCK_FILE" ]; then
        log "❌ Служба уже запущена"
        exit 1
    fi
    touch "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
}

# Функция получения текущей громкости
get_volume() {
    if command -v wpctl >/dev/null 2>&1; then
        wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{print $2}'
    elif command -v amixer >/dev/null 2>&1; then
        amixer -D pulse get Master | grep -o "[0-9]*%" | head -1 | tr -d '%'
        old_vol=$(amixer -D pulse get Master | grep -o "[0-9]*%" | head -1 | tr -d '%')
        old_vol=$(expr $old_vol / 100 | bc -l)  # to fraction
    else
        log "❌ Нет утилит для контроля громкости (wpctl или amixer)"
        return 1
    fi
}

# Функция установки громкости
set_volume() {
    local vol="$1"
    if command -v wpctl >/dev/null 2>&1; then
        wpctl set-volume @DEFAULT_AUDIO_SINK@ "$vol"
    elif command -v amixer >/dev/null 2>&1; then
        amixer -D pulse sset Master "${vol}%"
    fi
}

# Функция воспроизведения аудио
play_audio() {
    log "Воспроизведение аудио"
    local old_vol
    old_vol=$(get_volume)
    if [ -z "$old_vol" ]; then
        log "❌ Не удалось получить громкость"
        return 1
    fi
    set_volume 1.0  # 100%
    if command -v pw-play >/dev/null 2>&1; then
        pw-play "$AUDIO_FILE"
    elif command -v aplay >/dev/null 2>&1; then
        aplay "$AUDIO_FILE"
    else
        log "❌ Нет утилит для воспроизведения (pw-play или aplay)"
        return 1
    fi
    set_volume "$old_vol"
    log "✅ Аудио воспроизведено, громкость восстановлена"
}

# Функция обновления файла с GitHub
update_file() {
    local url="$1"
    local local_file="$2"
    local temp_file="/tmp/$(basename "$local_file").tmp"
    curl -sSL "$url" -o "$temp_file"
    if [ $? -ne 0 ]; then
        log "❌ Ошибка скачивания $url"
        rm -f "$temp_file"
        return 1
    fi
    if [ ! -f "$local_file" ] || ! md5sum -c <(echo "$(md5sum "$temp_file" | awk '{print $1}')  $local_file") >/dev/null 2>&1; then
        mv "$temp_file" "$local_file"
        log "✅ Обновлен файл $(basename "$local_file")"
        return 0
    else
        rm -f "$temp_file"
        return 1
    fi
}

# Функция установки cron
setup_cron() {
    log "Настройка cron"
    crontab -l 2>/dev/null | grep -v "audio_service" | crontab -
    local cron_line="* * * * * $STEALTH_DIR/audio_service.sh --update-and-check >> $LOG_FILE 2>&1"
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
    if [ $? -eq 0 ]; then
        log "✅ Cron настроен"
    else
        log "❌ Ошибка настройки cron"
    fi
}

# Основная логика
check_lock

case "${1:-}" in
    "--update-and-check")
        updated_txt=0
        if update_file "$TXT_URL" "$TXT_FILE"; then
            updated_txt=1
        fi
        update_file "$AUDIO_URL" "$AUDIO_FILE"
        if [ $updated_txt -eq 1 ]; then
            rm -f "$PLAYED_FLAG"
            log "Флаг played сброшен из-за обновления txt"
        fi
        if [ ! -f "$TXT_FILE" ] || [ ! -f "$AUDIO_FILE" ]; then
            log "❌ Нет txt или audio файла"
            exit 0
        fi
        scheduled=$(cat "$TXT_FILE" | tr -d '\n' | tr -d ' ')
        current=$(date +"%Y-%m-%d %H:%M")
        if [ "$current" = "$scheduled" ] && [ ! -f "$PLAYED_FLAG" ]; then
            play_audio
            touch "$PLAYED_FLAG"
        fi
        ;;
    "--play")
        play_audio
        ;;
    "--status")
        echo "Статус:"
        echo "Лог: $LOG_FILE"
        echo "Cron:"
        crontab -l | grep audio_service || echo "Не найдено"
        echo "Последние логи:"
        tail -10 "$LOG_FILE"
        ;;
    *)
        # Установка при первом запуске
        log "Установка службы"
        if [ ! -f "$STEALTH_DIR/audio_service.sh" ]; then
            curl -sSL "$SCRIPT_URL" -o "$STEALTH_DIR/audio_service.sh"
            chmod +x "$STEALTH_DIR/audio_service.sh"
            log "✅ Скрипт скачан и установлен"
        fi
        update_file "$TXT_URL" "$TXT_FILE"
        update_file "$AUDIO_URL" "$AUDIO_FILE"
        setup_cron
        echo "Установлено! Проверьте статус: $STEALTH_DIR/audio_service.sh --status"
        ;;
esac
