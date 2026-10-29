# Runs the core checks, then publishes dist\KeyBox.exe (single file; needs the .NET 10 Desktop Runtime).
# Usage:  powershell -ExecutionPolicy Bypass -File build.ps1 [-SelfContained]
#   -SelfContained  bundle the runtime too (bigger exe that runs on PCs without .NET 10)
param([switch]$SelfContained)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

dotnet run --project "$root\tests\KeyBox.Tests\KeyBox.Tests.csproj" -c Release
if ($LASTEXITCODE -ne 0) { throw 'tests failed' }

$sc = if ($SelfContained) { 'true' } else { 'false' }
dotnet publish "$root\src\KeyBox\KeyBox.csproj" -c Release -r win-x64 --self-contained $sc `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=$sc `
    -p:DebugType=none -o "$root\dist"
if ($LASTEXITCODE -ne 0) { throw 'publish failed' }
Get-Item "$root\dist\KeyBox.exe" | Select-Object Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
