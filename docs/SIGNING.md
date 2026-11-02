# Firma con SSH

Commits y tags se firman con tu clave SSH, que sirve el agente de KeePassXC (D13, SPEC 5.3). **El tag firmado es el control que impide desplegar en producción algo que no has aprobado tú** (SPEC 5.2).

Se hace una vez en el portátil.

## 1. Git firma con tu clave

La clave privada nunca sale de KeePassXC: git le pide la firma al agente usando la clave pública.

```bash
git config --global gpg.format ssh
git config --global user.signingkey "key::$(ssh-add -L | grep git-signing)"
git config --global user.email reposja@pm.me
git config --global tag.gpgSign true      # git tag -a/-m firma siempre
git config --global commit.gpgSign true   # opcional: firma también los commits
```

`ssh-add -L | grep git-signing` tiene que devolver una sola línea, con tu clave. KeePassXC tiene que estar desbloqueado.

## 2. Fichero de firmantes de confianza (fuera del repo)

`deploy.sh` solo se fía de **este** fichero, no del que hay en el repo (R4 en `DECISIONS.md`). Si alguien añadiera su clave al repo, no le serviría de nada.

```bash
mkdir -p ~/.config/infra-podman
cp docs/allowed_signers ~/.config/infra-podman/allowed_signers
chmod 600 ~/.config/infra-podman/allowed_signers
cat ~/.config/infra-podman/allowed_signers          # comprueba que la clave es la TUYA
git config --global gpg.ssh.allowedSignersFile ~/.config/infra-podman/allowed_signers
```

Compara la clave del fichero con la salida de `ssh-add -L` antes de darla por buena. Copiarla del repo es cómodo, pero quien manda es tu agente.

## 3. GitHub muestra tus firmas como verificadas

GitHub → Settings → SSH and GPG keys → **New SSH key** → tipo **Signing Key**, y pega tu clave pública. Es la misma clave que tienes como clave de autenticación, pero hay que darla de alta otra vez como clave de firma.

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
