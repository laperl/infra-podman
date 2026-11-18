# Añadir una aplicación nueva

El procedimiento para que una persona o una IA, la que sea, añada una aplicación a la plataforma. Es una lista ordenada: cada paso dice qué fichero se toca y enlaza al único sitio donde está la regla. Aquí no se repite ninguna regla.

- **Quién lo usa:** el operador le da este fichero a su IA con la aplicación que quiere (apartado 5).
- **El modelo es el rol `firefly`:** lo que no sepas cómo se escribe, míralo en `roles/firefly/` y `playbooks/firefly.yml`. No hay rol esqueleto: sería una segunda copia que mantener.
- **Reglas del repo:** [`CLAUDE.md`](../../CLAUDE.md), que valen para cualquier IA. Solo PRs en borrador, nada inventado y cero secretos.

## 1. Antes de escribir nada: la ficha

Rellénala **solo con la documentación oficial** de la aplicación y cita la URL de cada dato. Lo que no encuentres, déjalo en «no verificado»: no lo supongas. Enséñasela al operador y **espera su aprobación**.

| Dato | Qué hay que saber |
| --- | --- |
| Nombres | De código (`^[a-z][a-z0-9_]*$`, el del rol) y corto, de 2 a 8 letras ([`NAMING.md`](../NAMING.md), apartado 2) |
| Imagen | Registro, nombre, versión y **digest** (SPEC, D6). Sin suscripción ni registro de pago |
| Usuario del contenedor | Con qué UID corre, y si vale con `ReadOnly=true`, sin capacidades y sin privilegios nuevos. Si no, hace falta una excepción aprobada (SPEC 4.14, R51) |
| Contrato | ¿Guarda datos en Postgres? ¿Con qué otros contenedores habla? ¿Necesita salir a internet? ([`README.md`](README.md), apartado 9) |
| Entrada | Puerto interno y protocolo. Qué responde cuando está sana (orden o URL del healthcheck) |
| Datos | Qué directorios guardan datos (serán volúmenes) y cuáles pueden ser `tmpfs` |
| Secretos | Cuáles necesita y si los lee de un fichero (`*_FILE`) o solo de una variable |
| Copias | Qué hay que copiar además de su base: volúmenes enteros o una orden propia de la aplicación ([`README.md`](README.md), apartado 8) |
| Primer arranque | Migraciones, usuario inicial, tareas programadas |
| Configuración | El enlace a la página oficial con **todas** las opciones y, de ellas, las más importantes para esta plataforma: cada una con el valor que propones y por qué (sin salida, sin guardar contraseñas, registros…). Di cuáles solo se leen en el primer arranque |
| Recursos | Memoria, CPU y procesos razonables |
| Lo que no encaja | Red del host, GPU, dispositivos, ventana propia: está fuera del contrato; para y dilo |

**Para y pregunta** si la aplicación pide `egress: true`, un proveedor que no sea Postgres, una excepción al endurecimiento o cualquier cosa de SPEC, sección 7: son decisiones del operador. Las redes ya tienen plantilla común: la de salida (`egress.network.j2`) y la de una pareja de `connects_to` (`pair.network.j2`), en `roles/quadlet_deploy/templates/` ([`NETWORK.md`](../NETWORK.md)).

## 2. Los ficheros, en orden

`<app>` es el nombre de código y `<corto>` el nombre corto.

