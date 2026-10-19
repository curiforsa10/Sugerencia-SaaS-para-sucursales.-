"""El instalador del PC nuevo (`scripts/instalar_pc_jefa.ps1`), con `-Simular`.

Corre el script de verdad con el PowerShell de Windows en una carpeta temporal: no
instala programas, no pide claves y no llama a la plataforma (apunta a un puerto de
127.0.0.1 donde no hay nada). El motor se clona desde un "GitHub" armado en la carpeta
del test (un repositorio bare) con lo minimo: robot_erp.ps1, requirements-motor.txt y
un config_fuentes.py falso que anota que lo llamaron. Las librerias del motor son
paquetes vacios con su nombre, y pip no puede salir a internet (PIP_NO_INDEX).

Las corridas completas registran las tres tareas de Windows con el prefijo "PRUEBA-",
deshabilitadas, y el mismo instalador las borra al terminar (como en -Simular a mano).

Lo que cuida:
- Una copia del motor que quedo a medias (se corto la descarga) se aparta y se baja
  de nuevo, sin perder el .env; el codigo se baja en una carpeta al lado y recien al
  final se renombra; git queda con los certificados de Windows (schannel).
- Un entorno de Python sin pip se repara.
- Si no se puede instalar Python, se usa el portable del programa del ERP.
- La configuracion de Fuentes de datos queda guardada al final.
- El resumen dice solo lo que de verdad quedo.
- El programa del ERP se saca de OneDrive (su .env tiene las claves del ERP).
"""
import os
import pathlib
import re
import shutil
import socket
import subprocess
import sys
import zipfile

import pytest

SCRIPTS = pathlib.Path(__file__).resolve().parents[3] / "scripts"
POWERSHELL = shutil.which("powershell")
GIT = shutil.which("git")

pytestmark = pytest.mark.skipif(POWERSHELL is None or GIT is None,
                                reason="necesita el PowerShell de Windows y git")

_ENTORNO_GIT = {
    "GIT_AUTHOR_NAME": "Prueba", "GIT_AUTHOR_EMAIL": "prueba@ejemplo.cl",
    "GIT_COMMITTER_NAME": "Prueba", "GIT_COMMITTER_EMAIL": "prueba@ejemplo.cl",
    # Sin la configuracion del PC: el schannel que se revisa es el que deja el instalador.
    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
}

# El config_fuentes del motor, falso: `--probar --reportar` dice que aviso a la
# plataforma, y `--guardar-config` anota que lo llamaron y falla si se le pide.
_CONFIG_FUENTES_FALSO = """\
import os, pathlib, sys
if "--guardar-config" in sys.argv:
    pathlib.Path(os.environ["INSTALADOR_CONFIG_ANOTA"]).write_text("guardar-config")
    if os.environ.get("INSTALADOR_CONFIG_FALLA"):
        print("Este PC no tiene configuracion de fuentes (ni de la plataforma ni guardada).")
        sys.exit(1)
    print("Configuracion de fuentes en este PC (plataforma): modo prueba, titular PC anterior.")
    sys.exit(0)
print("Reporte enviado a la plataforma (tipo probar).")
"""

# Un pip falso que contesta --version e "instala" sin hacer nada.
_PIP_FALSO = """\
import sys
if "--version" in sys.argv:
    print("pip 99.0 (falso)")
sys.exit(0)
"""

_LIBRERIAS = ("polars", "fastexcel", "openpyxl", "httpx", "truststore")


def _git(cwd, *args) -> str:
    r = subprocess.run([GIT, *args], cwd=cwd, capture_output=True, text=True,
                       env={**os.environ, **_ENTORNO_GIT}, timeout=120)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


def _venv(destino: pathlib.Path):
    subprocess.run([sys.executable, "-m", "venv", "--without-pip", str(destino)], check=True, timeout=120)
    for nombre in _LIBRERIAS:
        (destino / "Lib" / "site-packages" / nombre).mkdir(parents=True)
        (destino / "Lib" / "site-packages" / nombre / "__init__.py").write_text("")


