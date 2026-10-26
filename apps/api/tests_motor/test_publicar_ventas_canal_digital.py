"""El motor publica las lineas de venta del canal digital (bodega 430).

Mismo patron que las ventas historicas: se le pregunta a la plataforma hasta que
periodo tiene, se suben SOLO los meses cerrados posteriores y en un dia normal no
se sube nada. A diferencia de aquellas, aca va la linea del documento y no la venta
agregada: una nota de credito de noviembre puede anular una venta de octubre, y
solo la plataforma, que guarda todas las lineas, puede emparejarlas.

Lo que estos tests cuidan:

1. Un POST por mes, nunca un mes partido (el endpoint borra el periodo que llega).
2. Solo meses cerrados, solo los cuatro tipos de venta del canal.
3. Un respaldo sin las columnas minimas NO publica nada, ni los meses buenos.
4. Las tres formas de fecha de los respaldos salen en ISO; si ninguna se entiende,
   el archivo cambio de formato y se frena en vez de perder las ventas en silencio.
5. Un fallo se anota como el de cualquier paso y no rompe la corrida.
6. Nada sale a la red de verdad: ni un socket.
"""
import csv
import datetime as dt
import socket
from datetime import date

import httpx
import pytest
from conftest import escribir_xlsx

from src.jobs import correr_motor_real as job

HOY = date(2026, 10, 26)  # ultimo mes cerrado: 202609
PASO = "las ventas del canal digital"

CABECERA = ["SUCURSAL", "Periodo", "tipoDocto", "Numero", "Fecha", "Tipo-Venta", "Producto",
            "Cantidad", "Costo Neto", "Documento Referencia", "Nro Documento Referencia",
            "Total Neta"]


def _serial(d: date) -> int:
    return (d - date(1899, 12, 30)).days


def _fila(periodo="202609", numero="835066", fecha=dt.datetime(2026, 9, 4), tipo_venta="VTA ML",
          producto="20 BXO5W30AA", cantidad=3.0, costo=5600.5, tipo_docto="FA-ELECTR REPTO",
          doc_ref="BOLETA-REPUESTOS", nro_doc_ref="7720"):
    return ["01 LINDEROS", periodo, tipo_docto, numero, fecha, tipo_venta, producto, cantidad,
            costo, doc_ref, nro_doc_ref, 99999]


def _linea(periodo="202609", numero="835066", fecha="2026-09-04", tipo_venta="VTA ML",
           producto="20 BXO5W30AA", cantidad=3.0, costo_neto=5600.5, tipo_docto="FA-ELECTR REPTO",
           doc_ref="BOLETA-REPUESTOS", nro_doc_ref="7720"):
    """La linea tal como la espera POST /api/canal-digital/lineas."""
    return {"periodo": periodo, "tipo_docto": tipo_docto, "numero": numero, "fecha": fecha,
            "tipo_venta": tipo_venta, "producto": producto, "cantidad": cantidad,
            "costo_neto": costo_neto, "doc_ref": doc_ref, "nro_doc_ref": nro_doc_ref}


# --- Una plataforma de mentira, y ni un socket ----------------------------------


@pytest.fixture(autouse=True)
def _sin_red(monkeypatch):
    """Si algo intenta abrir una conexion de verdad, el test cae.

    Un test publico 316 productos reales en produccion (07-10-2026). Aca ademas de
    `_token`, que corta los clientes httpx de verdad, se vigila el socket.
    """
    intentos: list = []

    def _prohibido(*a, **k):
        intentos.append(a)
        raise OSError("sin red en los tests")

    monkeypatch.setattr(socket.socket, "connect", _prohibido)
    monkeypatch.setattr(socket.socket, "connect_ex", _prohibido)
    monkeypatch.setattr(socket, "getaddrinfo", _prohibido)
    yield intentos
    assert intentos == [], f"un test intento salir a la red: {intentos}"


@pytest.fixture(autouse=True)
def _fallos_aislados():
    """Los fallos de un test no pueden volver incompleta la corrida de otro."""
    copia = list(job._FALLOS)
    job._FALLOS.clear()
    job.olvidar_token()
    yield
    job._FALLOS[:] = copia
    job.olvidar_token()


