<#
.SYNOPSIS
    Installs tmux + TPM + tmux-resurrect inside a chosen WSL distro.
.NOTES
    Called from WSLSleepManager.bat option 4.
    Does NOT require Administrator rights.
#>

# ── List available distros ────────────────────────────────────────────────────
$psi                        = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName               = "wsl.exe"
$psi.Arguments              = "--list --quiet"
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.UseShellExecute        = $false
$psi.CreateNoWindow         = $true
$proc   = [System.Diagnostics.Process]::Start($psi)
$stdout = $proc.StandardOutput.ReadToEnd()
$proc.WaitForExit()

$distros = $stdout -split "`n" |
    ForEach-Object { ($_ -replace '\x00','').Trim() } |
    Where-Object   { $_ -match '^[\w\.\-]{1,60}$' }

if (-not $distros) {
    Write-Host "  No WSL distros found." -ForegroundColor Red
    Read-Host "`n  Press Enter to return"
    exit 1
}

# ── Distro selection ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Available WSL distros:" -ForegroundColor Cyan
$i = 1
foreach ($d in $distros) { Write-Host "    $i  $d"; $i++ }
Write-Host ""
$choice = Read-Host "  Choose distro number"
$idx    = [int]$choice - 1
if ($idx -lt 0 -or $idx -ge $distros.Count) {
    Write-Host "  Invalid choice." -ForegroundColor Red
    Read-Host "`n  Press Enter to return"
    exit 1
}
$distro = $distros[$idx]
Write-Host ""
Write-Host "  Target distro: $distro" -ForegroundColor Green
Write-Host ""

# ── Helper: pipe bash script via stdin with LF line endings ──────────────────
# PowerShell strings contain CRLF on Windows; bash requires LF only.
# Writing raw UTF-8 bytes to BaseStream bypasses StreamWriter's CRLF auto-insert,
# preventing "$'\r': command not found" and unexpected EOF errors in bash.
function Invoke-WslScript {
    param([string]$Distro, [string]$Script)
    $unixScript = $Script -replace "`r`n", "`n" -replace "`r", "`n"
    $bytes      = [System.Text.Encoding]::UTF8.GetBytes($unixScript)

    $proc2 = New-Object System.Diagnostics.Process
    $proc2.StartInfo.FileName               = "wsl.exe"
    $proc2.StartInfo.Arguments              = "-d $Distro -- bash --login"
    $proc2.StartInfo.RedirectStandardInput  = $true
    $proc2.StartInfo.UseShellExecute        = $false
    $proc2.Start() | Out-Null

    $proc2.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc2.StandardInput.BaseStream.Flush()
    $proc2.StandardInput.Close()
    $proc2.WaitForExit()
}

# ── Step 1: Check / install tmux ─────────────────────────────────────────────
Write-Host "  [1/4] Checking tmux..." -ForegroundColor Yellow
$tmuxVer = wsl.exe -d $distro -- bash --login -c "command -v tmux &>/dev/null && tmux -V || echo MISSING" 2>$null
if ("$tmuxVer" -match 'MISSING') {
    Write-Host "        Installing tmux via apt..." -ForegroundColor Gray
    wsl.exe -d $distro -- bash --login -c "sudo apt-get update -qq && sudo apt-get install -y tmux"
} else {
    Write-Host "        Already installed: $($tmuxVer.Trim())" -ForegroundColor Gray
}

# ── Step 2: Clone / update TPM ───────────────────────────────────────────────
Write-Host "  [2/4] Setting up TPM..." -ForegroundColor Yellow
Invoke-WslScript -Distro $distro -Script '
if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
    echo "        Cloning TPM..."
    git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
else
    echo "        TPM already present - updating..."
    git -C "$HOME/.tmux/plugins/tpm" pull --ff-only
fi
'

# ── Step 3: Update ~/.tmux.conf ──────────────────────────────────────────────
Write-Host "  [3/4] Updating ~/.tmux.conf..." -ForegroundColor Yellow
Invoke-WslScript -Distro $distro -Script '
CONF="$HOME/.tmux.conf"
touch "$CONF"
if grep -q "tmux-resurrect" "$CONF" 2>/dev/null; then
    echo "        Already configured."
else
    printf "\n# --- WSL Sleep Manager: tmux-resurrect ---\n" >> "$CONF"
    printf "set -g @plugin '"'"'tmux-plugins/tpm'"'"'\n" >> "$CONF"
    printf "set -g @plugin '"'"'tmux-plugins/tmux-resurrect'"'"'\n" >> "$CONF"
    sed -i "/run .*.tmux.plugins.tpm.tpm.*/d" "$CONF"
    printf "run '"'"'~/.tmux/plugins/tpm/tpm'"'"'\n" >> "$CONF"
    echo "        .tmux.conf updated."
fi
'

# ── Step 4: Install plugins ───────────────────────────────────────────────────
Write-Host "  [4/4] Installing plugins via TPM..." -ForegroundColor Yellow
wsl.exe -d $distro -- bash --login -c "~/.tmux/plugins/tpm/bin/install_plugins 2>&1"

# ── Verify ────────────────────────────────────────────────────────────────────
$check = wsl.exe -d $distro -- bash --login -c "[ -f ~/.tmux/plugins/tmux-resurrect/scripts/save.sh ] && echo OK || echo MISSING" 2>$null
Write-Host ""
if ("$check" -match 'OK') {
    Write-Host "  ==========================================" -ForegroundColor Cyan
    Write-Host "   tmux-resurrect installed in: $distro" -ForegroundColor Green
    Write-Host "  ==========================================" -ForegroundColor Cyan
} else {
    Write-Host "  WARNING: save.sh not found - installation may have failed." -ForegroundColor Red
    Write-Host "  Check ~/.tmux/plugins/ inside the distro manually." -ForegroundColor Red
}
Write-Host "   Manual usage inside tmux:" -ForegroundColor White
Write-Host "     Ctrl+B  Ctrl+S  ->  save sessions" -ForegroundColor Gray
Write-Host "     Ctrl+B  Ctrl+R  ->  restore sessions" -ForegroundColor Gray
Write-Host "   WSL Sleep Manager handles this automatically on sleep/wake." -ForegroundColor White
Write-Host ""
Read-Host "  Press Enter to return to menu"
