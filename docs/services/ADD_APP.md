# Añadir una aplicación nueva

El procedimiento para que una persona o una IA, la que sea, añada una aplicación a la plataforma. Es una lista ordenada: cada paso dice qué fichero se toca y enlaza al único sitio donde está la regla. Aquí no se repite ninguna regla.

- **Quién lo usa:** el operador le da este fichero a su IA con la aplicación que quiere (apartado 6).
- **El modelo es el rol `firefly`:** lo que no sepas cómo se escribe, míralo en `roles/firefly/` y `playbooks/firefly.yml`. No hay rol esqueleto: sería una segunda copia que mantener.
- **Podman sin root y Quadlet, no Docker:** la documentación oficial de casi todas las aplicaciones está escrita para Docker. Antes de copiar una orden o un `docker-compose.yml`, lee el apartado 2.
- **Reglas del repo:** [`CLAUDE.md`](../../CLAUDE.md), que valen para cualquier IA. Solo PRs en borrador, nada inventado y cero secretos.

## 1. Antes de escribir nada: la ficha

Rellénala **solo con la documentación oficial** de la aplicación y cita la URL de cada dato. Lo que no encuentres, déjalo en «no verificado»: no lo supongas. Enséñasela al operador y **espera su aprobación**.

| Dato | Qué hay que saber |
| --- | --- |
| Nombres | De código (`^[a-z][a-z0-9_]*$`, el del rol) y corto, de 2 a 8 letras ([`NAMING.md`](../NAMING.md), apartado 2) |
| Imagen | Registro, nombre, versión y **digest** del índice (SPEC, D6), y que tenga `linux/amd64` y `linux/arm64`. Sin suscripción ni registro de pago. Si no llegas al registro, déjalo en «no verificado» y dale al operador las dos órdenes: `skopeo inspect --raw docker://<repositorio>:<versión> \| sha256sum` (el digest) y `skopeo inspect --raw docker://<repositorio>:<versión> \| jq -r '.manifests[].platform \| "\(.os)/\(.architecture)"'` (las arquitecturas). Sin el digest no se escribe `images.yml` |
| Actualizaciones | La etiqueta que seguirá `# track:`: una versión exacta con la forma que entiende `scripts/image-updates.sh` (cabecera de `images.yml`), nunca una que se mueve. Si una versión nueva migra los datos sin vuelta atrás. Si la aplicación busca sola versiones nuevas o manda telemetría, cómo se apaga: de las versiones avisa la plataforma (workflow `image-updates`, un correo cada lunes) |
| Usuario del contenedor | Con qué UID corre **dentro** del contenedor, si arranca como root para cambiar de usuario, y si vale con `ReadOnly=true`, sin capacidades y sin privilegios nuevos. Cómo queda en Podman sin root: apartado 2. Si no vale, hace falta una excepción aprobada (SPEC 4.14, R51) |
| Contrato | ¿Guarda datos en Postgres? ¿Con qué otros contenedores habla? ¿Necesita salir a internet? ([`README.md`](README.md), apartado 9) |
| Entrada | Puerto interno (1024 o más: apartado 2) y protocolo. Qué responde cuando está sana (orden o URL del healthcheck) y si esa orden (`curl`, `wget`…) existe dentro de la imagen |
| Lanzador | Si el operador la abre desde el escritorio: lleva un lanzador en su menú, como Firefly (SPEC 4.14, R47) |
| Datos | Qué directorios guardan datos (serán volúmenes) y cuáles pueden ser `tmpfs` |
| Secretos | Cuáles necesita y si los lee de un fichero (`*_FILE`) o solo de una variable |
| Copias | Qué hay que copiar además de su base: volúmenes enteros o una orden propia de la aplicación ([`README.md`](README.md), apartado 8) |
| Primer arranque | Migraciones, usuario inicial, tareas programadas |
| Recursos | Memoria, CPU y procesos razonables |
| Lo que no encaja | Red del host, GPU, dispositivos, ventana propia: está fuera del contrato; para y dilo |

