# Flujo de trabajo del operador

Cómo se hace cada cambio, siempre igual. Regla de oro: **nada entra en `main` sin PR, y nada se despliega en producción sin tag firmado.**

Resumen:

```text
1. Pedir el cambio → 2. Revisar el PR → 3. Probar en DEV → 4. Mergear → 5. Tag firmado → 6. plan y apply en producción
```

Cada PR dice en su descripción qué playbook hay que desplegar y en qué máquinas. Si no lo dice, pídelo antes de mergear.

**Nombres de esta documentación.** `laptop`, `servidor` y `vm` son los nombres de las máquinas en el inventario (`inventory/<entorno>/hosts.yml` del repo de datos) y sus alias en `~/.ssh/config`: ahí se dice a qué máquina y con qué usuario se despliega. `~/infra-podman-data` es la carpeta del repo de datos (`data_repo` en `~/.config/infra-podman/deploy.conf`). Si los tuyos son otros, usa los tuyos.

## 1. Pedir el cambio

Abre una conversación con Claude con este repo conectado y pide la tarea en una frase, por ejemplo:

> Implementa la fase 1 según `docs/SPEC.md`.

Claude crea una rama y abre un PR en borrador. Si no puede abrirlo, te da el enlace para abrirlo tú en un clic.

### Si una IA escribe el cambio y otra lo aplica

Sirve cuando quien diseña y prueba no puede abrir el PR. El cambio viaja como una **orden**: un fichero Markdown y un parche (`git format-patch`), escritos sobre `main` ya mergeado. Una orden, un PR.

**Quien escribe la orden** ejecuta todo lo que su entorno permita y lo deja escrito en ella, en dos apartados que no pueden faltar:

- **«Probado y no probado»:** cada comprobación ejecutada, con las versiones de las herramientas y sobre qué commit, y cada una que no pudo ejecutar, con el motivo. Quien aplica lo copia tal cual en la descripción del PR: es lo que dice a cualquiera qué se ha probado.
- **«Verificación»:** las órdenes exactas que tiene que ejecutar quien aplica. Solo lo que el autor no pudo probar y el CI tampoco prueba. Si no hay nada, lo dice: «ninguna: lo cubre el CI».

Quién ejecuta cada comprobación:

| Comprobación | Quien escribe la orden | Quien la aplica | CI |
| --- | --- | --- | --- |
| Las del workflow `lint` (las de [«Comprobaciones en local»](../README.md#comprobaciones-en-local)) | Todas, siempre | No las repite | En cada push |
| `lifecycle`: Podman y systemd de verdad | No suele poder: lo dice | No | Solo si el PR toca lo que lista `paths:` en `.github/workflows/lifecycle.yml` |
| Lo que la orden pida en «Verificación» | — | Sí, y dice el resultado | — |
| `plan` y `apply` en DEV | No | No: solo el operador | No |

**Quien aplica** hace solo esto: actualiza `main`, crea la rama, aplica el parche con `git am`, ejecuta lo de «Verificación», abre el PR en borrador y dice qué ha ejecutado y qué no. No instala herramientas para repetir lo que ya está probado, no cambia nada fuera del parche ni abre otros PRs, y si `git am` o una verificación falla, para y avisa. El filtro antes del merge es el CI en verde (paso 2).

## 2. Revisar el PR en GitHub

1. Pestaña **Pull requests** → abre el PR.
2. Espera a que el CI esté en verde.
3. Pestaña **Files changed**: revisa lo que entra.
4. Si algo no te gusta, coméntalo en el PR o pídeselo a Claude. La corrección llega como **commit nuevo en el mismo PR**. Nunca abras un PR nuevo para lo mismo ni edites `main` directamente.

También puedes editar tú un fichero del PR con el lápiz de GitHub, eligiendo **Commit directly to the `<rama>` branch**.

## 3. Probar en DEV (antes del merge)

En el portátil, en tu copia del repo (`~/src/infra-podman`):

```bash
git fetch origin && git switch <rama-del-PR> && git pull
./deploy.sh plan <playbook> --env dev
./deploy.sh apply <playbook> --env dev
./deploy.sh apply <playbook> --env dev      # el segundo apply tiene que dar changed=0
```

En DEV no hace falta tag. Lo lanzas tú; opencode solo ejecuta pruebas. Si ves algo raro, coméntalo en el PR antes de mergear.

## 4. Mergear

En GitHub, en el PR:

1. Si está en borrador: **Ready for review**.
2. Botón verde → **Squash and merge** → **Confirm**.
3. La rama se borra sola.

## 5. Crear el tag firmado

Antes de nada, lee el apartado **«Cómo desplegarlo»** de la descripción del PR: a veces hay que preparar algo antes, por ejemplo una entrada nueva en KeePassXC.

En el portátil, en tu copia del repo, con KeePassXC desbloqueado. **El orden importa:** primero traer el merge y después crear el tag. Un tag creado antes del `git pull` se queda en el commit anterior, y `deploy.sh` lo rechaza.

```bash
git switch main && git pull                        # 1. trae el merge
git log --oneline -1 --decorate                    # 2. tiene que salir (HEAD -> main, origin/main, ...) con el título del PR
git tag --sort=-v:refname | head -3                # 3. último tag, para elegir el siguiente número
git tag -s v0.2.0 -m "fase 1: Postgres"            # 4. cambia número y descripción
git tag --points-at HEAD                           # 5. tiene que mostrar el tag que acabas de crear
git verify-tag v0.2.0                              # 6. tiene que decir Good "git" signature
git push origin v0.2.0                             # 7. súbelo
```

- El número sigue `vMAYOR.MENOR.PARCHE` (ver [Versiones de los tags](#versiones-de-los-tags)).
- `git tag -s` firma con la clave de [`SIGNING.md`](SIGNING.md). Si `verify-tag` no dice `Good`, para: `deploy.sh` lo rechazará igual.
- **Si te equivocas de commit** y el tag **no** se ha subido todavía: `git tag -d v0.2.0` y vuelve al paso 1. Si ya se había subido, no lo reutilices: crea el siguiente número.

## 6. Desplegar en producción

Sigue en `main`, justo en el tag, sin tocar ningún fichero: `deploy.sh` rechaza un checkout con cambios o sin tag firmado.

**Una máquina cada vez.** La contraseña de sudo del portátil y la del servidor principal son distintas, y Ansible pide una sola por ejecución (R24). Por eso, en producción, usa siempre `--limit`:

```bash
./deploy.sh plan  <playbook> --limit laptop       # 1. lee el plan con calma
./deploy.sh apply <playbook> --limit laptop       # 2. escribe prod y la contraseña de sudo del portátil
./deploy.sh apply <playbook> --limit laptop       # 3. tiene que dar changed=0

./deploy.sh plan  <playbook> --limit servidor         # lo mismo con la contraseña de sudo del servidor principal
./deploy.sh apply <playbook> --limit servidor
./deploy.sh apply <playbook> --limit servidor
```

Qué vas a ver:

1. `deploy.sh: tag firmado verificado: v0.1.0` y `deploy.sh: commit firmado del repo de datos verificado: data@…`.
2. Solo en `apply`: `Vas a aplicar … en PRODUCCIÓN … Escribe 'prod' para continuar:`. Escribe `prod`.
3. `BECOME password:`: la contraseña de sudo **de esa máquina**. No se ve al escribir.
4. Al final, `PLAY RECAP` con `failed=0`. En el segundo `apply`, también `changed=0`.

Cada ejecución deja una línea en `~/.local/state/infra-podman/deploy.log`: `tail -5 ~/.local/state/infra-podman/deploy.log`.

Después puedes seguir trabajando en `main` con normalidad. El siguiente despliegue necesitará su propio tag.

### Si algo falla

Busca el mensaje en [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md): están todos los de `deploy.sh`, KeePassXC y las firmas (apartados 1 y 2), con su causa y qué hacer.

## Cambiar datos

Los datos (máquinas, instancias, bases, usuarios y aplicaciones) viven en tu **repo de datos**, `~/infra-podman-data` (SPEC 4.13, [`SETUP.md`](SETUP.md), paso 14). No pasan por GitHub ni por PR: los cambias tú y los apruebas con tu firma. Qué va en cada fichero: [`inventory.example/`](../inventory.example/README.md).

Cuando un PR de código diga «añade esto al repo de datos», hazlo así, con el volumen cifrado del repo de datos montado y KeePassXC desbloqueado:

```bash
cd ~/infra-podman-data
$EDITOR inventory/prod/group_vars/postgres_hosts.yml   # el fichero que diga el PR
git diff                                               # revisa el cambio
git add -A && git commit -m "qué cambias y por qué"    # se firma solo (commit.gpgSign)
git verify-commit HEAD                                 # Good "git" signature
```

Y después, desde tu copia del código, `plan` y `apply` como siempre (paso 6).

- **En DEV** puedes probar datos sin hacer commit: `deploy.sh` los acepta y anota `+dirty` en el registro.
- **En producción** el repo de datos tiene que estar sin cambios y con el último commit firmado. Si no, `deploy.sh` se niega antes de conectar con ninguna máquina.
- **Nunca** pongas contraseñas en el repo de datos: van en KeePassXC; en el inventario, solo sus nombres.

## Las órdenes de `deploy.sh`

| Orden | Qué hace |
| --- | --- |
| `./deploy.sh plan <playbook> [--env dev\|prod] [--limit HOSTS]` | Simula (`--check --diff`) y enseña qué cambiaría |
| `./deploy.sh apply <playbook> [--env dev\|prod] [--limit HOSTS]` | Aplica |
| `./deploy.sh apply <playbook> … --retire INSTANCIA` | Con cualquier playbook por instancias (hoy `postgres` y `firefly`), retira esa instancia conservando sus datos ([`services/INSTALL.md`](services/INSTALL.md), apartados 10 y 11) |
| `./deploy.sh apply postgres … --confirm-drop INSTANCIA` | Confirma que se borran todas las bases de esa instancia ([`POSTGRES.md`](POSTGRES.md), apartado 7) |
| `./deploy.sh secrets [--env dev\|prod] [--limit HOSTS] [--rotate NOMBRE]` | Pide la contraseña de KeePassXC y la de sudo, y crea en las máquinas los secretos que faltan (o rota uno) |

`--env` vale `prod` si no lo pones. `plan` y `apply` piden siempre la contraseña de sudo; si el playbook no la necesita, pulsa Intro.

## Los playbooks

| Playbook | Qué hace | Máquinas |
| --- | --- | --- |
| `check` | Solo lee: comprueba que llega a cada máquina y su versión de Podman | Todas |
| `base` | Usuario de servicio `svc_runner` con linger (fase 1) | `laptop`, `servidor` (DEV: `vm`) |
| `secrets` | Solo con `./deploy.sh secrets`: crea en cada máquina los secretos que le faltan, leyéndolos de KeePassXC. Pide la contraseña maestra y la de sudo | Una cada vez, con `--limit` |
| `postgres` | Las instancias de Postgres (`pg-main`). Necesita antes `base` y `secrets`. Si cambia la imagen, hace antes un backup y se para si falla | `laptop` (DEV: `vm`) |
| `firefly` | Las instancias de Firefly III (`ff-<instancia>`). Necesita antes `base`, `secrets` y `postgres`, con su base y su usuario. Si cambia la imagen, hace antes un backup y se para si falla ([`services/INSTALL.md`](services/INSTALL.md)) | `laptop` (DEV: `vm`) |
| `backup` | Backup diario local, a las 13:00, y el aviso de escritorio en el portátil. Con `backup_remote_url`, también la copia al servidor principal cada hora. Necesita antes `base` y `secrets` ([`SETUP.md`](SETUP.md), pasos 17 y 18) | `laptop` (DEV: `vm`) |
| `backup-server` | El servidor que guarda la copia de los backups, solo para añadir, y su puerto en Tailscale. Necesita antes `base` y `secrets` ([`SETUP.md`](SETUP.md), paso 18) | `servidor` (DEV: `vm`) |

## Cuando hay una imagen nueva

Cada lunes a las 10:00, el workflow `image-updates` mira si hay una versión nueva de las imágenes de `playbooks/group_vars/all/images.yml`. Si la hay, **falla y te llega un correo** de GitHub. Solo mira: nunca cambia nada.

1. **Qué hay:** en GitHub, Actions → `image-updates` → la ejecución en rojo. La tabla del resumen dice qué imagen, qué versión hay, su digest y sus plataformas. Tienen que salir `linux/amd64` y `linux/arm64` (D6).
2. **Pide el cambio a Claude**, con ese digest: un PR que lo pone en `images.yml` (y la versión nueva en `# track:`). Ese PR pasa por el CI y `lifecycle`, como cualquier otro (pasos 1 a 6). En DEV y después en producción, una máquina cada vez, con `--limit`.
3. **Si es Postgres**, el `apply` hace antes una copia (`reason=pre-upgrade`) y, si falla, no cambia la imagen. Si el healthcheck no pasa tras el cambio, Ansible para el servicio y no vuelve atrás solo: vuelve al tag anterior (paso 6).

Para mirarlo cuando quieras, sin esperar al lunes: Actions → `image-updates` → **Run workflow**.

## Versiones de los tags

`vMAYOR.MENOR.PARCHE`: sube el parche para correcciones, el menor para servicios o funciones nuevas y el mayor para cambios que rompen algo existente.

## Qué no hacer

- Pushear directamente a `main`.
- Desplegar desde una rama o desde un commit sin tag firmado.
- Dejar que una IA mergee, cree tags o ejecute `apply`.