class _Plataforma:
    """GET meta, POST lineas y el login. Guarda lo que recibe y, como la de verdad,
    deja de pedir un mes cuando ya lo tiene."""

    def __init__(self, periodo_hasta=None, meta=200):
        self.periodo_hasta = periodo_hasta
        self.codigo_meta = meta
        self.gets: list[str] = []
        self.posts: list[tuple[str, dict]] = []
        self.fallos_post: list = []  # una entrada por POST: codigo, excepcion o None
        self.clientes = 0

    def _resp(self, metodo, url, codigo, datos):
        return httpx.Response(codigo, json=datos, request=httpx.Request(metodo, url))

    def get(self, url, headers=None, **k):
        self.gets.append(url)
        return self._resp("GET", url, self.codigo_meta, {"periodo_hasta": self.periodo_hasta})

    def post(self, url, json=None, headers=None, **k):
        if url.endswith("/api/auth/login"):
            return self._resp("POST", url, 200, {"token": "t"})
        self.posts.append((url, json))
        falla = self.fallos_post.pop(0) if self.fallos_post else None
        if isinstance(falla, Exception):
            raise falla
        if falla:
            return self._resp("POST", url, falla, {})
        periodo = json["lineas"][0]["periodo"]
        self.periodo_hasta = max(self.periodo_hasta or "000000", periodo)
        return self._resp("POST", url, 200, {
            "lineas_cargadas": len(json["lineas"]), "lineas_ignoradas": 0,
            "periodos": [periodo], "filas_venta": 1, "estadisticas": {}})


class _Cliente:
    def __init__(self, plataforma):
        self.p = plataforma
        plataforma.clientes += 1

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def get(self, *a, **k):
        return self.p.get(*a, **k)

    def post(self, *a, **k):
        return self.p.post(*a, **k)


@pytest.fixture
def mundo(monkeypatch, tmp_path):
    """Credenciales de mentira, una plataforma de mentira y los respaldos que se le pasen."""
    monkeypatch.setattr(job, "_credenciales", lambda: ("http://api", "motor@ejemplo.cl", "clave"))
    monkeypatch.setattr(job, "ESPERA_BASE_SEG", 0)

    class _Mundo:
        def __init__(self):
            self.plataforma = None
            self.respaldos: list = []

        def respaldo(self, filas, nombre="2026 (6).xlsx", cabecera=CABECERA):
            ruta = escribir_xlsx(tmp_path / "Ventas" / nombre, cabecera, filas)
            self.respaldos = [*self.respaldos, ruta]
            monkeypatch.setattr(job, "_archivos_de_ventas", lambda fin: list(self.respaldos))
            return ruta

        def plataforma_con(self, periodo_hasta=None, meta=200):
            self.plataforma = _Plataforma(periodo_hasta, meta)
            monkeypatch.setattr(httpx, "Client", lambda **k: _Cliente(self.plataforma))
            return self.plataforma

        def publicar(self, hoy=HOY, **k):
            return job.publicar_ventas_canal_digital(hoy=hoy, **k)

    return _Mundo()


def _meses(plataforma):
    return [[l["periodo"] for l in cuerpo["lineas"]] for _, cuerpo in plataforma.posts]


# --- Que sube y que no ----------------------------------------------------------


def test_al_dia_no_sube_nada_ni_abre_el_respaldo(mundo, monkeypatch, tmp_path):
    """Con el ultimo mes cerrado ya cargado no hay nada que leer: el respaldo ni existe
    aca, y si el motor lo abriera el paso fallaria."""
    p = mundo.plataforma_con("202609")
    monkeypatch.setattr(job, "_archivos_de_ventas", lambda fin: [tmp_path / "no_existe.xlsx"])

    r = mundo.publicar()

    assert r == {"lineas_cargadas": 0, "periodos": [], "al_dia": True}
    assert p.posts == []
    assert not job._FALLOS


def test_el_respaldo_sin_meses_nuevos_tambien_es_al_dia(mundo):
    mundo.respaldo([_fila("202607", numero="1"), _fila("202608", numero="2")])
    p = mundo.plataforma_con("202608")

    assert mundo.publicar() == {"lineas_cargadas": 0, "periodos": [], "al_dia": True}
    assert p.posts == []


