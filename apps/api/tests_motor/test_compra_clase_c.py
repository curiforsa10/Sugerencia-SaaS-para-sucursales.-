"""En las sucursales compra tambien la clase C; en el CD sigue la agregada A/B.

Desde ago-2026 el CD solo consolida la demanda de las sucursales donde el
producto es D. Una C local no la compraba nadie: la sucursal no (solo A/B) y el
CD tampoco (no sumaba su venta). Abastecimiento pidio el 05-11-2026 que la C de
sucursal compre con la misma regla que A y B.
"""
from datetime import date

import polars as pl

from src.motor import parametros as P
from src.motor.sugerido import calcular_sugerido

HOY = date(2026, 11, 5)


def _sugerido(filas):
    """(producto, sucursal, clase local, clase agregada); misma demanda para todas."""
    safety = pl.DataFrame(
        [{"producto_master": p, "sucursal_final": s, "clasificacion_abc": c,
          "clasificacion_abc_agregada": a, "abastece_cd": "No", "lt_efectivo": 3.0,
          "stock_seguridad": 1.0} for p, s, c, a in filas]
    )
    demanda = safety.select("producto_master", "sucursal_final").with_columns(
        pl.lit(0.5).alias("demanda_diaria")
    )
    vacio_stock = pl.DataFrame(schema={"Producto": pl.Utf8, "SucursalID": pl.Utf8, "Stock": pl.Float64})
    seg = pl.DataFrame(schema={"Producto": pl.Utf8, "SucursalID": pl.Utf8, "Cantidad": pl.Float64,
                               "EstadoOC": pl.Utf8, "EstadoDoc": pl.Utf8, "Origen": pl.Utf8,
                               "Motivo": pl.Utf8, "FechaOC": pl.Date, "FechaDoc": pl.Date})
    mapeo = pl.DataFrame(schema={"Producto": pl.Utf8, "Producto_Master": pl.Utf8})
    r = calcular_sugerido(safety, demanda, vacio_stock, vacio_stock, seg, mapeo, HOY)
    return {(f["producto_master"], f["sucursal_final"]): f["sugerido"] for f in r.to_dicts()}


def test_la_clase_c_de_sucursal_compra_igual_que_la_a():
    s = _sugerido([("P1", "TALCA", "A", "A"), ("P2", "TALCA", "C", "B"), ("P3", "TALCA", "C", "C")])
    assert s[("P2", "TALCA")] == s[("P1", "TALCA")] > 0
    assert s[("P3", "TALCA")] == s[("P1", "TALCA")]


def test_la_clase_d_de_sucursal_sigue_sin_comprar():
    assert _sugerido([("P1", "TALCA", "D", "A")])[("P1", "TALCA")] == 0


def test_el_cd_sigue_mirando_la_agregada_a_b():
    s = _sugerido([("P1", P.CD_ID, "C", "C"), ("P2", P.CD_ID, "D", "B")])
    assert s[("P1", P.CD_ID)] == 0
    assert s[("P2", P.CD_ID)] > 0
