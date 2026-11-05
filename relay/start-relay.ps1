function Resolve-Dart {
    $candidates = @()
    if ($env:DART) { $candidates += $env:DART }
    if ($env:FLUTTER_ROOT) { $candidates += (Join-Path $env:FLUTTER_ROOT "bin\dart.bat") }
    $candidates += "dart"

    foreach ($candidate in $candidates) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    return $null
}

$dart = Resolve-Dart
if (-not $dart) {
    Write-Error "Dart tidak ditemukan. Tambahkan folder bin Flutter/Dart ke PATH, atau set variabel lingkungan DART ke dart.bat."
    exit 1
}

Set-Location $PSScriptRoot

if (-not (Test-Path ".env")) {
    Write-Error "File relay/.env belum ada. Salin relay/.env.example menjadi relay/.env lalu isi nilainya."
    exit 1
}

& $dart pub get
& $dart run bin/relay.dart serve