def test_subido_el_mes_la_corrida_siguiente_no_sube_nada(mundo):
    mundo.respaldo([_fila("202608"), _fila("202609", numero="2")])
    p = mundo.plataforma_con("202608")

    assert mundo.publicar()["periodos"] == ["202609"]
    p.posts.clear()

    assert mundo.publicar() == {"lineas_cargadas": 0, "periodos": [], "al_dia": True}
    assert p.posts == []


def test_un_mes_nuevo_es_un_solo_post_con_las_lineas_esperadas(mundo):
    mundo.respaldo([_fila("202608", numero="1"), _fila("202609", numero="835066")])
    p = mundo.plataforma_con("202608")

    r = mundo.publicar()

    assert r == {"lineas_cargadas": 1, "periodos": ["202609"], "al_dia": False}
    assert p.gets == ["http://api/api/canal-digital/meta?bodega=430"]
    assert len(p.posts) == 1
    url, cuerpo = p.posts[0]
    assert url == "http://api/api/canal-digital/lineas"
    assert cuerpo == {"bodega": "430", "lineas": [_linea()]}


def test_dos_meses_son_dos_post_separados_en_orden(mundo):
    mundo.respaldo([
        _fila("202609", numero="3"), _fila("202608", numero="1"),
        _fila("202608", numero="2"), _fila("202609", numero="4"),
    ])
    p = mundo.plataforma_con("202607")

    r = mundo.publicar()

    assert _meses(p) == [["202608", "202608"], ["202609", "202609"]], "un mes no se parte"
    assert r == {"lineas_cargadas": 4, "periodos": ["202608", "202609"], "al_dia": False}


def test_la_primera_carga_sube_todos_los_meses_del_respaldo(mundo):
    """Plataforma vacia: periodo_hasta null -> '000000'."""
    mundo.respaldo([_fila("202501", numero="1"), _fila("202609", numero="2")])
    p = mundo.plataforma_con(None)

    assert mundo.publicar()["periodos"] == ["202501", "202609"]
    assert len(p.posts) == 2


def test_lineas_repetidas_en_el_origen_se_mandan_todas(mundo):
    """El servidor guarda las repetidas: el motor no deduplica."""
    mundo.respaldo([_fila(numero="7"), _fila(numero="7")])
    p = mundo.plataforma_con("202608")

    mundo.publicar()

    assert len(p.posts[0][1]["lineas"]) == 2


def test_solo_pasan_los_cuatro_tipos_de_venta_del_canal(mundo):
    tipos = ["VTA ML", "VTA SHOPIFY", "VTA WALMART", "VTA PARIS", "VTA MOSTRADOR",
             "VTA MERCADOLIBRE FULL", "", None, "VTA ML "]
    mundo.respaldo([_fila(numero=str(i), tipo_venta=t) for i, t in enumerate(tipos)])
    p = mundo.plataforma_con("202608")

    mundo.publicar()

    enviados = [(l["numero"], l["tipo_venta"]) for l in p.posts[0][1]["lineas"]]
    assert enviados == [("0", "VTA ML"), ("1", "VTA SHOPIFY"), ("2", "VTA WALMART"),
                        ("3", "VTA PARIS"), ("8", "VTA ML")]


def test_el_mes_en_curso_no_se_sube(mundo):
    """Llega incompleto, y como despues solo se suben periodos posteriores, no se corregiria."""
    mundo.respaldo([_fila("202609", numero="1"), _fila("202610", numero="2")])
    p = mundo.plataforma_con("202608")

    r = mundo.publicar(hoy=date(2026, 10, 26))

    assert r["periodos"] == ["202609"]
    assert _meses(p) == [["202609"]]


def test_cerrado_el_mes_se_sube_el_dia_1(mundo):
    mundo.respaldo([_fila("202609", numero="1"), _fila("202610", numero="2")])
    p = mundo.plataforma_con("202609")

    assert mundo.publicar(hoy=date(2026, 11, 1))["periodos"] == ["202610"]
    assert _meses(p) == [["202610"]]


