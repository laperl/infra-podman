# Firefly III: requisitos (fase 2)

Qué tiene que cumplir Firefly III antes de escribir su código. Es una propuesta: lo que esté aquí y no en SPEC, sección 3, se aprueba con este PR. Lo marcado 🔍 se verifica en DEV durante la fase y el PR que lo verifique lo deja escrito.

Ahí van tus finanzas. Por eso el principio es: **Firefly no puede enviar nada fuera del portátil**, y eso lo garantiza la red, no un ajuste de la aplicación.

**Usa la Postgres de la plataforma:** la instancia `main` del portátil (`prod-pg-main`). Sin base propia dentro del contenedor, sin SQLite y sin otra instancia de Postgres.

Este documento dice solo lo propio de Firefly. Lo común (nombres, secretos, backups, red, Postgres) está en SPEC y en [`POSTGRES.md`](../POSTGRES.md), y aquí solo se enlaza.

## 1. Uso

| Tema | Decisión |
| --- | --- |
| Usuarios | Uno: el operador |
| Desde dónde | Solo desde el navegador del portátil (`127.0.0.1`). El móvil queda para más adelante (apartado 8) |
| Cómo entran los datos | A mano y con extractos del banco en CSV. Sin conexión con el banco. El Data Importer de Firefly queda para más adelante (ROADMAP) |
| Monedas | Euros y dólares. Los tipos de cambio se meten a mano, porque los automáticos van por internet |
| Criptomonedas | Solo si es fácil y estándar: crearla como una moneda más (por ejemplo, `BTC`) y anotar los saldos a mano, sin cotizaciones automáticas. 🔍 Cuántos decimales admite Firefly (bitcoin usa 8) |
| Justificantes | Los ficheros que adjuntas a un movimiento (la foto de un ticket, el PDF de una factura). Firefly los guarda en un volumen propio, que entra en el backup (apartado 5) |

## 2. Red: sin salida a internet

- **Firefly está en una red de Podman interna**, sin salida, cuyo único otro miembro es su Postgres: `prod-firefly-pg-main-net` ([SPEC](../SPEC.md) 4.4, 4.12). Ni internet, ni la red de casa, ni otros contenedores.
- **Se llega a él solo desde el portátil**, por un puerto en `127.0.0.1`. Cómo se publica un puerto sin dar salida a internet al contenedor se decide en el diseño 🔍 (una red interna no admite puertos publicados en Podman sin root).
- **Se prueba en `lifecycle`**, que comprueba que desde el contenedor de Firefly:
  - no se llega a una IP pública;
  - no se resuelve un nombre de internet;
  - no se llega a otra red de la plataforma.
- **Segunda capa, por si un día se abre la red por error:** todo lo que Firefly podría enviar fuera, apagado.

  | Ajuste | Qué haría si estuviera encendido |
  | --- | --- |
  | `ENABLE_EXTERNAL_RATES=false` | Descargar tipos de cambio de un almacén en Azure del autor |
  | `ENABLE_EXTERNAL_MAP=false` | Cargar un mapa externo para ubicar movimientos |
  | `ALLOW_WEBHOOKS=false` | Enviar avisos a otras direcciones |
  | Sin `MAIL_*` | Enviar correos, incluidos informes con movimientos |
  | Sin `TRACKER_*` | Analítica (Matomo) |
  | Comprobación de versiones, apagada en la administración 🔍 | Consultar GitHub. De las versiones nuevas ya avisa `image-updates` |

## 3. Seguridad

- **Acceso:**
  - registro cerrado tras crear tu usuario;
  - doble factor (TOTP) obligatorio, con KeePassXC;
  - sesiones con caducidad.
- **Secretos** en KeePassXC, grupo de la instalación, pasados como secretos de Podman. Firefly lee del fichero las variables terminadas en `_FILE`:
  - `firefly-app-key`: `APP_KEY`, exactamente 32 caracteres. Si se pierde, se pierden las sesiones; va en KeePassXC como cualquier otro secreto;
  - `firefly-cron-token`: `STATIC_CRON_TOKEN`, 32 caracteres;
  - `pg-main-firefly-password`: la contraseña de su usuario de Postgres (`firefly`).
- **Contenedor endurecido**, como el resto:
  - sin root (`www-data`) y sin capacidades extra;
  - con límites de memoria, CPU y procesos, y healthcheck;
  - imagen por digest, que existe para `linux/amd64` y `linux/arm64`.
