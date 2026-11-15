# Aplicaciones: lo común a todas

Cómo es **cualquier** aplicación de la plataforma (Firefly III, pgAdmin y las que lleguen). Para instalar una, el paso a paso está en [`INSTALL.md`](INSTALL.md). Lo propio de cada una está en su página de esta carpeta, por ejemplo [`firefly.md`](firefly.md); aquí solo lo que todas comparten. La regla sale de R48 ([`DECISIONS.md`](../DECISIONS.md)) y los nombres, de SPEC 4.12.

## 1. Instancias

**Cada aplicación se despliega por instancias**, aunque solo haya una. Una instancia es una copia completa e independiente de la aplicación, con su nombre: por ejemplo `casa` para tu uso diario, `canary` para probar una versión nueva antes de pasarla a `casa`, o `test` para probar con datos falsos.

**Una instancia no comparte nada con otra.** Ni datos, ni red, ni claves:

| Pieza | De cada instancia | Ejemplo, Firefly `casa` |
| --- | --- | --- |
| Contenedor y servicio | El suyo | `prod-ff-casa` |
| Entrada (`inbound.publish`) | La suya, si la aplicación la necesita | `127.0.0.1:18100` |
| Red e IPs | Su red interna, con su propia subred | `prod-ff-casa-pg-main-net` |
| Postgres | **Su propia base de datos**, con un único esquema del mismo nombre, y su usuario | base, esquema y usuario `ff_casa` |
| Imagen | La que elijas de `images.yml` | `firefly_image` |
| Volumen | El suyo | `prod-ff-casa-uploads` |
| Secretos | Los suyos | `ff-casa-app-key`, `ff-casa-db-password` |
| Tareas programadas | Las suyas | `prod-ff-casa-cron.timer` |
| Lanzador del menú | El suyo, con su navegador | «Firefly III (casa)» |
| Copias | Su base, en sus propias copias (`pgdump/ff_casa`) | — |

## 2. Postgres: una base por instancia, nunca un esquema compartido

- **Varias aplicaciones, y varias instancias de la misma, pueden usar la misma Postgres** (por ejemplo `pg-main`).
- **Dentro de ella, cada instancia tiene su propia base de datos.** Cada base tiene un solo esquema, que se llama como ella, y sus tres grupos (`<base>_owner`, `_writer` y `_reader`). Es el modelo de [`POSTGRES.md`](../POSTGRES.md), apartado 2.
- **Dos instancias nunca comparten base, ni siquiera con esquemas distintos.** Así:
  - una no puede ver ni siquiera la existencia de los datos de la otra;
  - cada una se copia y se restaura sola;
  - borrar una no toca la otra.
- Cada instancia puede ir a la Postgres que elijas (`pg_instance`): `canary`, por ejemplo, a una instancia `pg-test` aparte.

## 3. Nombres

La norma completa está en [`NAMING.md`](../NAMING.md); incluye la tabla de nombres cortos (`ff` es Firefly III). Para una aplicación, en resumen:
- **Tú solo escribes la instancia** (`name: laptop`). El rol compone el identificador `ff-laptop` y, de él, todo lo demás: `prod-ff-laptop`, `prod-ff-laptop-uploads`, `ff-laptop-app-key`, `ff-laptop-db-password`, la red `prod-ff-laptop-pg-<postgres>-net`, y `ff_laptop` dentro de Postgres.
- **En el código y el inventario,** la aplicación se llama por su nombre entero: `roles/firefly`, `firefly_instances`.

## 4. Puertos