def test_una_nota_de_credito_viaja_con_cantidad_positiva_y_su_referencia(mundo):
    """El motor no la resta ni la empareja: la plataforma resuelve el original."""
    mundo.respaldo([_fila("202609", numero="55", tipo_docto="NC-ELECTR REPTO", cantidad=2.0,
                          doc_ref="FA-ELECTR REPTO", nro_doc_ref="835066")])
    p = mundo.plataforma_con("202608")

    mundo.publicar()

    assert p.posts[0][1]["lineas"] == [_linea(
        numero="55", tipo_docto="NC-ELECTR REPTO", cantidad=2.0,
        doc_ref="FA-ELECTR REPTO", nro_doc_ref="835066")]


# --- Columnas -------------------------------------------------------------------


@pytest.mark.parametrize("falta", ["Costo Neto", "Fecha", "Numero", "Periodo", "tipoDocto"])
def test_sin_las_columnas_minimas_falla_claro_y_no_publica(mundo, falta):
    cabecera = [c for c in CABECERA if c != falta]
    filas = [[v for c, v in zip(CABECERA, _fila()) if c != falta]]
    mundo.respaldo(filas, cabecera=cabecera)
    p = mundo.plataforma_con("202608")

    assert mundo.publicar() is None

    assert p.posts == []
    assert [f["paso"] for f in job._FALLOS] == [PASO]
    error = job._FALLOS[0]["error"]
    assert falta in error and "2026 (6).xlsx" in error and "No se publico nada" in error
    assert not job._FALLOS[0]["transitorio"], "reintentar no arregla un respaldo mal armado"


def test_un_respaldo_malo_frena_tambien_los_meses_buenos_de_otro(mundo):
    """Se lee y valida todo antes del primer POST: quedar a medias es peor."""
    mundo.respaldo([_fila("202608", numero="1")], nombre="2025 (4).xlsx")
    sin_costo = [c for c in CABECERA if c != "Costo Neto"]
    mundo.respaldo([[v for c, v in zip(CABECERA, _fila()) if c != "Costo Neto"]],
                   nombre="2026 (6).xlsx", cabecera=sin_costo)
    p = mundo.plataforma_con("202607")

    assert mundo.publicar() is None

    assert p.posts == []
    assert "2026 (6).xlsx" in job._FALLOS[0]["error"]


def test_las_columnas_de_referencia_pueden_no_estar(mundo):
    """Un respaldo antiguo no las trae: salen vacias."""
    cabecera = [c for c in CABECERA if "Referencia" not in c]
    mundo.respaldo([[v for c, v in zip(CABECERA, _fila()) if "Referencia" not in c]],
                   cabecera=cabecera)
    p = mundo.plataforma_con("202608")

    assert mundo.publicar()["lineas_cargadas"] == 1

    assert p.posts[0][1]["lineas"] == [_linea(doc_ref="", nro_doc_ref="")]


def test_las_celdas_de_referencia_vacias_salen_como_texto_vacio(mundo):
    mundo.respaldo([_fila(doc_ref=None, nro_doc_ref=None)])
    p = mundo.plataforma_con("202608")

    mundo.publicar()

    linea = p.posts[0][1]["lineas"][0]
    assert linea["doc_ref"] == "" and linea["nro_doc_ref"] == ""


def test_el_encabezado_no_tiene_que_estar_en_la_primera_fila(mundo):
    """Los reportes del ERP a veces traen un titulo arriba."""
    mundo.respaldo([["Reporte de ventas"], [], CABECERA, _fila()], cabecera=["Reporte"])
    p = mundo.plataforma_con("202608")

    assert mundo.publicar()["lineas_cargadas"] == 1
    assert p.posts[0][1]["lineas"] == [_linea()]


# --- Como se leen los valores ---------------------------------------------------