def _rueda(carpeta: pathlib.Path, nombre: str):
    """Una rueda vacia con el nombre de una libreria del motor: con PIP_NO_INDEX y
    PIP_FIND_LINKS apuntando aca, un pip de verdad "instala" las librerias sin internet."""
    info = f"{nombre}-0.0.1.dist-info"
    archivos = {
        f"{nombre}/__init__.py": "",
        f"{info}/METADATA": f"Metadata-Version: 2.1\nName: {nombre}\nVersion: 0.0.1\n",
        f"{info}/WHEEL": "Wheel-Version: 1.0\nGenerator: prueba\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
    }
    archivos[f"{info}/RECORD"] = "".join(f"{a},,\n" for a in archivos) + f"{info}/RECORD,,\n"
    with zipfile.ZipFile(carpeta / f"{nombre}-0.0.1-py3-none-any.whl", "w") as z:
        for ruta, texto in archivos.items():
            z.writestr(ruta, texto)


@pytest.fixture(scope="module")
def origen(tmp_path_factory):
    """El "GitHub" del motor (rama principal, y otra sin requirements-motor.txt para que
    el instalador frene apenas termina el paso 2) y dos entornos de Python: uno sin pip
    y otro con el pip falso. Se arma una vez."""
    base = tmp_path_factory.mktemp("origen-instalador")
    github, publica = base / "github.git", base / "publica"
    _git(base, "init", "-q", "--bare", "-b", "principal", str(github))
    _git(base, "clone", "-q", str(github), str(publica))
    _git(publica, "checkout", "-q", "-b", "principal")
    (publica / "scripts").mkdir()
    shutil.copy2(SCRIPTS / "robot_erp.ps1", publica / "scripts" / "robot_erp.ps1")
    api = publica / "apps" / "api"
    (api / "src" / "motor").mkdir(parents=True)
    (api / "requirements-motor.txt").write_text("".join(f"{n}\n" for n in _LIBRERIAS))
    (api / "src" / "__init__.py").write_text("")
    (api / "src" / "motor" / "__init__.py").write_text("")
    (api / "src" / "motor" / "config_fuentes.py").write_text(_CONFIG_FUENTES_FALSO)
    (publica / ".gitignore").write_text("logs/\n.env\napps/api/.venv/\napps/api/data/\n")
    _git(publica, "add", ".")
    _git(publica, "commit", "-q", "-m", "motor")
    _git(publica, "push", "-q", "-u", "origin", "principal")
    _git(publica, "checkout", "-q", "-b", "sin-requisitos")
    _git(publica, "rm", "-q", "apps/api/requirements-motor.txt")
    _git(publica, "commit", "-q", "-m", "sin requirements")
    _git(publica, "push", "-q", "-u", "origin", "sin-requisitos")

    (base / "ruedas").mkdir()
    for nombre in _LIBRERIAS:
        _rueda(base / "ruedas", nombre)

    _venv(base / "venv-sin-pip")
    shutil.copytree(base / "venv-sin-pip", base / "venv-pip-falso")
    pip = base / "venv-pip-falso" / "Lib" / "site-packages" / "pip"
    pip.mkdir()
    (pip / "__init__.py").write_text("")
    (pip / "__main__.py").write_text(_PIP_FALSO)
    return base


def _puerto_cerrado() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    puerto = s.getsockname()[1]
    s.close()
    return puerto


def _entorno(tmp_path, origen, **extra) -> dict:
    return {**os.environ, **_ENTORNO_GIT, "PIP_NO_INDEX": "1", "PIP_FIND_LINKS": str(origen / "ruedas"),
            "INSTALADOR_CONFIG_ANOTA": str(tmp_path / "config_fuentes_llamado.txt"), **extra}


