#!/bin/bash
# Конфигурация
STEALTH_DIR="$HOME/.local/share/audio_service"
LOG_FILE="$STEALTH_DIR/audio_service.log"
LOCK_FILE="/tmp/audio_service_$(id -u).lock"
CONFIG_FILE="$STEALTH_DIR/audio_service.conf"
ALARM_SOUND="$STEALTH_DIR/alarm.wav"  # Custom alarm sound

# Создаем директорию и лог-файл
mkdir -p "$STEALTH_DIR"
touch "$LOG_FILE"

# Функция логирования
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Функция ротации логов
rotate_log() {
    local max_size=1048576  # 1MB
    if [ -f "$LOG_FILE" ] && [ $(stat -c %s "$LOG_FILE" 2>/dev/null || stat -f %z "$LOG_FILE" 2>/dev/null) -gt $max_size ]; then
        mv "$LOG_FILE" "$LOG_FILE.bak"
        touch "$LOG_FILE"
        log "Лог-файл очищен (старый сохранен как $LOG_FILE.bak)"
    fi
}

# Функция проверки блокировки
check_lock() {
    if [ -e "$LOCK_FILE" ]; then
        log "❌ Служба уже запущена (lock file существует)"
        exit 1
    fi
    trap 'rm -f "$LOCK_FILE"' EXIT
    touch "$LOCK_FILE"
}

# Функция диагностики
diagnose() {
    log "=== ДИАГНОСТИКА ==="
   
    # Проверка пользователя и групп
    log "Пользователь: $(whoami)"
    log "Группы: $(groups)"
    log "UID: $(id -u), GID: $(id -g)"
   
    # Проверка аудиоутилит
    log "Проверка утилит:"
    which pw-play 2>/dev/null && log "pw-play: найден" || log "pw-play: не найден"
    which paplay 2>/dev/null && log "paplay: найден" || log "paplay: не найден"
    which aplay 2>/dev/null && log "aplay: найден" || log "aplay: не найден"
    which pw-cli 2>/dev/null && log "pw-cli: найден" || log "pw-cli: не найден"
    which pactl 2>/dev/null && log "pactl: найден" || log "pactl: не найден"
    which ffmpeg 2>/dev/null && log "ffmpeg: найден" || log "ffmpeg: не найден"
   
    # Проверка аудиоустройств
    log "Аудиоустройства:"
    if which pw-cli >/dev/null; then
        log "PipeWire устройства:"
        pw-cli list-objects Node 2>&1 | head -5 | while read line; do log " $line"; done
    fi
    if which pactl >/dev/null; then
        log "PulseAudio устройства:"
        pactl list short sinks 2>&1 | head -5 | while read line; do log " $line"; done
    fi
    if which aplay >/dev/null; then
        log "ALSA устройства:"
        aplay -l 2>&1 | head -5 | while read line; do log " $line"; done
    fi
   
    # Проверка прав доступа
    log "Права на /dev/snd: $(ls -ld /dev/snd/)"
    log "Права на /dev/snd/*: $(ls -la /dev/snd/ | head -3)"
   
    # Проверка переменных окружения
    log "XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR:-не установлен}"
    log "PULSE_RUNTIME_PATH: ${PULSE_RUNTIME_PATH:-не установлен}"
   
    # Проверка процессов аудиосерверов
    log "Процессы аудиосерверов:"
    ps aux | grep -Ei 'pulse|pipewire' | grep -v grep | head -3 | while read line; do log " $line"; done
   
    log "=== ДИАГНОСТИКА ЗАВЕРШЕНА ==="
}

# Функция воспроизведения системного звука (работает всегда)
play_system_beep() {
    log "Воспроизведение системного beep"
    for i in {1..3}; do
        echo -e "\a"
        sleep 0.2
    done
}