**Para y pregunta** si la aplicación pide `egress: true`, un proveedor que no sea Postgres, una excepción al endurecimiento, entrar en Postgres con el superusuario o en bases que no son suyas (como pgAdmin, R37: hoy `pg_hba` solo abre los usuarios de una base declarada, [`NETWORK.md`](../NETWORK.md)), o cualquier cosa de SPEC, sección 7: son decisiones del operador. Las redes ya tienen plantilla común: la de salida (`egress.network.j2`) y la de una pareja de `connects_to` (`pair.network.j2`), en `roles/quadlet_deploy/templates/` ([`NETWORK.md`](../NETWORK.md)).

## 2. Podman sin root y Quadlet: lo que cambia respecto a Docker

La plataforma solo usa **Podman sin root con Quadlet** (SPEC, D1), con Podman 4.9 como mínimo. Lo que dice la documentación oficial para Docker se traduce así; lo que no puedas comprobar, a «no verificado», y lo prueba `lifecycle`.

- **Todo son unidades Quadlet**, plantillas del rol: `.container`, `.volume` y, si hace falta, `.network`. Nunca `docker run`, `podman run`, `docker-compose`, `podman-compose`, ficheros `.pod` ni `podman generate systemd`. Un `docker run` o un `docker-compose.yml` de la documentación se traduce **clave a clave**, y cada clave se comprueba en [`COMPATIBILITY.md`](../COMPATIBILITY.md). Si no existe en 4.9, va en `PodmanArgs=` solo si esa página lo permite; si no, para y dilo.
- **Los UID no son los del host.** Sin root, el root del contenedor es el usuario de servicio de la máquina, y cualquier otro UID del contenedor (el 5050 de pgAdmin, el 33 de Firefly) es un número de su rango de `/etc/subuid`. Por eso:
  - **Un `chown <uid> <carpeta>` en el host**, como piden muchas guías de Docker, no da permiso al contenedor. Los datos van siempre en volúmenes con nombre (`.volume`, con `:Z`), nunca en una carpeta del host.
  - **Un fichero que Ansible deja en el host y el contenedor monta**, como la configuración de `pg_hba.conf`, se ve dentro como de root. Si el proceso de la imagen no es root, tiene que poder leerlo igual: modo `0644`, y su carpeta `0755`. Nunca un secreto así.
  - **Los secretos se montan con el UID de dentro:** `Secret=<nombre>,type=mount,target=/run/secrets/<x>,uid=<uid>,gid=<gid>,mode=0400`, como `roles/firefly/templates/firefly.container.j2`.
  - **No cambies el usuario de la imagen** (`User=`, `UserNS=`) salvo que la ficha diga por qué.
- **Imágenes que arrancan como root y luego cambian de usuario** (`gosu`, `su-exec`, s6, las variables `PUID`/`PGID`): con `DropCapability=all` no arrancan. Necesitan `AddCapability=` con las imprescindibles, como Postgres (`roles/postgres/templates/pg.container.j2`). Ponlas en la ficha, cada una con su motivo, y pregunta.
- **Dentro del contenedor, puertos de 1024 o más.** Sin capacidades, un proceso no puede abrir el 80 ni el 443. Si la imagen escucha ahí por defecto, busca su variable de puerto; pgAdmin, por ejemplo, la documenta para este caso.
- **La red es la del inventario y nada más:** `PublishPort=` tal cual llega de `networking.inbound.publish`, y un `Network=` por cada red de la instancia ([`NETWORK.md`](../NETWORK.md)). Nunca la red del host, `-p` inventados ni opciones de slirp4netns o pasta (SPEC 4.4).
- **Esperar a otro contenedor:** `depends_on` de Compose no existe, y `Notify=healthy` tampoco en 4.9. Se escribe `Requires=` y `After=` en `[Unit]`, más la espera con `ExecStartPre` hasta que el otro pasa su healthcheck, como Firefly (SPEC 4.3).
- **Las órdenes de la documentación** (`docker exec`, `docker logs`) son en la máquina `svc podman exec …` y `sudo journalctl _SYSTEMD_USER_UNIT=<unidad>.service -n 50` ([`OPERATIONS.md`](../OPERATIONS.md), [`TROUBLESHOOTING.md`](../TROUBLESHOOTING.md)). En la página de la aplicación se escriben así.

