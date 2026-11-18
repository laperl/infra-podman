# Firefly III Data Importer (`firefly_importer`): requisitos (fase 2)

**`ffimport` es el Data Importer de Firefly III:** su nombre corto en todo lo que se crea en la máquina. Su nombre de código es `firefly_importer` (`roles/firefly_importer`, `firefly_importer_instances`). La instancia `laptop` es `prod-ffimport-laptop`. Instalarla, paso a paso: [`INSTALL.md`](INSTALL.md); lo propio del importer está en el apartado 8.

Qué tiene que cumplir el importer antes de escribir su código. Es una propuesta: lo que esté aquí y no en SPEC, sección 3, se aprueba con este PR. Lo marcado 🔍 no está verificado en la documentación oficial o en una máquina: se comprueba en DEV o en `lifecycle`, y el PR que lo verifique lo deja escrito.

**Para qué:** pasar a Firefly los extractos del banco en CSV, a mano y desde el navegador del portátil, sin que nada salga a internet. **La conexión directa con el banco no entra** (GoCardless, Enable Banking, SimpleFIN…): exige internet y dar acceso a las cuentas a un tercero, y se decide aparte ([`ROADMAP.md`](../ROADMAP.md)).

**Por instancias (R48),** como cualquier aplicación ([`README.md`](README.md)). Lo normal es una por máquina, que habla con **uno o varios** Firefly de esa máquina. Abajo, `<instancia>` es el `name:` de la tuya.

Fuentes de lo que dice este documento:

