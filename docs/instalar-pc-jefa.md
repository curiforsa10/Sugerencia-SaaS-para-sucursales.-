# Instalar la plataforma en tu PC

Tu PC va a hacer lo que hasta ahora hacía el PC del dueño: bajar las tablas del ERP,
calcular el sugerido de compras y publicarlo en la plataforma. Se instala una vez, con
doble clic, y tarda unos 10 minutos.

## Antes de empezar

- El programa que baja las tablas del ERP ya instalado en tu PC (la carpeta
  `automatizacion`, con `panel.bat`) y funcionando.
- OneDrive de la empresa abierto, con tu cuenta (`OneDrive - Curifor S.A`).
- Internet.
- Dos claves que te pasa quien mantiene la plataforma: la de la **cuenta del motor**
  (`admin@curifor.com`) y la **clave del agente**. Se escriben sin que se vean y quedan
  guardadas solo en tu PC.

## Instalar

1. Haz doble clic en **`INSTALAR PLATAFORMA.cmd`** (te lo mandan como archivo suelto;
   déjalo en el Escritorio). Si Windows dice "Windows protegió su PC", elige
   **Más información** y **Ejecutar de todas formas**.
2. Sigue la ventana. Cuando una pregunta trae un valor entre `[corchetes]`, Enter lo
   acepta.
3. Cuando pregunte por el programa del ERP, confirma la carpeta que encontró o elige la
   carpeta `automatizacion` en la ventana que se abre. Si esa carpeta está dentro de
   OneDrive (por ejemplo, en un Escritorio que OneDrive respalda), ofrece copiarla a
   `%USERPROFILE%\automatizacion` y borrar la de OneDrive y el `automatizacion.zip` del
   kit: su `.env` tiene las claves del ERP y OneDrive lo sube a la nube. Desde ahí sigue
   el `panel.bat`.
4. Al final lee el **Resumen**: dice qué quedó listo y, en "Falta", qué hacer con cada
   cosa. Se puede volver a correr cuantas veces haga falta: no pisa lo que está bien.

Si Windows pide permiso para instalar Python o Git, acéptalo. Si tu PC no te deja
instalar programas, el instalador usa el Python que trae el programa del ERP; **Git**
hay que pedírselo a TI y volver a correr el instalador.

### Si falta la carpeta Data BI

El resumen puede decir que falta el acceso directo a "Data BI - Datos" (el stock que
sube el equipo cada mañana). No frena nada, pero conviene agregarlo:

1. En el navegador, abre el sitio de SharePoint **Abastecimiento y Logística - Data BI**.
2. Entra a **Documentos > Data BI > Datos** y elige **Agregar acceso directo a Mis archivos**.
3. En el Explorador, dentro de `OneDrive - Curifor S.A`, clic derecho sobre la carpeta
   nueva y **Mantener siempre en este dispositivo**.

## El día del cambio

1. Un admin entra a la plataforma, **Cargar > Fuentes de datos**, y deja tu PC como
   **titular**. Hasta entonces tu PC calcula pero no publica.
2. Ese mismo día, en el PC del dueño, se deshabilitan sus tareas (ver
   `apps/api/data/crudos/README.md`, "Cambio de PC titular").
3. Haz doble clic en **Actualizar plataforma** y revisa que termine en **LISTO**.

## Todos los días

- **Acceso "Actualizar plataforma"** (en el Escritorio): baja las tablas del ERP y
  publica el sugerido. Tarda 35 a 45 minutos. Los primeros **9 minutos no toques el mouse
  ni el teclado** (el programa hace clics en Flexline); después puedes trabajar. Al
  final dice qué pasó y qué hacer.
- **Si no lo usas**, a las **09:30** el PC calcula solo con los archivos que haya. Si ya
  lo usaste (o alguien apretó "Actualizar ahora") y salió bien, no calcula otra vez; si
  falló, a las 09:30 lo vuelve a intentar.
- El PC tiene que estar **prendido y con tu sesión iniciada**. Si se reinició de
  madrugada (pasa a la 01:00), al iniciar sesión recupera la corrida perdida.
- En la plataforma, **Actualizar ahora** recalcula desde cualquier lado (tu PC tiene que
  estar prendido) y **Actualizar motor** (solo admin, en Cargar) baja la última versión
  del motor sin recalcular nada.
- Cada mes hay que dejar el respaldo de ventas en `Bases de datos\Ventas`
  (`apps/api/data/crudos/README.md`, "El paso de cada mes").

## Si algo falla

- El mensaje de la ventana o de la tarjeta de la web dice el motivo y qué hacer.
- Los registros quedan en `%USERPROFILE%\dev\Sugerencia-SaaS-para-sucursales\logs`:
  `motor_<fecha>.log` (cálculo del día) y `agente_<fecha>.log` (botones de la web).
- Ante la duda, vuelve a correr `INSTALAR PLATAFORMA.cmd`: revisa todo y arregla lo que
  falte.

## Para quien mantiene el motor

- El instalador es `scripts/instalar_pc_jefa.ps1`; el `.cmd` de la raíz lo corre, y
  suelto lo baja de GitHub (rama `arreglar-job-diario`), así que esa rama tiene que
  tener este instalador publicado.
- `-Simular` hace todo en `%TEMP%\simulacion-instalador`: sin instalar programas, sin
  claves (valores ficticios), sin la plataforma de verdad (`http://127.0.0.1:8765`) y con
  las tareas registradas como `PRUEBA-...`, deshabilitadas, y borradas al final.
  `-SimularSinCarpetas` muestra los avisos de carpetas faltantes, `-SimularSinRobot` el
  resumen sin programa del ERP y `-SimularRobotEnOneDrive` cómo se saca de OneDrive. Las
  pruebas están en `apps/api/tests_motor/test_instalador_pc.py`.
- El código se clona con `http.sslBackend=schannel` y queda así en la configuración del
  repositorio: la red de la empresa revisa las conexiones seguras con un certificado que
  Windows conoce y OpenSSL no. El agente usa lo mismo en "Actualizar motor".
- Al final el instalador deja guardada la configuración de Fuentes de datos
  (`python -m src.motor.config_fuentes --guardar-config`): sin ella, si la plataforma no
  respondía en la primera corrida, el PC nuevo se creía titular y publicaba.
- Las tareas quedan como las del PC del dueño (con la sesión iniciada) y corren a través
  de `scripts/sin_ventana.vbs` para no abrir ventanas; si el PC no permite VBScript,
  el instalador usa PowerShell oculto.
