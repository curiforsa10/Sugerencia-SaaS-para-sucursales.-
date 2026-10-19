# ============================================================
#  instalar_pc_jefa.ps1 - Deja este PC manteniendo la plataforma al día
#
#  Se corre con doble clic en "INSTALAR PLATAFORMA.cmd". Hace todo, paso a paso, y
#  dice qué hace y qué falta:
#    1. Python y Git (si faltan, los instala con winget).
#    2. El código del motor, en %USERPROFILE%\dev (nunca dentro de OneDrive).
#    3. El entorno de Python del motor (requirements-motor.txt).
#    4. La configuración (.env): plataforma, cuenta del motor, clave del agente y
#       carpetas de datos. Las claves se piden sin mostrarlas y solo van al .env.
#    5. Dónde está el programa que baja las tablas del ERP.
#    6. El acceso "Actualizar plataforma" en el Escritorio.
#    7. Las tareas de Windows: la de las 09:30, la de al iniciar sesión y el agente.
#    8. Una prueba final, sin publicar nada.
#  Se puede repetir las veces que haga falta: no pisa lo que ya está bien.
#
#  -Simular: hace todo en una carpeta temporal, sin instalar programas, sin tareas
#  reales (las registra con el prefijo "PRUEBA-", deshabilitadas, y las borra), sin
#  pedir claves (usa valores ficticios) y sin llamar a la plataforma de verdad (por
#  defecto apunta a http://127.0.0.1:8765, donde no hay nada o una plataforma falsa).
#    powershell -ExecutionPolicy Bypass -File scripts\instalar_pc_jefa.ps1 -Simular
#
#  Va en UTF-8 con BOM: los textos de pantalla llevan tildes.
# ============================================================
param(
    [switch]$Simular,
    # Con -Simular: no crea las carpetas de OneDrive de prueba, para ver los avisos.
    [switch]$SimularSinCarpetas,
    # Con -Simular: dónde (por defecto %TEMP%\simulacion-instalador). Si ya existe, se
    # comporta como una reinstalación.
    [string]$CarpetaSimulacion,
    # La plataforma. Por defecto la de producción (simulando, 127.0.0.1:8765).
    [string]$ApiUrl,
    # De dónde se clona y qué rama. Por defecto GitHub y arreglar-job-diario
    # (simulando, este mismo repositorio y su rama actual).
    [string]$Origen,
    [string]$Rama
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { $Host.UI.RawUI.WindowTitle = "Instalar plataforma de sugerido" } catch { }
# Lo que escriben git, pip y el motor se lee en UTF-8 (si no, las tildes salen rotas).
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$env:PYTHONIOENCODING = "utf-8"

$REPO_GITHUB = "https://github.com/platoniaaa/Sugerencia-SaaS-para-sucursales.-.git"
$RAMA_MOTOR = "arreglar-job-diario"
$API_PRODUCCION = "https://sugerido-api.onrender.com"
$CUENTA_MOTOR = "admin@curifor.com"   # la cuenta con que el motor publica
$TAREA_DIARIA = "Sugerido Curifor - Motor diario"
$TAREA_SESION = "Sugerido Curifor - Motor al iniciar sesion"
$TAREA_AGENTE = "Sugerido Curifor - Agente"

function Titulo($t) { Write-Host "`n==> $t" -ForegroundColor Cyan }
function Bien($t)   { Write-Host "    OK  $t" -ForegroundColor Green }
function Ojo($t)    { Write-Host "    !   $t" -ForegroundColor Yellow }
function Mal($t)    { Write-Host "    X   $t" -ForegroundColor Red }
function Info($t)   { Write-Host "        $t" }
function Sim($t)    { Write-Host "    [simulación] $t" -ForegroundColor Magenta }

$pendientes = New-Object System.Collections.Generic.List[string]
$listo = New-Object System.Collections.Generic.List[string]

function Salir($codigo) {
    if (-not $Simular) { Read-Host "`nEnter para cerrar esta ventana" | Out-Null }
    exit $codigo
}
function Frenar($texto, $queHacer) {
    Mal $texto
    foreach ($l in @($queHacer)) { Info $l }
    Write-Host "`nLa instalación quedó a medias. Cuando lo resuelvas, vuelve a hacer doble clic en" -ForegroundColor Yellow
    Write-Host "'INSTALAR PLATAFORMA': lo que ya quedó listo no se repite." -ForegroundColor Yellow
    Salir 1
}

# Corre un programa sin que PowerShell convierta en error lo que escribe en stderr
# (git y pip escriben ahí hasta el avance normal). Devuelve @{ codigo; salida }.
function Correr {
    param([string]$exe, [string[]]$argumentos, [switch]$Mostrar)
    $eap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $salida = & $exe @argumentos 2>&1 | ForEach-Object {
            $l = "$_"
            if ($Mostrar) { Write-Host "        $l" -ForegroundColor DarkGray }
            $l
        }
        $codigo = $LASTEXITCODE
    }
    catch { $salida = @("$($_.Exception.Message)"); $codigo = 1 }
    finally { $ErrorActionPreference = $eap }
    if ($null -eq $codigo) { $codigo = 0 }
    return @{ codigo = $codigo; salida = (@($salida) -join "`n").TrimEnd() }
}

function Refrescar-Path {
    # winget deja el PATH nuevo en el registro, no en esta ventana.
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User")
}

