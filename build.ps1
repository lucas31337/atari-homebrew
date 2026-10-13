# Usage: .\build.ps1 hello [-Run]
# Assembles src\<name>.asm -> bin\<name>.a26 (4K, raw binary) and optionally opens it in Stella.
param(
    [Parameter(Mandatory)] [string]$Name,
    [switch]$Run
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force "$PSScriptRoot\bin" | Out-Null

$src = "$PSScriptRoot\src\$Name.asm"
$out = "$PSScriptRoot\bin\$Name.a26"

dasm $src -f3 -v0 "-I$PSScriptRoot\include" "-I$PSScriptRoot\src" "-o$out" "-l$PSScriptRoot\bin\$Name.lst" "-s$PSScriptRoot\bin\$Name.sym"
if ($LASTEXITCODE -ne 0) { throw "dasm failed ($LASTEXITCODE)" }
Write-Host "Built $out ($((Get-Item $out).Length) bytes)"

if ($Run) { & "C:\Program Files\Stella\Stella.exe" $out }
