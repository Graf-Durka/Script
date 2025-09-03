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
    log "UID: $(id -u), GID: $(id -g)"
    
    # Проверка аудиоутилит
    log "Проверка утилит:"
    which paplay 2>/dev/null && log "paplay: найден" || log "paplay: не найден"
    which aplay 2>/dev/null && log "aplay: найден" || log "aplay: не найден"
    which pactl 2>/dev/null && log "pactl: найден" || log "pactl: не найден"
    which ffmpeg 2>/dev/null && log "ffmpeg: найден" || log "ffmpeg: не найден"
    
    # Проверка аудиоустройств
    log "Аудиоустройства:"
    if which pactl >/dev/null; then
        pactl list short sinks 2>&1 | head -5 | while read line; do log "  $line"; done
    fi
    
    if which aplay >/dev/null; then
        aplay -l 2>&1 | head -5 | while read line; do log "  $line"; done
    fi
    
    # Проверка прав доступа
    log "Права на /dev/snd: $(ls -ld /dev/snd/)"
    log "Права на /dev/snd/*: $(ls -la /dev/snd/ | head -3)"
    
    # Проверка переменных окружения
    log "XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR:-не установлен}"
    log "PULSE_RUNTIME_PATH: ${PULSE_RUNTIME_PATH:-не установлен}"
    
    # Проверка процессов PulseAudio
    log "Процессы PulseAudio:"
    ps aux | grep -i pulse | grep -v grep | head -3 | while read line; do log "  $line"; done
    
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

# Функция воспроизведения через PulseAudio/ALSA
play_advanced_audio() {
    log "Попытка воспроизведения через аудиосистему"
    
    # Создаем простой WAV-файл с тоном (1КГц, 1 секунда)
    local temp_wav="/tmp/test_tone.wav"
    if which ffmpeg >/dev/null; then
        ffmpeg -loglevel quiet -f lavfi -i "sine=frequency=1000:duration=1" "$temp_wav" 2>/dev/null
    else
        # Простой заголовок WAV файла с тоном
        cat > "$temp_wav" << 'EOF'
RIFF$\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x00\x04\x00\x00\x00\x04\x00\x00\x01\x00\x08\x00data\x00\x00\x00\x00
EOF
    fi
    
    # Пробуем разные методы воспроизведения
    local success=0
    
    # Метод 1: PulseAudio
    if which paplay >/dev/null && [ -f "$temp_wav" ]; then
        log "Пробуем paplay"
        if timeout 5s paplay "$temp_wav" 2>>"$LOG_FILE"; then
            log "✅ Успешно через paplay"
            success=1
        fi
    fi
    
    # Метод 2: ALSA
    if [ $success -eq 0 ] && which aplay >/dev/null && [ -f "$temp_wav" ]; then
        log "Пробуем aplay"
        if timeout 5s aplay "$temp_wav" 2>>"$LOG_FILE"; then
            log "✅ Успешно через aplay"
            success=1
        fi
    fi
    
    # Метод 3: Через /dev/dsp (если доступно)
    if [ $success -eq 0 ] && [ -w /dev/dsp ]; then
        log "Пробуем /dev/dsp"
        if which sox >/dev/null; then
            echo -e "\a" > /dev/dsp 2>/dev/null && success=1
        fi
    fi
    
    # Очистка
    rm -f "$temp_wav" 2>/dev/null
    
    return $success
}

# Функция установки cron
setup_cron() {
    log "Настройка cron"
    
    # Удаляем старые записи
    crontab -l 2>/dev/null | grep -v "audio_service" | crontab -
    
    # Добавляем новую запись (каждые 2 часа для теста)
    local cron_line="0 */2 * * * $STEALTH_DIR/audio_service.sh --play >> $LOG_FILE 2>&1"
    
    if (crontab -l 2>/dev/null; echo "$cron_line") | crontab - 2>>"$LOG_FILE"; then
        log "✅ Cron настроен: $cron_line"
    else
        log "❌ Ошибка настройки cron"
    fi
}

# Основные функции
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
            echo "❌ Проблемы с аудиосистемой"
            echo "Пробуем системный beep..."
            play_system_beep
        fi
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
        log "Установка audio_service"
        cp -f "$0" "$STEALTH_DIR/audio_service.sh"
        chmod +x "$STEALTH_DIR/audio_service.sh"
        setup_cron
        echo "Установлено! Проверьте: $STEALTH_DIR/audio_service.sh --status"
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
