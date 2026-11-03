# Firma con SSH

Commits y tags se firman con tu clave SSH, que sirve el agente de KeePassXC (D13, SPEC 5.3). **El tag firmado es el control que impide desplegar en producción algo que no has aprobado tú** (SPEC 5.2).

Se hace una vez en el portátil.

## 1. Git firma con tu clave, solo en este repo

La clave privada nunca sale de KeePassXC: git le pide la firma al agente usando la clave pública.

Todo se configura **solo para este repo** (sin `--global`), dentro de tu copia (`~/src/infra-podman`). Así tus otros repos no cambian: no firman ni necesitan KeePassXC abierto para hacer un commit.

```bash
cd ~/src/infra-podman
git config gpg.format ssh
git config user.signingkey "key::$(ssh-add -L | grep git-signing)"
git config user.email reposja@pm.me
git config tag.gpgSign true      # git tag -a/-m firma siempre
git config commit.gpgSign true   # opcional: firma también los commits de este repo
```

`ssh-add -L | grep git-signing` tiene que devolver una sola línea, con tu clave. KeePassXC tiene que estar desbloqueado para firmar.

Comprueba qué tiene este repo y qué viene de la configuración global: `git config --show-origin --get-regexp '^(user|gpg|commit|tag)\.'`.

### Si lo configuraste antes con `--global`

Hasta el 2026-11-03 esta guía decía `--global`, y eso hace que **todos** tus repos firmen sus commits y pidan KeePassXC. Para deshacerlo, mira primero lo que tienes:

```bash
git config --global --show-origin --get-regexp '^(user\.(email|signingkey)|gpg\.|commit\.gpgsign|tag\.gpgsign)'
```

Quita lo que puso esta guía y después configura este repo con el bloque de arriba:

```bash
git config --global --unset commit.gpgSign
git config --global --unset tag.gpgSign
git config --global --unset user.signingkey
git config --global --unset gpg.format
git config --global --unset gpg.ssh.allowedSignersFile
```

`user.email`: si antes de esta guía usabas otro correo en general, vuelve a ponerlo con `git config --global user.email <tu-correo-de-siempre>`. Este repo ya tiene el suyo.

## 2. Fichero de firmantes de confianza (fuera del repo)

`deploy.sh` solo se fía de **este** fichero, no del que hay en el repo (R4 en `DECISIONS.md`). Si alguien añadiera su clave al repo, no le serviría de nada.

```bash
mkdir -p ~/.config/infra-podman
cp docs/allowed_signers ~/.config/infra-podman/allowed_signers
chmod 600 ~/.config/infra-podman/allowed_signers
cat ~/.config/infra-podman/allowed_signers          # comprueba que la clave es la TUYA
git config gpg.ssh.allowedSignersFile ~/.config/infra-podman/allowed_signers   # solo este repo, dentro de ~/src/infra-podman
```

Compara la clave del fichero con la salida de `ssh-add -L` antes de darla por buena. Copiarla del repo es cómodo, pero quien manda es tu agente.

## 3. GitHub muestra tus firmas como verificadas

GitHub → Settings → SSH and GPG keys → **New SSH key** → tipo **Signing Key**, y pega tu clave pública. Si usas la misma clave para entrar en GitHub y para firmar, hay que darla de alta otra vez, ahora como clave de firma.

**Recomendado: dos claves distintas**, una para entrar (GitHub, servidores, `authorized_keys`) y otra solo para firmar (la que lleva el comentario `git-signing`). La de firmar es el control de producción (SPEC 5.2): si nunca sirve para entrar en ninguna máquina, se usa menos y queda menos expuesta. Las dos viven en KeePassXC y no cuesta nada mantenerlas separadas.

## 4. Comprobación

En tu copia del repo, en una rama donde `HEAD` no tenga ya un tag firmado (por ejemplo, la del PR):

```bash
git tag -s prueba-firma -m "prueba" && git verify-tag prueba-firma   # debe decir Good "git" signature for reposja@pm.me
git tag -d prueba-firma
git tag -a prueba-sin-firma -m "x" --no-sign                        # un tag sin firma...
./deploy.sh plan check                                              # ...es rechazado por deploy.sh (criterio de hecho)
git tag -d prueba-sin-firma
```

El `plan` de la prueba se rechaza antes de conectar con ningún servidor. La línea `refused` queda en `~/.local/state/infra-podman/deploy.log`.
