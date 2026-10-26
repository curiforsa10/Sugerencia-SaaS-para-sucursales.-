# Reemplazos y precios de FORD (cada lunes)

Un programa aparte (Python + Chrome automatizado) consulta el portal de FORD WINGS por los códigos que
Curifor tiene en stock o en pautas de mantención (unos 7.000) y deja el Excel
`Bases de datos\Vigentes Ford\Vigentes ford curifor_<fecha>_resultado.xlsx`. El motor lo toma en el
siguiente **Actualizar ahora** de la plataforma. **Nada se publica solo.**

El programa **no vive en este repositorio** (trae la lógica del portal de FORD). Se entrega como la
carpeta `extractor-ford` (con `INSTALAR FORD.cmd` y su `LEEME.md`); este repositorio solo trae el script
que lo corre y el acceso.

## Cada lunes (a mano, 35 minutos)

1. Baja las tablas del ERP, como siempre.
2. Doble clic en **Actualizar FORD** (Escritorio) = `ACTUALIZAR FORD.cmd` en la carpeta del motor, que corre
   `scripts\tarea_vigentes_ford.ps1`. Se abre un Chrome: no lo cierres ni lo uses.
3. Si la sesión de Ford venció, Chrome pide usuario, clave y el código de verificación (MFA). Hay que entrar
   ahí y la corrida sigue sola. Si nadie entra, a los 90 minutos se corta y deja una incidencia en la
   plataforma.
4. Cuando la ventana diga **LISTO**, aprieta **Actualizar ahora**.

## Cómo sabe el script dónde está todo

`scripts\tarea_vigentes_ford.ps1` lee el `.env` del motor:

| Variable | Qué es | Si falta |
|---|---|---|
| `FORD_EXTRACTOR_DIR` | La carpeta `extractor-ford` (con `armar_lista_consulta.py` y `correr_vigentes_curifor.py`) | `%OneDriveCommercial%\Documentos\Desarrollos\Automatizaciones\5. Extraccion precios ford` (el PC del dueño) |
| `FORD_PYTHON` | El Python que tiene playwright, openpyxl y keyring | `%LOCALAPPDATA%\Python\pythoncore-3.14-64\python.exe` |
| `MOTOR_CRUDOS_DIR` | La carpeta `Bases de datos` (se usa la primera si hay varias) | `%OneDriveCommercial%\Documentos\Desarrollos\Bases de datos` |

`INSTALAR FORD.cmd` (dentro de la carpeta `extractor-ford`) escribe las dos primeras en el `.env`.

## Qué cambió el 26-10-2026

- El script ya no lanza el motor al terminar: en el PC de la jefa el motor corre solo con el botón.
- Las rutas ya no son las del PC del dueño.
- En el PC del dueño la tarea programada `Sugerido Curifor - Vigentes FORD semanal` (lunes 09:00) sigue
  funcionando igual hasta el día del cambio de PC titular, salvo que ya no encadena el motor.

## Lo que el traspaso no resuelve solo

- **El usuario de Ford y su MFA.** El código de verificación llega al dispositivo registrado en la cuenta. Si
  es el de una persona que se va, nadie podrá entrar cuando la sesión venza. Hay que dejar el segundo factor
  en un dispositivo que se quede, antes de la salida.
- **La lista original de precios de Ford** (hoja `CHILE`, ~39 mil códigos, `entrada\` del paquete). Hay que
  reemplazarla cuando Ford publique una nueva.
- **Si Ford cambia el portal**, los selectores de `fordwings\scraper.py` hay que reajustarlos (trabajo técnico).
