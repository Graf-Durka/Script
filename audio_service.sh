#!/bin/bash

# Конфигурация
STEALTH_DIR="$HOME/.local/share/audio_service"
LOG_FILE="$STEALTH_DIR/audio_service.log"
LOCK_FILE="/tmp/audio_service.lock"

# Создаем директорию и лог-файл
mkdir -p "$STEALTH_DIR"
touch "$LOG_FILE"

# Функция логирования
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Функция диагностики
diagnose() {
    log "=== ДИАГНОСТИКА ==="
    
    # Проверка пользователя и групп
    log "Пользователь: $(whoami)"
    log "Группы: $(groups)"
    
    # Проверка аудиоутилит
    log "Проверка утилит:"
    which pw-play 2>/dev/null && log "pw-play: найден" || log "pw-play: не найден"
    which aplay 2>/dev/null && log "aplay: найден" || log "aplay: не найден"
    which pactl 2>/dev/null && log "pactl: найден" || log "pactl: не найден"
    
    # Проверка аудиоустройств
    log "Аудиоустройства:"
    if which pactl >/dev/null; then
        pactl list short sinks 2>&1 | head -5 | while read line; do log "  $line"; done
    fi
    
    if which aplay >/dev/null; then
        aplay -l 2>&1 | head -5 | while read line; do log "  $line"; done
    fi
    
    log "=== ДИАГНОСТИКА ЗАВЕРШЕНА ==="
}

# Функция воспроизведения системного звука
play_system_beep() {
    log "Воспроизведение системного beep"
    for i in {1..3}; do
        echo -e "\a"
        sleep 0.2
    done
}

# Функция воспроизведения через PipeWire/ALSA
play_advanced_audio() {
    log "Попытка воспроизведения через аудиосистему"
    
    # Создаем простой WAV-файл с тоном
    local temp_wav="/tmp/test_tone.wav"
    
    # Генерируем тон через ALSA
    if which aplay >/dev/null; then
        # Создаем простой WAV файл с тоном 1000Hz
        cat > "$temp_wav" << 'EOF'
RIFF$X\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x00\x04\x00\x00\x00\x04\x00\x00\x01\x00\x08\x00data\x00\x00\x00\x00
EOF
        
        # Пробуем aplay
        log "Пробуем aplay"
        if timeout 5s aplay "$temp_wav" 2>>"$LOG_FILE"; then
            log "✅ Успешно через aplay"
            rm -f "$temp_wav"
            return 0
        fi
    fi
    
    # Пробуем pw-play (PipeWire)
    if which pw-play >/dev/null; then
        log "Пробуем pw-play"
        if timeout 5s pw-play --target=alsa_output.pci-0000_04_00.6.analog-stereo /usr/share/sounds/ubuntu/stereo/system-ready.ogg 2>>"$LOG_FILE"; then
            log "✅ Успешно через pw-play"
            return 0
        fi
    fi
    
    # Fallback на системный beep
    log "Ошибка продвинутого воспроизведения, пробуем системный beep"
    play_system_beep
    return 1
}

# Функция установки cron
setup_cron() {
    log "Настройка cron"
    
    # Удаляем старые записи
    crontab -l 2>/dev/null | grep -v "audio_service" | crontab -
    
    # Добавляем новую запись (каждые 2 часа для теста)
    local cron_line="0 */2 * * * export XDG_RUNTIME_DIR=/run/user/1000 && export PULSE_RUNTIME_PATH=/run/user/1000/pipewire-0 && $STEALTH_DIR/audio_service.sh --play >> $LOG_FILE 2>&1"
    
    if (crontab -l 2>/dev/null; echo "$cron_line") | crontab - 2>>"$LOG_FILE"; then
        log "✅ Cron настроен: $cron_line"
    else
        log "❌ Ошибка настройки cron"
    fi
}

# Функция установки
install_self() {
    log "Установка audio_service"
    
    # Сохраняем скрипт в файл
    cat > "$STEALTH_DIR/audio_service.sh" << 'EOF'
#!/bin/bash

STEALTH_DIR="$HOME/.local/share/audio_service"
LOG_FILE="$STEALTH_DIR/audio_service.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

play_audio() {
    log "Запуск воспроизведения из резидентной копии"
    
    # Пробуем разные методы воспроизведения
    if which aplay >/dev/null; then
        # Генерируем простой тон
        if timeout 5s aplay -q -D plughw:1,0 -c 1 -f S16_LE -r 44100 -t raw - 2>/dev/null <<< "$(echo -e '\x00\x00')"; then
            log "✅ Успешно через aplay"
            return 0
        fi
    fi
    
    # Системный beep
    log("Используем системный beep")
    for i in {1..3}; do
        echo -e "\a"
        sleep 0.1
    done
    return 0
}

case "${1:-}" in
    "--play")
        play_audio
        ;;
    "--status")
        echo "Статус audio_service:"
        echo "Лог-файл: $LOG_FILE"
        echo "Cron задачи:"
        crontab -l | grep -i audio_service || echo "  Не найдено"
        echo "Последние записи в логе:"
        tail -5 "$LOG_FILE" 2>/dev/null
        ;;
    *)
        echo "Использование: $0 --play | --status"
        ;;
esac
EOF

    chmod +x "$STEALTH_DIR/audio_service.sh"
    setup_cron
    echo "Установлено! Проверьте: $STEALTH_DIR/audio_service.sh --status"
}

# Основные функции
case "${1:-}" in
    "--play")
        log "Запуск воспроизведения"
        play_advanced_audio
        ;;
        
    "--diagnose")
        diagnose
        ;;
        
    "--test")
        log "Тестовый запуск"
        echo "Тестирование аудиосистемы..."
        play_advanced_audio
        ;;
        
    "--status")
        echo "Статус audio_service:"
        echo "Лог-файл: $LOG_FILE"
        echo "Cron задачи:"
        crontab -l | grep -i audio_service || echo "  Не найдено"
        echo "Последние записи в логе:"
        tail -10 "$LOG_FILE" 2>/dev/null || echo "  Лог не доступен"
        ;;
        
    "--install")
        install_self
        ;;
        
    *)
        echo "Использование:"
        echo "  $0 --install    - Установить службу"
        echo "  $0 --play       - Воспроизвести звук"
        echo "  $0 --test       - Тест аудиосистемы"
        echo "  $0 --diagnose   - Диагностика"
        echo "  $0 --status     - Статус службы"
        ;;
esac
