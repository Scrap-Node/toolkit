# toolkit

Outillage commun aux dépôts d'infrastructure : amorçage d'un hôte Debian,
secrets sops, contrôles avant push, notifications Discord.

**Ce dépôt est public.** Il ne contient ni topologie (adresses, noms d'hôtes,
domaines), ni secret, ni rien qui décrive une installation précise : chaque
dépôt qui l'utilise garde ces informations chez lui. `.forbidden-patterns`
fait respecter la règle à chaque push et en CI.

## Contenu

| Chemin | Rôle |
|---|---|
| `bootstrap/debian.sh` | Amène un hôte Debian neuf au point où `make secrets && make up` fonctionne : paquets, sops épinglé et vérifié, Docker depuis son dépôt apt, Tailscale en option, clone du dépôt |
| `validate/validate.sh` | Contrôles bloquants : Compose, YAML, JSON, secrets (`.env` en clair, `.sops` réellement chiffrés), shellcheck, motifs interdits |
| `hooks/pre-push` | Lance `validate.sh` sur chaque commit poussé, dans un worktree jetable |
| `sops/sops-files.sh` | Chiffre et déchiffre `<fichier>` ↔ `<fichier>.sops`, en passant le format explicitement |
| `make/toolkit.mk` | Cibles `secrets`, `encrypt`, `validate` et `hooks` |
| `actions/discord-notify` | Action composite : un embed Discord par exécution de workflow |
| `.github/workflows/validate.yml` | Workflow réutilisable qui lance `validate.sh` |

## Utilisation

### En sous-module

```bash
git submodule add https://github.com/Scrap-Node/toolkit.git toolkit
git -C toolkit checkout v1.0.1
```

Le sous-module épingle un commit : une nouvelle version du toolkit n'arrive
que par un commit du dépôt qui l'utilise. Dependabot les propose avec
l'écosystème `gitsubmodule` :

```yaml
# .github/dependabot.yml du dépôt consommateur
- package-ecosystem: gitsubmodule
  directory: /
  schedule:
    interval: monthly
```

### Makefile

```make
SOPS_PLAINTEXT := $(foreach s,$(STACKS),compose/$(s)/.env)
include toolkit/make/toolkit.mk
```

Chaque chemin en clair a son chiffré à côté, `<chemin>.sops`. Le format
(dotenv, YAML, JSON, INI, binaire) est déduit du nom en clair. `make hooks`
active le hook pre-push une fois par clone.

### validate.conf

À la racine du dépôt consommateur, un fichier bash lu après les valeurs par
défaut. Les globs partent de la racine, et un motif sans correspondance
disparaît :

```bash
COMPOSE_DIRS=(compose/*/)                       # défaut
YAML_FILES=(.github/workflows/*.yml config/*.yaml)
JSON_FILES=(clients/*/*.json)                   # défaut : aucun
SHELL_FILES=(scripts/*.sh)                      # défaut : scripts/*.sh .githooks/*
FORBIDDEN_PATTERNS_FILE=.forbidden-patterns     # défaut
```

Les motifs interdits sont des expressions régulières étendues, une par ligne,
cherchées dans les fichiers suivis par git. Les sous-modules ne sont pas
parcourus. Un dépôt privé y met ce qui ne doit jamais apparaître chez lui, par
exemple les références à une autre infrastructure.

Le hook utilise le toolkit du clone de travail, pas la version épinglée par le
commit poussé : un worktree jetable ne récupère pas les sous-modules.

⚠️ `git worktree add` n'initialise pas les sous-modules. Dans un nouveau
worktree, lancer `git submodule update --init` : sinon le toolkit est absent,
et avec `core.hooksPath` pointé sur lui, git n'exécute **aucun** hook, sans
rien dire. Un dépôt qui préfère un échec explicite garde son propre dossier de
hooks, qui délègue au toolkit et échoue s'il manque, et le déclare au
Makefile avant l'`include` :

```make
TOOLKIT_HOOKS_DIR := .githooks
```

### CI

```yaml
jobs:
  validate:
    uses: Scrap-Node/toolkit/.github/workflows/validate.yml@v1.0.1
```

### Notification Discord

```yaml
  notify:
    needs: [build, test]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - uses: Scrap-Node/toolkit/actions/discord-notify@v1.0.1
        with:
          webhook-url: ${{ secrets.DISCORD_WEBHOOK_CI }}
          status: ${{ contains(needs.*.result, 'failure') && 'failure' || 'success' }}
          fields: '[{"name": "Durée", "value": "12 min", "inline": true}]'
```

Champs par défaut : dépôt, branche, commit, événement. Le titre est un lien
vers l'exécution. Les textes trop longs sont tronqués aux limites de Discord,
qui sinon refuse le message. Un 429 est retenté après le délai demandé.

L'hôte doit fournir `curl` et `jq`. Pour qu'un échec d'envoi ne fasse pas
échouer le workflow : `continue-on-error: true`.

### Amorçage d'un hôte

```bash
curl -fsSLO https://raw.githubusercontent.com/Scrap-Node/toolkit/v1.0.1/bootstrap/debian.sh
REPO=git@github.com:<owner>/<repo>.git DEST=/opt/<repo> TAILSCALE=1 bash debian.sh
```

À lancer en utilisateur normal avec sudo, jamais en root : le clone doit lui
appartenir. Idempotent.

## Versions

- Les versions sont des tags `vX.Y.Z`, jamais déplacés. Pas de tag mobile `v1` :
  une référence qui change sans commit côté consommateur est exactement ce que
  l'épinglage doit empêcher.
- **sops** est épinglé dans `bootstrap/debian.sh` avec ses sommes SHA-256.
  Dependabot ne sait pas le suivre : pour monter de version, reporter la
  version et les deux sommes de `sops-v<version>.checksums.txt`, publié sur la
  page de la release.

## Développer

```bash
make hooks           # le hook de ce dépôt
make validate        # contrôles complets
make test            # validate, sops (si sops et age sont là), action Discord
```

La CI ajoute un passage de `bootstrap/debian.sh` dans des conteneurs Debian
(bookworm et trixie), deux fois de suite pour vérifier qu'il est idempotent.

La CI tourne uniquement sur les runners hébergés par GitHub. **Jamais de
runner auto-hébergé sur ce dépôt** : il est public, et n'importe quelle pull
request y exécuterait son code.

## Licence

MIT, voir `LICENSE`.
