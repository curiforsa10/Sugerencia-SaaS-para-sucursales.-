"""Excepcion de transito por proveedor: Gildemeister cuenta 5 dias habiles.

Una OC nacional pendiente cuenta como transito hasta 30 dias corridos. Las de
Automotores Gildemeister (79649140-K) cuentan solo 5 dias habiles, de lunes a
viernes y sin descontar feriados. Los demas proveedores siguen igual.
"""
from datetime import date

import polars as pl

from src.jobs.correr_motor_real import dias_habiles
from src.motor.sugerido import _stock_transito

GILDEMEISTER = "79649140-K"
OTRO = "76123456-7"
HOY = date(2026, 11, 2)  # lunes


def _seg(*filas):
    """(rut, fecha OC, cantidad), con producto distinto por fila."""
    return pl.DataFrame(
        [
            {"Producto": f"P{i}", "SucursalID": "CURICO", "Cantidad": float(c),
             "EstadoOC": "Pendiente", "EstadoDoc": "", "Origen": "Curifor Nacional",
             "Motivo": "reposicion", "FechaOC": f, "FechaDoc": None, "RutProveedor": r}
            for i, (r, f, c) in enumerate(filas)
        ],
        schema={"Producto": pl.Utf8, "SucursalID": pl.Utf8, "Cantidad": pl.Float64,
                "EstadoOC": pl.Utf8, "EstadoDoc": pl.Utf8, "Origen": pl.Utf8,
                "Motivo": pl.Utf8, "FechaOC": pl.Date, "FechaDoc": pl.Date,
                "RutProveedor": pl.Utf8},
    )


def _productos(seg, hoy=HOY):
    return set(_stock_transito(seg, hoy).get_column("producto_master").to_list())


def test_gildemeister_cuenta_hasta_el_quinto_dia_habil():
    seg = _seg((GILDEMEISTER, date(2026, 10, 26), 1),  # lunes: 5 habiles
               (GILDEMEISTER, date(2026, 10, 23), 1))  # viernes: 6 habiles
    assert _productos(seg) == {"P0"}


def test_el_fin_de_semana_no_consume_dias():
    seg = _seg((GILDEMEISTER, date(2026, 10, 30), 1))  # viernes -> martes: 2 habiles
    assert _productos(seg, date(2026, 11, 3)) == {"P0"}


def test_una_oc_del_sabado_cuenta_igual_que_dias_habiles_del_job():
    sabado = date(2026, 10, 24)
    assert dias_habiles(sabado, HOY) == 6
    assert _productos(_seg((GILDEMEISTER, sabado, 1))) == set()
    assert _productos(_seg((GILDEMEISTER, sabado, 1)), date(2026, 10, 30)) == {"P0"}


def test_los_demas_proveedores_siguen_con_30_dias_corridos():
    seg = _seg((OTRO, date(2026, 10, 3), 1),   # 30 dias
               (OTRO, date(2026, 10, 2), 1),   # 31 dias
               (None, date(2026, 10, 3), 1))   # sin RUT
    assert _productos(seg) == {"P0", "P2"}


def test_el_rut_se_reconoce_con_puntos_minuscula_y_espacios():
    seg = _seg((" 79.649.140-k ", date(2026, 10, 23), 1))
    assert _productos(seg) == set()


def test_la_ventana_general_tambien_manda_sobre_el_proveedor(monkeypatch):
    monkeypatch.setattr("src.motor.parametros.TRANSITO_VENTANA_NACIONAL_DIAS", 3)
    seg = _seg((GILDEMEISTER, date(2026, 10, 28), 1))  # 5 dias corridos, 3 habiles
    assert _productos(seg) == set()


def test_sin_la_columna_del_rut_no_cambia_nada():
    seg = _seg((GILDEMEISTER, date(2026, 10, 23), 1)).drop("RutProveedor")
    assert _productos(seg) == {"P0"}


def test_importado_no_lleva_la_excepcion():
    seg = _seg((GILDEMEISTER, date(2026, 10, 23), 1)).with_columns(
        pl.lit("Curifor Importado").alias("Origen")
    )
    assert _productos(seg) == {"P0"}