# ------------------------------------------------------------- Dónde se instala
if ($Simular) {
    if (-not $CarpetaSimulacion) { $CarpetaSimulacion = Join-Path $env:TEMP "simulacion-instalador" }
    # No se vacía: correrla dos veces prueba lo mismo que reinstalar. Para empezar de
    # cero, se borra la carpeta.
    New-Item -ItemType Directory -Force $CarpetaSimulacion | Out-Null
    $perfil = Join-Path $CarpetaSimulacion "perfil"
    $od = Join-Path $perfil "OneDrive - Curifor S.A"
    $escritorio = Join-Path $perfil "Escritorio"
    New-Item -ItemType Directory -Force $perfil, $escritorio | Out-Null
    if (-not $ApiUrl) { $ApiUrl = "http://127.0.0.1:8765" }
    if (-not $Origen) { $Origen = Split-Path $PSScriptRoot -Parent }
    if (-not $Rama) { $Rama = (& git -C $Origen rev-parse --abbrev-ref HEAD).Trim() }
    $prefijoTarea = "PRUEBA-"
}
else {
    $perfil = $env:USERPROFILE
    $od = $env:OneDriveCommercial
    $escritorio = [Environment]::GetFolderPath("Desktop")
    if (-not $ApiUrl) { $ApiUrl = $API_PRODUCCION }
    if (-not $Origen) { $Origen = $REPO_GITHUB }
    if (-not $Rama) { $Rama = $RAMA_MOTOR }
    $prefijoTarea = ""
}
$destino = Join-Path $perfil "dev\Sugerencia-SaaS-para-sucursales"
$envFile = Join-Path $destino ".env"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Plataforma de sugerido de compras: instalar en este PC" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
if ($Simular) { Sim "Todo pasa en $CarpetaSimulacion. No se instala nada en el PC." }
Write-Host "Este PC va a quedar calculando el sugerido todos los días y atendiendo los"
Write-Host "botones de la plataforma. Tarda unos 10 minutos y se hace una sola vez."
Write-Host "Si una pregunta tiene un valor entre [corchetes], Enter lo acepta."

# ================================================================ 1) Python y Git
Titulo "[1/8] Python y Git"

# El motor se probó con Python 3.14 (el del PC del dueño). Se busca ese primero.
function Buscar-Python {
    $candidatos = @()
    $py = Get-Command py -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($py) {
        $r = Correr $py.Source @("-3.14", "-c", "import sys; print(sys.executable)")
        if ($r.codigo -eq 0 -and $r.salida) { $candidatos += ($r.salida -split "`n")[-1].Trim() }
    }
    $candidatos += @(
        "$env:LOCALAPPDATA\Python\pythoncore-3.14-64\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python314\python.exe",
        "$env:ProgramFiles\Python314\python.exe"
    )
    $g = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g) { $candidatos += $g.Source }
    foreach ($v in @("313", "312")) {
        $candidatos += "$env:LOCALAPPDATA\Programs\Python\Python$v\python.exe"
        $candidatos += "$env:ProgramFiles\Python$v\python.exe"
    }
    $mejor = $null
    foreach ($c in $candidatos) {
        if (-not $c -or -not (Test-Path $c)) { continue }
        # El "python" de la Microsoft Store es un atajo que no corre nada: se prueba.
        $r = Correr $c @("-c", "import sys; print('%d.%d' % sys.version_info[:2])")
        if ($r.codigo -ne 0 -or $r.salida -notmatch '(\d+)\.(\d+)\s*$') { continue }
        $menor = [int]$matches[2]
        if ([int]$matches[1] -ne 3 -or $menor -lt 12) { continue }
        if ($menor -eq 14) { return @{ exe = $c; version = "3.14" } }
        if (-not $mejor) { $mejor = @{ exe = $c; version = "3.$menor" } }
    }
    return $mejor
}

