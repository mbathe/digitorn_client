$flutterPath = "C:\Users\ASUS\flutter"
if (-not (Test-Path $flutterPath)) {
    Write-Host "Cloning Flutter SDK..."
    git clone https://github.com/flutter/flutter.git -b stable $flutterPath
} else {
    Write-Host "Flutter directory already exists."
}

$flutterBin = "$flutterPath\bin"
if ($env:Path -notlike "*$flutterBin*") {
    Write-Host "Adding Flutter to session PATH..."
    $env:Path += ";$flutterBin"
}

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notmatch [regex]::Escape($flutterBin)) {
    Write-Host "Adding Flutter to User PATH permanently..."
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$flutterBin", "User")
}

Write-Host "Running flutter setup..."
flutter doctor