def _sin_python(tmp_path, origen, **extra) -> dict:
    """Un PC donde no hay Python y winget no puede instalarlo: ni en el PATH, ni en
    las carpetas de siempre."""
    vacia = tmp_path / "sin-python"
    vacia.mkdir()
    windows = os.environ["SystemRoot"]
    # El git de la carpeta cmd: el de mingw64\bin, solo en el PATH, se cae al clonar.
    git = pathlib.Path(GIT)
    git_cmd = next((str(p / "cmd") for p in git.parents if (p / "cmd" / "git.exe").exists()), str(git.parent))
    return _entorno(tmp_path, origen, LOCALAPPDATA=str(vacia), ProgramFiles=str(vacia),
                    PATH=os.pathsep.join([git_cmd, windows + "\\System32",
                                          windows + "\\System32\\WindowsPowerShell\\v1.0", windows]),
                    **extra)


def _instalar(sim, origen, *args, rama="principal", entorno) -> subprocess.CompletedProcess:
    return subprocess.run(
        [POWERSHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
         "-File", str(SCRIPTS / "instalar_pc_jefa.ps1"), "-Simular", "-CarpetaSimulacion", str(sim),
         "-Origen", str(origen / "github.git"), "-Rama", rama,
         "-ApiUrl", f"http://127.0.0.1:{_puerto_cerrado()}", *args],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=900, env=entorno)


def _destino(sim) -> pathlib.Path:
    return sim / "perfil" / "dev" / "Sugerencia-SaaS-para-sucursales"


def _clonado(tmp_path, origen, venv: str) -> pathlib.Path:
    """Un PC donde el motor ya se habia instalado (se vuelve a correr el instalador)."""
    sim = tmp_path / "sim"
    destino = _destino(sim)
    _git(tmp_path, "clone", "-q", "-b", "principal", str(origen / "github.git"), str(destino))
    shutil.copytree(origen / venv, destino / "apps" / "api" / ".venv")
    return sim


def _resumen(salida: str) -> tuple[list[str], list[str]]:
    """Las lineas de "Quedó listo" y las de "Falta" del resumen final."""
    resumen = salida.split(" Resumen", 1)[1]
    listo = resumen.split("Quedó listo:", 1)[1].split("Falta:", 1)[0].split("Qué hacer ahora:", 1)[0]
    falta = resumen.split("Falta:", 1)[1].split("Qué hacer ahora:", 1)[0] if "Falta:" in resumen else ""
    limpiar = lambda texto: [l.strip() for l in texto.splitlines() if l.strip()]
    return limpiar(listo), limpiar(falta)


# --- Paso 2: el codigo ------------------------------------------------------------


def test_una_copia_cortada_a_mitad_se_aparta_y_se_baja_de_nuevo(tmp_path, origen):
    """Se cerro la ventana mientras decia "Bajando el código": quedo un .git sin la
    version. Antes el instalador decia "Ya está", despues "hay archivos cambiados a
    mano" (git status respondio 'bad object HEAD') y se caia con un error rojo al
    cargar robot_erp.ps1, en cada reintento."""
    sim = tmp_path / "sim"
    destino = _destino(sim)
    _git(tmp_path, "init", "-q", "-b", "principal", str(destino))
    (destino / ".git" / "refs" / "heads" / "principal").write_text("0123456789abcdef0123456789abcdef01234567\n")
    (destino / "README.md").write_text("a medias\n")
    (destino / ".env").write_bytes(b"PLATAFORMA_EMAIL=motor@ejemplo.cl\n")

    r = _instalar(sim, origen, rama="sin-requisitos", entorno=_entorno(tmp_path, origen))

    assert "no sirve (no tiene una versión completa)" in r.stdout, r.stdout + r.stderr
    assert "cambiados a mano" not in r.stdout
    # Paso el paso 2 y frena en el 3 porque esa rama de prueba no trae requirements.
    assert "no trae requirements-motor.txt" in r.stdout
    assert _git(destino, "rev-parse", "--abbrev-ref", "HEAD") == "sin-requisitos"
    assert (destino / "scripts" / "robot_erp.ps1").exists()
    apartadas = list(destino.parent.glob("Sugerencia-SaaS-para-sucursales-danada-*"))
    assert len(apartadas) == 1 and (apartadas[0] / "README.md").exists()
    assert (destino / ".env").read_text() == "PLATAFORMA_EMAIL=motor@ejemplo.cl\n", "no se pierden las claves"
    assert not list(destino.parent.glob("*.bajando")), "la carpeta temporal del clon se renombra"
    assert _git(destino, "config", "--local", "http.sslBackend") == "schannel"


