# Restore dump relay ke database kosong. PERINGATAN: --clean menghapus objek
# yang ada di database tujuan.
# Contoh:
#   .\scripts\restore.ps1 -DumpFile .\backups\pusatkupos-relay-20260101-030000.dump
param(
    [Parameter(Mandatory = $true)][string]$DumpFile,
    [string]$DatabaseUrl = "",
    [string]$PgBin = "C:\PostgreSQL\17\bin",
    [switch]$Force
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
if (-not (Test-Path $DumpFile)) {
    Write-Error "File dump tidak ditemukan: $DumpFile"
    exit 1
}
$pgRestore = Join-Path $PgBin "pg_restore.exe"
if (-not (Test-Path $pgRestore)) {
    Write-Error "pg_restore tidak ditemukan di $pgRestore. Sesuaikan -PgBin."
    exit 1
}

if (-not $Force) {
    Write-Output "Tujuan restore: $DatabaseUrl"
    $answer = Read-Host "Ketik RESTORE untuk melanjutkan"
    if ($answer -ne "RESTORE") {
        Write-Output "Dibatalkan."
        exit 1
    }
}

& $pgRestore --clean --if-exists --no-owner --no-privileges --dbname=$DatabaseUrl $DumpFile
if ($LASTEXITCODE -ne 0) {
    Write-Error "pg_restore selesai dengan kode $LASTEXITCODE. Periksa log di atas."
    exit $LASTEXITCODE
}
Write-Output "OK restore=$DumpFile"
