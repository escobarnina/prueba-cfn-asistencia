# =====================================================================
#  Escaneo local de las plantillas (Windows / PowerShell) - mismos escáneres que el pipeline.
#  Requisito: Docker Desktop abierto.
#
#  Uso (desde la raíz del repo):
#     .\anidados\escanear.ps1                         # plantillas anidadas (el "después")
#     .\anidados\escanear.ps1 -Ruta docs\seguridad    # plantilla insegura de demo (el "antes")
#
#  Si PowerShell bloquea el script:  Set-ExecutionPolicy -Scope Process Bypass
# =====================================================================
param(
    [string]$Ruta = "anidados"
)

$rutaUnix = $Ruta -replace '\\', '/'
$nombre   = ($rutaUnix -split '/')[-1]
$salida   = "reportes\$nombre"
New-Item -ItemType Directory -Force -Path "$salida\kics" | Out-Null

function Titulo($texto) {
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  $texto" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

if (Get-Command cfn-lint -ErrorAction SilentlyContinue) {
    Titulo "0. cfn-lint (sintaxis)"
    cfn-lint "$Ruta\*.yaml"
    if ($LASTEXITCODE -eq 0) { Write-Host "Sin errores." -ForegroundColor Green }
}

Titulo "1. cfn-nag (seguridad propia de CloudFormation)"
docker run --rm --entrypoint cfn_nag_scan -v "${PWD}/${rutaUnix}:/templates" stelligent/cfn_nag --input-path /templates |
    Tee-Object -FilePath "$salida\cfn-nag.txt"

Titulo "2. Trivy (malas configuraciones IaC)"
docker run --rm -v "${PWD}/${rutaUnix}:/src" aquasec/trivy config /src |
    Tee-Object -FilePath "$salida\trivy.txt"

Titulo "3. KICS (cumplimiento CIS/NIST, reporte HTML)"
docker run --rm -v "${PWD}:/w" checkmarx/kics scan -p "/w/$rutaUnix" -o "/w/reportes/$nombre/kics" --report-formats "html,json" --ignore-on-exit results

Titulo "Listo. Reportes en $salida (KICS: $salida\kics\results.html)"