function Buscar-Git {
    $g = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g) { return $g.Source }
    foreach ($p in @("$env:ProgramFiles\Git\cmd\git.exe", "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Instalar-ConWinget($id, $nombre) {
    if ($Simular) { Sim "Acá se instalaría $nombre con: winget install -e --id $id"; return }
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { Ojo "Este PC no tiene winget (el instalador de programas de Windows)."; return }
    Ojo "Instalando $nombre con winget (1 a 3 minutos). Si Windows pide permiso, acéptalo."
    # Primero solo para este usuario (no pide administrador); si el programa no se
    # ofrece así, para todo el PC.
    $r = Correr $winget.Source @("install", "-e", "--id", $id, "--scope", "user", "--silent",
        "--accept-package-agreements", "--accept-source-agreements") -Mostrar
    if ($r.codigo -ne 0) {
        Correr $winget.Source @("install", "-e", "--id", $id, "--silent",
            "--accept-package-agreements", "--accept-source-agreements") -Mostrar | Out-Null
    }
    Refrescar-Path
}

$python = Buscar-Python
if (-not $python -or $python.version -ne "3.14") {
    Instalar-ConWinget "Python.Python.3.14" "Python 3.14"
    $nuevo = Buscar-Python
    if ($nuevo) { $python = $nuevo }
}
if (-not $python) {
    Frenar "No hay Python en este PC y no se pudo instalar solo." @(
        "Instálalo desde https://www.python.org/downloads/ (Python 3.14, 'Download for Windows').",
        "En la primera pantalla marca 'Add python.exe to PATH' y después 'Install Now'.",
        "Si el PC no te deja instalar programas, pídeselo a TI.")
}
if ($python.version -ne "3.14") {
    Ojo "Se usa Python $($python.version). El motor se probó con 3.14; debería andar igual."
    $pendientes.Add("Python quedó en $($python.version) y no en 3.14 (el motor se probó con 3.14).")
}
Bien "Python $($python.version): $($python.exe)"

$git = Buscar-Git
if (-not $git) {
    Instalar-ConWinget "Git.Git" "Git"
    $git = Buscar-Git
}
if (-not $git) {
    Frenar "No hay Git en este PC y no se pudo instalar solo." @(
        "Git baja el código del motor y lo actualiza con el botón 'Actualizar motor'.",
        "Instálalo desde https://git-scm.com/download/win (todo con 'Next') o pídeselo a TI.")
}
Bien "Git: $git"

# Sin preguntas de usuario y clave: el repositorio es público, y una ventana de
# GitHub pidiendo entrar dejaría todo esperando.
$env:GIT_TERMINAL_PROMPT = "0"
$env:GCM_INTERACTIVE = "never"

# ================================================================== 2) Código
Titulo "[2/8] Código del motor"
foreach ($raiz in @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer, $od) | Where-Object { $_ }) {
    if ($destino.StartsWith($raiz.TrimEnd("\") + "\", [StringComparison]::OrdinalIgnoreCase)) {
        Frenar "La carpeta de destino quedó dentro de OneDrive ($destino)." @(
            "OneDrive sincronizaría el entorno de Python y los registros, y rompe el motor.",
            "Avísale a quien mantiene el motor.")
    }
}
if (Test-Path (Join-Path $destino ".git")) {
    $origenActual = (Correr $git @("-C", $destino, "remote", "get-url", "origin")).salida
    $ramaActual = (Correr $git @("-C", $destino, "rev-parse", "--abbrev-ref", "HEAD")).salida
    $shaActual = (Correr $git @("-C", $destino, "rev-parse", "--short", "HEAD")).salida
    Bien "Ya está en $destino (versión $shaActual, rama $ramaActual)."
    if (-not $Simular -and $origenActual -notmatch 'Sugerencia-SaaS-para-sucursales') {
        Frenar "Esa carpeta es una copia de otro proyecto ($origenActual). No la toco." @(
            "Muévela a otro lado y vuelve a correr el instalador.")
    }
    $respuesta = if ($Simular) { "S" } else { Read-Host "    ¿Bajar la última versión? (S/N) [S]" }
    if ($respuesta -eq "" -or $respuesta -match '^[sS]') {
        $cambios = (Correr $git @("-C", $destino, "status", "--porcelain", "--untracked-files=no")).salida
        if ($cambios) {
            Ojo "No se actualiza: hay archivos del motor cambiados a mano en este PC."
            $pendientes.Add("El código del motor tiene cambios a mano: revisarlos antes de actualizar.")
        }
        else {
            $f = Correr $git @("-C", $destino, "fetch", "--quiet", "origin", $ramaActual)
            $m = if ($f.codigo -eq 0) { Correr $git @("-C", $destino, "merge", "--ff-only", "--quiet", "origin/$ramaActual") } else { $f }
            $shaNuevo = (Correr $git @("-C", $destino, "rev-parse", "--short", "HEAD")).salida
            if ($m.codigo -ne 0) {
                Ojo "No se pudo actualizar: $(($m.salida -split "`n")[0])"
                $pendientes.Add("El código del motor no se pudo actualizar (ver arriba).")
            }
            elseif ($shaNuevo -eq $shaActual) { Bien "Ya estaba al día." }
            else { Bien "Actualizado de $shaActual a $shaNuevo." }
        }
    }
}
elseif (Test-Path $destino) {
    Frenar "Ya existe la carpeta $destino y no es una copia del motor. No la toco." @(
        "Muévela o bórrala y vuelve a correr el instalador.")
}
else {
    Info "Bajando el código a $destino ..."
    New-Item -ItemType Directory -Force (Split-Path $destino -Parent) | Out-Null
    $c = Correr $git @("clone", "--quiet", "--branch", $Rama, $Origen, $destino) -Mostrar
    if ($c.codigo -ne 0) {
        Frenar "No se pudo bajar el código del motor." @(
            "Revisa que el PC tenga internet y vuelve a intentarlo.",
            "Detalle: $(($c.salida -split "`n")[-1])")
    }
    Bien "Código listo (rama $Rama, versión $((Correr $git @('-C', $destino, 'rev-parse', '--short', 'HEAD')).salida))."
}
$scripts = Join-Path $destino "scripts"
. (Join-Path $scripts "robot_erp.ps1")

# ================================================================= 3) Entorno
Titulo "[3/8] Entorno de Python del motor (lo que más tarda: 2 a 5 minutos)"
$venv = Join-Path $destino "apps\api\.venv"
$venvPy = Join-Path $venv "Scripts\python.exe"
$req = Join-Path $destino "apps\api\requirements-motor.txt"
if (-not (Test-Path $req)) {
    Frenar "La versión del motor que se bajó no trae requirements-motor.txt." @(
        "Avísale a quien mantiene el motor: hay que publicar la rama $Rama con ese archivo.")
}
if (Test-Path $venvPy) {
    $v = Correr $venvPy @("-c", "import sys; print('%d.%d' % sys.version_info[:2])")
    if ($v.codigo -ne 0) {
        Ojo "El entorno que había no funciona: se arma de nuevo."
        Remove-Item $venv -Recurse -Force
    }
}
if (-not (Test-Path $venvPy)) {
    $r = Correr $python.exe @("-m", "venv", $venv)
    if ($r.codigo -ne 0) { Frenar "No se pudo crear el entorno de Python." @("Detalle: $($r.salida)") }
}
if (-not $Simular) { Correr $venvPy @("-m", "pip", "install", "--quiet", "--upgrade", "pip") | Out-Null }
Info "Instalando las librerías del motor (versiones fijas de requirements-motor.txt)..."
$pip = Correr $venvPy @("-m", "pip", "install", "--disable-pip-version-check", "--quiet", "-r", $req)
if ($pip.codigo -ne 0) {
    Frenar "No se pudieron instalar las librerías del motor." @(
        "Casi siempre es la conexión: revisa que el PC tenga internet y vuelve a intentarlo.",
        "Detalle: $(($pip.salida -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1))")
}
$prueba = Correr $venvPy @("-c", "import polars, fastexcel, openpyxl, httpx, truststore; print('ok')")
if ($prueba.codigo -ne 0) { Frenar "Las librerías quedaron instaladas pero no cargan." @("Detalle: $($prueba.salida)") }
Bien "Entorno listo."

# ============================================================ 4) Configuración
Titulo "[4/8] Configuración"

# El .env se lee y se escribe en UTF-8 sin BOM, y se conservan las líneas que ya tenía.
function Leer-Env {
    $valores = [ordered]@{}
    if (Test-Path $envFile) {
        foreach ($l in [IO.File]::ReadAllLines($envFile, [Text.Encoding]::UTF8)) {
            if ($l -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$') {
                $valores[$matches[1]] = $matches[2].Trim().Trim('"').Trim("'")
            }
        }
    }
    return $valores
}
function Escribir-Env($nuevos) {
    $lineas = New-Object System.Collections.Generic.List[string]
    $puestos = @{}
    if (Test-Path $envFile) {
        foreach ($l in [IO.File]::ReadAllLines($envFile, [Text.Encoding]::UTF8)) {
            $l = $l.TrimStart([char]0xFEFF)
            if ($l -match '^\s*([A-Z_][A-Z0-9_]*)\s*=' -and $nuevos.Contains($matches[1])) {
                $clave = $matches[1]
                if (-not $puestos.ContainsKey($clave)) { $lineas.Add("$clave=$($nuevos[$clave])"); $puestos[$clave] = $true }
                continue
            }
            $lineas.Add($l)
        }
    }
    foreach ($clave in $nuevos.Keys) {
        if (-not $puestos.ContainsKey($clave)) { $lineas.Add("$clave=$($nuevos[$clave])") }
    }
    [IO.File]::WriteAllLines($envFile, $lineas.ToArray(), (New-Object Text.UTF8Encoding $false))
}
function Leer-Clave($pregunta, $hayAnterior) {
    $extra = if ($hayAnterior) { " (Enter = dejar la que ya está)" } else { "" }
    $sec = Read-Host "    $pregunta$extra" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

$actual = Leer-Env
$cfg = [ordered]@{}

# La plataforma y la cuenta del motor.
$porDefecto = if ($actual["PLATAFORMA_API_URL"]) { $actual["PLATAFORMA_API_URL"] } else { $ApiUrl }
if ($Simular) { $cfg["PLATAFORMA_API_URL"] = $ApiUrl; Sim "Plataforma: $ApiUrl" }
else {
    $r = Read-Host "    Dirección de la plataforma [$porDefecto]"
    $cfg["PLATAFORMA_API_URL"] = if ($r) { $r.Trim().TrimEnd("/") } else { $porDefecto }
}
$porDefecto = if ($actual["PLATAFORMA_EMAIL"]) { $actual["PLATAFORMA_EMAIL"] } else { $CUENTA_MOTOR }
if ($Simular) { $cfg["PLATAFORMA_EMAIL"] = "motor@ejemplo.cl"; Sim "Cuenta del motor: motor@ejemplo.cl" }
else {
    Info "La cuenta con que el motor publica en la plataforma (no la tuya)."
    $r = Read-Host "    Correo de esa cuenta [$porDefecto]"
    $cfg["PLATAFORMA_EMAIL"] = if ($r) { $r.Trim() } else { $porDefecto }
}
if ($Simular) {
    $cfg["PLATAFORMA_PASSWORD"] = "clave-ficticia"
    $cfg["AGENTE_SECRET"] = "secreto-prueba"
    Sim "Claves ficticias: no se pide ninguna."
}
else {
    Info "Las claves no se ven al escribirlas y quedan guardadas solo en este PC (archivo .env)."
    $clave = Leer-Clave "Clave de esa cuenta" ([bool]$actual["PLATAFORMA_PASSWORD"])
    if (-not $clave) { $clave = $actual["PLATAFORMA_PASSWORD"] }
    if (-not $clave) { Frenar "Sin la clave de la cuenta del motor no se puede publicar." @("Pídesela a un admin de la plataforma.") }
    $cfg["PLATAFORMA_PASSWORD"] = $clave
    Info "La clave del agente es la que tiene configurada el servidor (AGENTE_SECRET en Render)."
    $secreto = Leer-Clave "Clave del agente" ([bool]$actual["AGENTE_SECRET"])
    if (-not $secreto) { $secreto = $actual["AGENTE_SECRET"] }
    if (-not $secreto) {
        Ojo "Sin la clave del agente, los botones 'Actualizar ahora' y 'Actualizar motor' no van a funcionar."
        $pendientes.Add("Falta la clave del agente: vuelve a correr el instalador cuando la tengas.")
    }
    else { $cfg["AGENTE_SECRET"] = $secreto }
}

# Carpetas de datos.
if ($Simular -and -not $SimularSinCarpetas) {
    foreach ($sub in @("stock", "Seguimientos de compras", "Ventas")) {
        New-Item -ItemType Directory -Force (Join-Path $od "Documentos\Desarrollos\Bases de datos\$sub") | Out-Null
    }
    New-Item -ItemType Directory -Force (Join-Path $od "Abastecimiento y Logística-Data BI - Datos") | Out-Null
    Sim "Carpetas de OneDrive de prueba creadas en $od"
}
if (-not $od) {
    Frenar "No encuentro el OneDrive de la empresa en este PC." @(
        "Abre OneDrive (la nube en la barra de tareas, junto a la hora) y entra con tu cuenta de la empresa.",
        "Cuando aparezca la carpeta 'OneDrive - Curifor S.A', vuelve a correr el instalador.")
}
$bases = Join-Path $od "Documentos\Desarrollos\Bases de datos"
$cfg["MOTOR_CRUDOS_DIR"] = $bases
if (Test-Path $bases) {
    $faltan = @("stock", "Seguimientos de compras") | Where-Object { -not (Test-Path (Join-Path $bases $_)) }
    if ($faltan) {
        Ojo "En 'Bases de datos' faltan las carpetas: $($faltan -join ', ')."
        Info "Las crea el programa del ERP la primera vez que baja las tablas: abre su panel.bat y"
        Info "descarga todo una vez (o usa el acceso 'Actualizar plataforma' cuando termine esto)."
        $pendientes.Add("Bajar las tablas del ERP una vez para que existan stock y Seguimientos de compras.")
    }
    else { Bien "Bases de datos: $bases" }
    if (-not (Test-Path (Join-Path $bases "Ventas"))) {
        Ojo "Falta la carpeta 'Ventas' con los respaldos de venta del año y del anterior."
        Info "El motor no publica sin ellos. Se bajan de la biblioteca 'Respaldos BBDD' de SharePoint"
        Info "y se dejan en Bases de datos\Ventas (ver docs\instalar-pc-jefa.md)."
        $pendientes.Add("Dejar los respaldos de venta en Bases de datos\Ventas.")
    }
}
else {
    Ojo "No existe todavía la carpeta $bases"
    Info "La crea el programa del ERP la primera vez que baja las tablas: abre su panel.bat y"
    Info "descarga todo una vez. La configuración queda escrita igual."
    $pendientes.Add("Bajar las tablas del ERP una vez para que exista Bases de datos.")
}

$dataBi = Get-ChildItem -Path $od -Directory -Filter "Abastecimiento y Log*stica-Data BI - Datos" -ErrorAction SilentlyContinue |
          Select-Object -First 1
if ($dataBi) {
    $cfg["MOTOR_STOCK_DIR"] = $dataBi.FullName
    Bien "Data BI (stock de Curifor): $($dataBi.FullName)"
}
else {
    $cfg["MOTOR_STOCK_DIR"] = Join-Path $od "Abastecimiento y Logística-Data BI - Datos"
    Ojo "Falta el acceso directo a la carpeta de SharePoint 'Data BI - Datos' (el stock que sube el equipo)."
    Info "No frena nada: el motor usa la copia del programa del ERP. Para agregarlo:"
    Info " 1. En el navegador, abre el sitio de SharePoint 'Abastecimiento y Logística - Data BI'."
    Info " 2. Entra a Documentos > Data BI > Datos."
    Info " 3. Arriba, elige 'Agregar acceso directo a Mis archivos'."
    Info " 4. En el Explorador, dentro de 'OneDrive - Curifor S.A', clic derecho sobre la carpeta"
    Info "    nueva > 'Mantener siempre en este dispositivo'."
    $pendientes.Add("Agregar el acceso directo de SharePoint 'Data BI - Datos' a OneDrive.")
}
New-Item -ItemType Directory -Force $destino | Out-Null
Escribir-Env $cfg
Bien "Configuración guardada en $envFile"
$cfg = $null; $clave = $null; $secreto = $null

# ======================================================== 5) Programa del ERP
Titulo "[5/8] Programa que baja las tablas del ERP"
$robot = $null
if ($Simular) {
    $robot = Join-Path $CarpetaSimulacion "automatizacion"
    New-Item -ItemType Directory -Force $robot | Out-Null
    Set-Content (Join-Path $robot "panel.bat") "@echo off" -Encoding ascii
    Set-Content (Join-Path $robot "flexline_flows.py") @(
        "import time",
        "print('§PC§|0|Descargando de Flexline (simulacion) - NO uses el mouse/teclado')",
        "time.sleep(2)",
        "print('LISTO: 7/7 pasos OK (simulacion)')") -Encoding ascii
    Set-Content (Join-Path $robot "pywinauto.py") "" -Encoding ascii
    Sim "Programa del ERP de prueba: $robot (no abre Flexline)."
}
else {
    $anterior = (Leer-Env)["ROBOT_ERP_DIR"]
    $probables = @(Carpetas-RobotProbables)
    if (Es-CarpetaRobot $anterior) { $probables = @($anterior) + @($probables | Where-Object { $_ -ne $anterior }) }
    if ($probables.Count -gt 0) {
        Info "Lo encontré en: $($probables[0])"
        $r = Read-Host "    ¿Es esa la carpeta del programa? (S/N) [S]"
        if ($r -eq "" -or $r -match '^[sS]') { $robot = $probables[0] }
    }
    if (-not $robot) {
        Info "Se abre una ventana para elegir la carpeta 'automatizacion' del programa del ERP"
        Info "(la que tiene panel.bat). Si no aparece, mira detrás de esta ventana."
        Add-Type -AssemblyName System.Windows.Forms
        $ventanaPadre = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "Carpeta 'automatizacion' del programa del ERP (la que tiene panel.bat)"
        $dlg.ShowNewFolderButton = $false
        if ($probables.Count -gt 0) { $dlg.SelectedPath = $probables[0] }
        elseif (Test-Path ([Environment]::GetFolderPath("Desktop"))) { $dlg.SelectedPath = [Environment]::GetFolderPath("Desktop") }
        if ($dlg.ShowDialog($ventanaPadre) -eq [System.Windows.Forms.DialogResult]::OK) { $robot = $dlg.SelectedPath }
        $ventanaPadre.Dispose()
    }
}
if ($robot -and -not (Es-CarpetaRobot $robot)) {
    if (Test-Path (Join-Path $robot "panel.bat")) { Ojo "Esa carpeta tiene panel.bat pero no flexline_flows.py: está incompleta." }
    else { Ojo "Esa carpeta no es la del programa del ERP (no tiene flexline_flows.py)." }
    $robot = $null
}
if ($robot) {
    Escribir-Env ([ordered]@{ ROBOT_ERP_DIR = $robot })
    Bien "Programa del ERP: $robot"
    $pyRobot = Buscar-PythonRobot $robot
    if ($pyRobot) { Bien "Su Python está listo: $pyRobot" }
    else {
        Ojo "El programa no tiene su Python listo en este PC."
        Info "Abre esa carpeta, haz doble clic en instalar.bat y espera a que diga TODO LISTO."
        $pendientes.Add("Correr instalar.bat del programa del ERP.")
    }
    Info "El acceso 'Actualizar plataforma' lo corre sin abrir el panel:"
    Info "  python flexline_flows.py descargar --tablas $TABLAS_ROBOT"
    Info "Baja stock Curifor y Frontera y los 3 seguimientos en unos 9 minutos, y mientras"
    Info "tanto maneja el mouse y el teclado."
}
else {
    Ojo "Sin la carpeta del programa del ERP, el acceso 'Actualizar plataforma' no puede bajar las tablas."
    Info "Lo demás queda instalado: la tarea de las 09:30 calcula con los archivos que haya."
    $pendientes.Add("Elegir la carpeta del programa del ERP (volver a correr el instalador).")
}

# =================================================== 6) Acceso del Escritorio
Titulo "[6/8] Acceso 'Actualizar plataforma' en el Escritorio"
$lnk = Join-Path $escritorio "Actualizar plataforma.lnk"
$shell = New-Object -ComObject WScript.Shell
$acceso = $shell.CreateShortcut($lnk)
$acceso.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$acceso.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scripts\actualizar_plataforma.ps1`""
$acceso.WorkingDirectory = $destino
$acceso.Description = "Baja las tablas del ERP y publica el sugerido de compras"
$acceso.IconLocation = "$env:SystemRoot\System32\shell32.dll,238"
$acceso.Save()
Bien "Acceso creado: $lnk"
Info "Doble clic cuando quieras dejar la plataforma al día (35 a 45 minutos en total)."
if ($Simular) {
    Sim "Prueba del acceso, sin el programa del ERP de verdad (el motor tampoco publica):"
    # No se corre el motor en la simulación: solo se revisa que el acceso arranque
    # y encuentre al programa de prueba. El motor oficial nunca corre acá.
    $pyR = Buscar-PythonRobot $robot
    if ($pyR) {
        Push-Location $robot
        $r = Correr $pyR @("flexline_flows.py", "descargar", "--tablas", $TABLAS_ROBOT)
        Pop-Location
        if ($r.codigo -eq 0) { Sim "El programa de prueba corrió: $(($r.salida -split "`n")[-1])" }
        else { Ojo "El programa de prueba falló: $($r.salida)" }
    }
    else { Ojo "No encontré un Python para el programa de prueba." }
}

# ========================================================= 7) Tareas de Windows
Titulo "[7/8] Tareas de Windows"
$usuario = "$env:USERDOMAIN\$env:USERNAME"
# Las tareas corren el .ps1 a través de sin_ventana.vbs: con powershell directo,
# Windows muestra una ventana un instante (con Windows Terminal, la deja abierta), y
# el agente corre cada minuto: le quitaría el foco al programa del ERP mientras hace
# clics. Si este PC no deja correr VBScript, se usa powershell oculto.
$vbs = Join-Path $scripts "sin_ventana.vbs"
$usarVbs = $false
if (Test-Path $vbs) {
    $pruebaDir = Join-Path $env:TEMP "prueba-sin-ventana-$PID"
    New-Item -ItemType Directory -Force $pruebaDir | Out-Null
    $pruebaPs1 = Join-Path $pruebaDir "prueba.ps1"
    Set-Content $pruebaPs1 "Set-Content -Path `"$pruebaDir\corrio.txt`" -Value si; exit 3" -Encoding ascii
    try {
        $p = Start-Process -FilePath "wscript.exe" -ArgumentList @("//B", "//Nologo", "`"$vbs`"", "`"$pruebaPs1`"") `
             -Wait -PassThru -WindowStyle Hidden
        $usarVbs = ($p.ExitCode -eq 3) -and (Test-Path (Join-Path $pruebaDir "corrio.txt"))
    }
    catch { $usarVbs = $false }
    Remove-Item $pruebaDir -Recurse -Force -ErrorAction SilentlyContinue
}
if ($usarVbs) { Bien "Las tareas van a correr sin abrir ventanas." }
else { Ojo "Este PC no deja correr VBScript: las tareas van con PowerShell oculto (puede asomar una ventana)." }

function Accion($script) {
    $ps1 = Join-Path $scripts $script
    if ($usarVbs) {
        return New-ScheduledTaskAction -Execute "wscript.exe" -Argument "//B //Nologo `"$vbs`" `"$ps1`"" -WorkingDirectory $destino
    }
    return New-ScheduledTaskAction -Execute "powershell.exe" -WorkingDirectory $destino -Argument (
        "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ps1`"")
}
# Como las del PC del dueño: con la sesión de ella iniciada (OneDrive y el programa
# del ERP solo andan con sesión). Sin "-RunLevel Highest": no hace falta administrador.
$principal = New-ScheduledTaskPrincipal -UserId $usuario -LogonType Interactive -RunLevel Limited