# Функция воспроизведения через аудиосистему
play_advanced_audio() {
    log "Попытка воспроизведения через аудиосистему"
   
    # Используем пользовательский звук или генерируем тестовый
    local audio_file="$ALARM_SOUND"
    if [ ! -f "$audio_file" ]; then
        audio_file=$(mktemp /tmp/alarm_tone.XXXXXX.wav)
        if which ffmpeg >/dev/null; then
            ffmpeg -loglevel quiet -f lavfi -i "sine=frequency=1000:duration=3" "$audio_file" 2>/dev/null
        else
            log "❌ ffmpeg не найден, пропускаем воспроизведение"
            return 1
        fi
    fi
   
    # Пробуем разные методы воспроизведения
    local success=0
   
    # Метод 1: PipeWire
    if which pw-play >/dev/null && [ -f "$audio_file" ]; then
        log "Пробуем pw-play"
        if timeout 5s pw-play "$audio_file" 2>>"$LOG_FILE"; then
            log "✅ Успешно через pw-play"
            success=1
        else
            log "❌ Ошибка pw-play, см. лог"
        fi
    fi
   
    # Метод 2: PulseAudio
    if [ $success -eq 0 ] && which paplay >/dev/null && [ -f "$audio_file" ]; then
        log "Пробуем paplay"
        if timeout 5s paplay "$audio_file" 2>>"$LOG_FILE"; then
            log "✅ Успешно через paplay"
            success=1
        else
            log "❌ Ошибка paplay, см. лог"
        fi
    fi
   
    # Метод 3: ALSA
    if [ $success -eq 0 ] && which aplay >/dev/null && [ -f "$audio_file" ]; then
        log "Пробуем aplay"
        if timeout 5s aplay "$audio_file" 2>>"$LOG_FILE"; then
            log "✅ Успешно через aplay"
            success=1
        else
            log "❌ Ошибка aplay, см. лог"
        fi
    fi
   
    # Очистка
    if [[ "$audio_file" == /tmp/* ]]; then
        rm -f "$audio_file" 2>/dev/null
    fi
   
    return $success
}

# Функция установки cron
setup_cron() {
    log "Настройка cron"
   
    # Проверка доступности crontab
    if ! crontab -l 2>/dev/null; then
        log "❌ Cron недоступен или не настроен"
        return 1
    fi
   
    # Удаляем старые записи
    crontab -l 2>/dev/null | grep -v "audio_service" | crontab -
   
    # Читаем расписание из конфига или используем значение по умолчанию
    local cron_schedule="0 */2 * * *"
    if [ -f "$CONFIG_FILE" ]; then
        cron_schedule=$(grep "^CRON_SCHEDULE=" "$CONFIG_FILE" | cut -d= -f2-)
    fi
    local cron_line="$cron_schedule $STEALTH_DIR/audio_service.sh --play >> $LOG_FILE 2>&1"
   
    if (crontab -l 2>/dev/null; echo "$cron_line") | crontab - 2>>"$LOG_FILE"; then
        log "✅ Cron настроен: $cron_line"
    else
        log "❌ Ошибка настройки cron"
    fi
}

# Функция создания конфигурационного файла
create_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << 'EOF'
# Конфигурация audio_service
# Расписание cron (по умолчанию каждые 2 часа)
CRON_SCHEDULE="0 */2 * * *"
# Путь к пользовательскому звуку (если не указан, используется тестовый тон)
ALARM_SOUND="$HOME/.local/share/audio_service/alarm.wav"
EOF
        log "Создан конфигурационный файл: $CONFIG_FILE"
    fi
}

# Основные функции
check_lock
rotate_log

case "${1:-}" in
    "--play")
        log "Запуск воспроизведения"
        diagnose
        if ! play_advanced_audio; then
            log "Ошибка продвинутого воспроизведения, пробуем системный beep"
            play_system_beep
        fi
        ;;
       
    "--diagnose")
        diagnose
        ;;
       
    "--test")
        log "Тестовый запуск"
        echo "Тестирование аудиосистемы..."
        diagnose
        echo "Пробуем воспроизведение..."
        if play_advanced_audio; then
            echo "✅ Аудиосистема работает"
        else
            echo "❌ Проблемы с аудиосистемой, пробуем системный beep..."
            play_system_beep
            echo "✅ Системный beep выполнен"
        fi
        ;;
       
    "--status")
        echo "Статус audio_service:"
        echo "Лог-файл: $LOG_FILE"
        echo "Конфигурация: $CONFIG_FILE"
        echo "Cron задачи:"
        crontab -l | grep -i audio_service || echo " Не найдено"
        echo "Последние записи в логе:"
        tail -10 "$LOG_FILE" 2>/dev/null || echo " Лог не доступен"
        ;;
       
    "--install")
        log "Установка audio_service"
        if [ "$0" = "bash" ] || [ "$0" = "-bash" ]; then
            log "❌ Скрипт запущен через pipe, скачайте его сначала"
            echo "Скачайте скрипт: curl -sSL https://raw.githubusercontent.com/Graf-Durka/Script/main/audio_service.sh -o audio_service.sh"
            exit 1
        fi
        cp -f "$0" "$STEALTH_DIR/audio_service.sh"
        chmod +x "$STEALTH_DIR/audio_service.sh"
        create_config
        setup_cron
        echo "Установлено! Проверьте: $STEALTH_DIR/audio_service.sh --status"
        echo "Настройте $CONFIG_FILE для изменения расписания или звука будильника"
        ;;
       
    *)
        echo "Использование:"
        echo " $0 --install - Установить службу"
        echo " $0 --play - Воспроизвести звук"
        echo " $0 --test - Тест аудиосистемы"
        echo " $0 --diagnose - Диагностика"
        echo " $0 --status - Статус службы"
        ;;
esac
