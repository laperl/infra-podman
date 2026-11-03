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

En el portátil, con KeePassXC desbloqueado:

```bash
cd ~/src/infra-podman
git switch main && git pull                        # trae el merge
git tag --sort=-v:refname | head -3                # último tag, para elegir el siguiente número
git tag -s v0.1.0 -m "fase 1: usuario de servicio"  # cambia número y descripción
git verify-tag v0.1.0                              # tiene que decir Good "git" signature
git push origin v0.1.0
```

- El número sigue `vMAYOR.MENOR.PARCHE` (ver [Versiones de los tags](#versiones-de-los-tags)). El primero es `v0.1.0`.
- `git tag -s` firma con la clave de [`SIGNING.md`](SIGNING.md). Si `verify-tag` no dice `Good`, para: `deploy.sh` lo rechazará igual.

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

1. `deploy.sh: tag firmado verificado: v0.1.0`.
2. Solo en `apply`: `Vas a aplicar … en PRODUCCIÓN … Escribe 'prod' para continuar:`. Escribe `prod`.
3. `BECOME password:`: la contraseña de sudo **de esa máquina**. No se ve al escribir.
4. Al final, `PLAY RECAP` con `failed=0`. En el segundo `apply`, también `changed=0`.

Cada ejecución deja una línea en `~/.local/state/infra-podman/deploy.log`: `tail -5 ~/.local/state/infra-podman/deploy.log`.

Después puedes seguir trabajando en `main` con normalidad. El siguiente despliegue necesitará su propio tag.

### Si algo falla

| Mensaje | Qué pasa | Qué hacer |
| --- | --- | --- |
| `HEAD no tiene ningún tag firmado…` | No estás en el commit del tag, o el tag no está firmado | `git switch main && git pull`, comprueba con `git tag --points-at HEAD` y con `git verify-tag <tag>` |
| `hay cambios sin commit o ficheros sin seguimiento` | Hay algo modificado en tu copia | `git status`. Guarda tus cambios en otra rama o descártalos |
| `Incorrect sudo password` o `Missing sudo password` | Contraseña de sudo de otra máquina, o falta `--limit` | Repite con `--limit` y la contraseña de esa máquina |
| `UNREACHABLE` en `laptop` | sshd parado o el alias `laptop` no está bien | `ssh laptop true`; [`SETUP.md`](SETUP.md), paso 9 |
| `UNREACHABLE` en `gx10` | GX10 apagado o fuera de Tailscale | `ssh gx10 true` |
| `apply --env prod necesita un terminal interactivo` | Lo has lanzado sin terminal | Lánzalo tú desde una terminal |

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
| `postgres` | Las instancias de Postgres (`pg-main`). Necesita antes `base` y `secrets` | `laptop` (DEV: `vmiadev`) |

## Versiones de los tags

`vMAYOR.MENOR.PARCHE`: sube el parche para correcciones, el menor para servicios o funciones nuevas y el mayor para cambios que rompen algo existente.

## Qué no hacer

- Pushear directamente a `main`.
- Desplegar desde una rama o desde un commit sin tag firmado.
- Dejar que una IA mergee, cree tags o ejecute `apply`.
