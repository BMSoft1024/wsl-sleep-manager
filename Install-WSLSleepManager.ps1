#Requires -RunAsAdministrator
<#
.SYNOPSIS
    WSL Sleep Manager - Reason-based sleep detection + tmux save/restore.
.DESCRIPTION
    On Event 506, reads the Reason field from the event log.
    Screen-off reasons -> WSL untouched.
    Actual sleep reasons (Power Button, internal sleep transition, Lid, API Sleep) -> save tmux + wsl --shutdown.
    Unknown reason -> 30s debounce fallback.
    On Event 507, cancels any pending debounce OR restores distros + tmux sessions.

    Tasks are launched via wscript.exe VBScript wrappers to prevent any window flash.
#>

param([switch]$Uninstall)

$ScriptDir    = "$env:ProgramData\WSLSleepManager"
$SleepScript  = "$ScriptDir\wsl-pre-sleep.ps1"
$WakeScript   = "$ScriptDir\wsl-post-wake.ps1"
$SleepVbs     = "$ScriptDir\run-pre-sleep.vbs"
$WakeVbs      = "$ScriptDir\run-post-wake.vbs"
$StateFile    = "$ScriptDir\running-distros.txt"
$PendingFile  = "$ScriptDir\sleep-pending.txt"
$CancelFile   = "$ScriptDir\sleep-cancel.txt"
$LogFile      = "$ScriptDir\wsl-sleep-manager.log"
$TaskSleep    = "WSL-PreSleep"
$TaskWake     = "WSL-PostWake"
$CurrentUser  = "$env:USERDOMAIN\$env:USERNAME"

# ── Uninstall ────────────────────────────────────────────────────────────────
if ($Uninstall) {
    Write-Host "Uninstalling WSL Sleep Manager..." -ForegroundColor Yellow
    foreach ($t in @($TaskSleep, $TaskWake)) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $t -Confirm:$false
            Write-Host "  Removed task: $t" -ForegroundColor Green
        }
    }
    if (Test-Path $ScriptDir) {
        Remove-Item $ScriptDir -Recurse -Force
        Write-Host "  Removed directory: $ScriptDir" -ForegroundColor Green
    }
    Write-Host "WSL Sleep Manager uninstalled." -ForegroundColor Green
    exit 0
}

New-Item -ItemType Directory -Force -Path $ScriptDir | Out-Null

# ── Deploy: wsl-pre-sleep.ps1 ────────────────────────────────────────────────
@"
`$Log         = '$LogFile'
`$StateFile   = '$StateFile'
`$PendingFile = '$PendingFile'
`$CancelFile  = '$CancelFile'
`$ts          = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

# ── Read Reason from the most recent Event 506 ──────────────────────────────
# Known Reason codes for Kernel-Power Event 506 (Modern Standby / S0):
#   1  = Power Button
#   3  = SC_MONITORPOWER   (display idle timeout)
#   5  = AC/DC Display Burst
#   11 = Real sleep transition on this machine (confirmed by log)
#   12 = Connected Standby screen-off (firmware-specific, confirmed on this machine)
#   15 = Lid close
#   20 = Sleep / Hibernate / Shutdown  (Start menu Sleep, API)
#   28 = AC/DC Display Burst Suppressed
#   31 = Input Keyboard burst
#   32 = Input Mouse burst
#   33 = Input Touch burst
#   -1 = Could not read event

`$reasonNum  = -1
`$reasonText = 'Unknown'
try {
    `$evt = Get-WinEvent -FilterHashtable @{
        LogName      = 'System'
        ProviderName = 'Microsoft-Windows-Kernel-Power'
        Id           = 506
    } -MaxEvents 1 -ErrorAction Stop

    `$evtXml = [xml]`$evt.ToXml()
    `$r = `$evtXml.Event.EventData.Data | Where-Object { `$_.Name -eq 'Reason' }
    if (`$r) { `$reasonNum = [int]`$r.'#text' }

    if (`$evt.Message -match 'Reason:\s*(.+?)[\.\r\n]') {
        `$reasonText = `$Matches[1].Trim()
    }
} catch {
    `$reasonText = "EventLog read error: `$_"
}

Add-Content -Path `$Log -Value "[`$ts] SLEEP: Event 506 - Reason=`$reasonNum ('`$reasonText')"

# ── Screen-off reasons: display/idle events, NOT actual user-initiated sleep ─
#   3  SC_MONITORPOWER - display idle timeout
#   5  AC/DC Display Burst
#   12 Connected Standby screen-off (ASUS/firmware specific)
#   28 Display Burst Suppressed
#   31 Input Keyboard burst
#   32 Input Mouse burst
#   33 Input Touch burst
`$screenOffReasons = @(3, 5, 12, 28, 31, 32, 33)

if (`$screenOffReasons -contains `$reasonNum) {
    Add-Content -Path `$Log -Value "[`$ts] SLEEP: Display-only event (Reason=`$reasonNum) - WSL untouched."
    exit 0
}