- **Documentación oficial:** [instalación con Docker](https://docs.firefly-iii.org/how-to/data-importer/installation/docker/), [configuración](https://docs.firefly-iii.org/how-to/data-importer/how-to-configure/), [importar un fichero](https://docs.firefly-iii.org/how-to/data-importer/import/file/), [ficheros JSON](https://docs.firefly-iii.org/how-to/data-importer/import/json/), [duplicados](https://docs.firefly-iii.org/references/data-importer/duplicate-detection/) y [duplicados que se cuelan o sobran](https://docs.firefly-iii.org/how-to/data-importer/import/duplicates/).
- **Todas las opciones de configuración:** el [`.env.example` de la v2.3.5](https://github.com/firefly-iii/data-importer/blob/v2.3.5/.env.example).
- **Lo que la documentación no dice** se ha leído en el código de la v2.3.5 ([firefly-iii/data-importer](https://github.com/firefly-iii/data-importer/tree/v2.3.5)) y de su imagen base ([firefly-iii/base-image](https://github.com/firefly-iii/base-image)). Cada vez se dice en qué fichero.

## 1. Ficha

| Dato | Valor |
| --- | --- |
| Nombres | De código `firefly_importer`; corto `ffimport` (8 letras, R52; `ffimporter` no cabe) |
| Imagen | `docker.io/fireflyiii/data-importer`, la oficial, en Docker Hub; sin suscripción. Se sigue la versión exacta: `# track: version-2.3.5`, la última publicada el 2026-09-23. Digest del índice calculado por el operador el 2026-11-18 con `skopeo inspect --raw \| sha256sum`, con `linux/amd64` y `linux/arm64`. Exige Firefly 6.6.0 o posterior (`minimum_version` en `config/importer.php`) |
| Usuario del contenedor | `www-data`, UID 33, como Firefly: las dos imágenes salen de la misma base (`serversideup/php:8.5-fpm-nginx`, que termina en `USER www-data`; `Dockerfile.web` de `base-image`). Sin `User=` ni `UserNS=` |
| Endurecimiento | `DropCapability=all` y `NoNewPrivileges=true`, sin excepción, como Firefly. Sin `ReadOnly=true`: escribe sesiones y ficheros subidos en `storage/`, igual que Firefly. 🔍 Que arranca así: el script de arranque propio del importer no es público; lo comprueba `lifecycle` |
| Contrato | `database: none` (no tiene base de datos), `providers: [firefly]` (al menos un Firefly en `connects_to`; apartado 2), `egress: false` |
| Entrada | HTTP en el 8080, publicado en `127.0.0.1:<puerto>`. Salud: `GET /health` responde `OK` (`routes/web.php`, `HealthcheckController`). No mira si Firefly responde. Con el `curl` de la imagen base |
| Datos | Ninguno que guardar: sin volúmenes (apartado 4) |
| Secretos | Ninguno: se entra con OAuth (apartado 4) |
| Copias | Nada: `firefly_importer_backup_available: {}`. Las configuraciones de cada banco (los JSON) las guardas tú (apartado 6.4) |
| Primer arranque | Sin base, sin migraciones y sin tareas programadas. Después, una vez: el cliente OAuth en Firefly (apartado 6.1) |
| Recursos | 512 MB, 1 CPU y 200 procesos, como Firefly. 🔍 Se miden en DEV y en `lifecycle` |
| Lanzador | «Firefly Importer (<instancia>)» en el menú de Sway (rofi `drun`, R47): todo se maneja desde la web |
| ¿Siempre en marcha? | Arranca con la máquina, como las demás, aunque se use de vez en cuando. «Arrancar al usar» sigue en el [`ROADMAP.md`](../ROADMAP.md) |
| Lo que no encaja | Nada |

## 2. Red: sin salida a internet

- **Sin `egress`:** solo está en redes internas, una por cada Firefly de su `connects_to`, sin ruta a fuera. El importer habla con Firefly solo por su API: no entra en Postgres.
- **Con uno o varios Firefly:** `connects_to: [ff-laptop]`, o `[ff-laptop, ff-canary]`. Cada pareja tiene su red ([`NETWORK.md`](../NETWORK.md)).
  - **Con uno solo,** el rol le dice al importer a qué Firefly va y entras con un clic (apartado 5).
  - **Con varios,** el importer te pregunta en cada sesión a cuál conectarse (dirección interna, dirección en tu navegador y Client ID). Para cambiar de Firefly, cierras la sesión con `/flush`.
- **Añadir o quitar un Firefly reinicia el importer y ese Firefly** una vez, al cambiar sus redes. Hacen falta los dos `apply`, en cualquier orden: `apply firefly_importer` y `apply firefly` ([`NETWORK.md`](../NETWORK.md), apartado 6).
- **`providers: [firefly]`** es un tipo de proveedor nuevo: hasta ahora solo existía `postgres`. No cambia nada en marcha. Hace que el contrato diga la verdad, porque sin un Firefly el importer no sirve para nada. Lo que de verdad para el `plan` si falta es la comprobación del rol: «al menos un `ff-*` en `connects_to`». Supone una línea en `tests/unit/test_app_contract.py` (`PROVIDERS`), la fila del apartado 9 de [`README.md`](README.md) y el «Hoy» de R56 en [`DECISIONS.md`](../DECISIONS.md). Va en el PR del rol.
- **Se llega solo desde la propia máquina**, por un puerto en `127.0.0.1`, como Firefly y pgAdmin.
- **Lo que pediría tu navegador:** `egress` limita al contenedor, no a tu navegador. En el código, la interfaz carga sus estilos y scripts desde el propio importer (`resources/views/v2/layout/v2.blade.php`, con Vite), y la analítica Matomo solo se activa con `TRACKER_*`, que se dejan vacías. 🔍 Que no quede ninguna otra petición externa: prueba del apartado 8.

## 3. Cómo llega a Firefly

- **`FIREFLY_III_URL`** es la dirección de Firefly **vista desde el contenedor del importer**: `http://<entorno>-ff-<instancia>:8080`, por la red de la pareja. Como dice la documentación de configuración, `localhost` y `127.0.0.1` serían el propio contenedor del importer.
- **`VANITY_URL`** es la dirección de ese Firefly **en tu navegador**: la primera de su `inbound.publish` (`http://127.0.0.1:18100`). Se usa para mandarte a Firefly a autorizar y en los enlaces de la interfaz. El rol la lee de `firefly_instances`: no se escribe dos veces.
- **Con varios Firefly en `connects_to`,** el rol no fija ninguna de las dos y te las pide el formulario.

## 4. Seguridad

- **Se entra con OAuth y un Client ID, sin nada en KeePassXC:**
  - En Firefly creas un cliente OAuth «no confidencial», sin contraseña, con la dirección de vuelta del importer (apartado 6.1).
  - Su **Client ID es un número y no es secreto**: va en la instancia (`client_id:`), en tu repo de datos.
  - Al pulsar «Authenticate», tu navegador va a Firefly, entras si hace falta y apruebas. Firefly devuelve un token al importer, que lo guarda **solo en su sesión**, dentro del contenedor (`TokenController.php`).
  - La sesión caduca a los 120 minutos (`SESSION_LIFETIME`). `/flush` la cierra en el momento.
- **Sin token personal.** Un token personal de Firefly no caduca y da acceso a toda su API; solo hace falta para importar sin la web (por línea de órdenes o desde una carpeta). Aquí no se usa (apartado 7).
- **Tus extractos, dentro del contenedor:** el CSV que subes y la sesión se guardan en `storage/`, en la capa propia del contenedor, sin volumen. Desaparecen cuando el contenedor se reinicia: Quadlet lo arranca con `podman run --rm --replace` y lo crea de nuevo cada vez (comprobado con el generador de Podman 4.9.3, `quadlet -dryrun`). No se ha encontrado en el código que el importer los borre al terminar de importar.
- **Sin clave de aplicación:** la de Laravel viene fija en `config/app.php`, y su comentario dice que no se usa. No hace falta un secreto `APP_KEY`.
- **Registros sin tus datos:**
  - Por defecto el `.env.example` trae `LOG_LEVEL=debug` y escribe también en un fichero diario. Aquí van a `stdout`, al journal, con `notice`.
  - `LOG_RETURN_JSON` sigue apagado: el propio fichero avisa de que vuelca muchos datos privados.
- **Contenedor endurecido**, como el resto: sin capacidades, sin privilegios nuevos y con límites (R46, R51).

## 5. Configuración

Todas las opciones: el [`.env.example` de la v2.3.5](https://github.com/firefly-iii/data-importer/blob/v2.3.5/.env.example). Se leen en cada arranque: cambiar una en el inventario y aplicar reinicia el importer con el valor nuevo.

**Por instancia, en tu inventario:**

| Ajuste de la instancia (variable) | Por defecto | Para qué |
| --- | --- | --- |
| `client_id` (`FIREFLY_III_CLIENT_ID`) | vacío: lo pide el formulario | El cliente OAuth de tu Firefly (apartado 6.1). Solo con un Firefly en `connects_to` |
| `locale` (`FALLBACK_LOCALE`) | `en_US` | Solo decide qué es un importe ambiguo como `14.000` (`app/Services/CSV/Converter/Amount.php`). Con `es_ES` es catorce mil, como lo escribe un banco español. En los demás importes el importer adivina solo. La codificación del fichero no depende de esto: si no es UTF-8, el importer la convierte (`FileReader.php`) |
| `timezone` (`TZ`) | `UTC` | Fechas y horas de sus registros; la misma que tu Firefly |
| `session_lifetime` (`SESSION_LIFETIME`) | `120` | Minutos hasta que hay que volver a autorizar |
| `ignore_duplicate_errors` (`IGNORE_DUPLICATE_ERRORS`) | `false` | Con `false`, el informe final lista los duplicados que se saltó. Con `true` no sabrías si algo falló por ser duplicado: el propio fichero lo advierte |
| `connection_timeout` (`CONNECTION_TIMEOUT`) | `31.41` | Segundos que espera a Firefly en cada petición |
| `log_level` (`LOG_LEVEL`) | `notice` | Detalle del registro. `debug` deja en el journal datos de tus movimientos: solo para depurar y un rato |
| `memory`, `cpus`, `pids_limit` | `512m`, `1`, `200` | Límites |
| `launcher`, `launcher_name`, `launcher_command` | sí, «Firefly Importer (<instancia>)», `[xdg-open]` | Su lanzador |
| `image` | `firefly_importer_image` | Otra de `images.yml`, para probar una versión |

**Fijos en el rol** (no se pueden cambiar desde el inventario):

| Variable | Valor | Por qué |
| --- | --- | --- |
| `FIREFLY_III_URL`, `VANITY_URL` | de `connects_to` y de `firefly_instances` | Apartado 3. Vacías con varios Firefly |
| `FIREFLY_III_ACCESS_TOKEN` | vacía | Sin token personal (apartado 4) |
| `LOG_CHANNEL` | `stdout` | Al journal, sin fichero dentro del contenedor |
| `LOG_RETURN_JSON` | `false` | Volcaría datos privados |
| `APP_ENV`, `APP_DEBUG` | `production`, `false` | Sin trazas con datos en el navegador |
| `EXPECT_SECURE_URL` | `false` | Firefly va por HTTP dentro de la red de la pareja |
| Fuentes bancarias: `NORDIGEN_*`, `ENABLE_BANKING_*`, `SIMPLEFIN_*`, `LUNCH_FLOW_*`, `SOPHTRON_*`, `SPECTRE_*` | vacías | Sin conexión con el banco |
| `ENABLE_MAIL_REPORT`, `MAIL_MAILER` | `false`, `log` | Sin correo y sin salida |
| `CAN_POST_AUTOIMPORT`, `CAN_POST_FILES`, `AUTO_IMPORT_SECRET`, `IMPORT_DIR_ALLOWLIST`, `JSON_CONFIGURATION_DIR` | apagadas o vacías | Solo desde la web (apartado 7) |
| `TRACKER_SITE_ID`, `TRACKER_URL` | vacías | Sin analítica en tu navegador |
| `FAKE_DATA`, `STORE_FAKE_DATA` | `false` | Son para desarrollar el importer |

Lo demás se deja como viene: `TRUSTED_PROXIES` (no hay proxy), `ASSET_URL`, `USE_CACHE` y `APP_URL` (su comentario dice que no se usa).

## 6. Importar extractos, paso a paso

Así se usa, banco a banco. Las pantallas son las del importer v2.3.5 y la [guía oficial de CSV](https://docs.firefly-iii.org/tutorials/data-importer/csv/). Los ajustes de cada pantalla se explican en [importar un fichero](https://docs.firefly-iii.org/how-to/data-importer/import/file/) y los papeles de cada columna en [roles](https://docs.firefly-iii.org/references/data-importer/roles/).

### 6.1. Una sola vez: el cliente OAuth en Firefly

1. Abre Firefly (`127.0.0.1:18100`) y, en tu perfil, la sección OAuth. Crea un cliente nuevo 🔍 (los nombres exactos del menú, en DEV):
   - **Nombre:** el que quieras, por ejemplo `ffimport-laptop`.
   - **Dirección de vuelta (redirect URL):** `http://127.0.0.1:<puerto del importer>/callback`. En el portátil, `http://127.0.0.1:18115/callback`.
   - **«Confidential»: desmarcado.** Si se queda marcado, Firefly devuelve una página que solo dice «Empty» (FAQ oficial).
2. Copia el **Client ID** (un número) en tu instancia: `client_id: <número>`. Aplica (apartado 8).

### 6.2. La primera vez con cada banco (o cada cuenta)

1. **Mira si alguien ya lo hizo:** el repositorio oficial [import-configurations](https://github.com/firefly-iii/import-configurations) tiene JSON aportados por usuarios, por país y banco. De España (carpeta `es`): `caixabank`, `cajasur` y `n26`. Sirven de punto de partida: el JSON nombra cuentas por su número interno en el Firefly de quien lo hizo, así que en el paso de mapeo las cambias por las tuyas.
2. **Descarga el extracto** de la web del banco en CSV, o en CAMT.053 (XML) si lo da: el importer acepta las dos cosas.
3. **Revisa el fichero antes de subirlo**, como pide la guía oficial: quita las líneas que haya por encima de los datos, como el nombre del titular o el saldo, y las cabeceras repetidas a mitad del fichero. Si tu banco siempre las pone, lo apuntas en tu nota de ese banco (paso 9).
4. **Abre el lanzador** «Firefly Importer (laptop)». Si la sesión caducó, pulsa «Authenticate»: vas a Firefly, entras si hace falta, apruebas y vuelves.
5. **Elige importar un fichero** y **sube el CSV**. Si tienes un JSON de partida (paso 1), súbelo junto al CSV; si no, sigue sin él.
6. **Configura el fichero:**
   - **Cabecera (*Headers*):** márcala si la primera línea tiene los nombres de las columnas.
   - **Delimitador:** en España suele ser el punto y coma.
   - **Formato de fecha** en la [notación de PHP](https://www.php.net/manual/en/datetime.format.php): `d/m/Y` para `17/09/2026`, `Y-m-d` para `2026-09-17`. Para meses escritos en español, con el prefijo de idioma: `es:d F Y`.
   - **Cuenta por defecto (*Default import account*):** tu cuenta de Firefly de ese banco. Se usa cuando el fichero no dice de qué cuenta es cada movimiento, que es lo normal en un extracto.
   - **Reglas (*rules*):** márcalo para que Firefly aplique tus reglas a lo importado (por ejemplo, poner categorías).
   - **Etiqueta de importación (*add import tag*):** márcalo siempre. Cada importación lleva su etiqueta, y si sale mal la deshaces de golpe (apartado 6.5).
   - **Duplicados:** «por contenido» (*content-based*), salvo que el banco dé una columna con una referencia única de cada movimiento; entonces, «por identificador» con esa columna (apartado 6.6).
7. **Di qué es cada columna (*roles*):**
   - **Fecha:** la fecha del movimiento (*Transaction date*). Si hay fecha valor, puede ir como otra fecha.
   - **Descripción:** el concepto (*Description*).
   - **Importe:**
     - Si viene en una columna con signo, *Amount*.
     - Si viene en dos columnas, *Amount (debit)* para los cargos y *Amount (credit)* para los abonos.
     - Si tu banco pone los cargos en positivo, *Amount (negated)*.
   - **La otra parte:** el nombre de la contraparte (*Opposing account name*) y su IBAN (*Opposing account IBAN*), si los da.
   - **El saldo** y lo que no sirva: *Ignore this column*.
8. **Relaciona valores con lo que ya tienes en Firefly (*mapping*):** por ejemplo, que el texto «NOMINA EMPRESA SL» de la columna de contraparte sea siempre tu cuenta de ingresos «Empresa». Lo que no relaciones, Firefly lo busca por nombre y, si no existe, lo crea. Con el JSON de otra persona, aquí cambias sus cuentas por las tuyas.
9. **Descarga la configuración** (el importer ofrece descargarla durante y después de la importación) y guárdala en tu repo de datos (apartado 6.4). Si tu banco tiene manías, como cabeceras extra que hay que quitar a mano, apúntalo en un `<banco>-<cuenta>.md` al lado del JSON.
10. **Convierte y envía:** el importer convierte las líneas en movimientos y te enseña los errores. Después los envía a Firefly. Al terminar verás un informe: cuántos movimientos ha creado, cuántos duplicados se ha saltado y cualquier error.
11. **Comprueba en Firefly** que el saldo de la cuenta cuadra con el del extracto. Si no cuadra, apartado 6.5.

### 6.3. Cada extracto, después

1. Descarga el CSV del banco y, si tu nota de ese banco lo dice, quita las líneas de más.
2. Lanzador → «Authenticate», si la sesión caducó.
3. Sube **el CSV y su JSON** de `ff-importer-json/`. Los pasos 6 a 8 salen ya rellenados: solo los revisas y avanzas.
4. Convierte, envía y lee el informe. Puedes solapar periodos: lo que ya estaba se salta (apartado 6.6).
5. Si cambiaste algo de la configuración, descarga el JSON nuevo y sustituye el antiguo.
6. **Borra el CSV de tu carpeta de descargas:** es un extracto bancario, y lo que necesitas ya está en Firefly y en el JSON.
7. Cierra la pestaña. Si quieres cerrar la sesión en el momento, abre `/flush`. El contenedor sigue en marcha: no hay que pararlo.

### 6.4. Dónde guardar los JSON

En tu repo de datos, en la carpeta **`ff-importer-json/`** de su raíz, al lado de `inventory/`. Por ejemplo: `~/infra-podman-data/ff-importer-json/caixabank-nomina.json`.

- **Nunca dentro de `inventory/dev/` ni de `inventory/prod/`:** Ansible lee como inventario todo lo que hay ahí, también los `.json`, y el `plan` fallaría.
- **Es un sitio privado, con historia y con copias:** el repo vive en el disco cifrado, sin remoto, con commits firmados (SPEC 4.13). Los JSON no tienen secretos, pero sí nombres de comercios y contrapartes, así que no deben acabar en un sitio público.
- **Haz commit firmado** de cada JSON nuevo o cambiado. `deploy.sh` exige en producción el repo de datos limpio.
- **El JSON entra en las copias con el siguiente despliegue que salga bien:** las copias se hacen de la copia del repo que deja `deploy.sh` (SPEC 4.11, R43).
- **Al reinstalar en otro sitio:**
  - Si restauras Firefly desde las copias, sus cuentas conservan los números y los JSON valen tal cual.
  - Con un Firefly vacío, rehaces solo el paso de mapeo y descargas el JSON nuevo.
  - Si cambia la versión del importer, los JSON llevan su número de versión y el importer los pone al día.

### 6.5. Deshacer una importación

Si una importación sale mal (fecha mal leída, importes con el signo cambiado), en Firefly abre la etiqueta de esa importación y borra sus movimientos, corrige la configuración e importa de nuevo. Ojo: los movimientos borrados **también cuentan como duplicados** (apartado 6.6). Para volver a importarlos, primero purga los borrados desde tu perfil de Firefly, como dice la guía de [duplicados](https://docs.firefly-iii.org/how-to/data-importer/import/duplicates/).

### 6.6. Duplicados

- **Por contenido (lo normal):** el importer prepara cada movimiento y Firefly calcula una huella de su contenido. Si ya tiene uno con la misma huella, no lo crea y avisa. Por eso puedes subir extractos que se solapan, o el mismo dos veces.
- **Lo que hay que saber:**
  - **Dentro de un mismo fichero,** dos líneas idénticas (dos cafés iguales, el mismo día y con el mismo concepto) se tratan como duplicadas y se salta la segunda. Si tu banco puede repetir líneas legítimas, desmarca *ignore duplicate lines* en ese JSON.
  - **Los movimientos borrados también cuentan** (apartado 6.5).
  - **Si el banco cambia cómo escribe un movimiento** (el concepto o los decimales) entre dos extractos, la huella cambia y puede colarse uno repetido.
  - **Una transferencia entre dos cuentas tuyas** aparece en el extracto de cada banco. No es un duplicado: se importa como transferencia siguiendo la [guía de transferencias](https://docs.firefly-iii.org/how-to/data-importer/import/transfers/).
- **Por identificador:** si el banco da una referencia única por movimiento, eliges esa columna y el importer compara por ella. Es más fiable, pero solo si la referencia no cambia entre extractos.

## 7. Lo que no se hace

- **Importar desde una carpeta o por línea de órdenes** (`importer:auto-import`, `importer:import`). Necesita un token personal de Firefly, un volumen donde dejar los ficheros y un temporizador. Además, no borra ni mueve los ficheros al terminar. Y obliga a que tus ficheros lleguen a un contenedor de `svc_runner`, que es el tema abierto de «Aplicaciones de escritorio». Queda en el [`ROADMAP.md`](../ROADMAP.md).
- **Una carpeta de JSON montada en el contenedor** (`JSON_CONFIGURATION_DIR`), para elegirlos en un desplegable: es el mismo problema. Los JSON se suben a mano junto al CSV.
- **Conexión directa con el banco:** se decide aparte.

## 8. Instalación: lo propio del importer

El orden general está en [`INSTALL.md`](INSTALL.md). Lo del importer, cuando llegue el momento:

1. **Firefly ya funciona** en esa máquina, con su instancia (por ejemplo `ff-laptop`).
2. **El cliente OAuth** en ese Firefly (apartado 6.1), con la dirección de vuelta del puerto que vayas a usar.
3. **Repo de datos**, `group_vars/firefly_importer_hosts.yml` (y la máquina en el grupo `firefly_importer_hosts` de `hosts.yml`). Sin secretos en `infra_secrets`: no tiene ninguno.
   ```yaml
   firefly_importer_instances:
     - name: laptop
       networking:
         inbound:
           publish: ["127.0.0.1:18115:8080"]   # Firefly usa el 18100 y pgAdmin el 18110
         connects_to: [ff-laptop]              # uno o varios Firefly de esta máquina
       client_id: 2                            # el de tu cliente OAuth (un número; no es secreto)
       locale: es_ES
       timezone: Europe/Madrid
       launcher_command: [flatpak, run, org.mozilla.firefox, --new-window]
   ```
   En una máquina sin escritorio, como la VM de DEV, `launcher: false`. Los nombres de los ajustes son los de este documento; si el PR del rol cambia alguno, lo dice.
4. **`./deploy.sh plan firefly_importer`** y **`apply firefly_importer`**. Después **`plan firefly`** y **`apply firefly`**. Ese segundo `apply` **reinicia Firefly** una vez, unos segundos, al unirlo a la red de la pareja.
5. **Primer acceso**, desde el lanzador: «Authenticate», apruebas en Firefly y vuelves al importer.
6. **Prueba con un fichero falso (DEV):** un CSV inventado de tres líneas con una cuenta de prueba. Impórtalo dos veces: la segunda no debe crear nada (apartado 6.6). Es la prueba de duplicados de [`firefly.md`](firefly.md), apartado 6.
7. **Prueba de que nada sale (DEV, dos minutos):** abre las herramientas del navegador, pestaña «Red», recarga el importer y haz una importación. Ninguna petición puede ir a un dominio que no sea `127.0.0.1`.

**Si algo sale mal y quieres empezar de cero:** no hay datos ni secretos que perder. `--retire` y `apply` de nuevo; si el cliente OAuth está mal (la dirección de vuelta, «Confidential»), bórralo en Firefly y créalo otra vez, con su nuevo Client ID en la instancia.

## 9. Actualizaciones y copias

- **Actualizaciones**, como las demás imágenes: digest fijo, aviso semanal de `image-updates`, PR, DEV y producción. **Lee las notas de cada versión antes de subir:** las v2.3.1 a v2.3.3 avisaban de que podían aparecer duplicados por cambios internos (`changelog.md`). Una actualización no migra datos: no tiene. El importer no busca versiones nuevas por sí mismo.
- **Copias:** nada que copiar. Lo que importa son tus JSON, que viven en tu repo de datos (apartado 6.4), y los movimientos, que están en la base de Firefly.
- **Retirar y purgar**, como cualquier instancia ([`README.md`](README.md), apartado 7). Al retirarlo, el siguiente `apply firefly` quita la red de la pareja y reinicia Firefly una vez.