def test_la_fecha_en_cualquiera_de_sus_formas_sale_en_iso(mundo):
    sept4 = date(2026, 9, 4)
    formas = [dt.datetime(2026, 9, 4, 15, 30), dt.date(2026, 9, 4), _serial(sept4),
              float(_serial(sept4)), str(_serial(sept4)), "04-09-2026", "04/09/2026",
              "2026-09-04", "2026-09-04T00:00:00", " 04-09-2026 "]
    mundo.respaldo([_fila(numero=str(i), fecha=f) for i, f in enumerate(formas)])
    p = mundo.plataforma_con("202608")

    mundo.publicar()

    assert {l["fecha"] for l in p.posts[0][1]["lineas"]} == {"2026-09-04"}
    assert len(p.posts[0][1]["lineas"]) == len(formas)


def test_el_serial_de_excel_corresponde_a_la_fecha_conocida(mundo):
    """45684 = 27-ene-2025, el ejemplo documentado en `lectores_excel._a_fecha`."""
    mundo.respaldo([_fila("202501", fecha=45684)])
    p = mundo.plataforma_con("202412")

    mundo.publicar()

    assert p.posts[0][1]["lineas"][0]["fecha"] == "2025-01-27"


def test_numero_y_periodo_sin_el_punto_cero(mundo):
    """Un numero guardado como decimal sale como "835066.0": el servidor lo espera sin cola."""
    mundo.respaldo([
        _fila(periodo=202609, numero=835066.0),
        _fila(periodo="202609.0", numero="835067.0"),
        _fila(periodo=202609.0, numero=835068),
    ])
    p = mundo.plataforma_con("202608")

    mundo.publicar()

    assert [(l["periodo"], l["numero"]) for l in p.posts[0][1]["lineas"]] == [
        ("202609", "835066"), ("202609", "835067"), ("202609", "835068")]


def test_cantidad_y_costo_aceptan_numero_texto_con_coma_y_vacio(mundo):
    mundo.respaldo([
        _fila(numero="1", cantidad=2, costo=100),
        _fila(numero="2", cantidad="1.234,5", costo="5600,5"),
        _fila(numero="3", cantidad=None, costo=None),
        _fila(numero="4", cantidad="-2", costo="no es un numero"),
    ])
    p = mundo.plataforma_con("202608")

    mundo.publicar()

    assert [(l["cantidad"], l["costo_neto"]) for l in p.posts[0][1]["lineas"]] == [
        (2.0, 100.0), (1234.5, 5600.5), (0.0, 0.0), (-2.0, 0.0)]


def test_el_producto_viaja_como_viene_el_servidor_lo_normaliza(mundo):
    producto = "15 mxd1454m  "
    mundo.respaldo([_fila(producto=producto), _fila(numero="2", producto=12345)])
    p = mundo.plataforma_con("202608")

    mundo.publicar()

    assert [l["producto"] for l in p.posts[0][1]["lineas"]] == [producto, "12345"]


def test_las_lineas_sin_producto_se_omiten_y_se_avisan(mundo, capsys):
    mundo.respaldo([_fila(numero="1", producto=None), _fila(numero="2", producto="  "),
                    _fila(numero="3")])
    p = mundo.plataforma_con("202608")

    mundo.publicar()

    assert [l["numero"] for l in p.posts[0][1]["lineas"]] == ["3"]
    assert "2 sin producto" in capsys.readouterr().out


def test_unas_pocas_fechas_ilegibles_se_omiten_y_se_avisan(mundo, capsys):
    mundo.respaldo([_fila(numero=str(i)) for i in range(199)]
                   + [_fila(numero="mala", fecha="sin fecha")])
    p = mundo.plataforma_con("202608")

    r = mundo.publicar()

    assert r["lineas_cargadas"] == 199
    assert "mala" not in [l["numero"] for l in p.posts[0][1]["lineas"]]
    assert "1 lineas sin fecha legible" in capsys.readouterr().out
    assert not job._FALLOS


def test_si_el_respaldo_no_trae_fechas_legibles_cambio_de_formato_y_no_se_publica(mundo):
    """El 2025 llego como serial de Excel y se leyo como texto: 198.032 ventas perdidas
    sin un error. Con un formato que no se entiende, el archivo entero queda sin fecha."""
    mundo.respaldo([_fila(numero=str(i), fecha="9 de septiembre") for i in range(20)])
    p = mundo.plataforma_con("202608")

    assert mundo.publicar() is None

    assert p.posts == []
    error = job._FALLOS[0]["error"]
    assert "20 de 20" in error and "9 de septiembre" in error and "cambio de formato" in error


