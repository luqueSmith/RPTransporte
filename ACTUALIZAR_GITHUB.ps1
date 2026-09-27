$ErrorActionPreference = "Stop"
$src = $PSScriptRoot
$repo = "C:\Users\luque\Downloads\RPTransporte_v17"

Write-Host "Copiando APC Transporte Web v1.6..." -ForegroundColor Cyan
robocopy $src $repo /E /XD node_modules .git dist docs | Out-Host
if ($LASTEXITCODE -ge 8) { throw "Robocopy fallo con codigo $LASTEXITCODE" }

Set-Location $repo
Write-Host "Instalando dependencias..." -ForegroundColor Cyan
npm install
Write-Host "Compilando..." -ForegroundColor Cyan
npm run build

if (!(Test-Path "$repo\dist\index.html")) { throw "No se genero dist\index.html" }
if (Test-Path "$repo\docs") { Remove-Item "$repo\docs" -Recurse -Force }
New-Item -ItemType Directory -Path "$repo\docs" | Out-Null
Copy-Item "$repo\dist\*" "$repo\docs" -Recurse -Force
New-Item -ItemType File -Path "$repo\docs\.nojekyll" -Force | Out-Null

git add -A
$changes = git status --porcelain
if ($changes) {
  git commit -m "Optimiza carga y ajusta logos APC Transporte v1.6"
  git push
  Write-Host "WEB APC v1.6 SUBIDA CORRECTAMENTE" -ForegroundColor Green
} else {
  Write-Host "No hay cambios nuevos para subir." -ForegroundColor Yellow
}
