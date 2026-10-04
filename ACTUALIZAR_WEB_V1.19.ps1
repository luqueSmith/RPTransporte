$ErrorActionPreference = "Stop"

# ============================================================
# APC Transporte Web v1.19 - Publicacion automatica en GitHub
# ============================================================
$src  = $PSScriptRoot
$repo = "C:\Users\luque\Downloads\RPTransporte_v17"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " APC TRANSPORTE - ACTUALIZAR WEB v1.19" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "Origen:      $src"
Write-Host "Repositorio: $repo"
Write-Host ""

if (!(Test-Path (Join-Path $src "package.json"))) {
    throw "No se encontro package.json. Ejecuta este archivo dentro de la carpeta APC_Transporte_Web_v1.19_FILTROS_SUSTENTOS."
}
if (!(Test-Path (Join-Path $repo ".git"))) {
    throw "No se encontro el repositorio Git en $repo"
}
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw "No se encontro npm. Abre PowerShell despues de instalar Node.js."
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "No se encontro git. Instala Git o abre una terminal donde git funcione."
}

$package = Get-Content (Join-Path $src "package.json") -Raw | ConvertFrom-Json
$version = $package.version
Write-Host "Version detectada: $version" -ForegroundColor Green
Write-Host ""

Write-Host "[1/5] Copiando la nueva web al repositorio..." -ForegroundColor Yellow
robocopy $src $repo /E /XD node_modules .git dist docs /XF ACTUALIZAR_WEB_V1.19.ps1 | Out-Host
if ($LASTEXITCODE -ge 8) {
    throw "Robocopy fallo con codigo $LASTEXITCODE"
}

Set-Location $repo

Write-Host ""
Write-Host "[2/5] Instalando/verificando dependencias..." -ForegroundColor Yellow
npm install
if ($LASTEXITCODE -ne 0) { throw "npm install fallo." }

Write-Host ""
Write-Host "[3/5] Compilando la web..." -ForegroundColor Yellow
npm run build
if ($LASTEXITCODE -ne 0) { throw "La compilacion de Vite fallo." }
if (!(Test-Path "$repo\dist\index.html")) {
    throw "No se genero dist\index.html"
}

Write-Host ""
Write-Host "[4/5] Preparando GitHub Pages..." -ForegroundColor Yellow
if (Test-Path "$repo\docs") {
    Remove-Item "$repo\docs" -Recurse -Force
}
New-Item -ItemType Directory -Path "$repo\docs" | Out-Null
Copy-Item "$repo\dist\*" "$repo\docs" -Recurse -Force
New-Item -ItemType File -Path "$repo\docs\.nojekyll" -Force | Out-Null

Write-Host ""
Write-Host "[5/5] Subiendo cambios a GitHub..." -ForegroundColor Yellow
git add -A
$changes = git status --porcelain
if ($changes) {
    git commit -m "Filtros y sustentos APC Transporte v$version"
    if ($LASTEXITCODE -ne 0) { throw "No se pudo crear el commit." }
    git push
    if ($LASTEXITCODE -ne 0) { throw "No se pudo hacer git push." }
    Write-Host ""
    Write-Host "LISTO: web v$version enviada a GitHub." -ForegroundColor Green
    Write-Host "Espera 1-3 minutos y abre:" -ForegroundColor Green
    Write-Host "https://luquesmith.github.io/RPTransporte/" -ForegroundColor Cyan
} else {
    Write-Host "No habia cambios nuevos para subir." -ForegroundColor Yellow
}

Write-Host ""
Read-Host "Presiona ENTER para cerrar"
