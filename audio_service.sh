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
mkdir -p "$STEALTH_DIR" || { echo "Ошибка: Не удалось создать $STEALTH_DIR"; exit 1; }
touch "$LOG_FILE" || { echo "Ошибка: Не удалось создать $LOG_FILE"; exit 1; }

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
    touch "$LOCK_FILE" || { log "❌ Не удалось создать lock-файл"; exit 1; }
    trap 'rm -f "$LOCK_FILE"' EXIT
}

# Функция получения текущей громкости
get_volume() {
    if command -v wpctl >/dev/null 2>&1 && XDG_RUNTIME_DIR=/run/user/$(id -u) wpctl get-volume @DEFAULT_AUDIO_SINK@ >/dev/null 2>&1; then
        XDG_RUNTIME_DIR=/run/user/$(id -u) wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{print $2}'
    elif command -v amixer >/dev/null 2>&1 && amixer -D pulse get Master >/dev/null 2>&1; then
        amixer -D pulse get Master | grep -o "[0-9]*%" | head -1 | tr -d '%'
    else
        log "❌ Нет утилит для контроля громкости или аудиосервер недоступен, использую громкость по умолчанию (100)"
        echo "100"
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
    if [ ! -f "$AUDIO_FILE" ]; then
        log "❌ Аудиофайл $AUDIO_FILE отсутствует"
        return 1
    fi
    local old_vol
    old_vol=$(get_volume)
    if [ -z "$old_vol" ]; then
        log "❌ Не удалось получить громкость, продолжаем с максимальной громкостью"
        old_vol=100
    fi
    set_volume 1.0  # 100%
    if command -v pw-play >/dev/null 2>&1 && XDG_RUNTIME_DIR=/run/user/$(id -u) pw-play "$AUDIO_FILE" 2>/dev/null; then
        log "✅ Аудио воспроизведено с помощью pw-play"
    elif command -v aplay >/dev/null 2>&1 && aplay "$AUDIO_FILE" 2>/dev/null; then
        log "✅ Аудио воспроизведено с помощью aplay"
    else
        log "❌ Не удалось воспроизвести аудио: нет утилит (pw-play или aplay) или файл недоступен"
        set_volume "$old_vol"
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
    if curl -sSL -H "Cache-Control: no-cache" "$url" -o "$temp_file" && [ -s "$temp_file" ]; then
        if [ ! -f "$local_file" ] || ! cmp -s "$temp_file" "$local_file"; then
            mv "$temp_file" "$local_file"
            log "✅ Обновлен файл $(basename "$local_file")"
            return 0
        else
            rm -f "$temp_file"
            return 1
        fi
    else
        log "❌ Ошибка скачивания $url или файл пуст"
        rm -f "$temp_file"
        return 1
    fi
}

# Функция обновления самого скрипта
update_self() {
    local temp_script="/tmp/audio_service.sh.tmp"
    if curl -sSL -H "Cache-Control: no-cache" "$SCRIPT_URL" -o "$temp_script" && [ -s "$temp_script" ]; then
        if ! cmp -s "$temp_script" "$STEALTH_DIR/audio_service.sh"; then
            mv "$temp_script" "$STEALTH_DIR/audio_service.sh"
            chmod +x "$STEALTH_DIR/audio_service.sh"
            log "✅ Скрипт обновлен до новой версии"
            exec "$STEALTH_DIR/audio_service.sh" "$@"  # Перезапуск с текущими аргументами
        else
            rm -f "$temp_script"
            return 1
        fi
    else
        log "❌ Ошибка скачивания новой версии скрипта"
        rm -f "$temp_script"
        return 1
    fi
}

# Функция настройки sudoers для rtcwake
setup_sudoers() {
    local sudoers_file="/etc/sudoers.d/audio_service"
    local username="$USER"
    if [ ! -f "$sudoers_file" ]; then
        if sudo -n true 2>/dev/null; then
            echo "$username ALL=(ALL) NOPASSWD: /usr/sbin/rtcwake" | sudo tee "$sudoers_file" >/dev/null || { log "❌ Ошибка настройки sudoers"; exit 1; }
            sudo chmod 0440 "$sudoers_file" || { log "❌ Ошибка установки прав для sudoers"; exit 1; }
            if sudo visudo -c -f "$sudoers_file" >/dev/null; then
                log "✅ Настроен sudoers для rtcwake"
            else
                log "❌ Некорректный синтаксис sudoers, удаляю файл"
                sudo rm -f "$sudoers_file"
                exit 1
            fi
        else
            log "⚠️ Требуется пароль sudo для настройки $sudoers_file. Вручную добавьте: echo '$username ALL=(ALL) NOPASSWD: /usr/sbin/rtcwake' | sudo tee $sudoers_file && sudo chmod 0440 $sudoers_file"
            echo "Для настройки sudoers выполните: echo '$username ALL=(ALL) NOPASSWD: /usr/sbin/rtcwake' | sudo tee $sudoers_file && sudo chmod 0440 $sudoers_file"
        fi
    fi
}