# Tope de 2 horas para el motor: una corrida normal son 22 a 35 minutos, pero con
# reintentos y archivos bajando de OneDrive puede pasar de la hora (la del dueño
# tiene 1 hora y Windows la cortaría a mitad de la publicación).
$comun = @{ AllowStartIfOnBatteries = $true; DontStopIfGoingOnBatteries = $true; MultipleInstances = "IgnoreNew" }
if ($Simular) { $comun["Disable"] = $true }

$tDiaria = New-ScheduledTaskTrigger -Daily -At "09:30"
# Sin zona horaria: New-ScheduledTaskTrigger la anota (-03:00 en el horario de
# verano) y Windows la toma como "sincronizar entre zonas horarias": desde abril, con
# -04:00, la tarea correria a las 08:30. La del dueño no tiene zona.
$tDiaria.StartBoundary = (Get-Date "09:30").ToString("yyyy-MM-dd'T'HH:mm:ss")
$sDiaria = New-ScheduledTaskSettingsSet @comun -StartWhenAvailable -WakeToRun -ExecutionTimeLimit (New-TimeSpan -Hours 2)

$tSesion = New-ScheduledTaskTrigger -AtLogOn -User $usuario
$tSesion.Delay = "PT2M"   # que OneDrive alcance a arrancar
$sSesion = New-ScheduledTaskSettingsSet @comun -ExecutionTimeLimit (New-TimeSpan -Hours 2)

