# Backup PostgreSQL relay ke file dump kustom.
# Contoh:
#   .\scripts\backup.ps1
#   .\scripts\backup.ps1 -OutDir D:\backup\relay -KeepDays 14
param(
    [string]$DatabaseUrl = "",
    [string]$OutDir = (Join-Path $PSScriptRoot "..\backups"),
    [string]$PgBin = "C:\PostgreSQL\17\bin",
    [int]$KeepDays = 30
)

$ErrorActionPreference = "Stop"

function Read-DotEnvValue([string]$key) {
    $envFile = Join-Path $PSScriptRoot "..\.env"
    if (-not (Test-Path $envFile)) { return $null }
    foreach ($line in Get-Content $envFile) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) { continue }
        $separator = $trimmed.IndexOf("=")
        if ($separator -le 0) { continue }
        if ($trimmed.Substring(0, $separator).Trim() -eq $key) {
            return $trimmed.Substring($separator + 1).Trim().Trim('"').Trim("'")
        }
    }
    return $null
}

if ([string]::IsNullOrWhiteSpace($DatabaseUrl)) {
    $DatabaseUrl = Read-DotEnvValue "RELAY_DATABASE_URL"
}
if ([string]::IsNullOrWhiteSpace($DatabaseUrl)) {
    Write-Error "RELAY_DATABASE_URL belum diatur. Isi relay/.env atau pakai -DatabaseUrl."
    exit 1
}

$pgDump = Join-Path $PgBin "pg_dump.exe"
$pgRestore = Join-Path $PgBin "pg_restore.exe"
if (-not (Test-Path $pgDump)) {
    Write-Error "pg_dump tidak ditemukan di $pgDump. Sesuaikan -PgBin."
    exit 1
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$file = Join-Path $OutDir "pusatkupos-relay-$stamp.dump"

& $pgDump --format=custom --no-owner --no-privileges --file=$file --dbname=$DatabaseUrl
if ($LASTEXITCODE -ne 0) {
    Write-Error "pg_dump gagal dengan kode $LASTEXITCODE."
    exit $LASTEXITCODE
}

# Dump dianggap valid hanya bila daftar isinya dapat dibaca.
& $pgRestore --list $file | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Dump tidak dapat dibaca ulang oleh pg_restore: $file"
    exit $LASTEXITCODE
}

$size = (Get-Item $file).Length
Write-Output "OK dump=$file bytes=$size"

if ($KeepDays -gt 0) {
    $cutoff = (Get-Date).AddDays(-$KeepDays)
    Get-ChildItem $OutDir -Filter "pusatkupos-relay-*.dump" |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force
}