- **Los escribes tú** en `inbound.publish`, una lista con el formato de Podman y Docker: `<dirección>:<puerto>:<puerto interno>`, los tres obligatorios (R55). El puerto interno es el de la aplicación dentro del contenedor y lo dice su página (Firefly: `8080`).
- **Lo habitual: `127.0.0.1` y puertos desde 18100**, uno por instancia: `18100`, `18101`… Con `127.0.0.1` solo se entra desde la propia máquina. Cualquier otra dirección abre la aplicación a esa red: lo decides tú, nada lo impide.
- **La primera de la lista** es la que abre el lanzador y la que la aplicación da en sus enlaces.
- El rol se para si dos instancias de la misma máquina repiten nombre, o dirección y puerto.
- **Desde otra máquina, por Tailscale:** `inbound.tailscale_serve`, una lista de puertos, por ejemplo `[18000]`. Ansible ejecuta `tailscale serve` como root para cada uno (rol `tailscale_serve`); ese puerto tiene que estar publicado en `127.0.0.1`. Hoy lo usa el servidor de copias (`backup_server_inbound`); una aplicación lo tendrá cuando su rol lo incluya.
- Los puertos que ya usa la plataforma están en [`ARCHITECTURE.md`](../ARCHITECTURE.md), apartado 4.

## 5. Cómo se declara

En tu repo de datos, en el grupo de la aplicación (por ejemplo `group_vars/firefly_hosts.yml`), una lista `<app>_instances` (con el nombre de código):

```yaml
firefly_instances:
  - name: casa
    inbound:
      publish: ["127.0.0.1:18100:8080"]
  - name: canary
    inbound:
      publish: ["127.0.0.1:18101:8080"]
    image: firefly_canary_image     # una variable de images.yml
    launcher_command: [flatpak, run, org.mozilla.firefox, --new-window]
```

Para cada instancia, además:

1. su base y su usuario en `postgres_hosts.yml` (`POSTGRES.md`, apartado 6);
2. sus secretos en `infra_secrets` y en KeePassXC ([`SECRETS_INVENTORY.md`](../SECRETS_INVENTORY.md)).

Lo que una instancia no dice lo toma del valor por defecto del rol (`roles/<app>/defaults/main.yml`). Escribe los ajustes **dentro de cada instancia**, nunca como variables `<app>_*` sueltas: esas mandarían sobre todas.

**El navegador del lanzador** (`launcher_command`) es una lista de palabras, sin la dirección, que la añade el rol. Solo admite letras, cifras y `._/:=@+,-`. Así no hace falta entrecomillar nada en el `.desktop` y no se puede colar una orden. Por defecto, `[xdg-open]`: tu navegador predeterminado. Vale cualquier navegador que comparta la red del portátil: Flatpak, distrobox o toolbox.

## 6. Canary y test

**Probar una versión nueva solo en `canary`:**

1. Añade su imagen a `playbooks/group_vars/all/images.yml` con otro nombre (`firefly_canary_image`), por digest, en un PR. `image-updates` la vigila como a las demás.
2. En el inventario, `image: firefly_canary_image` en la instancia `canary`.
3. `apply` de la aplicación: solo `canary` cambia de imagen, con su copia previa.
4. Si va bien, `firefly_image` pasa a ese digest en otro PR y se aplica a todas.

**`test`** es una instancia más, con datos falsos. Si quieres que ni siquiera comparta Postgres, ponle `pg_instance: test`, con su propia instancia de Postgres.

## 7. Quitar una instancia

- **Borrarla del inventario no la para ni la borra:** el `apply` solo avisa de que sigue en marcha (`left running as they are`), como Postgres.
- **Retirarla**, mientras sigue declarada: `./deploy.sh apply <app> --retire <instancia>`. Se van el contenedor, sus tareas y su lanzador. Se quedan su base, su volumen y sus secretos, y las demás instancias no se tocan.
- **Purgarla**, mientras sigue declarada: `./deploy.sh apply <app> --purge <instancia>`. La retira y después **borra** sus volúmenes y sus secretos propios. Antes copia los volúmenes en el backup de la máquina (`reason=pre-purge`, que la retención diaria no borra); si esa copia no se puede hacer, no borra nada y la instancia queda solo retirada. Escribir el nombre es la única confirmación.
- **Su base se borra aparte**, por el camino de Postgres, con su propia copia previa.

El procedimiento completo, orden por orden, está en [`INSTALL.md`](INSTALL.md), apartado 10. `<instancia>` es siempre su `name:` en el inventario ([`NAMING.md`](../NAMING.md), «De dónde sale `<instancia>`»).

## 8. Copias

