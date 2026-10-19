# ============================================================
#  agente_actualizacion.ps1 - Atiende los botones "Actualizar ahora" y "Actualizar motor"
#
#  La plataforma corre en la nube y NO ve los Excel de "Bases de datos", que estan en
#  este PC. Cuando alguien aprieta un boton en la web, la plataforma solo deja una
#  solicitud anotada. Este script es quien la va a buscar: pregunta cada minuto si hay
#  algo pendiente, lo hace y devuelve el resultado para que la web lo muestre.
#
#  Dos tipos de solicitud:
#    recalcular        "Actualizar ahora": corre el motor oficial y publica.
#    actualizar_motor  "Actualizar motor" (solo admin): baja la ultima version del
#                      motor desde GitHub (avance rapido de la rama actual) y, si
#                      cambiaron las librerias, las reinstala. Nunca corre el motor.
#
#  No lo ejecuta una persona: lo dispara una tarea programada de Windows cada minuto
#  (la crean instalar_agente.ps1 o instalar_pc_jefa.ps1). Corre oculto, sin ventanas.
#
#  Este archivo va en UTF-8 CON BOM: los mensajes de la tarjeta llevan tildes, y sin
#  BOM Windows PowerShell 5.1 lo lee como Windows-1252 y las rompe.
#
#  Uso manual (para probar):
#    .\agente_actualizacion.ps1 -Verboso     -> una pasada, mostrando lo que hace
# ============================================================
param(
    # Muestra en pantalla lo que va haciendo. Sin esto solo escribe en el log.
    [switch]$Verboso
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root = Split-Path $PSScriptRoot -Parent
$logDir = "$root\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$log = "$logDir\agente_$(Get-Date -Format 'yyyy-MM-dd').log"

# Plazos. Tienen que calzar con los de la plataforma (routers/actualizacion.py): si el
# agente sigue trabajando cuando la plataforma ya dio la solicitud por caida, la web
# muestra un error de algo que en realidad termino bien.
#   - Una corrida del motor tarda 22 a 35 minutos (logs de octubre de 2026); la
#     plataforma espera 75 antes de darla por perdida. El candado dura lo mismo.
#   - La tarea de Windows corta al agente a los 90 minutos (instalar_*.ps1).
$CANDADO_MIN = 75

function Escribir($texto) {
    $linea = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $texto
    Add-Content -Path $log -Value $linea -Encoding utf8
    if ($Verboso) { Write-Host $linea }
}

# Que dijo el motor: si publico, cuantas filas, si este PC no es el titular, y si hay
# una corrida en curso.
. "$PSScriptRoot\salida_motor.ps1"

# --- Configuracion: se lee del .env (lo dejan los instaladores) ---
# -Encoding UTF8: sin eso PowerShell 5.1 lee como Windows-1252 un .env sin BOM, y la
# carpeta de Data BI se llama "...Logística...": el motor, que hereda estas variables y
# les da prioridad sobre su propio .env, recibia la ruta rota y no veia el stock.
$envFile = "$root\.env"
if (Test-Path $envFile) {
    foreach ($linea in Get-Content $envFile -Encoding UTF8) {
        if ($linea -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$') {
            $valor = $matches[2].Trim().Trim('"').Trim("'")
            if ($valor) { Set-Item -Path "env:$($matches[1])" -Value $valor }
        }
    }
}
$apiUrl = $env:PLATAFORMA_API_URL
if (-not $apiUrl) { $apiUrl = "https://sugerido-api.onrender.com" }
$secreto = $env:AGENTE_SECRET
if (-not $secreto) {
    Escribir "Sin AGENTE_SECRET en el .env: el agente no puede identificarse. Corre el instalador."
    exit 1
}

# Una corrida del motor tarda ~30 min y la tarea despierta cada minuto: sin este candado
# se lanzarian varios motores encima del mismo Excel. La tarea ademas esta configurada
# como IgnorarNueva; el candado cubre el caso de ejecuciones a mano.
$candado = "$root\.agente.lock"
if (Test-Path $candado) {
    $desde = (Get-Item $candado).LastWriteTime
    if ((Get-Date) - $desde -lt [TimeSpan]::FromMinutes($CANDADO_MIN)) {
        Escribir "Ya hay una corrida en curso (desde $($desde.ToString('HH:mm:ss'))). No hago nada."
        exit 0
    }
    # Candado viejo: quedo de una corrida que murio a medias (se apago el PC).
    Escribir "Candado vencido de las $($desde.ToString('HH:mm:ss')): lo descarto."
    Remove-Item $candado -Force
}

$cabeceras = @{ "X-Agente-Secret" = $secreto }

# --- Git (solo para "actualizar_motor" y para informar la version) ---------------
function Buscar-Git {
    $g = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g) { return $g.Source }
    foreach ($p in @("$env:ProgramFiles\Git\cmd\git.exe", "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}
$gitExe = Buscar-Git

# Corre git en la raiz del repo. Devuelve @{ codigo; salida } con la salida como texto.
# "Continue" a proposito: con "Stop", PowerShell 5.1 convierte en excepcion la primera
# linea que un programa escribe en stderr, y git escribe ahi hasta el avance normal.
function Correr-Git {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $salida = & $gitExe -C $root @args 2>&1 | ForEach-Object { "$_" }
        # TrimEnd y no Trim: "git status --porcelain" parte con un espacio (" M archivo").
        return @{ codigo = $LASTEXITCODE; salida = (@($salida) -join "`n").TrimEnd() }
    }
    finally { $ErrorActionPreference = $eap }
}

# "<sha corto> <rama>", igual que lo informa el motor en Fuentes de datos.
function Version-Motor {
    if (-not $gitExe) { return $null }
    $sha = (Correr-Git rev-parse --short HEAD)
    $rama = (Correr-Git rev-parse --abbrev-ref HEAD)
    if ($sha.codigo -ne 0) { return $null }
    if ($rama.codigo -eq 0 -and $rama.salida) { return "$($sha.salida) $($rama.salida)" }
    return $sha.salida
}

# La primera linea util de un error de git, para la tarjeta de la web.
function Primera-Linea($texto) {
    $l = @("$texto" -split "`n" | Where-Object { $_ -match '\S' }) | Select-Object -First 1
    $l = "$l".Trim() -replace '^(fatal|error):\s*', ''
    if ($l.Length -gt 200) { $l = $l.Substring(0, 200) + "…" }
    return $l
}

# --- actualizar_motor -------------------------------------------------------------
# Devuelve @{ ok; mensaje }. Nunca corre el motor.
function Actualizar-Motor {
    $enCurso = Corrida-EnCurso $root
    if ($enCurso) {
        return @{ ok = $false; mensaje = "No se actualizó: el motor está calculando en este PC " +
            "(desde $enCurso). Vuelve a intentarlo cuando termine; tarda unos 30 minutos." }
    }
    if (-not $gitExe) {
        return @{ ok = $false; mensaje = "No se actualizó: este PC no tiene Git instalado. " +
            "Hay que correr de nuevo el instalador (INSTALAR PLATAFORMA)." }
    }
    $rama = Correr-Git rev-parse --abbrev-ref HEAD
    if ($rama.codigo -ne 0) {
        return @{ ok = $false; mensaje = "No se actualizó: la carpeta del motor no es un repositorio " +
            "de Git ($(Primera-Linea $rama.salida)). Hay que correr de nuevo el instalador." }
    }
    $rama = $rama.salida
    if ($rama -eq "HEAD") {
        return @{ ok = $false; mensaje = "No se actualizó: el motor de este PC no está en ninguna " +
            "rama (quedó fijo en una versión). Avísale a quien mantiene el motor." }
    }
    # Solo archivos versionados: los logs, el .env y el candado no cuentan.
    $cambios = Correr-Git status --porcelain --untracked-files=no
    if ($cambios.codigo -ne 0) {
        return @{ ok = $false; mensaje = "No se actualizó: no se pudo revisar el código del motor " +
            "($(Primera-Linea $cambios.salida))." }
    }
    if ($cambios.salida) {
        $archivos = @($cambios.salida -split "`n" | ForEach-Object { $_.Substring(3).Trim() })
        $lista = ($archivos | Select-Object -First 3) -join ", "
        if ($archivos.Count -gt 3) { $lista += " y $($archivos.Count - 3) más" }
        return @{ ok = $false; mensaje = "No se actualizó: el código del motor en este PC tiene " +
            "cambios hechos a mano ($lista). Hay que revisarlos antes; avísale a quien mantiene el motor." }
    }

    $antes = (Correr-Git rev-parse --short HEAD).salida
    # Sin preguntas: la tarea corre oculta, y una ventana pidiendo clave la dejaria
    # colgada hasta que Windows la corte.
    $env:GIT_TERMINAL_PROMPT = "0"
    $env:GCM_INTERACTIVE = "never"
    # Mensajes de git en ingles siempre: los de abajo se reconocen por su texto.
    $env:LC_ALL = "C"
    Escribir "Bajando la version nueva de origin/$rama (hoy en $antes)..."
    $fetch = Correr-Git fetch --quiet origin $rama
    if ($fetch.codigo -ne 0) {
        return @{ ok = $false; mensaje = "No se pudo bajar la versión nueva desde GitHub: " +
            "$(Primera-Linea $fetch.salida). Revisa que este PC tenga internet y vuelve a intentarlo." }
    }
    $merge = Correr-Git merge --ff-only --quiet "origin/$rama"
    if ($merge.codigo -ne 0) {
        Escribir "git merge fallo: $($merge.salida)"
        if ($merge.salida -match 'untracked working tree files would be overwritten') {
            $nombres = @($merge.salida -split "`n" | Where-Object { $_ -match '^\s+\S' } |
                         ForEach-Object { $_.Trim() } | Select-Object -First 3) -join ", "
            return @{ ok = $false; mensaje = "No se actualizó: en este PC hay archivos sin registrar " +
                "que la versión nueva trae con el mismo nombre ($nombres). Hay que moverlos o borrarlos antes." }
        }
        if ($merge.salida -match 'Not possible to fast-forward|not possible to fast-forward|Diverging') {
            return @{ ok = $false; mensaje = "No se actualizó: la versión de este PC tiene cambios que " +
                "no están en GitHub, así que no puede avanzar sola. Avísale a quien mantiene el motor." }
        }
        return @{ ok = $false; mensaje = "No se actualizó: $(Primera-Linea $merge.salida)." }
    }
    $despues = (Correr-Git rev-parse --short HEAD).salida
    if ($despues -eq $antes) {
        return @{ ok = $true; mensaje = "El motor ya estaba al día ($antes)." }
    }
    $n = (Correr-Git rev-list --count "$antes..$despues").salida
    $mensaje = "Motor actualizado de $antes a $despues ($n cambios)."
    Escribir $mensaje

    # Las librerias solo se tocan si la version nueva cambio la lista.
    $reqs = (Correr-Git diff --name-only $antes $despues -- "apps/api/requirements*.txt").salida
    if ($reqs) {
        $venvPy = "$root\apps\api\.venv\Scripts\python.exe"
        $req = "$root\apps\api\requirements-motor.txt"
        if (-not (Test-Path $req)) { $req = "$root\apps\api\requirements.txt" }
        Escribir "Cambiaron las librerias ($($reqs -replace "`n", ', ')): reinstalando con $req"
        $pipCodigo = 1
        $pipSalida = "Falta el entorno de Python del motor ($venvPy)."
        if (Test-Path $venvPy) {
            $eap = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $pipSalida = & $venvPy -m pip install --disable-pip-version-check -r $req 2>&1 |
                             ForEach-Object { "$_" }
                $pipCodigo = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $eap }
            Add-Content -Path $log -Value $pipSalida -Encoding utf8
        }
        if ($pipCodigo -ne 0) {
            # Codigo nuevo con librerias viejas puede romper la corrida de mañana:
            # se vuelve a la version anterior, que sigue funcionando con lo instalado.
            $atras = Correr-Git reset --keep $antes
            $err = ($pipSalida | Where-Object { $_ -match 'ERROR|error:' } | Select-Object -Last 1)
            if (-not $err) { $err = ($pipSalida | Where-Object { $_ -match '\S' } | Select-Object -Last 1) }
            if ($atras.codigo -eq 0) {
                return @{ ok = $false; mensaje = "No se actualizó: la versión $despues necesita " +
                    "librerías nuevas y no se pudieron instalar ($(Primera-Linea $err)). El motor quedó " +
                    "en la versión anterior ($antes), que sigue funcionando." }
            }
            return @{ ok = $false; mensaje = "El código quedó en $despues, pero no se pudieron instalar " +
                "las librerías nuevas ($(Primera-Linea $err)). El motor puede fallar hasta que alguien " +
                "corra de nuevo el instalador." }
        }
        $mensaje += " Se instalaron las librerías nuevas."
    }
    return @{ ok = $true; mensaje = $mensaje }
}

# --- recalcular -------------------------------------------------------------------
function Ya-EnCurso($desde) {
    $cuando = if ($desde) { " (desde $desde)" } else { "" }
    return @{ ok = $false; mensaje = "No se lanzó otra corrida: el motor ya está calculando en este " +
        "PC$cuando. Los datos nuevos se publican cuando esa corrida termine; no hace falta " +
        "volver a apretar el botón." }
}

# Devuelve @{ ok; mensaje }.
function Correr-Motor {
    # Con otra corrida andando (la tarea de las 09:30, o el acceso "Actualizar
    # plataforma") el motor sale con 0 sin calcular, y la tarjeta decia "terminó
    # correctamente" sin haber hecho nada.
    $enCurso = Corrida-EnCurso $root
    if ($enCurso) { return (Ya-EnCurso $enCurso) }
    $venvPy = "$root\apps\api\.venv\Scripts\python.exe"
    if (-not (Test-Path $venvPy)) {
        return @{ ok = $false; mensaje = "Falta el entorno de Python en este PC. Hay que correr el instalador." }
    }
    # El motor escribe en UTF-8 y PowerShell lo lee igual: si no, las tildes de un
    # error del motor llegaban rotas a la tarjeta.
    $env:PYTHONIOENCODING = "utf-8"
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

    Push-Location "$root\apps\api"
    $eap = $ErrorActionPreference
    # "Continue" como en tarea_diaria.ps1: con "Stop" la primera linea que el motor
    # escribia en stderr (un aviso, o el traceback de un error) cortaba la corrida
    # y esa linea llegaba sola a la tarjeta.
    $ErrorActionPreference = "Continue"
    try {
        # Se llama al modulo directo y no a correr_motor.ps1: ese pide confirmar
        # escribiendo SI por teclado, y aca no hay nadie mirando la pantalla.
        $salida = & $venvPy -m src.jobs.correr_motor_real --oficial 2>&1 | ForEach-Object { "$_" }
        $codigo = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $eap
        Pop-Location
    }
    if ($null -eq $codigo) { $codigo = 1 }
    Add-Content -Path $log -Value $salida -Encoding utf8

    $titular = if ($codigo -eq 0) { Titular-SiNoPublico $salida } else { $null }
    if ($titular) {
        # Este PC ya no es el titular de Fuentes de datos: el motor sale con 0 a
        # proposito (no es una falla), pero no calculo ni publico. La tarjeta no
        # puede quedar en OK. Pasa si el PC que dejo de ser titular conserva la
        # tarea del agente: los dos compiten por cada clic (ver data/crudos/README.md).
        return @{ ok = $false; mensaje = "No se publicó nada: la solicitud la tomó un PC que ya no es el titular " +
                   "(el titular es $titular). Vuelve a apretar el botón; si se repite, avísale a un admin." }
    }
    if ($codigo -eq 0 -and ($salida | Select-String -Pattern '^NO SE CORRE:' -Quiet)) {
        # La otra corrida partio entre la pregunta de arriba y el arranque del motor.
        return (Ya-EnCurso $null)
    }
    if ($codigo -eq 0) {
        # El mensaje va tal cual a la tarjeta de la web, asi que se arma en lenguaje
        # de usuario a partir de lo que el motor imprimio.
        $filas = Filas-Publicadas $salida
        if ($filas) { return @{ ok = $true; mensaje = "Se publicaron $filas filas." } }
        return @{ ok = $true; mensaje = "El motor terminó correctamente." }
    }
    # Los errores utiles del motor salen como "ERROR ..." o como la ultima linea
    # de un traceback; cualquiera de los dos le dice al usuario que revisar.
    $err = ($salida | Select-String -Pattern '^(ERROR|ValueError|FileNotFoundError|.*Error:)' |
            Select-Object -Last 1)
    if (-not $err) { $err = ($salida | Where-Object { $_ -match '\S' } | Select-Object -Last 1) }
    $mensaje = "$err".Trim()
    if ($mensaje.Length -gt 400) { $mensaje = $mensaje.Substring(0, 400) + "…" }
    if (-not $mensaje) { $mensaje = "El motor terminó con error (código $codigo)." }
    return @{ ok = $false; mensaje = $mensaje }
}

# --- 1) Hay algo pendiente? ---
try {
    $url = "$apiUrl/api/actualizacion/pendiente?agente=$([uri]::EscapeDataString($env:COMPUTERNAME))"
    $pendiente = Invoke-RestMethod -Uri $url -Headers $cabeceras -Method Get -TimeoutSec 60
}
catch {
    # El servidor gratuito de Render se duerme: el primer intento puede fallar por
    # timeout. Es normal y no vale la pena ensuciar el log todos los minutos.
    Escribir "No pude consultar la plataforma: $($_.Exception.Message)"
    exit 0
}

if (-not $pendiente.hay) {
    if ($Verboso) { Escribir "Sin solicitudes pendientes." }
    exit 0
}

$idSolicitud = $pendiente.id
# Una plataforma anterior al campo "tipo" solo sabe pedir que se recalcule.
$tipo = "$($pendiente.tipo)"
if (-not $tipo) { $tipo = "recalcular" }
Escribir "Solicitud $idSolicitud ($tipo) tomada (la pidio $($pendiente.solicitado_por))."
New-Item -ItemType File -Path $candado -Force | Out-Null

# --- 2) Hacer lo pedido ---
$ok = $false
$mensaje = "El agente no alcanzó a reportar."
try {
    if ($tipo -eq "recalcular") {
        Escribir "Corriendo el motor..."
        $r = Correr-Motor
    }
    elseif ($tipo -eq "actualizar_motor") {
        $r = Actualizar-Motor
    }
    else {
        # Un tipo nuevo de la plataforma que este agente no conoce: no se adivina.
        $r = @{ ok = $false; mensaje = "Este PC no sabe atender una solicitud de tipo '$tipo'. " +
                "Hay que actualizar el motor de este PC." }
    }
    $ok = [bool]$r.ok
    $mensaje = $r.mensaje
}
catch {
    $mensaje = $_.Exception.Message
}
finally {
    Remove-Item $candado -Force -ErrorAction SilentlyContinue
}

# --- 3) Reportar el resultado a la plataforma ---
try {
    $cuerpo = @{ id = $idSolicitud; ok = $ok; mensaje = $mensaje; version = (Version-Motor) } |
              ConvertTo-Json -Compress
    # En bytes UTF-8: con el texto tal cual, PowerShell 5.1 lo manda en ISO-8859-1 y la
    # plataforma rechaza el cuerpo apenas el mensaje trae una tilde.
    Invoke-RestMethod -Uri "$apiUrl/api/actualizacion/terminar" -Headers $cabeceras -Method Post `
        -ContentType "application/json; charset=utf-8" `
        -Body ([Text.Encoding]::UTF8.GetBytes($cuerpo)) -TimeoutSec 60 | Out-Null
    Escribir "Reportado: ok=$ok - $mensaje"
}
catch {
    # Si no se puede avisar, la solicitud queda "en curso" y la plataforma la cierra
    # sola con un aviso (75 minutos si era recalcular, 15 si era actualizar el motor).
    # Peor seria dejarla girando para siempre.
    Escribir "No pude reportar el resultado: $($_.Exception.Message)"
}
