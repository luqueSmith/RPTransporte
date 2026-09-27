$ErrorActionPreference = "Stop"
$src = $PSScriptRoot
$repo = "C:\Users\luque\Downloads\RPTransporte_v17"

Write-Host "Copiando APC Transporte v1.5..." -ForegroundColor Cyan
robocopy $src $repo /E /XD node_modules .git dist docs | Out-Host
if ($LASTEXITCODE -ge 8) { throw "Robocopy fallo con codigo $LASTEXITCODE" }

Set-Location $repo

Write-Host "Instalando dependencias..." -ForegroundColor Cyan
npm install

Write-Host "Compilando web..." -ForegroundColor Cyan
npm run build

if (!(Test-Path "$repo\dist\index.html")) {
  throw "No se genero dist\index.html"
}

Write-Host "Preparando docs para GitHub Pages..." -ForegroundColor Cyan
if (Test-Path "$repo\docs") { Remove-Item "$repo\docs" -Recurse -Force }
New-Item -ItemType Directory -Path "$repo\docs" | Out-Null
Copy-Item "$repo\dist\*" "$repo\docs" -Recurse -Force
New-Item -ItemType File -Path "$repo\docs\.nojekyll" -Force | Out-Null

if (Test-Path "$repo\.github\workflows\deploy-pages.yml") {
  Remove-Item "$repo\.github\workflows\deploy-pages.yml" -Force
}

git add -A
$changes = git status --porcelain
if ($changes) {
  git commit -m "Mejora logos y movimientos APC Transporte v1.5"
  git push
} else {
  Write-Host "No hay cambios nuevos para subir." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host " APC TRANSPORTE v1.5 SUBIDA A GITHUB" -ForegroundColor Green
Write-Host " GitHub Pages: main / docs" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