## 3. Los ficheros, en orden

`<app>` es el nombre de código y `<corto>` el nombre corto.

| # | Fichero | Qué se hace | La regla está en |
| --- | --- | --- | --- |
| 1 | `docs/NAMING.md`, apartado 2 | Fila con el nombre corto | Ese apartado y su lista del 9 |
| 2 | `playbooks/group_vars/all/images.yml` | `<app>_image`, por digest y con su `# track:` | SPEC, D6; la cabecera de ese fichero |
| 3 | `roles/<app>/defaults/main.yml` | `<app>_short`, `<app>_contract`, `<app>_id`, nombres compuestos desde la instancia, sus parejas (`<app>_pairs` con el filtro `pairs_of`, `<app>_pair_networks` y `<app>_pair_units`, como en `roles/firefly`; la red de una pareja con Postgres la instala el rol `postgres`, así que en `<app>_pair_units` solo van las demás), `<app>_quadlet_units`, lo que se puede copiar (`<app>_backup_available`) y los valores por defecto de cada ajuste | `README.md`, apartados 1, 8 y 9; `NAMING.md`; [`NETWORK.md`](../NETWORK.md) |
| 4 | `roles/<app>/templates/` | `.container` y sus `.volume`: nombres explícitos, cuatro etiquetas, endurecimiento, límites, healthcheck, secretos como fichero con el UID de dentro, `PublishPort=` tal cual viene de `networking.inbound.publish`, un `Network=` por cada red de `<app>_pair_networks` y, si usa Postgres, la espera a que esté sana. Si la abre el operador, su `.desktop` | Apartado 2; SPEC 4.2 a 4.5 y 4.14; [`COMPATIBILITY.md`](../COMPATIBILITY.md) (solo claves de Podman 4.9) |
| 5 | `roles/<app>/tasks/` | `checks.yml` (rechazos claros; secretos con `podman_secrets`), `main.yml` (`connects_to` con `connects_to_problems` y, si usa Postgres, `pg_hba` con `pg_hba_problems`; unidades con `quadlet_deploy`, pasándole `quadlet_deploy_pair_owner` y `quadlet_deploy_pair_networks`; copias con `roles/backup/tasks/app_items.yml`; temporizadores con `user_units`, como `cron.yml`), `launcher.yml` (el lanzador, si lo lleva), `purge.yml` (sin las redes de sus parejas) | Los mismos ficheros de `roles/firefly/tasks/`; [`NETWORK.md`](../NETWORK.md) |
| 6 | `roles/<app>/meta/main.yml` y `roles/<app>/CLAUDE.md` | Licencia `GPL-3.0-or-later`. `CLAUDE.md` corto: qué leer, qué no se toca y qué tests tiene | [`CLAUDE.md`](../../CLAUDE.md), «Dónde va cada cosa nueva» |
| 7 | `playbooks/<app>.yml` | Un despliegue por elemento de `<app>_instances`, con `<app>_retire` y `<app>_purge` (así `deploy.sh` acepta `--retire` y `--purge`) | `playbooks/firefly.yml`; SPEC 4.10 |
| 8 | `playbooks/group_vars/all/apps.yml` | Línea `<app>: <corto>` en `infra_apps`: con ella sus instancias salen en `check` y otras pueden nombrarlas en `connects_to` | La cabecera de ese fichero |
| 9 | `tests/quadlet/ci_vars.yml` y `tests/quadlet/golden/` | Una instancia `ci`; después `tests/quadlet/run.sh --update-golden` y **revisar el diff**: solo deben aparecer las unidades nuevas | Cabecera de `tests/quadlet/run.sh` |
| 10 | `tests/lifecycle/` y `.github/workflows/lifecycle.yml` | `check-<app>.sh`, sus variables y su job: rechazos, plan, apply, reaplicar sin cambios, salud, aislamiento, retirar y purgar | `check-firefly.sh` y el job `firefly` |
| 11 | `inventory.example/{dev,prod}/` | Grupo `<app>_hosts` en `hosts.yml`, `group_vars/<app>_hosts.yml` con ejemplo comentado, sus secretos en `infra_secrets` con `readers:`, y la fila de `README.md` | `README.md`, apartado 5; [`SECRETS_INVENTORY.md`](../SECRETS_INVENTORY.md) |
| 12 | `docs/services/<app>.md` | Solo lo propio: uso, red, seguridad, actualizaciones, copias. Con las URL oficiales de la ficha | La forma de [`firefly.md`](firefly.md) |
| 13 | Tablas de los demás documentos | Una fila en `README.md` (apartado 9), `ARCHITECTURE.md`, `OPERATIONS.md` (apartados 1 y 4), `SECRETS_INVENTORY.md`, y una sección en `TROUBLESHOOTING.md`. Sin copiar textos entre ellos | [`CLAUDE.md`](../../CLAUDE.md) |

