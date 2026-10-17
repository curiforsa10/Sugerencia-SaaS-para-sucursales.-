"""Lo que leen de la salida del motor los scripts que lo corren sin nadie mirando:
`scripts/agente_actualizacion.ps1` (el boton "Actualizar ahora") y
`scripts/tarea_vigentes_ford.ps1`. Las dos funciones viven en
`scripts/salida_motor.ps1` y se prueban con el PowerShell de Windows, el mismo que
usan las tareas programadas.

El caso que cuidan: en un PC que no es el titular, el motor no calcula ni publica y
sale con 0 a proposito. El agente tomaba ese 0 como "OK" y la tarjeta de la web
quedaba en verde sin que se hubiera publicado nada.
"""
import json
import pathlib
import shutil
import subprocess

import pytest

SCRIPTS = pathlib.Path(__file__).resolve().parents[3] / "scripts"
POWERSHELL = shutil.which("powershell")

pytestmark = pytest.mark.skipif(POWERSHELL is None, reason="necesita el PowerShell de Windows")

NO_TITULAR = [
    "Crudos: C:\\datos\\Bases de datos",
    "  fuentes de datos: se lee con el .env de este PC (configuracion de la plataforma, modo prueba).",
    "NO SE PUBLICA: este PC no es el titular (PC de la jefa)",
]
PUBLICO = [
    "Crudos: C:\\datos\\Bases de datos",
    "CSV generado: C:\\datos\\sugerido_motor.csv",
    "CARGA OFICIAL: 17102 filas.",
]


def _llamar(tmp_path, funcion, lineas):
    """Lo que devuelve `funcion` con esa salida del motor, como texto ('<nulo>' si
    devuelve $null). Corre con $ErrorActionPreference = "Stop", como el agente."""
    entrada = tmp_path / "salida.json"
    entrada.write_text(json.dumps(lineas), encoding="utf-8")
    comando = (
        "$ErrorActionPreference = 'Stop'; "
        f". '{SCRIPTS / 'salida_motor.ps1'}'; "
        f"$salida = Get-Content -Raw -Encoding UTF8 '{entrada}' | ConvertFrom-Json; "
        f"$r = {funcion} $salida; "
        "if ($null -eq $r) { '<nulo>' } else { $r }"
    )
    r = subprocess.run([POWERSHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                        "-Command", comando], capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


def test_un_pc_que_no_es_el_titular_se_reconoce(tmp_path):
    assert _llamar(tmp_path, "Titular-SiNoPublico", NO_TITULAR) == "PC de la jefa"
    assert _llamar(tmp_path, "Titular-SiNoPublico", PUBLICO) == "<nulo>"


def test_las_filas_sin_la_linea_de_carga_no_revientan(tmp_path):
    """Antes: `.Matches.Groups[1]` sobre un resultado nulo, que con "Stop" lanzaba
    "No se puede indizar en una matriz nula" y ese texto llegaba a la tarjeta."""
    assert _llamar(tmp_path, "Filas-Publicadas", PUBLICO) == "17102"
    assert _llamar(tmp_path, "Filas-Publicadas", NO_TITULAR) == "<nulo>"


def test_los_dos_scripts_miran_si_el_pc_es_el_titular():
    for nombre in ("agente_actualizacion.ps1", "tarea_vigentes_ford.ps1"):
        texto = (SCRIPTS / nombre).read_text(encoding="utf-8-sig")
        assert '. "$PSScriptRoot\\salida_motor.ps1"' in texto, nombre
        assert "Titular-SiNoPublico" in texto, nombre
    agente = (SCRIPTS / "agente_actualizacion.ps1").read_text(encoding="utf-8")
    assert ".Matches.Groups[1]" not in agente
