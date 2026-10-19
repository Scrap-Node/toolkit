# toolkit

Outillage commun aux dépôts d'infrastructure de Scrap-Node : amorçage d'un hôte
Debian, secrets sops, contrôles avant push, notifications Discord.

**Ce dépôt est public.** Il ne contient ni topologie (adresses, noms d'hôtes,
domaines), ni secret : `.forbidden-patterns` le vérifie à chaque push et en CI.
Pour la même raison, **jamais de runner auto-hébergé ici** : n'importe quelle
pull request y exécuterait son code.

## Contenu

| Chemin | Rôle |
|---|---|
| `bootstrap/debian.sh` | Amène un hôte Debian neuf au point où `make secrets && make up` fonctionne : paquets, sops épinglé et vérifié, Docker, Tailscale en option, clone du dépôt. Idempotent |
| `validate/validate.sh` | Contrôles bloquants : Compose, YAML, JSON, secrets (`.env` en clair, `.sops` non chiffrés), shellcheck, motifs interdits |
| `hooks/pre-push` | Lance `validate.sh` sur chaque commit poussé, dans un worktree jetable, avec le toolkit du clone de travail |
| `sops/sops-files.sh` | Chiffre et déchiffre `<fichier>` ↔ `<fichier>.sops` |
| `make/toolkit.mk` | Cibles `secrets`, `encrypt`, `validate` et `hooks` |
| `actions/discord-notify` | Action composite : un embed Discord par exécution de workflow |
| `.github/workflows/validate.yml` | Workflow réutilisable qui lance `validate.sh` |

## Utilisation

### Sous-module

```bash
git submodule add https://github.com/Scrap-Node/toolkit.git toolkit
git -C toolkit checkout v1.0.1
```

Pour être averti des nouvelles versions, configurer Dependabot avec
`package-ecosystem: gitsubmodule`.

⚠️ `git worktree add` n'initialise pas les sous-modules : lancer
`git submodule update --init` dans chaque nouveau worktree. Sinon le toolkit
manque, et git n'exécute **aucun** hook, sans prévenir. Pour un échec
explicite, garder un dossier de hooks local qui délègue au toolkit, déclaré
avant l'`include` : `TOOLKIT_HOOKS_DIR := .githooks`.

### Makefile

```make
SOPS_PLAINTEXT := $(foreach s,$(STACKS),compose/$(s)/.env)
include toolkit/make/toolkit.mk
```

Chaque fichier en clair a son chiffré à côté, `<chemin>.sops`. Le format est
déduit du nom. `make hooks` active le hook pre-push, une fois par clone.

### validate.conf

Un fichier bash à la racine du dépôt, lu après les valeurs par défaut. Les
globs partent de la racine, et un motif sans correspondance disparaît.

```bash
COMPOSE_DIRS=(compose/*/)                       # défaut
YAML_FILES=(.github/workflows/*.yml config/*.yaml)
JSON_FILES=(clients/*/*.json)                   # défaut : aucun
SHELL_FILES=(scripts/*.sh)                      # défaut : scripts/*.sh .githooks/*
FORBIDDEN_PATTERNS_FILE=.forbidden-patterns     # défaut
```

Dans `.forbidden-patterns`, chaque ligne est une expression régulière étendue,
cherchée dans les fichiers suivis, hors sous-modules.

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

Par défaut, l'embed affiche le dépôt, la branche, le commit et l'événement.
L'action tronque les textes aux limites de Discord et retente après un 429.
L'hôte doit fournir `curl` et `jq`. Ajouter `continue-on-error: true` pour
qu'un échec d'envoi ne fasse pas échouer le workflow.

### Amorçage d'un hôte

```bash
curl -fsSLO https://raw.githubusercontent.com/Scrap-Node/toolkit/v1.0.1/bootstrap/debian.sh
REPO=git@github.com:<owner>/<repo>.git DEST=/opt/<repo> TAILSCALE=1 bash debian.sh
```

À lancer en utilisateur normal avec sudo, jamais en root : le clone doit lui
appartenir.

## Versions

Les versions sont des tags `vX.Y.Z`, jamais déplacés, sans tag mobile `v1`.
sops est épinglé dans `bootstrap/debian.sh` avec ses sommes SHA-256, et
Dependabot ne le suit pas : pour changer de version, reporter à la main la
version et les sommes de `sops-v<version>.checksums.txt`.

## Développer

```bash
make hooks && make validate
make test     # validate, sops (si sops et age sont installés), action Discord
```

La CI exécute aussi `bootstrap/debian.sh` deux fois de suite, sur bookworm et
trixie, pour vérifier qu'il est idempotent.

## Licence

Apache 2.0, voir `LICENSE` et `NOTICE`. La licence porte sur le code : elle ne
cède ni le nom « Scrap », ni les logos, ni les autres signes distinctifs des
projets Scrap Node. Les tags jusqu'à `v1.0.1` inclus ont été publiés sous MIT et
le restent.
