# ============================================================
#  tarea_al_iniciar_sesion.ps1 - Recupera la corrida diaria que se perdio
#
#  El PC se reinicia solo a la 01:00 (politica de la empresa) y la tarea de las
#  09:30 necesita una sesion iniciada: si nadie entra antes, Windows no la lanza
#  y tampoco la recupera despues (evento 332, "user not logged-on"). Esta tarea
#  corre al iniciar sesion y lanza la corrida del dia SOLO si:
#    - ya pasaron las 09:30 (antes, la corre la tarea diaria a su hora);
#    - hoy no hubo corrida (el log del dia no tiene la linea RESULTADO);
#    - no hay otra corrida en curso (candado del motor).
#  Asi no corre dos veces ni antes que el programa del ERP.
# ============================================================
$ErrorActionPreference = "Continue"
$root = Split-Path $PSScriptRoot -Parent
$log = "$root\logs\motor_$(Get-Date -Format 'yyyy-MM-dd').log"
$candado = "$root\apps\api\data\motor.lock"

if ((Get-Date).TimeOfDay -lt [TimeSpan]::Parse("09:30")) { exit 0 }
if ((Test-Path $log) -and (Select-String -Path $log -Pattern '^RESULTADO' -Quiet)) { exit 0 }
if (Test-Path $candado) { exit 0 }

& "$PSScriptRoot\tarea_diaria.ps1"
exit $LASTEXITCODE