def _python_portable(carpeta: pathlib.Path):
    """Un python\\python.exe como el del kit del programa del ERP: el lanzador de un
    entorno, puesto al lado de su pyvenv.cfg. Trae venv y ensurepip."""
    subprocess.run([sys.executable, "-m", "venv", "--without-pip", str(carpeta)], check=True, timeout=120)
    shutil.copy2(carpeta / "Scripts" / "python.exe", carpeta / "python.exe")


def test_si_no_se_puede_instalar_python_usa_el_del_programa_del_erp(tmp_path, origen):
    """En un PC que bloquea instaladores winget no puede instalar Python, pero el kit
    del programa del ERP trae uno portable que sirve. Antes el instalador frenaba con
    "No hay Python en este PC"."""
    sim = tmp_path / "sim"
    kit = sim / "perfil" / "Escritorio" / "INSTALAR_EN_PC_JEFA" / "automatizacion"
    _python_portable(kit / "python")
    r = _instalar(sim, origen, rama="sin-requisitos", entorno=_sin_python(tmp_path, origen))

    assert "No hay Python en este PC" not in r.stdout, r.stdout + r.stderr
    assert "se usa el que trae el programa del ERP" in r.stdout
    assert f"Python 3.{sys.version_info.minor}: {kit / 'python' / 'python.exe'}" in r.stdout
    assert "Código listo (rama sin-requisitos" in r.stdout


# --- Corridas completas -----------------------------------------------------------


def test_un_entorno_sin_pip_se_repara_y_la_configuracion_queda_guardada(tmp_path, origen):
    """`python -m venv` tarda unos 15 s porque instala pip: si se cerraba la ventana en
    ese rato, cada reintento frenaba con "Casi siempre es la conexión ... No module named
    pip". Y al final, la configuracion de Fuentes de datos queda guardada: sin ella, si la
    plataforma no respondia en su primera corrida, el PC nuevo se creia titular."""
    sim = _clonado(tmp_path, origen, "venv-sin-pip")
    destino = _destino(sim)

    r = _instalar(sim, origen, entorno=_entorno(tmp_path, origen))

    assert r.returncode == 0, r.stdout[-4000:] + r.stderr[-2000:]
    assert "le falta pip" in r.stdout
    assert "No module named pip" not in r.stdout
    pip = subprocess.run([destino / "apps" / "api" / ".venv" / "Scripts" / "python.exe", "-m", "pip", "--version"],
                         capture_output=True, text=True)
    assert pip.returncode == 0, pip.stderr
    assert (tmp_path / "config_fuentes_llamado.txt").read_text() == "guardar-config"
    assert "Configuración de Fuentes de datos guardada en este PC" in r.stdout
    # Una copia que ya estaba (la clonó otro instalador) queda igual con schannel.
    assert _git(destino, "config", "--local", "http.sslBackend") == "schannel"


