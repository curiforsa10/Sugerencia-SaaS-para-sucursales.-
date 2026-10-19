# ============================================================
#  tarea_si_no_corrio_hoy.ps1 - La corrida de las 09:30, sin repetir
#
#  Lo corre la tarea "Sugerido Curifor - Motor diario" en el PC de la jefa (la deja
#  instalar_pc_jefa.ps1). Lanza tarea_diaria.ps1 SOLO si:
#    - hoy no hubo corrida: el log del dia (logs\motor_<fecha>.log) no tiene la
#      linea RESULTADO. El acceso del Escritorio "Actualizar plataforma" corre el
#      programa del ERP y despues tarea_diaria.ps1, que deja esa linea: si ella ya
#      actualizo temprano, a las 09:30 no se calcula dos veces lo mismo;
#    - no hay otra corrida en curso (candado del motor con su proceso vivo; uno
#      viejo de un proceso muerto no frena, el motor lo pisa al arrancar).
#
#  Si a las 09:30 el acceso "Actualizar plataforma" esta bajando las tablas, espera
#  a que termine (hasta 60 minutos) y vuelve a mirar: si el acceso publico, no hace
#  nada; si el programa del ERP fallo y el acceso no calculo, calcula con lo que
#  haya. Lanzar el motor en ese momento leeria archivos a medio bajar, y despues el
#  acceso ya no podria publicar los nuevos ("NO SE CORRE: ya hay una corrida").
#
#  En el PC del dueño la tarea de las 09:30 corre tarea_diaria.ps1 directo: ahi no
#  hay acceso "Actualizar plataforma" que pueda haber corrido antes.
# ============================================================
param(
    # Cada cuanto se vuelve a mirar si el acceso termino, y hasta cuando. Solo las
    # pruebas los cambian.
    [int]$EsperaSeg = 30,
    [int]$EsperaMaxMin = 60
)
$ErrorActionPreference = "Continue"
$root = Split-Path $PSScriptRoot -Parent
$log = "$root\logs\motor_$(Get-Date -Format 'yyyy-MM-dd').log"

. "$PSScriptRoot\salida_motor.ps1"

$limite = (Get-Date).AddMinutes($EsperaMaxMin)
while ((Actualizacion-EnCurso $root) -and (Get-Date) -lt $limite) {
    Start-Sleep -Seconds $EsperaSeg
}

if ((Test-Path $log) -and (Select-String -Path $log -Pattern '^RESULTADO' -Quiet)) { exit 0 }
if (Corrida-EnCurso $root) { exit 0 }
if (Actualizacion-EnCurso $root) { exit 0 }  # paso la hora y el acceso sigue: que publique el

& "$PSScriptRoot\tarea_diaria.ps1"
exit $LASTEXITCODE