# El agente: al iniciar sesión y cada minuto, para siempre. 90 minutos de tope: la
# plataforma espera 75 una corrida del motor.
$tAgente1 = New-ScheduledTaskTrigger -AtLogOn -User $usuario
$tAgente2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
$sAgente = New-ScheduledTaskSettingsSet @comun -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 90)

$tareas = @(
    @{ nombre = $TAREA_DIARIA; script = "tarea_si_no_corrio_hoy.ps1"; disparadores = @($tDiaria); ajustes = $sDiaria
       descripcion = "Calcula y publica el sugerido a las 09:30 si hoy no se hizo con el acceso 'Actualizar plataforma'." },
    @{ nombre = $TAREA_SESION; script = "tarea_al_iniciar_sesion.ps1"; disparadores = @($tSesion); ajustes = $sSesion
       descripcion = "Recupera la corrida diaria del motor si el PC se reinició de madrugada y nadie inició sesión antes de las 09:30." },
    @{ nombre = $TAREA_AGENTE; script = "agente_actualizacion.ps1"; disparadores = @($tAgente1, $tAgente2); ajustes = $sAgente
       descripcion = "Atiende los botones 'Actualizar ahora' y 'Actualizar motor' de la plataforma." }
)
if (-not (Leer-Env)["AGENTE_SECRET"]) {
    Ojo "El agente queda instalado, pero sin su clave no va a atender los botones."
}
$registradas = @()
try {
    foreach ($t in $tareas) {
        $nombre = "$prefijoTarea$($t.nombre)"
        $def = New-ScheduledTask -Action (Accion $t.script) -Trigger $t.disparadores -Settings $t.ajustes `
               -Principal $principal -Description $t.descripcion
        Register-ScheduledTask -TaskName $nombre -InputObject $def -Force | Out-Null
        $registradas += $nombre
        $info = Get-ScheduledTask -TaskName $nombre
        if ($Simular) {
            $xmlDir = Join-Path $CarpetaSimulacion "tareas"
            New-Item -ItemType Directory -Force $xmlDir | Out-Null
            Export-ScheduledTask -TaskName $nombre | Out-File (Join-Path $xmlDir "$($t.nombre).xml") -Encoding utf8
            Sim "Tarea '$nombre' registrada deshabilitada ($($info.State)); definición en $xmlDir"
        }
        else { Bien "Tarea '$nombre' lista." }
    }
}
catch {
    Mal "No se pudo dejar la tarea '$nombre': $($_.Exception.Message)"
    $pendientes.Add("Las tareas de Windows no quedaron (ver arriba). Pide ayuda a quien mantiene el motor.")
}
finally {
    if ($Simular) {
        foreach ($n in $registradas) { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue }
        $quedan = @(Get-ScheduledTask -TaskName "PRUEBA-Sugerido*" -ErrorAction SilentlyContinue)
        if ($quedan.Count -eq 0) { Sim "Tareas de prueba borradas." } else { Ojo "Quedaron tareas de prueba: $($quedan.TaskName -join ', ')" }
    }
}
if (-not $Simular) {
    Info "El dueño tenía las mismas tareas en su PC: el día del cambio de PC titular hay que"
    Info "deshabilitarlas allá (ver docs\instalar-pc-jefa.md)."
}

# =========================================================== 8) Prueba final
Titulo "[8/8] Prueba final (no publica nada)"
$cfgFinal = Leer-Env
$apiFinal = $cfgFinal["PLATAFORMA_API_URL"]
Info "Qué archivo leería el motor de cada tabla, y aviso a la pantalla Fuentes de datos..."
Push-Location (Join-Path $destino "apps\api")
$env:PYTHONIOENCODING = "utf-8"
$probar = Correr $venvPy @("-m", "src.motor.config_fuentes", "--probar", "--reportar") -Mostrar
Pop-Location
if ($probar.codigo -eq 0 -and $probar.salida -match 'Reporte enviado a la plataforma') {
    Bien "La plataforma recibió la prueba: este PC ya aparece en Cargar > Fuentes de datos."
    $listo.Add("Este PC aparece en Fuentes de datos (todavía no es el titular: no publica).")
}
elseif ($probar.codigo -eq 0) {
    Ojo "La prueba corrió, pero no se pudo avisar a la plataforma (revisa la clave de la cuenta del motor)."
    $pendientes.Add("La prueba de Fuentes de datos no llegó a la plataforma.")
}
else {
    Ojo "La prueba de las fuentes falló: $(($probar.salida -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1))"
    $pendientes.Add("La prueba de Fuentes de datos falló (ver arriba).")
}

Info "Conexión del agente con la plataforma..."
if (-not $cfgFinal["AGENTE_SECRET"]) { Ojo "Sin clave del agente: no se prueba." }
else {
    try {
        $r = Invoke-RestMethod -Uri "$apiFinal/api/actualizacion/pendiente?agente=$([uri]::EscapeDataString($env:COMPUTERNAME))" `
             -Headers @{ "X-Agente-Secret" = $cfgFinal["AGENTE_SECRET"] } -Method Get -TimeoutSec 90
        Bien "La plataforma responde y acepta la clave del agente."
        $listo.Add("El agente atiende 'Actualizar ahora' y 'Actualizar motor' (cada minuto, con la sesión iniciada).")
        if ($r.hay) {
            # Preguntar ya la tomó: si no se cierra acá, la tarjeta de la web queda
            # girando hasta que la plataforma la dé por perdida.
            $cuerpo = @{ id = $r.id; ok = $false
                         mensaje = "Este PC se estaba instalando y no pudo atender la solicitud. Vuelve a apretar el botón." } |
                      ConvertTo-Json -Compress
            try {
                Invoke-RestMethod -Uri "$apiFinal/api/actualizacion/terminar" -Headers @{ "X-Agente-Secret" = $cfgFinal["AGENTE_SECRET"] } `
                    -Method Post -ContentType "application/json; charset=utf-8" `
                    -Body ([Text.Encoding]::UTF8.GetBytes($cuerpo)) -TimeoutSec 60 | Out-Null
            } catch { }
            Ojo "Había un pedido pendiente en la web: quedó cerrado; que lo vuelvan a pedir."
        }
    }
    catch {
        if ("$($_.Exception.Message)" -match "403") {
            Mal "La plataforma rechazó la clave del agente."
            $pendientes.Add("La clave del agente no es la del servidor: vuelve a correr el instalador con la correcta.")
        }
        else {
            Ojo "No pude hablar con la plataforma: $($_.Exception.Message)"
            Info "Si el servidor estaba dormido, en un minuto el agente lo intenta solo."
            $pendientes.Add("Confirmar que el agente se conecta (en la web, botón 'Actualizar motor').")
        }
    }
}
$cfgFinal = $null