# Функция установки пробуждения из сна/гибернации
setup_wakeup() {
    if command -v rtcwake >/dev/null 2>&1; then
        local wakeup_time=$((scheduled_epoch - 60))  # Пробуждение за 60 секунд до будильника
        if [ $wakeup_time -gt $(date +%s) ]; then
            if sudo -n rtcwake -m mem -t $wakeup_time 2>/dev/null; then
                log "✅ Установлено пробуждение на $scheduled"
            else
                log "⚠️ Не удалось установить пробуждение (требуется sudo). Настройте /etc/sudoers.d/audio_service"
            fi
        else
            log "⚠️ Время пробуждения уже прошло"
        fi
    else
        log "❌ rtcwake не установлен, пробуждение не настроено. Установите: sudo pacman -S pm-utils"
    fi
}

# Функция проверки настройки для работы с закрытой крышкой
setup_lid_ignore() {
    local conf_file="/etc/systemd/logind.conf"
    if [ -f "$conf_file" ] && ! grep -q "^HandleLidSwitch=ignore" "$conf_file"; then
        log "⚠️ Для работы с закрытой крышкой добавьте в $conf_file: HandleLidSwitch=ignore и выполните: sudo systemctl restart systemd-logind"
        echo "Для работы с закрытой крышкой выполните: echo 'HandleLidSwitch=ignore' | sudo tee -a $conf_file && sudo systemctl restart systemd-logind"
    fi
}

# Функция установки cron
setup_cron() {
    log "Настройка cron"
    crontab -l 2>/dev/null | grep -v "audio_service" | crontab - || true
    local cron_line="* * * * * XDG_RUNTIME_DIR=/run/user/$(id -u) $STEALTH_DIR/audio_service.sh --update-and-check >> $LOG_FILE 2>&1"
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab - || { log "❌ Ошибка настройки cron"; exit 1; }
    log "✅ Cron настроен"
}

# Проверка, запущен ли скрипт в интерактивной оболочке
is_interactive() {
    if [ -t 0 ] && [ -t 1 ]; then
        return 0  # Интерактивная оболочка (терминал открыт пользователем)
    else
        return 1  # Неинтерактивная оболочка (например, запущено через cron или терминал с автозакрытием)
    fi
}

# Основная логика
check_lock

case "${1:-}" in
    "--update-and-check")
        update_self  # Проверка и обновление самого скрипта
        updated_txt=0
        if update_file "$TXT_URL" "$TXT_FILE"; then
            updated_txt=1
        fi
        update_file "$AUDIO_URL" "$AUDIO_FILE"
        if [ $updated_txt -eq 1 ]; then
            rm -f "$PLAYED_FLAG"
            log "Флаг played сброшен из-за обновления txt"
            setup_wakeup  # Установка пробуждения при обновлении txt
        fi
        if [ ! -f "$TXT_FILE" ] || [ ! -f "$AUDIO_FILE" ]; then
            log "❌ Нет txt или audio файла"
            exit 0
        fi
        scheduled=$(cat "$TXT_FILE" | tr -d '\n' | tr -d ' ')
        current=$(date +"%Y-%m-%d %H:%M")
        current_epoch=$(date -d "$current" +%s)
        scheduled_epoch=$(date -d "$scheduled" +%s 2>/dev/null) || { log "❌ Некорректный формат времени в $TXT_FILE"; exit 1; }
        if [ $current_epoch -ge $scheduled_epoch ] && [ $((current_epoch - scheduled_epoch)) -le 60 ] && [ ! -f "$PLAYED_FLAG" ]; then
            play_audio
            touch "$PLAYED_FLAG"
        elif [ $current_epoch -gt $((scheduled_epoch + 60)) ]; then
            rm -f "$PLAYED_FLAG"
            log "Флаг played сброшен, так как время будильника прошло"
        fi
        ;;
    "--play")
        play_audio
        ;;
    "--status")
        echo "Статус:"
        echo "Лог: $LOG_FILE"
        echo "Cron:"
        crontab -l 2>/dev/null | grep audio_service || echo "Не найдено"
        echo "Последние логи:"
        tail -10 "$LOG_FILE"
        ;;
    *)
        # Установка при первом запуске
        log "Установка службы"
        setup_sudoers  # Настройка sudoers для rtcwake
        setup_lid_ignore  # Проверка настройки для закрытой крышки
        if [ ! -f "$STEALTH_DIR/audio_service.sh" ]; then
            curl -sSL -H "Cache-Control: no-cache" "$SCRIPT_URL" -o "$STEALTH_DIR/audio_service.sh" || { log "❌ Ошибка скачивания скрипта"; exit 1; }
            chmod +x "$STEALTH_DIR/audio_service.sh"
            log "✅ Скрипт скачан и установлен"
        fi
        update_self  # Проверка обновления при установке
        update_file "$TXT_URL" "$TXT_FILE"
        update_file "$AUDIO_URL" "$AUDIO_FILE"
        setup_cron
        setup_wakeup  # Установка пробуждения при первой установке
        echo "Установлено! Проверьте статус: bash -c '$STEALTH_DIR/audio_service.sh --status; read -p \"Нажмите Enter для закрытия...\"'"
        if is_interactive; then
            echo "Для автозакрытия терминала используйте: bash -c '$STEALTH_DIR/audio_service.sh'"
        fi
        exit 0  # Завершение скрипта, терминал закроется, если запущен с автозакрытием
        ;;
esac
