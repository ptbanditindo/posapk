$dart = "C:\Users\sukron\flutter\bin\dart.bat"
if (-not (Test-Path $dart)) {
    $dart = "dart"
}

Set-Location $PSScriptRoot

if (-not (Test-Path ".env")) {
    Write-Error "File relay/.env belum ada. Salin relay/.env.example menjadi relay/.env lalu isi nilainya."
    exit 1
}

& $dart pub get
& $dart run bin/relay.dart serve