# ================================================================== Resumen
Write-Host "`n============================================================" -ForegroundColor Green
Write-Host " Resumen" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "Quedó listo:" -ForegroundColor Green
Write-Host "  - El motor en $destino (Python $($python.version))."
Write-Host "  - El acceso 'Actualizar plataforma' en el Escritorio."
Write-Host "  - Las tareas: el sugerido a las 09:30 si no se hizo antes, el rescate al iniciar"
Write-Host "    sesión si el PC se reinició de madrugada, y el agente de los botones."
foreach ($l in $listo) { Write-Host "  - $l" }
if ($pendientes.Count -gt 0) {
    Write-Host "`nFalta:" -ForegroundColor Yellow
    $i = 1
    foreach ($p in ($pendientes | Select-Object -Unique)) { Write-Host "  $i. $p" -ForegroundColor Yellow; $i++ }
}
Write-Host "`nQué hacer ahora:" -ForegroundColor Cyan
Write-Host "  1. Pídele a un admin que, en la plataforma (Cargar > Fuentes de datos), deje este PC"
Write-Host "     como titular. Hasta entonces este PC calcula pero no publica."
Write-Host "  2. El mismo día, en el PC anterior, hay que deshabilitar sus tareas del motor."
Write-Host "  3. Ese día, haz doble clic en 'Actualizar plataforma' y revisa que termine en LISTO."
Write-Host "`nEste PC tiene que quedar prendido y con tu sesión iniciada en los días de trabajo."
Write-Host "Registros: $destino\logs"
Salir 0
