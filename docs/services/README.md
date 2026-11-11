# Aplicaciones: lo común a todas

Cómo es **cualquier** aplicación de la plataforma (Firefly III, pgAdmin y las que lleguen). Lo propio de cada una está en su página de esta carpeta, por ejemplo [`firefly.md`](firefly.md); aquí solo lo que todas comparten. La regla sale de R48 ([`DECISIONS.md`](../DECISIONS.md)) y los nombres, de SPEC 4.12.

## 1. Instancias

**Cada aplicación se despliega por instancias**, aunque solo haya una. Una instancia es una copia completa e independiente de la aplicación, con su nombre: por ejemplo `casa` para tu uso diario, `canary` para probar una versión nueva antes de pasarla a `casa`, o `test` para probar con datos falsos.

**Una instancia no comparte nada con otra.** Ni datos, ni red, ni claves:

| Pieza | De cada instancia | Ejemplo, Firefly `casa` |
| --- | --- | --- |
| Contenedor y servicio | El suyo | `prod-firefly-casa` |
| Puerto, solo en `127.0.0.1` | El suyo, si la aplicación lo necesita | `127.0.0.1:18100` |
| Red e IPs | Su red interna, con su propia subred | `prod-fireflycasa-pg-main-net` |
| Postgres | **Su propia base de datos**, con un único esquema del mismo nombre, y su usuario | base, esquema y usuario `firefly_casa` |
| Imagen | La que elijas de `images.yml` | `firefly_image` |
| Volumen | El suyo | `prod-firefly-casa-uploads` |
| Secretos | Los suyos | `firefly-casa-app-key`, `pg-main-firefly_casa-password` |
| Tareas programadas | Las suyas | `prod-firefly-casa-cron.timer` |
| Lanzador del menú | El suyo, con su navegador | «Firefly III (casa)» |
| Copias | Su base, en sus propias copias (`pgdump/firefly_casa`) | — |

## 2. Postgres: una base por instancia, nunca un esquema compartido

- **Varias aplicaciones, y varias instancias de la misma, pueden usar la misma Postgres** (por ejemplo `pg-main`).
- **Dentro de ella, cada instancia tiene su propia base de datos.** Cada base tiene un solo esquema, que se llama como ella, y sus tres grupos (`<base>_owner`, `_writer` y `_reader`). Es el modelo de [`POSTGRES.md`](../POSTGRES.md), apartado 2.
- **Dos instancias nunca comparten base, ni siquiera con esquemas distintos.** Así:
  - una no puede ver ni siquiera la existencia de los datos de la otra;
  - cada una se copia y se restaura sola;
  - borrar una no toca la otra.
- Cada instancia puede ir a la Postgres que elijas (`pg_instance`): `canary`, por ejemplo, a una instancia `pg-test` aparte.

## 3. Nombres

Con `<instancia>` en minúsculas y cifras (`^[a-z0-9]{1,14}$`):

| Qué | Patrón | Firefly `casa` |
| --- | --- | --- |
| Contenedor | `<entorno>-<app>-<instancia>` | `prod-firefly-casa` |
| Volumen | `<entorno>-<app>-<instancia>-<contenido>` | `prod-firefly-casa-uploads` |
| Base, esquema y usuario | `<app>_<instancia>` | `firefly_casa` |
| Consumidor de Postgres y su red | `<app><instancia>`, sin guion | `fireflycasa`, red `prod-fireflycasa-pg-main-net` |
| Secretos (KeePassXC) | `<app>-<instancia>-<clave>` y `pg-<postgres>-<usuario>-password` | `firefly-casa-app-key` |
| Etiqueta `infra.app` | `<app>-<instancia>` | `firefly-casa` |

El consumidor va sin guion porque así lo exige la red de Postgres (`POSTGRES.md`, apartado 6).

## 4. Puertos

- **Solo en `127.0.0.1`** (R25). La dirección no es un ajuste: un error en el inventario no puede abrir una aplicación a la red de casa.
- **Desde 18100**, y **los eliges tú** en el inventario, uno por instancia: `18100`, `18101`… El rol se para si dos instancias de la misma máquina repiten nombre o puerto.
- Los puertos que ya usa la plataforma están en [`ARCHITECTURE.md`](../ARCHITECTURE.md), apartado 4.

## 5. Cómo se declara

En tu repo de datos, en el grupo de la aplicación (por ejemplo `group_vars/firefly_hosts.yml`), una lista `<app>_instances`:

```yaml
firefly_instances:
  - name: casa
    port: 18100
  - name: canary
    port: 18101
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
- **Retirarla conservando sus datos:** mientras sigue declarada, `-e <app>_retire=<instancia>`. Se van el contenedor, el temporizador y el lanzador. Se quedan su base y su volumen. Las demás instancias no se tocan. `deploy.sh` aún no lo pasa (ROADMAP).
- **Su base** se borra como cualquier otra: quitándola de `postgres_hosts.yml`, con su copia previa (`POSTGRES.md`, apartado 7).
