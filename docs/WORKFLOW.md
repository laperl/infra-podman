# Flujo de trabajo del operador

Cómo se hace cada cambio, siempre igual. Regla de oro: **nada entra en `main` sin PR, y nada se despliega en producción sin tag firmado.**

Resumen:

```text
1. Pedir el cambio → 2. Revisar el PR → 3. Probar en DEV → 4. Mergear → 5. Tag firmado → 6. plan y apply en producción
```

Cada PR dice en su descripción qué playbook hay que desplegar y en qué máquinas. Si no lo dice, pídelo antes de mergear.

## 1. Pedir el cambio

Abre una conversación con Claude con este repo conectado y pide la tarea en una frase, por ejemplo:

> Implementa la fase 1 según `docs/SPEC.md`.

Claude crea una rama y abre un PR en borrador. Si no puede abrirlo, te da el enlace para abrirlo tú en un clic.

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

**Una máquina cada vez.** La contraseña de sudo del portátil y la del GX10 son distintas, y Ansible pide una sola por ejecución (R24). Por eso, en producción, usa siempre `--limit`:

```bash
./deploy.sh plan  <playbook> --limit laptop       # 1. lee el plan con calma
./deploy.sh apply <playbook> --limit laptop       # 2. escribe prod y la contraseña de sudo del portátil
./deploy.sh apply <playbook> --limit laptop       # 3. tiene que dar changed=0

./deploy.sh plan  <playbook> --limit gx10         # lo mismo con la contraseña de sudo del GX10
./deploy.sh apply <playbook> --limit gx10
./deploy.sh apply <playbook> --limit gx10
```

Qué vas a ver:

1. `deploy.sh: tag firmado verificado: v0.1.0` y `deploy.sh: commit firmado del repo de datos verificado: data@…`.
2. Solo en `apply`: `Vas a aplicar … en PRODUCCIÓN … Escribe 'prod' para continuar:`. Escribe `prod`.
3. `BECOME password:`: la contraseña de sudo **de esa máquina**. No se ve al escribir.
4. Al final, `PLAY RECAP` con `failed=0`. En el segundo `apply`, también `changed=0`.

Cada ejecución deja una línea en `~/.local/state/infra-podman/deploy.log`: `tail -5 ~/.local/state/infra-podman/deploy.log`.

Después puedes seguir trabajando en `main` con normalidad. El siguiente despliegue necesitará su propio tag.

### Si algo falla

| Mensaje | Qué pasa | Qué hacer |
| --- | --- | --- |
| `HEAD no tiene ningún tag firmado…` | El tag está en otro commit (creado antes del `git pull`) o no está firmado. El mensaje dice en qué commit estás y dónde está el último tag | Si el tag no se ha subido: `git tag -d <tag>` y repite el paso 5. Comprueba con `git tag --points-at HEAD` y `git verify-tag <tag>` |
| `kdbx: there is no entry '…' in the group 'laperl'` | Falta esa entrada en el `.kdbx`, o tiene otro título | Créala en KeePassXC: grupo `laperl` (el nombre de tu instalación) y título exactamente el del mensaje. Ver «Cómo desplegarlo» del PR |
| `kdbx: cannot list the group 'laperl'` | El grupo de KeePassXC no se llama como tu instalación | Renómbralo ([`SETUP.md`](SETUP.md), paso 16) |
| `kdbx: … has 2 entries titled '…'` | Dos entradas con el mismo título en el grupo | Deja solo una en KeePassXC |
| `infra_site is missing or not valid` | Falta el nombre de la instalación en el repo de datos | `infra_site: laperl` en los dos `group_vars/all.yml` ([`SETUP.md`](SETUP.md), paso 16) |
| `hay cambios sin commit o ficheros sin seguimiento` | Hay algo modificado en tu copia | `git status`. Guarda tus cambios en otra rama o descártalos |
| `el repo de datos tiene cambios sin commit…` | Has editado datos y no has hecho el commit | En el repo de datos: `git status`, y commit firmado o `git restore` («Cambiar datos») |
| `el último commit del repo de datos … no está firmado…` | Commit hecho sin firma, o con otra clave | `git -C ~/Documents/SECURE_vc/ansible/infra-podman verify-commit HEAD`. Revisa la configuración de firma de ese repo ([`SETUP.md`](SETUP.md), paso 14) y rehaz el commit: `git commit --amend --no-edit -S` |
| `no existe el repo de datos …` o `define data_repo…` | Volumen `SECURE_vc` sin montar, o falta la línea en `deploy.conf` | Monta el volumen; [`SETUP.md`](SETUP.md), pasos 7 y 14 |
| `Incorrect sudo password` o `Missing sudo password` | Contraseña de sudo de otra máquina, o falta `--limit` | Repite con `--limit` y la contraseña de esa máquina |
| `UNREACHABLE` en `laptop` | sshd parado o el alias `laptop` no está bien | `ssh laptop true`; [`SETUP.md`](SETUP.md), paso 9 |
| `UNREACHABLE` en `gx10` | GX10 apagado o fuera de Tailscale | `ssh gx10 true` |
| `apply --env prod necesita un terminal interactivo` | Lo has lanzado sin terminal | Lánzalo tú desde una terminal |

## Cambiar datos

Los datos (máquinas, instancias y, más adelante, bases, usuarios y aplicaciones) viven en tu **repo de datos**, `~/Documents/SECURE_vc/ansible/infra-podman` (SPEC 4.13, [`SETUP.md`](SETUP.md), paso 14). No pasan por GitHub ni por PR: los cambias tú y los apruebas con tu firma. Qué va en cada fichero: [`inventory.example/`](../inventory.example/README.md).

Cuando un PR de código diga «añade esto al repo de datos», hazlo así, con el volumen `SECURE_vc` montado y KeePassXC desbloqueado:

```bash
cd ~/Documents/SECURE_vc/ansible/infra-podman
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
| `./deploy.sh secrets [--env dev\|prod] [--limit HOSTS] [--rotate NOMBRE]` | Pide la contraseña de KeePassXC y la de sudo, y crea en las máquinas los secretos que faltan (o rota uno) |

`--env` vale `prod` si no lo pones. `plan` y `apply` piden siempre la contraseña de sudo; si el playbook no la necesita, pulsa Intro.

## Los playbooks

| Playbook | Qué hace | Máquinas |
| --- | --- | --- |
| `check` | Solo lee: comprueba que llega a cada máquina y su versión de Podman | Todas |
| `base` | Usuario de servicio `svc_runner` con linger (fase 1) | `laptop`, `gx10` (DEV: `vmiadev`) |
| `secrets` | Solo con `./deploy.sh secrets`: crea en cada máquina los secretos que le faltan, leyéndolos de KeePassXC. Pide la contraseña maestra y la de sudo | Una cada vez, con `--limit` |
| `postgres` | Las instancias de Postgres (`pg-main`). Necesita antes `base` y `secrets`. Si cambia la imagen, hace antes un backup y se para si falla | `laptop` (DEV: `vmiadev`) |
| `backup` | Backup diario local, a las 13:00, y el aviso de escritorio en el portátil. Necesita antes `base` y `secrets` ([`SETUP.md`](SETUP.md), paso 17) | `laptop` (DEV: `vmiadev`) |

## Versiones de los tags

`vMAYOR.MENOR.PARCHE`: sube el parche para correcciones, el menor para servicios o funciones nuevas y el mayor para cambios que rompen algo existente.

## Qué no hacer

- Pushear directamente a `main`.
- Desplegar desde una rama o desde un commit sin tag firmado.
- Dejar que una IA mergee, cree tags o ejecute `apply`.