Si usa Postgres, el rol **no crea** ni la base ni el usuario ni la red: el operador declara la base y el usuario en `postgres_hosts.yml`, y en la instancia `connects_to` y `pg_hba`; los crea el rol `postgres` ([`POSTGRES.md`](../POSTGRES.md), apartado 6; [`NETWORK.md`](../NETWORK.md)). El rol de la aplicación solo comprueba que existen.

## 4. Comprobar

Todo esto tiene que pasar antes de entregar. Son las mismas órdenes del CI:

```bash
yamllint --strict .
ansible-lint
git ls-files -z -- '*.sh' deploy.sh | xargs -0 --no-run-if-empty shellcheck
python3 -m unittest discover -s tests/unit -v
tests/quadlet/run.sh
tests/deploy/run.sh && tests/images/run.sh
```

- `tests/unit/test_app_contract.py` falla si falta el contrato, su fila en `README.md`, la línea de `infra_apps` o si las unidades no cuadran con lo declarado: es lo que dice si la aplicación está bien añadida.
- Lo que no hayas podido ejecutar (por ejemplo `lifecycle`, que necesita systemd), dilo: no lo des por probado.

## 5. Entregar

- **Varios PR pequeños, en este orden**, cada uno verde por sí solo: (a) ficha y página de la aplicación; (b) imagen, rol, playbook, unidades y tests; (c) `lifecycle` y el resto de documentos.
- Cada entrega dice **«Probado y no probado»** ([`WORKFLOW.md`](../WORKFLOW.md), «Si una IA escribe el cambio y otra lo aplica»).
- La prueba en una máquina la hace el operador: `./deploy.sh plan <app> --env dev`, `apply`, y `./deploy.sh plan check --env dev`, que debe acabar en `RESUMEN: todo correcto`. Lo que tiene que escribir en su inventario va en la página de la aplicación.

## 6. Cómo se lo pides a tu IA

Vale con cualquier modelo que pueda leer el repo y ejecutar órdenes en él. Con Podman 4.9 o posterior instalado puede ejecutar también `tests/quadlet/run.sh`.

```text
Lee CLAUDE.md y docs/services/ADD_APP.md de este repo y síguelos al pie de la letra.
Quiero añadir la aplicación: <nombre y URL de su documentación oficial>.
Empieza por la ficha del apartado 1 y para: no escribas código hasta que la apruebe.
```

- **Claude Code** lo encuentra solo como skill `add-app` (`.claude/skills/add-app/SKILL.md`, que solo manda aquí): «añade la aplicación X».
- **Otras herramientas** leen `AGENTS.md`, en la raíz, que manda a `CLAUDE.md`.
- **Un modelo sin acceso al repo** (un chat): dale este fichero, `CLAUDE.md`, `docs/services/README.md`, `docs/NAMING.md` y la carpeta `roles/firefly/`. Podrá escribir, pero no probar: las órdenes del apartado 4 las ejecutas tú.