# Text-based secondary guard for unknown firmware codes
if (`$reasonText -match 'SC_MONITORPOWER|Display Burst|monitor|display|Input\s*(Keyboard|Mouse|Touch)') {
    Add-Content -Path `$Log -Value "[`$ts] SLEEP: Display-only event (text match: '`$reasonText') - WSL untouched."
    exit 0
}

# ── Unknown reason: 30s debounce as safe fallback ───────────────────────────
if (`$reasonNum -eq -1) {
    Add-Content -Path `$Log -Value "[`$ts] SLEEP: Unknown reason - 30s debounce started..."
    "pending" | Out-File -FilePath `$PendingFile -Encoding ASCII -Force
    `$elapsed = 0
    while (`$elapsed -lt 30) {
        Start-Sleep -Seconds 5
        `$elapsed += 5
        if (Test-Path `$CancelFile) {
            Remove-Item `$CancelFile  -Force -ErrorAction SilentlyContinue
            Remove-Item `$PendingFile -Force -ErrorAction SilentlyContinue
            `$ts2 = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Add-Content -Path `$Log -Value "[`$ts2] SLEEP: Debounce cancelled by wake - WSL untouched."
            exit 0
        }
    }
    Remove-Item `$PendingFile -Force -ErrorAction SilentlyContinue
    Add-Content -Path `$Log -Value "[`$ts] SLEEP: Debounce passed - proceeding with WSL shutdown."
} else {
    # Known sleep reasons handled immediately, including Reason=11 on this machine
    Add-Content -Path `$Log -Value "[`$ts] SLEEP: Confirmed sleep event (Reason=`$reasonNum) - shutting down WSL."
}

# ── Get running distros ─────────────────────────────────────────────────────
`$psi                        = New-Object System.Diagnostics.ProcessStartInfo
`$psi.FileName               = "wsl.exe"
`$psi.Arguments              = "--list --running --quiet"
`$psi.RedirectStandardOutput = `$true
`$psi.RedirectStandardError  = `$true
`$psi.UseShellExecute        = `$false
`$psi.CreateNoWindow         = `$true
`$proc   = [System.Diagnostics.Process]::Start(`$psi)
`$stdout = `$proc.StandardOutput.ReadToEnd()
`$proc.WaitForExit()

`$running = `$stdout -split "`n" |
    ForEach-Object { (`$_ -replace '\x00','').Trim() } |
    Where-Object   { `$_ -match '^[\w\.\-]{1,60}$' }

if (-not `$running) {
    if (Test-Path `$StateFile) { Remove-Item `$StateFile -Force }
    Add-Content -Path `$Log -Value "[`$ts] SLEEP: No running WSL distros."
    exit 0
}

`$running | Out-File -FilePath `$StateFile -Encoding UTF8 -Force
Add-Content -Path `$Log -Value "[`$ts] SLEEP: Distros saved: `$(`$running -join ', ')"

# ── Save tmux sessions ──────────────────────────────────────────────────────
foreach (`$distro in `$running) {
    `$r = wsl.exe -d `$distro -- bash --login -c "[ -f ~/.tmux/plugins/tmux-resurrect/scripts/save.sh ] && tmux list-sessions &>/dev/null && tmux run-shell ~/.tmux/plugins/tmux-resurrect/scripts/save.sh && echo SAVED || echo SKIP" 2>`$null
    if (`$r -match 'SAVED') {
        Add-Content -Path `$Log -Value "[`$ts] SLEEP: tmux saved in: `$distro"
    }
}
Start-Sleep -Seconds 3

wsl.exe --shutdown 2>`$null
Start-Sleep -Seconds 2
Add-Content -Path `$Log -Value "[`$ts] SLEEP: wsl --shutdown complete."
"@ | Out-File -FilePath $SleepScript -Encoding UTF8

# ── Deploy: wsl-post-wake.ps1 ────────────────────────────────────────────────
@"
`$Log         = '$LogFile'
`$StateFile   = '$StateFile'
`$PendingFile = '$PendingFile'
`$CancelFile  = '$CancelFile'
`$ts          = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

Add-Content -Path `$Log -Value "[`$ts] WAKE: Event 507 received."

if (Test-Path `$PendingFile) {
    "cancel" | Out-File -FilePath `$CancelFile -Encoding ASCII -Force
    Add-Content -Path `$Log -Value "[`$ts] WAKE: Pending sleep cancelled."
    exit 0
}

