# Datos crudos del motor

El motor lee los Excel de dos carpetas que OneDrive mantiene sincronizadas en el PC
donde corre. Nada de esos archivos se sube a git (de esta carpeta, solo este README).

| Carpeta | Ruta en el PC (portable) | Cómo se lee |
|---|---|---|
| Bases de datos | `%OneDriveCommercial%\Documentos\Desarrollos\Bases de datos` | Con subcarpetas. Todas las fuentes. |
| Data BI › Datos | `%OneDriveCommercial%\Abastecimiento y Logística-Data BI - Datos` (acceso directo a SharePoint) | Solo el primer nivel y solo para los dos stocks. |

`apps/api/data/crudos/` (esta carpeta) es lo que usa el motor si el `.env` no dice
nada. En el PC del motor no se usa.

## Quién elige el archivo

Mientras la pantalla **Fuentes de datos** (plataforma, solo admins) esté sin
configurar o en prueba, el motor elige con el `.env` del PC, como siempre:

- `MOTOR_CRUDOS_DIR`: la carpeta Bases de datos (admite varias, separadas por `;`).
- `MOTOR_STOCK_DIR`: la carpeta Data BI › Datos.
- Los patrones de nombre de `src/motor/fuentes.py` (`FUENTES`). Entre varios
  archivos que calzan gana el de fecha más reciente, esté en la carpeta que esté.

Con Fuentes de datos en modo **activa**, el motor elige con la configuración del
panel: carpeta, subcarpeta, "siempre este archivo" o "el más reciente cuyo nombre
contenga…", plazo y si es obligatoria. Los cambios rigen desde la corrida siguiente.

En cualquier modo, cada corrida copia los archivos elegidos a `apps/api/data/corrida/`
y lee la copia, y el panel muestra qué archivo tomó cada fuente, de qué fecha y con
cuántas filas.

## Qué hay en Bases de datos y quién lo deja

| Fuente | Subcarpeta y nombre de hoy | Quién lo deja | Se espera al día cada |
|---|---|---|---|
| Stock bodegas Curifor | `stock\STOCK_BODEGAS_CURIFOR.xlsx` (compite con `Stock bodegas.xlsx` de Data BI) | El programa del ERP | 2 días hábiles; frena |
| Stock bodegas Frontera | `stock\stock_frontera.xlsx` (compite con `Stock bodegas Frontera.xlsx` de Data BI) | El programa del ERP | 2; frena |
| Seguimiento de compras nacional | `Seguimientos de compras\seguimiento_compras_nacional.xlsx` | El programa del ERP | 2; frena |
| Seguimiento importado y de Frontera | `Seguimientos de compras\seguimiento_compras_importado.xlsx` y `…_frontera.xlsx` | El programa del ERP | 7; frena |
| Respaldos de venta | `Ventas\2025 (4).xlsx`, `Ventas\2026 (6).xlsx` (el año y el anterior) | A mano, cada mes (ver abajo) | Por contenido: el mes cerrado tiene que traer ventas |
| Ventas Frontera | `Ventas\vtas frontera.xlsx` | Fuera del programa del ERP | 35; solo avisa |
| Lista de precios (maestro) | `Lista de precios\Lista de precios curifor\LISTA DE PRECIOS.xlsx` | Fuera del programa del ERP | 120; frena |
| Mix de reemplazos | `Base mix reemplazos\BASE NUEVO MIX 2026_1.xlsx` | Fuera del programa del ERP | 120; frena |
| Lista del ERP | `Lista ERP\lista_erp.xlsx` | Exportación manual, semanal | 10; solo avisa |
| Listas de precios Ford y Gildemeister | `Lista de precios\Lista de precios proveedores\` | Fuera del programa del ERP | Sin plazo |
| Vigentes Ford | `Vigentes Ford\Vigentes ford curifor_<fecha>_resultado.xlsx` | La tarea semanal del extractor Ford | Sin plazo |

Las pautas de mantención y las otras listas de proveedor el motor no las lee, pero
las reconoce por nombre para no confundirlas con un respaldo de venta.

## El paso de cada mes: el respaldo de ventas

Los respaldos de venta no tienen un nombre fijo (`2026 (6).xlsx`): el motor los
reconoce **por descarte**, como todo `.xlsx` con el año en el nombre que no es de
ninguna otra fuente y que tiene las columnas de un respaldo.

1. A principios de mes, baja el respaldo del año desde la biblioteca de SharePoint
   "Respaldos BBDD" (enero a hoy).
2. Déjalo en `Bases de datos\Ventas`, reemplazando el del mismo año.
3. Revisa en Fuentes de datos que "Respaldos de venta" traiga el mes recién cerrado.
   Desde el día 4 de cada mes, si el mes cerrado viene sin ventas, el sugerido no se
   publica.

No dejes en `Bases de datos` otros archivos con el año en el nombre que no sean
respaldos: el motor los prueba como respaldo de venta y, si no lo son, los descarta
y lo avisa en el panel. Si ni siquiera se pueden abrir como Excel, la corrida se
detiene y el motivo dice cuál es el archivo.

## Para que OneDrive no deje archivos a medio bajar

En el PC que corre el motor, en el Explorador de archivos, haz clic derecho sobre
las dos carpetas y elige **"Mantener siempre en este dispositivo"**. Si un archivo
está solo en la nube, el motor lo baja al copiarlo, y si OneDrive no termina en 10
minutos la fuente queda como "Bajando de OneDrive".

## Comandos

Desde `apps/api`:

```powershell
# Qué archivo elige cada fuente con el .env y con la plataforma, lado a lado.
# No calcula, no publica y no escribe nada en este PC.
.venv\Scripts\python.exe -m src.motor.config_fuentes --probar

# Lo mismo, y lo manda al panel de Fuentes de datos (no toca el sugerido).
.venv\Scripts\python.exe -m src.motor.config_fuentes --probar --reportar

# Inventario con columnas de cada archivo (herramienta antigua, sigue sirviendo).
.venv\Scripts\python.exe -m src.motor.fuentes
```

Variables del `.env` del PC para emergencias:

- `MOTOR_FUENTES=env`: el motor ignora la plataforma por completo (también el PC
  titular) y elige con el `.env`. Rige desde la corrida siguiente, sin deploy.
- `MOTOR_CARPETA_<CLAVE>=<ruta>`: usa esa ruta para la carpeta `<clave>` del panel
  (por ejemplo `MOTOR_CARPETA_BASES_DE_DATOS`). Es la única forma de usar una
  carpeta que no esté dentro de OneDrive.

## Golden snapshot (referencia de paridad)

`data/golden/` guarda el `sugerido` congelado que produce el Power BI actual:

```powershell
.venv\Scripts\python.exe -m src.motor.golden
```

Los tests de paridad comparan el output del motor contra ese CSV.
