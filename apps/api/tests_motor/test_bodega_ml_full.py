"""Bodega ML-FULL (centro Full de Mercado Libre) independiente del CD.

Abastecimiento, 27-11-2026: el CD no debe ver esta bodega. Tiene su propio stock
y su venta es la que Mercado Libre liquida (LIQ FACT-REPUESTOS y su NC LIQ FACT,
venta ML, en la 430 Canal Digital; antes de enero de 2026 en Oficinas Centrales).
Se abastece siempre por traslado desde el CD, que compra por ella.
"""
from datetime import date

import polars as pl

from src.motor import clasificacion_abc, fuentes_reales, lead_time, parametros as P
from src.motor.conectores import sql_flexline as F

FIN = date(2026, 7, 1)
ML = P.SUCURSAL_ML_FULL


def _crudo(filas):
    """filas: (producto, sucursal, tipo_venta, documento, cantidad)."""
    return pl.DataFrame(
        {
            "Producto": [f[0] for f in filas],
            "SUCURSAL": [f[1] for f in filas],
            "Tipo-Venta": [f[2] for f in filas],
            "Fecha": [date(2026, 6, 1)] * len(filas),
            "Cantidad": [f[4] for f in filas],
            "tipoDocto": [f[3] for f in filas],
            "tipoproducto": ["REPUESTOS"] * len(filas),
        }
    )


def test_la_liquidacion_de_mercado_libre_va_a_ml_full():
    out = F.normalizar_ventas_curifor(_crudo([
        ("A", "CANAL DIGITAL", "VTA ML", "LIQ FACT-REPUESTOS", 5),
        ("A", "CANAL DIGITAL", "VTA ML", "NC LIQ FACT", 2),
        ("A", "OFICINAS CENTRALES", "VTA ML", "LIQ FACT-REPUESTOS", 3),
        # Lo demas del canal sigue en el CD.
        ("A", "CANAL DIGITAL", "VTA ML", "FA-ELECTR REPTO", 4),
        ("A", "CANAL DIGITAL", "VTA SHOPIFY", "FA-ELECTR REPTO", 1),
        # Una liquidacion fuera del canal o sin venta ML no es de ML-FULL.
        ("A", "DIEZ DE JULIO (2)", "VTA ML", "LIQ FACT-REPUESTOS", 6),
        ("A", "OFICINAS CENTRALES", "VTA MESON", "LIQ FACT-REPUESTOS", 7),
    ]))
    assert out["SUCURSAL"].to_list() == [
        ML, ML, ML, "CANAL DIGITAL", "CANAL DIGITAL", "DIEZ DE JULIO (2)", "OFICINAS CENTRALES",
    ]
    # La nota de credito sigue restando.
    assert out["CantidadAjustada"].to_list()[:3] == [5, -2, 3]


def test_el_stock_de_ml_full_ya_no_es_del_cd():
    assert fuentes_reales.STOCK_BODEGA_SUCURSAL["BODEGA ML-FULL"] == ML
    # La bodega ML (430) sigue siendo del CD.
    assert fuentes_reales.STOCK_BODEGA_SUCURSAL["BODEGA ML"] == P.CD_ID


def _ventas(filas):
    """filas: (producto, sucursal, meses atras) -> una venta ese mes."""
    return pl.DataFrame(
        [{"Producto": p, "SUCURSAL": s, "TipoVenta": "NORMAL", "Fecha": date(2026, 6 - m, 1),
          "CantidadAjustada": 1.0, "Fuente": "Curifor"} for p, s, m in filas],
        schema={"Producto": pl.Utf8, "SUCURSAL": pl.Utf8, "TipoVenta": pl.Utf8,
                "Fecha": pl.Date, "CantidadAjustada": pl.Float64, "Fuente": pl.Utf8},
    )


VACIO_MAPEO = pl.DataFrame(schema={"Producto": pl.Utf8, "Producto_Master": pl.Utf8})
VACIO_DIM = pl.DataFrame(schema={"Producto": pl.Utf8, "Categoria": pl.Utf8})


def test_ml_full_clase_a_se_centraliza_en_el_cd():
    """Una sucursal clase A compra directo; ML-FULL no: el CD le crea su fila y
    la abastece aunque ML-FULL venda todos los meses."""
    abc = clasificacion_abc.calcular_abc(
        _ventas([("X", ML, m) for m in range(6)]), VACIO_MAPEO, VACIO_DIM, FIN)
    ml = abc.filter(pl.col("sucursal_final") == ML)
    assert ml["clasificacion_abc"].item() == "A"
    # La agregada de las centralizadas incluye a ML-FULL.
    assert ml["clasificacion_abc_agregada_d"].item() == "A"
    # El CD tiene fila para comprar por ella.
    assert abc.filter(pl.col("sucursal_final") == P.CD_ID).height == 1


def test_ml_full_siempre_se_abastece_del_cd():
    abc = clasificacion_abc.calcular_abc(
        _ventas([("X", ML, m) for m in range(6)] + [("X", "LINDEROS", m) for m in range(6)]),
        VACIO_MAPEO, VACIO_DIM, FIN)
    seg = pl.DataFrame(schema={
        "Producto": pl.Utf8, "SucursalID": pl.Utf8, "RazonSocial": pl.Utf8,
        "FechaOC": pl.Date, "NOC": pl.Int64, "Origen": pl.Utf8, "Motivo": pl.Utf8,
    })
    lt_prov = pl.DataFrame(schema={"Razon Social Proveedor": pl.Utf8, "Lead Time Dias": pl.Float64})
    lt_suc = pl.DataFrame(schema={"Razon Social Proveedor": pl.Utf8, "SucursalID": pl.Utf8,
                                  "Lead Time Dias": pl.Float64, "N Muestras": pl.Int64})
    dim = pl.DataFrame({"SucursalID": [ML, "LINDEROS", P.CD_ID], "Region": ["RM", "RM", "RM"]})
    lt = lead_time.calcular_lead_time(abc, seg, lt_prov, lt_suc, dim, [])
    abast = dict(zip(lt["sucursal_final"].to_list(), lt["abastece_cd"].to_list()))
    assert abast[ML] == "Si"
    assert abast["LINDEROS"] == "No"   # clase A: compra directo
