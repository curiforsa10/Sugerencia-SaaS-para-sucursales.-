"""El motor manda la ultima recepcion de cada producto en cada sucursal.

La muestra el requerimiento de sucursal (Abastecimiento, 24-11-2026): si el repuesto
llego en los ultimos 12 meses a esa sucursal o a otra parte de la empresa.
"""
import csv
from datetime import date, timedelta
from pathlib import Path

import polars as pl

from src.jobs import correr_motor_real as job
from src.motor import lectores_excel as lx

HOY = date(2026, 11, 24)


def _df(filas, col_suc="Sucursal"):
    return pl.DataFrame(
        [{"Producto": p, col_suc: s, "FechaPE": f} for p, s, f in filas],
        schema={"Producto": pl.Utf8, col_suc: pl.Utf8, "FechaPE": pl.Date},
    )


def _correr(monkeypatch, tmp_path, nacional, importado=None, frontera=None):
    monkeypatch.setattr(job, "SALIDA_RECEPCIONES", tmp_path / "recepciones.csv")
    datos = {"seguimiento_curifor_nacional": nacional,
             "seguimiento_curifor_importado": importado,
             "seguimiento_frontera": frontera}
    monkeypatch.setattr(job, "_buscar",
                        lambda fuente, obligatorio=True: Path(fuente) if datos.get(fuente) is not None else None)
    monkeypatch.setattr(lx, "leer_seguimiento_nacional_excel", lambda r: datos[str(r)])
    monkeypatch.setattr(lx, "leer_seguimiento_importado_excel", lambda r: datos[str(r)])
    monkeypatch.setattr(lx, "leer_seguimiento_frontera_excel", lambda r: datos[str(r)])
    ruta = job._guardar_recepciones(hoy=HOY)
    if ruta is None:
        return []
    with open(ruta, encoding="utf-8", newline="") as f:
        return [(r["producto"], r["sucursal_id"], r["fecha"]) for r in csv.DictReader(f)]


def _d(n):
    return HOY - timedelta(days=n)


def test_la_mas_reciente_por_producto_y_sucursal(monkeypatch, tmp_path):
    filas = _correr(monkeypatch, tmp_path, _df([
        (" 61 FL500S ", "SUC070", _d(40)),
        ("61 FL500S", "SUC070", _d(26)),
        ("61 FL500S", "SUC050", _d(5)),
    ]))
    assert filas == [("61 FL500S", "CURICO", _d(5).isoformat()),
                     ("61 FL500S", "LINDEROS", _d(26).isoformat())]


def test_solo_los_ultimos_12_meses_y_con_fecha(monkeypatch, tmp_path):
    filas = _correr(monkeypatch, tmp_path, _df([
        ("19 VIEJO", "SUC070", _d(400)),
        ("19 SIN FECHA", "SUC070", None),
        ("19 NUEVO", "SUC070", _d(364)),
    ]))
    assert [f[0] for f in filas] == ["19 NUEVO"]


def test_suman_los_tres_seguimientos_y_el_importado_va_sin_sucursal(monkeypatch, tmp_path):
    filas = _correr(
        monkeypatch, tmp_path,
        nacional=_df([("19 A", "SUC070", _d(10))]),
        importado=_df([("19 A", None, _d(3))]),
        frontera=_df([("70 B", "BRASIL 18", _d(7))], col_suc="NombreLocal"),
    )
    assert sorted(filas) == [("19 A", "DESCONOCIDO", _d(3).isoformat()),
                             ("19 A", "LINDEROS", _d(10).isoformat()),
                             ("70 B", "BRASIL 18", _d(7).isoformat())]


def test_sin_seguimientos_no_escribe_nada(monkeypatch, tmp_path):
    assert _correr(monkeypatch, tmp_path, None) == []