# --- Fallos: nunca rompen la corrida --------------------------------------------


def test_un_500_devuelve_none_y_queda_anotado(mundo):
    mundo.respaldo([_fila()])
    p = mundo.plataforma_con("202608")
    p.fallos_post = [500]

    assert mundo.publicar() is None

    assert [f["paso"] for f in job._FALLOS] == [PASO]
    assert "500" in job._FALLOS[0]["error"]
    assert not job._FALLOS[0]["transitorio"]


def test_un_corte_de_red_devuelve_none_y_se_marca_transitorio(mundo):
    mundo.respaldo([_fila()])
    p = mundo.plataforma_con("202608")
    p.fallos_post = [httpx.ConnectError("sin conexion")]

    assert mundo.publicar() is None

    assert job._FALLOS[0]["transitorio"]


def test_un_fallo_del_meta_tambien_se_anota_sin_romper(mundo):
    mundo.respaldo([_fila()])
    p = mundo.plataforma_con("202608", meta=502)

    assert mundo.publicar() is None

    assert [f["paso"] for f in job._FALLOS] == [PASO] and p.posts == []


def test_una_plataforma_sin_el_modulo_no_es_un_fallo(mundo, capsys):
    """El motor puede salir antes que la plataforma: el 404 del meta se avisa y se sigue."""
    mundo.respaldo([_fila()])
    p = mundo.plataforma_con("202608", meta=404)

    assert mundo.publicar() is None

    assert not job._FALLOS and p.posts == []
    assert "todavia no tiene el modulo" in capsys.readouterr().out


def test_un_fallo_a_mitad_se_reintenta_y_retoma_en_el_mes_que_falta(mundo):
    """Se subio agosto y septiembre cayo con un 502: el reintento le pregunta de nuevo a la
    plataforma y sube solo septiembre. Subir de nuevo es inofensivo: el servidor reemplaza el periodo."""
    mundo.respaldo([_fila("202608", numero="1"), _fila("202609", numero="2")])
    p = mundo.plataforma_con("202607")
    p.fallos_post = [None, 502]

    r = job.publicar_con_reintentos(PASO, job.publicar_ventas_canal_digital)

    assert _meses(p) == [["202608"], ["202609"], ["202609"]]
    assert len(p.gets) == 2
    assert r == {"lineas_cargadas": 1, "periodos": ["202609"], "al_dia": False}
    assert not job._FALLOS, "el fallo solo cuenta si el ultimo intento tambien falla"


def test_sin_credenciales_no_hace_nada(mundo, monkeypatch):
    mundo.respaldo([_fila()])
    p = mundo.plataforma_con("202608")
    monkeypatch.setattr(job, "_credenciales", lambda: ("http://api", None, None))

    assert mundo.publicar() is None

    assert p.clientes == 0 and not job._FALLOS


def test_sin_respaldos_no_hace_nada(mundo, monkeypatch):
    p = mundo.plataforma_con("202608")
    monkeypatch.setattr(job, "_archivos_de_ventas", lambda fin: [])

    assert mundo.publicar() is None

    assert p.clientes == 0 and not job._FALLOS


def test_la_bodega_va_en_el_meta_y_en_el_cuerpo(mundo):
    mundo.respaldo([_fila()])
    p = mundo.plataforma_con("202608")

    mundo.publicar(bodega="431")

    assert p.gets == ["http://api/api/canal-digital/meta?bodega=431"]
    assert p.posts[0][1]["bodega"] == "431"


# --- Nada sale a la red de verdad -----------------------------------------------


def test_con_el_cliente_http_de_verdad_la_guarda_corta_antes_de_salir(mundo):
    """Sin parchear `httpx.Client`: `_token` lo corta con una BaseException, que el
    `except Exception` del paso no atrapa, y no se abre ningun socket."""
    mundo.respaldo([_fila()])  # la plataforma de mentira NO se instala

    with pytest.raises(job.LlamadaRealDesdeUnTest):
        mundo.publicar()

    assert not job._FALLOS, "la guarda no es un fallo de publicacion: tiene que caer el test"