- **La base de una instancia** ya está en el backup diario de su Postgres: no hay que declarar nada.
- **Lo demás lo declara el rol y lo activas tú**, por instancia, con `backup:`, una lista de nombres. Sin `backup:`, no se copia nada más. La página de cada aplicación dice qué nombres ofrece (Firefly: `uploads`).
  ```yaml
  firefly_instances:
    - name: casa
      backup: [uploads]
  ```
- **Las dos formas de copiar** ([`BACKUPS.md`](../BACKUPS.md), apartado 4), que escribe el rol de la aplicación (`roles/backup/tasks/app_items.yml`):
  - `volume`: un volumen entero, con `podman volume export`. Conserva dueños y permisos, y funciona con el contenedor parado.
  - `exec`: lo que imprime una orden dentro del contenedor en marcha. Sirve para la herramienta propia de la aplicación que saca sus datos, o para copiar solo algunos directorios con `tar`.
- **Cómo funciona:** el rol deja un fichero en `~/.config/infra-podman/backup/backup.d/` del usuario de servicio, y el backup diario de la máquina lo lee en cada ejecución. Ansible solo escribe ese fichero. Al retirar la instancia, se borra.
- **Hace falta el backup en esa máquina** (`./deploy.sh apply backup`): sin él, el fichero queda escrito y no se copia nada.
- **Restaurar un volumen:** saca la copia como cualquier otra ([`OPERATIONS.md`](../OPERATIONS.md), apartado 5; su ruta es `<app>/volume/<nombre>/<nombre>.tar`), para el contenedor y, como usuario de servicio, `podman volume import <volumen> <fichero>.tar`.

## 9. El contrato: qué es cada aplicación

Tres cosas dependen de cómo está hecha la aplicación. Las fija **su rol**, en `<app>_contract` de `roles/<app>/defaults/main.yml`, y no se cambian desde el inventario (R56). La cuarta, por dónde se entra, la escribes tú (apartado 4).

| Pregunta | En el rol | Lo que monta la plataforma |
| --- | --- | --- |
| ¿Guarda sus datos en Postgres? | `database: postgres` o `none` | Con `postgres`: su base, su usuario y su contraseña, en la instancia que elijas (`pg_instance`) |
| ¿Con qué otros contenedores habla? | `providers:`, una lista. Hoy solo existe `postgres` | Una red **interna** por cada uno, solo para los dos: sin salida a internet, a la red de casa ni al host |
| ¿Necesita salir a internet? | `egress: true` o `false` | Con `true`, además, una red con salida. Es todo o nada: limitar a qué destinos sale queda para una fase posterior |

Lo que resulta de combinarlas con la entrada:

| Caso | Base propia | Proveedores | Salida | Entrada | Red del contenedor |
| --- | --- | --- | --- | --- | --- |
| Sin red | no | ninguno | no | ninguna | `Network=none` |
| Solo entra | sí o no | los que tenga | no | uno o más puertos | Solo redes internas, con los puertos publicados desde ellas |
| Entra y sale | sí o no | los que tenga | sí | uno o más puertos | Redes internas y una con salida |
| Solo sale | sí o no | los que tenga | sí | ninguna | Redes internas y una con salida, sin puertos |

Las aplicaciones de hoy:

| Aplicación | Rol | Base propia | Proveedores | Salida | Caso |
| --- | --- | --- | --- | --- | --- |
| Firefly III | `firefly` | sí | Postgres | no | Solo entra |

- **Añadir una aplicación:** el paso a paso está en [`ADD_APP.md`](ADD_APP.md). Aquí, su fila y su `<app>_contract`; `tests/unit/test_app_contract.py` comprueba que los dos existen y que las unidades del rol cuadran con lo declarado.
- **La red con salida todavía no tiene plantilla:** se escribe con la primera aplicación que declare `egress: true`. Lo mismo un proveedor nuevo (un proxy, Tor, LiteLLM): entra como Postgres, con una red interna por pareja.
- **Fuera de este contrato:** la red del host (prohibida), la salida limitada a ciertos destinos, la GPU y los dispositivos, y las aplicaciones con ventana ([`ROADMAP.md`](../ROADMAP.md)).
