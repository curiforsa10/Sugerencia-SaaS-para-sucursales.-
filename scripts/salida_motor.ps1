# ============================================================
#  salida_motor.ps1 - Que dijo una corrida oficial del motor
#
#  Lo cargan los scripts que corren el motor sin nadie mirando:
#  agente_actualizacion.ps1 (los botones "Actualizar ahora" y "Actualizar motor"),
#  tarea_vigentes_ford.ps1, tarea_si_no_corrio_hoy.ps1 y actualizar_plataforma.ps1.
#    . "$PSScriptRoot\salida_motor.ps1"
#
#  Que el motor salga con 0 no quiere decir que publico. En un PC que no es el
#  titular de Fuentes de datos no calcula ni publica: imprime "NO SE PUBLICA: este
#  PC no es el titular (<alias>)" y sale con 0 a proposito, porque no es una falla.
#  Sin mirar esa linea, el agente le decia "OK" a la web sin haber publicado nada.
#
#  Las pruebas estan en apps/api/tests_motor/test_scripts_salida_motor.py.
# ============================================================

# El alias del PC titular si el motor no publico porque este PC no es el titular.
# $null si no.
function Titular-SiNoPublico($salida) {
    $linea = $salida | Select-String -Pattern 'NO SE PUBLICA: este PC no es el titular \((.*)\)' |
             Select-Object -First 1
    if ($linea) { return $linea.Matches[0].Groups[1].Value }
    return $null
}

# Las filas de la carga oficial ("CARGA OFICIAL: 17102 filas."). $null si el motor
# no imprimio esa linea. Se pregunta antes de indizar: `.Matches.Groups[1]` sobre un
# resultado nulo, con $ErrorActionPreference = "Stop", lanzaba "No se puede indizar
# en una matriz nula" y ese texto llegaba a la tarjeta de la web.
function Filas-Publicadas($salida) {
    $linea = $salida | Select-String -Pattern 'CARGA OFICIAL:\s*([\d\.]+)\s*filas' |
             Select-Object -First 1
    if ($linea) { return $linea.Matches[0].Groups[1].Value }
    return $null
}

# Si hay una corrida del motor en curso en este PC: la fecha de inicio que anoto
# el motor en su candado (apps/api/data/motor.lock, "<PID> <fecha>"). $null si no
# hay candado, o si el proceso que lo dejo ya no existe: el motor pisa ese candado
# viejo al arrancar (`tomar_candado`), asi que no frena nada y tampoco tiene que
# frenar a quien pregunta. Se mira que el proceso sea Python porque Windows recicla
# los PID: un candado viejo con el numero de otro programa no es una corrida.
function Corrida-EnCurso($root) {
    $candado = Join-Path $root "apps\api\data\motor.lock"
    if (-not (Test-Path $candado)) { return $null }
    $texto = "$(Get-Content $candado -Raw -ErrorAction SilentlyContinue)".Trim()
    if ($texto -notmatch '^(\d+)\s*(.*)$') { return $null }
    $desde = $matches[2].Trim()
    $proceso = Get-Process -Id ([int]$matches[1]) -ErrorAction SilentlyContinue
    if (-not $proceso -or $proceso.ProcessName -notlike "python*") { return $null }
    if (-not $desde) { $desde = "hora desconocida" }
    return $desde
}

# Si el acceso "Actualizar plataforma" (actualizar_plataforma.ps1) esta corriendo en
# este PC: la fecha en que empezo. $null si no. Mientras baja las tablas del ERP no
# hay que lanzar el motor (leeria archivos a medio bajar y despues el acceso ya no
# podria publicar los nuevos: "NO SE CORRE") ni cambiar el codigo. Mismo formato
# de candado que el del motor, con el PID de esa ventana de PowerShell.
function Actualizacion-EnCurso($root) {
    $candado = Join-Path $root ".actualizar_plataforma.lock"
    if (-not (Test-Path $candado)) { return $null }
    $texto = "$(Get-Content $candado -Raw -ErrorAction SilentlyContinue)".Trim()
    if ($texto -notmatch '^(\d+)\s*(.*)$') { return $null }
    $desde = $matches[2].Trim()
    $proceso = Get-Process -Id ([int]$matches[1]) -ErrorAction SilentlyContinue
    if (-not $proceso -or $proceso.ProcessName -notlike "powershell*") { return $null }
    if (-not $desde) { $desde = "hora desconocida" }
    return $desde
}