- **Logs sin datos financieros:** `APP_DEBUG=false` y nivel de log bajo. El registro de auditoría de Firefly, activo.
- **Postgres** (según [`POSTGRES.md`](../POSTGRES.md)):
  - una base `firefly` con su esquema `firefly` y sus grupos `firefly_owner`, `firefly_writer` y `firefly_reader` (R35, R36);
  - Firefly migra sola, así que usa un único usuario, `firefly`, en `firefly_owner` (`POSTGRES.md`, tabla de usuarios);
  - 🔍 que Firefly cree sus tablas en el esquema `firefly`: la base no tiene esquema `public`;
  - `pg_hba` generado: cada usuario, solo en su base y solo desde la red de Firefly.

## 4. Actualizaciones

- **Igual que las demás imágenes:**
  1. digest fijo;
  2. aviso semanal de `image-updates`;
  3. PR;
  4. DEV y producción, con `--limit`.

  Nunca se actualiza sola.
- **Antes de cambiar la imagen, una copia de la base**, como ya hace Postgres (`reason=pre-upgrade`). Una versión nueva cambia la estructura de la base al arrancar, y no se vuelve atrás solo con la imagen: volver atrás es restaurar la base más la imagen anterior.
- **`image-updates` tiene que reconocer las etiquetas con versión de Firefly** 🔍 (si llevan prefijo, como `version-6.x.y`, hoy no las vería).
- **Las tareas programadas de Firefly** (movimientos recurrentes, presupuestos automáticos y avisos de facturas), con un temporizador diario de `svc_runner` que lanza `php artisan firefly-iii:cron` dentro del contenedor. Sin red añadida.

## 5. Copias y restauración

- **La base `firefly`** entra sola en el backup diario: se vuelcan todas las bases.
- **El volumen de justificantes** entra en el backup y en la copia al GX10. Es el pendiente «Copia de los volúmenes de las aplicaciones» del ROADMAP.
- **Restaurar**, probado en `lifecycle` y escrito en [`OPERATIONS.md`](../OPERATIONS.md): la base y los justificantes, desde la copia local y desde la del GX10. Con los permisos de la base repuestos por Ansible (pendiente «Restaurar bases de aplicaciones»).
- **Conservación:** 7 diarias, 12 mensuales y 5 anuales. Hacienda puede revisar 4 años, así que da para los justificantes de la declaración.

## 6. Lo que importa para las cuentas

- **Cuadre con el banco:** conciliar cada cuenta con el saldo del extracto. Es lo que dice que no falta ni sobra nada.
- **Duplicados:** importar el mismo CSV dos veces no duplica movimientos. Se prueba en DEV con un fichero falso.
- **Datos de prueba siempre falsos** en DEV y en el CI. Nunca un extracto real fuera del portátil de producción.

## 7. La IA local, más adelante (fases 4 y 5)

En la fase 2 solo se deja listo el grupo `firefly_reader` y se prueba que no puede escribir. El resto se diseña en su fase. Requisitos desde ya:

- **Solo lectura, garantizada por la base y no por la IA.** Entra con un usuario propio del grupo `firefly_reader`, nunca con el usuario `firefly` ni con un token de su API, que da acceso a todo 🔍.
- **Que vea solo lo necesario:** unas vistas preparadas (movimientos, categorías, saldos), no toda la base, que tiene usuarios, tokens y sesiones.
- **Nunca un modelo externo.** LiteLLM, en el GX10, apunta también a IAs de fuera. Lo que lea datos de Firefly solo puede llegar a vLLM local:
  - con su propia ruta o clave, limitada a los modelos locales 🔍;
  - y sin salida a internet en su red.

  Un nombre de modelo equivocado no puede acabar en un proveedor externo.
- **Nada guardado en el GX10.** Su disco no está cifrado. Por Tailscale los datos viajan cifrados, pero ni vLLM ni LiteLLM pueden guardar en logs lo que preguntes ni lo que responda 🔍.

## 8. El móvil, si algún día lo quieres

Lo que supondría:

- **Firefly visible en tu red de Tailscale** con `tailscale serve`, en HTTPS. Firefly seguiría sin salida a internet: `serve` solo deja entrar.
- **Lo vería cualquier dispositivo de tu Tailscale**, salvo que se limite con las reglas de acceso de Tailscale. El doble factor pasa a ser imprescindible.
- **Si pierdes el móvil**, quien lo tenga desbloqueado entra en tu red y en las sesiones abiertas. Habría que caducar sesiones y poder quitar el móvil de Tailscale enseguida.
- **Las apps de móvil para Firefly son de terceros.** El navegador del móvil es lo más simple.

Queda en el ROADMAP. No entra en la fase 2.