def test_el_resumen_dice_solo_lo_que_quedo(tmp_path, origen):
    """Sin programa del ERP el acceso del Escritorio no puede bajar las tablas: no va en
    "Quedó listo". Y si la configuracion de Fuentes de datos no se pudo traer, va en
    "Falta"."""
    sim = _clonado(tmp_path, origen, "venv-pip-falso")

    r = _instalar(sim, origen, "-SimularSinRobot",
                  entorno=_entorno(tmp_path, origen, INSTALADOR_CONFIG_FALLA="1"))

    assert r.returncode == 0, r.stdout[-4000:] + r.stderr[-2000:]
    listo, falta = _resumen(r.stdout)
    assert not any("Actualizar plataforma" in l for l in listo), listo
    assert any(l.startswith("- El motor en ") for l in listo), listo
    assert any(l.startswith("- Las tareas:") for l in listo), listo
    assert any("Elegir la carpeta del programa del ERP" in l for l in falta), falta
    assert any("guarde la configuración de Fuentes de datos" in l for l in falta), falta


def test_el_programa_del_erp_se_saca_de_onedrive(tmp_path, origen):
    """El kit queda en el Escritorio y OneDrive suele respaldar el Escritorio: el .env
    del programa, con las claves del ERP, y sus registros se subian a la nube."""
    sim = _clonado(tmp_path, origen, "venv-pip-falso")
    kit = sim / "perfil" / "OneDrive - Curifor S.A" / "Escritorio" / "INSTALAR_EN_PC_JEFA"
    fuera = sim / "perfil" / "automatizacion"

    r = _instalar(sim, origen, "-SimularRobotEnOneDrive", entorno=_entorno(tmp_path, origen))

    assert r.returncode == 0, r.stdout[-4000:] + r.stderr[-2000:]
    assert "El programa del ERP está dentro de OneDrive" in r.stdout
    assert (fuera / "flexline_flows.py").exists()
    assert (fuera / ".env").read_text().strip() == "CLAVE_DE_PRUEBA=ficticia"
    assert not (kit / "automatizacion").exists()
    assert not (kit / "automatizacion.zip").exists()
    env = (_destino(sim) / ".env").read_text(encoding="utf-8")
    assert re.search(rf"(?m)^ROBOT_ERP_DIR={re.escape(str(fuera))}$", env), env
    assert "se arma de nuevo su entorno" not in r.stdout, "el motor no usaba ese Python"


def test_si_el_motor_usaba_el_python_del_kit_en_onedrive_queda_con_el_de_la_copia(tmp_path, origen):
    """Las dos cosas juntas, que es lo probable en el PC de ella si bloquea instaladores
    y OneDrive respalda el Escritorio: el entorno del motor se arma con el Python del kit,
    y despues esa carpeta se borra de OneDrive. Sin rearmarlo, el motor quedaba sin
    Python."""
    sim = tmp_path / "sim"
    kit = sim / "perfil" / "OneDrive - Curifor S.A" / "Escritorio" / "INSTALAR_EN_PC_JEFA" / "automatizacion"
    fuera = sim / "perfil" / "automatizacion"
    _python_portable(kit / "python")

    r = _instalar(sim, origen, "-SimularRobotEnOneDrive", entorno=_sin_python(tmp_path, origen))

    assert r.returncode == 0, r.stdout[-4000:] + r.stderr[-2000:]
    assert "se usa el que trae el programa del ERP" in r.stdout
    assert "se arma de nuevo su entorno con el de la copia" in r.stdout
    assert not kit.exists()
    cfg = (_destino(sim) / "apps" / "api" / ".venv" / "pyvenv.cfg").read_text(encoding="utf-8")
    assert str(kit) not in cfg, cfg
    venv_py = _destino(sim) / "apps" / "api" / ".venv" / "Scripts" / "python.exe"
    prueba = subprocess.run([venv_py, "-c", "import polars, fastexcel, openpyxl, httpx, truststore; print('ok')"],
                            capture_output=True, text=True)
    assert prueba.stdout.strip() == "ok", prueba.stderr
    assert (fuera / "python" / "python.exe").exists()
