$ErrorActionPreference = "Stop"
$src = $PSScriptRoot
$repo = "C:\Users\luque\Downloads\RPTransporte_v17"

Write-Host "Origen: $src"
Write-Host "Repositorio: $repo"

if (!(Test-Path (Join-Path $src "package.json"))) { throw "No se encontro package.json en la carpeta de esta actualizacion." }
if (!(Test-Path (Join-Path $repo ".git"))) { throw "No se encontro el repositorio RPTransporte_v17." }

$version = (Get-Content (Join-Path $src "package.json") -Raw | ConvertFrom-Json).version
Write-Host "Actualizando APC Transporte Web v$version..." -ForegroundColor Cyan

robocopy $src $repo /E /XD node_modules .git dist docs | Out-Host
if ($LASTEXITCODE -ge 8) { throw "Robocopy fallo con codigo $LASTEXITCODE" }

Set-Location $repo
npm install
npm run build

if (!(Test-Path "$repo\dist\index.html")) { throw "La compilacion no genero dist\index.html" }
if (Test-Path "$repo\docs") { Remove-Item "$repo\docs" -Recurse -Force }
New-Item -ItemType Directory -Path "$repo\docs" | Out-Null
Copy-Item "$repo\dist\*" "$repo\docs" -Recurse -Force
New-Item -ItemType File -Path "$repo\docs\.nojekyll" -Force | Out-Null

git add -A
$changes = git status --porcelain
if ($changes) {
  git commit -m "Simplifica filtro de fechas APC Transporte v$version"
  git push
  Write-Host "Actualizacion enviada a GitHub correctamente." -ForegroundColor Green
} else {
  Write-Host "No hay cambios nuevos para subir." -ForegroundColor Yellow
}
