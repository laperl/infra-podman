# Rol `firefly_importer`

El Data Importer de Firefly III en contenedores Quadlet sin root, para pasar a Firefly extractos en CSV a mano desde la web, **por instancias** (R48): `playbooks/firefly_importer.yml` aplica el rol una vez por cada elemento de `firefly_importer_instances`. Requisitos: [`docs/services/firefly_importer.md`](../../docs/services/firefly_importer.md); lo común a toda aplicación: [`docs/services/README.md`](../../docs/services/README.md).

## Qué leer

- `docs/services/firefly_importer.md`: qué tiene que cumplir, por qué y cómo se usa.
- `docs/NETWORK.md`: la red de cada pareja con Firefly la escribe cualquiera de los dos lados.
- SPEC 4.4 (red y puerto) y 4.14 (límites, endurecimiento y lanzador).

## Qué no se toca

- **El nombre corto `ffimport`** (`firefly_importer_short`, R52).
- **La red.** Solo internas, una por cada Firefly de `connects_to` y una por cada otra pareja. Sin `egress` y nunca `Network=host`: sin conexión con el banco (se decide aparte).
- **Sin `pg_hba`:** no entra en Postgres; escribe por la API de Firefly.
- **Sin token personal ni secretos:** se entra con OAuth y un Client ID, que no es secreto. Nada en `infra_secrets`.
- **Solo desde la web:** `CAN_POST_AUTOIMPORT`, `CAN_POST_FILES`, `IMPORT_DIR_ALLOWLIST` y `JSON_CONFIGURATION_DIR`, apagadas o sin poner. Importar desde una carpeta está en el ROADMAP.
- **Registros sin tus datos:** `LOG_CHANNEL=stdout`, `LOG_RETURN_JSON=false` y `notice` por defecto (el de la imagen es `debug`).
- **Sin volumen con nombre:** lo que se sube va al volumen anónimo que declara la imagen (`/var/www/html/storage/upload`) y se borra con el contenedor (`--rm`) al reiniciar; lo comprueba `lifecycle`. No añadas uno con nombre sin decidirlo en su página (copias, datos de extractos).

## Tests

- `lint`: renderiza `firefly_importer.container` y la red de su pareja con Firefly, política y generador de Podman 4.9; la copia de referencia en `tests/quadlet/golden`.
- `unit`: el contrato (`test_app_contract.py`), con el proveedor `firefly`.
- `lifecycle`: pendiente (tercer PR de `docs/services/ADD_APP.md`).
