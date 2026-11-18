# Rol `pgadmin`

pgAdmin 4 en contenedores Quadlet sin root, para administrar las Postgres de la plataforma, **por instancias** (R48): `playbooks/pgadmin.yml` aplica el rol una vez por cada elemento de `pgadmin_instances`. Requisitos: [`docs/services/pgadmin.md`](../../docs/services/pgadmin.md); lo común a toda aplicación: [`docs/services/README.md`](../../docs/services/README.md).

## Qué leer

- `docs/services/pgadmin.md`: qué tiene que cumplir y por qué.
- R37 y `docs/POSTGRES.md`, apartado 3: el superusuario entra por TCP solo desde la red de pgAdmin. Esa línea de `pg_hba.conf` la escribe el rol `postgres`, no este.
- SPEC 4.4 (red y puerto) y 4.14 (límites, endurecimiento y lanzador).

## Qué no se toca

- **El nombre corto `pgadmin`** (`pgadmin_short`, R52), y su línea en `infra_postgres_admins` (`playbooks/group_vars/all/apps.yml`): es la única aplicación que puede administrar Postgres, y `tests/unit/test_app_contract.py` lo exige.
- **La red.** Solo internas: una por cada Postgres de `connects_to` y una por cada otra pareja. Sin `egress` y nunca `Network=host`: pgAdmin tiene una sesión de superusuario abierta.
- **Sin `pg_hba` en la instancia:** entra como superusuario. El `plan` lo rechaza.
- **Las contraseñas de Postgres no se guardan** (`ALLOW_SAVE_PASSWORD=False`), ni `.pgpass` ni `servers.json`: viven en KeePassXC.
- **Lo que pediría el navegador, apagado:** Gravatar y la comprobación de versiones.
- **El secreto, como fichero** (`PGADMIN_DEFAULT_PASSWORD_FILE`), nunca en `Environment=`. El email, solo en el repo de datos.
- **`--purge` borra datos** (`tasks/purge.yml`, R57): nunca antes de que la copia del volumen haya terminado bien.

## Tests

- `lint`: renderiza `pgadmin.container` y su `.volume`, política y generador de Podman 4.9; la copia de referencia en `tests/quadlet/golden`.
- `unit`: el contrato (`test_app_contract.py`) y el filtro `admins_of` (`test_networking.py`).
- `lifecycle`, job `pgadmin` (`tests/lifecycle/check-pgadmin.sh`): rechazos, plan, apply, reaplicar sin cambios, salud, endurecimiento, la entrada de tu usuario y la del superusuario de punta a punta, aislamiento, el informe de `check`, el manual, retirar y volver a desplegar sobre el volumen.