| # | Fichero | Qué se hace | La regla está en |
| --- | --- | --- | --- |
| 1 | `docs/NAMING.md`, apartado 2 | Fila con el nombre corto | Ese apartado y su lista del 9 |
| 2 | `playbooks/group_vars/all/images.yml` | `<app>_image`, por digest y con su `# track:` | SPEC, D6; la cabecera de ese fichero |
| 3 | `roles/<app>/defaults/main.yml` | `<app>_short`, `<app>_contract`, `<app>_id`, nombres compuestos desde la instancia, sus parejas (`<app>_pairs` con el filtro `pairs_of`, `<app>_pair_networks` y `<app>_pair_units`, como en `roles/firefly`), `<app>_quadlet_units`, lo que se puede copiar (`<app>_backup_available`) y los valores por defecto de cada ajuste | `README.md`, apartados 1, 8 y 9; `NAMING.md`; [`NETWORK.md`](../NETWORK.md) |
| 4 | `roles/<app>/templates/` | `.container` y sus `.volume`: nombres explícitos, cuatro etiquetas, endurecimiento, límites, healthcheck, secretos como fichero, `PublishPort=` tal cual viene de `networking.inbound.publish`, y un `Network=` por cada red de `<app>_pair_networks` | SPEC 4.2 a 4.5 y 4.14; [`COMPATIBILITY.md`](../COMPATIBILITY.md) (solo claves de Podman 4.9) |
| 5 | `roles/<app>/tasks/` | `checks.yml` (rechazos claros), `main.yml` (`connects_to` con `connects_to_problems` y, si usa Postgres, `pg_hba` con `pg_hba_problems`; secretos con `podman_secrets`; unidades con `quadlet_deploy`, pasándole `quadlet_deploy_pair_owner` y `quadlet_deploy_pair_networks`; copias con `roles/backup/tasks/app_items.yml`; temporizadores con `user_units`), `purge.yml` (sin las redes de sus parejas) | Los mismos ficheros de `roles/firefly/tasks/`; [`NETWORK.md`](../NETWORK.md) |
| 6 | `roles/<app>/meta/main.yml` y `roles/<app>/CLAUDE.md` | Licencia `GPL-3.0-or-later`. `CLAUDE.md` corto: qué leer, qué no se toca y qué tests tiene | [`CLAUDE.md`](../../CLAUDE.md), «Dónde va cada cosa nueva» |
| 7 | `playbooks/<app>.yml` | Un despliegue por elemento de `<app>_instances`, con `<app>_retire` y `<app>_purge` (así `deploy.sh` acepta `--retire` y `--purge`) | `playbooks/firefly.yml`; SPEC 4.10 |
| 8 | `playbooks/group_vars/all/apps.yml` | Línea `<app>: <corto>` en `infra_apps`: con ella sus instancias salen en `check` y otras pueden nombrarlas en `connects_to` | La cabecera de ese fichero |
| 9 | `tests/quadlet/ci_vars.yml` y `tests/quadlet/golden/` | Una instancia `ci`; después `tests/quadlet/run.sh --update-golden` y **revisar el diff**: solo deben aparecer las unidades nuevas | Cabecera de `tests/quadlet/run.sh` |
| 10 | `tests/lifecycle/` y `.github/workflows/lifecycle.yml` | `check-<app>.sh`, sus variables y su job: rechazos, plan, apply, reaplicar sin cambios, salud, aislamiento, retirar y purgar | `check-firefly.sh` y el job `firefly` |
| 11 | `inventory.example/{dev,prod}/` | Grupo `<app>_hosts` en `hosts.yml`, `group_vars/<app>_hosts.yml` con ejemplo comentado, sus secretos en `infra_secrets` con `readers:`, y la fila de `README.md` | `README.md`, apartado 5; [`SECRETS_INVENTORY.md`](../SECRETS_INVENTORY.md) |
| 12 | `docs/services/<app>.md` | Solo lo propio: uso, red, seguridad, actualizaciones, copias. Con las URL oficiales de la ficha | La forma de [`firefly.md`](firefly.md) |
| 13 | Tablas de los demás documentos | Una fila en `README.md` (apartado 9), `ARCHITECTURE.md`, `OPERATIONS.md` (apartados 1 y 4), `SECRETS_INVENTORY.md`, y una sección en `TROUBLESHOOTING.md`. Sin copiar textos entre ellos | [`CLAUDE.md`](../../CLAUDE.md) |

Si usa Postgres, el rol **no crea** ni la base ni el usuario ni la red: el operador declara la base y el usuario en `postgres_hosts.yml`, y en la instancia `connects_to` y `pg_hba`; los crea el rol `postgres` ([`POSTGRES.md`](../POSTGRES.md), apartado 6; [`NETWORK.md`](../NETWORK.md)). El rol de la aplicación solo comprueba que existen.

## 3. Comprobar

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

## 4. Entregar

- **Varios PR pequeños, en este orden**, cada uno verde por sí solo: (a) ficha y página de la aplicación; (b) imagen, rol, playbook, unidades y tests; (c) `lifecycle` y el resto de documentos.
- Cada entrega dice **«Probado y no probado»** ([`WORKFLOW.md`](../WORKFLOW.md), «Si una IA escribe el cambio y otra lo aplica»).
- La prueba en una máquina la hace el operador: `./deploy.sh plan <app> --env dev`, `apply`, y `./deploy.sh plan check --env dev`, que debe acabar en `RESUMEN: todo correcto`. Lo que tiene que escribir en su inventario va en la página de la aplicación.
- **Mientras trabajas, anota** en la descripción de cada PR, en «Notas para mejorar el procedimiento», lo que este fichero no previó: preguntas del operador que la ficha no respondía, decisiones que costaron varias vueltas y pasos que sobraron.
- **Al terminar, una evaluación corta** con el operador sobre esas notas: qué cambia en este fichero y cuánto costó el alta. Los cambios van en un PR propio y pequeño.

## 5. Cómo se lo pides a tu IA

Vale con cualquier modelo que pueda leer el repo y ejecutar órdenes en él. Con Podman 4.9 o posterior instalado puede ejecutar también `tests/quadlet/run.sh`.

```text
Lee CLAUDE.md y docs/services/ADD_APP.md de este repo y síguelos al pie de la letra.
Quiero añadir la aplicación: <nombre y URL de su documentación oficial>.
Empieza por la ficha del apartado 1 y para: no escribas código hasta que la apruebe.
```

- **Claude Code** lo encuentra solo como skill `add-app` (`.claude/skills/add-app/SKILL.md`, que solo manda aquí): «añade la aplicación X».
- **Otras herramientas** leen `AGENTS.md`, en la raíz, que manda a `CLAUDE.md`.
- **Un modelo sin acceso al repo** (un chat): dale este fichero, `CLAUDE.md`, `docs/services/README.md`, `docs/NAMING.md` y la carpeta `roles/firefly/`. Podrá escribir, pero no probar: las órdenes del apartado 3 las ejecutas tú.