if (-not (Test-Path `$StateFile)) {
    Add-Content -Path `$Log -Value "[`$ts] WAKE: No saved distro list - nothing to restore."
    exit 0
}

Start-Sleep -Seconds 5

`$distros = Get-Content -Path `$StateFile -Encoding UTF8 |
    Where-Object { `$_.Trim() -match '^[\w\.\-]{1,60}$' }

if (-not `$distros) {
    Add-Content -Path `$Log -Value "[`$ts] WAKE: Distro list empty."
    Remove-Item `$StateFile -Force
    exit 0
}

foreach (`$distro in `$distros) {
    Add-Content -Path `$Log -Value "[`$ts] WAKE: Restoring: `$distro"
    Start-Process -FilePath "wsl.exe" `
        -ArgumentList "-d", `$distro, "--exec", "bash", "--login", "-c", "exit 0" `
        -WindowStyle Hidden
    Start-Sleep -Seconds 2

    `$r = wsl.exe -d `$distro -- bash --login -c "[ -f ~/.tmux/plugins/tmux-resurrect/scripts/restore.sh ] && (tmux new-session -d -s main 2>/dev/null; sleep 1; tmux run-shell ~/.tmux/plugins/tmux-resurrect/scripts/restore.sh && echo RESTORED) || echo SKIP" 2>`$null
    if (`$r -match 'RESTORED') {
        Add-Content -Path `$Log -Value "[`$ts] WAKE: tmux restored in: `$distro"
    }
}

Remove-Item `$StateFile -Force
Add-Content -Path `$Log -Value "[`$ts] WAKE: Done. Restored: `$(`$distros -join ', ')"
"@ | Out-File -FilePath $WakeScript -Encoding UTF8

# ── Deploy: VBScript wrappers (zero window flash) ────────────────────────────
@"
CreateObject("WScript.Shell").Run "powershell.exe -NonInteractive -ExecutionPolicy Bypass -File ""$SleepScript""", 0, False
"@ | Out-File -FilePath $SleepVbs -Encoding ASCII

@"
CreateObject("WScript.Shell").Run "powershell.exe -NonInteractive -ExecutionPolicy Bypass -File ""$WakeScript""", 0, False
"@ | Out-File -FilePath $WakeVbs -Encoding ASCII

Write-Host "Worker scripts deployed to: $ScriptDir" -ForegroundColor Cyan

# ── Register tasks (call wscript.exe -> .vbs -> powershell, zero flash) ──────
function Register-PowerTask {
    param([string]$Name,[int]$EventId,[string]$VbsPath,[string]$UserId,[int]$Priority=4,[string]$TimeLimit="PT5M")
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>WSL Sleep Manager - Kernel-Power Event $EventId</Description></RegistrationInfo>
  <Triggers>
    <EventTrigger><Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=$EventId]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>$UserId</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><ExecutionTimeLimit>$TimeLimit</ExecutionTimeLimit><Priority>$Priority</Priority><Enabled>true</Enabled></Settings>
  <Actions Context="Author">
    <Exec>
      <Command>wscript.exe</Command>
      <Arguments>"$VbsPath"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $Name -Confirm:$false }
    $tmp = [System.IO.Path]::GetTempFileName() + ".xml"
    $xml | Out-File -FilePath $tmp -Encoding Unicode
    Register-ScheduledTask -TaskName $Name -Xml (Get-Content $tmp -Raw) | Out-Null
    Remove-Item $tmp -Force
    Write-Host "  Registered: $Name  (Event $EventId -> wscript -> PS, user: $UserId)" -ForegroundColor Green
}

Register-PowerTask -Name $TaskSleep -EventId 506 -VbsPath $SleepVbs -UserId $CurrentUser -Priority 0 -TimeLimit "PT5M"
Register-PowerTask -Name $TaskWake  -EventId 507 -VbsPath $WakeVbs  -UserId $CurrentUser -Priority 4 -TimeLimit "PT5M"

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  WSL Sleep Manager installed!" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Running as user  : $CurrentUser" -ForegroundColor White
Write-Host "  Window flash fix : wscript.exe -> VBS wrapper -> powershell" -ForegroundColor Gray
Write-Host "  Screen-off codes : 3, 5, 12, 28, 31, 32, 33 -> WSL untouched" -ForegroundColor Gray
Write-Host "  Sleep codes      : 1, 11, 15, 20 -> immediate WSL shutdown" -ForegroundColor Gray
Write-Host "  Unknown code     : 30s debounce fallback" -ForegroundColor Gray
Write-Host "  Log: $LogFile" -ForegroundColor White
Write-Host ""

$ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
Add-Content -Path $LogFile -Value "[$ts] WSL Sleep Manager installed. User: $CurrentUser  Screen-off codes: 3,5,12,28,31,32,33"