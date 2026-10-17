# ============================================================
#  salida_motor.ps1 - Que dijo una corrida oficial del motor
#
#  Lo cargan los scripts que corren el motor sin nadie mirando:
#  agente_actualizacion.ps1 (el boton "Actualizar ahora") y tarea_vigentes_ford.ps1.
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