def test_la_guarda_de_sockets_ve_los_intentos(_sin_red):
    with pytest.raises(OSError):
        socket.create_connection(("127.0.0.1", 9))
    assert _sin_red, "la guarda no vio el intento"
    _sin_red.clear()  # este test lo provoco a proposito


# --- El enganche en la corrida --------------------------------------------------


def _correr(monkeypatch, tmp_path, canal, oficial=True):
    """`job.run` con todo apagado salvo lo que se anota en `llamadas`."""
    csv_ = tmp_path / "sugerido_motor.csv"
    with open(csv_, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["Producto", "SucursalID", "Periodo Ultimo Mes",
                                          "Venta Mes 01", "Venta Mes 02"])
        w.writeheader()
        w.writerow({"Producto": "17 P0", "SucursalID": "LINDEROS", "Periodo Ultimo Mes": "202608",
                    "Venta Mes 01": 3, "Venta Mes 02": 5})
    llamadas: list[str] = []
    monkeypatch.setattr(job, "revisar_frescura", lambda hoy=None: [])
    monkeypatch.setattr(job, "construir_csv", lambda hoy=None: csv_)
    monkeypatch.setattr(job, "enviar", lambda p, oficial=False: {
        "filas_cargadas": 1, "advertencias": [], "paridad_pct": 100, "filas_comunes": 1,
        "filas_solo_motor": 0, "filas_solo_bi": 0})
    monkeypatch.setattr(job, "avisar_falla", lambda *a, **k: False)
    monkeypatch.setattr(job, "CANDADO", tmp_path / "motor.lock")

    class _Hoy(date):
        @classmethod
        def today(cls):
            return date(2026, 9, 21)
    monkeypatch.setattr(job, "date", _Hoy)
    # Se apagan TODOS los pasos que publican, tambien los que se agreguen despues
    # (ver `test_ventas_mes_cerrado`).
    apagar = {n for n in dir(job)
              if n.startswith(("publicar_", "obtener_config", "preparar_fuentes"))
              and n != "publicar_con_reintentos"}
    apagar |= {"recargar_instock", "recalcular_precios"}
    for nombre in sorted(apagar):
        monkeypatch.setattr(job, nombre, lambda *a, **k: None)

    def _anota(nombre, devuelve=None):
        def paso(*a, **k):
            llamadas.append(nombre)
            return devuelve
        return paso

    monkeypatch.setattr(job, "publicar_ventas_historicas", _anota("ventas", {"al_dia": True}))
    monkeypatch.setattr(job, "publicar_reglas_manuales", _anota("reglas"))
    monkeypatch.setattr(job, "publicar_ventas_canal_digital", canal(llamadas))
    return job.run(oficial=oficial), llamadas


def test_la_corrida_oficial_publica_el_canal_entre_las_ventas_y_las_reglas(monkeypatch, tmp_path):
    def canal(llamadas):
        def paso(*a, **k):
            llamadas.append("canal")
            return {"lineas_cargadas": 0, "periodos": [], "al_dia": True}
        return paso

    codigo, llamadas = _correr(monkeypatch, tmp_path, canal)

    assert codigo == 0
    assert llamadas == ["ventas", "canal", "reglas"]


def test_la_corrida_en_sombra_no_publica_el_canal(monkeypatch, tmp_path):
    def canal(llamadas):
        return lambda *a, **k: llamadas.append("canal")

    codigo, llamadas = _correr(monkeypatch, tmp_path, canal, oficial=False)

    assert codigo == 0 and llamadas == []


def test_un_fallo_del_canal_se_anota_y_no_frena_los_pasos_que_siguen(monkeypatch, tmp_path):
    def canal(llamadas):
        def paso(*a, **k):
            llamadas.append("canal")
            job.fallo_publicacion(PASO, RuntimeError("HTTP 500"))
        return paso

    codigo, llamadas = _correr(monkeypatch, tmp_path, canal)

    assert llamadas == ["ventas", "canal", "reglas"], "las reglas corrieron despues del fallo"
    assert codigo == 1, "como cualquier paso: la carga queda marcada incompleta"
    assert [f["paso"] for f in job._FALLOS] == [PASO]
