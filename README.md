# devops-eval

API HTTP en Flask, conteneurisée, avec CI/CD GitHub Actions et métriques Prometheus.
Évaluation DevOps — ESIEA.

## Lancer en local

```bash
docker compose up -d --build
```

```bash
curl http://localhost:8000/health
curl http://localhost:8000/status
curl http://localhost:8000/metrics
```

Prometheus est sur http://localhost:9090 (onglet Status > Rules pour voir les alertes).

Arrêter : `docker compose down`, ou `docker compose down -v` pour supprimer aussi les volumes.

## Lancer les tests

Les tests parlent à un vrai Redis, il faut donc le démarrer d'abord.

```bash
docker compose up -d redis
python -m venv .venv
source .venv/Scripts/activate
pip install -r requirements-dev.txt
pytest -v
flake8 .
yamllint --strict .
```

## Endpoints

| Endpoint | Réponse | Rôle |
|---|---|---|
| `/health` | 200 ou 503 | ping Redis |
| `/status` | 200 | version semver et SHA du commit déployé |
| `/visits` | 200 | compteur persisté dans Redis |
| `/metrics` | 200 | format texte Prometheus |
| `/boom` | 500 | erreur simulée, pour tester l'alerte 5xx |
| `/slow?seconds=2` | 200 | réponse lente, pour tester l'alerte de latence |

`/boom` et `/slow` servent uniquement à déclencher les alertes pendant les démos.

## Services

- `app` — l'API, servie par gunicorn, port 8000
- `redis` — dépendance applicative, données dans un volume nommé
- `prometheus` — scrape `/metrics` et évalue les règles d'alerte, port 9090

## Docker

Le `Dockerfile` est en deux stages. Le premier, sur `python:3.12-slim`, installe les
dépendances dans `/install`. Le second récupère uniquement ce dossier avec
`COPY --from=builder`, donc l'image finale n'embarque ni pip cache ni outils de build.

Image de base fixée à `python:3.12-slim`, jamais `latest`.

L'application tourne sous `appuser`, pas sous root :

```bash
docker run --rm devops-eval-app:local whoami
```

Le `HEALTHCHECK` interroge `/health`, qui vérifie lui-même Redis. Ce n'est pas un `exit 0`
déguisé : si Redis tombe, le conteneur passe `unhealthy`. La commande utilise `python`
plutôt que `curl`, absent de l'image slim.

Un seul worker gunicorn, parce que les compteurs Prometheus vivent en mémoire du process.
Avec plusieurs workers, `/metrics` renverrait les chiffres d'un worker au hasard.

Le `.dockerignore` exclut `.git`, `.github`, `.venv`, les caches et les fichiers
d'infrastructure inutiles au runtime.

## Tests

Six tests d'intégration. Pas de double : la fixture `clean_redis` échoue si Redis est
injoignable, ce qui garantit que le service est réellement utilisé.

Ce qui est vérifié : `/health` en 200 avec le bon corps ; `/visits` qui incrémente, la
valeur étant relue directement dans Redis ; `/boom` qui renvoie bien 500 ; `/metrics` qui
expose les trois familles de métriques ; et le compteur qui porte les bons labels après un
appel en succès et un appel en erreur.

## Métriques

| Métrique | Type | Labels |
|---|---|---|
| `http_requests_total` | Counter | `endpoint`, `code` |
| `http_request_duration_seconds` | Histogram | `endpoint` |
| `app_build_info` | Gauge | `version`, `commit_sha` |

Deux hooks Flask, `before_request` et `after_request`, alimentent tout ça : n'importe quelle
route est instrumentée sans code en plus.

p95 sur une route :

```promql
histogram_quantile(0.95, sum by (le, endpoint) (rate(http_request_duration_seconds_bucket[5m])))
```

## Alertes

Définies dans `monitoring/alerts.yml`.

**HighErrorRate** — ratio de 5xx > 5 %, `for: 5m`.

Seuil à 5 % : sur une API de cette taille, un échec isolé fait mécaniquement monter le ratio.
En dessous de 5 % sur 5 minutes glissantes on est dans le bruit, au-dessus c'est une panne.
`for: 5m` correspond à deux fenêtres d'évaluation : plus court, on se réveille à chaque
redémarrage de conteneur ; plus long, une panne réelle passe trop longtemps inaperçue.

Le `clamp_min` au dénominateur évite une division par zéro quand il n'y a pas de trafic —
sans lui l'expression vaut `NaN` et l'alerte ne part jamais.

**HighLatencyP95** — p95 > 500 ms, `for: 10m`.

L'application répond normalement en quelques millisecondes. Un p95 à 500 ms, c'est un
facteur 100 : une dégradation franche, pas du jitter. Le `for` est plus long que pour les
erreurs, volontairement : une latence élevée est moins urgente qu'une indisponibilité et
bien plus sujette aux faux positifs.

Pour les déclencher :

```bash
for i in $(seq 1 200); do curl -s http://localhost:8000/boom > /dev/null; sleep 2; done
for i in $(seq 1 400); do curl -s "http://localhost:8000/slow?seconds=2" > /dev/null; done
```

Il faut du trafic continu pendant toute la durée du `for:` — une rafale unique sort de la
fenêtre de 5 minutes avant que l'alerte ne bascule.

## CI

`ci.yml`, déclenchée sur pull request et sur push vers `main`.
`permissions: contents: read` en tête : la CI ne fait que lire.

| Job | Dépend de | Rôle |
|---|---|---|
| `lint` | — | flake8 |
| `lint-yaml` | — | yamllint --strict |
| `test` | `lint` | pytest sur Python 3.11 et 3.12, avec un service Redis |
| `build` | `test` | construit l'image et vérifie qu'elle sert `/metrics` |
| `ci-ok` | tous | le job requis pour merger sur `main` |

Chaque job a un `timeout-minutes`.

La matrice tourne avec `fail-fast: false` pour que les deux versions soient rapportées. Si
une case échoue, `test` échoue, donc `ci-ok` échoue, donc le merge est bloqué.

Le service Redis est déclaré avec ses `--health-cmd` et réellement utilisé : un step vérifie
qu'il répond, puis les tests écrivent et relisent dedans.

Le cache est celui de `setup-python` (`cache: pip`), avec `cache-dependency-path` sur les
deux fichiers de dépendances. Au second run sur la même branche, le step d'installation
affiche `Cache restored from key:`.

pytest produit un JUnit XML et une couverture XML, publiés par `upload-artifact` (un
artefact par version de Python). `ci-ok` les récupère avec `download-artifact`.

`ci-ok` tourne avec `if: always()` pour s'exécuter même si un job amont a échoué, et sort en
erreur si `contains(needs.*.result, 'failure')`.

### Action locale

`.github/actions/setup-app` : installation de Python avec cache pip, puis des dépendances.
`lint`, `lint-yaml` et `test` l'appellent avec `uses: ./.github/actions/setup-app`. Aucun ne
duplique ce bloc.

## CD

`cd.yml`, déclenché de deux façons seulement :

- `workflow_run` à la fin du workflow CI, restreint à `main`, avec
  `if: github.event.workflow_run.conclusion == 'success'` — donc après une CI verte
- `workflow_dispatch` manuel, avec un input `environment` valant `production`

`permissions: contents: read, packages: write`. L'authentification passe par `GITHUB_TOKEN`,
masqué par `docker/login-action`.

### build-and-push

Pousse sur `ghcr.io/alwayz-z/devops-eval` avec trois tags : `latest`, le **SHA court** du
commit, et la version semver lue dans `VERSION`.

Le tag SHA est immuable : c'est lui qui est déployé, et c'est lui qui permet de revenir à une
version antérieure précise. `latest` seul ne le permettrait pas.

### deploy

Tourne sur un runner self-hosted installé sur la machine cible, dans l'environnement
`production`, et seulement si `github.ref == 'refs/heads/main'` ou en déclenchement manuel.

Appelle `deploy/deploy.sh`, qui :

1. lit le SHA déployé dans `~/.devops-eval/current_sha`, hors du workspace que le runner
   efface à chaque run
2. pull l'image taguée par le SHA court, puis `docker compose up -d --no-build`
3. interroge `/health`, trois tentatives espacées de 10 secondes
4. compare le `commit_sha` exposé par `/status` au commit attendu
5. en cas de succès, écrit le nouveau SHA dans le fichier d'état
6. en cas d'échec, restaure le `docker-compose.yml` du commit précédent, re-pull l'image
   précédente, relance la stack dessus, et sort en erreur

Le point 6 mérite une note : une première version du script ne remettait que l'image. En
testant un déploiement cassé au niveau de la configuration, le rollback échouait — l'ancienne
image redémarrait avec la compose cassée. D'où le `git checkout <sha> -- docker-compose.yml`
et le `fetch-depth: 0` dans le workflow, sans lequel le runner n'a qu'un commit en local.

### Installer le runner

Settings > Actions > Runners > New self-hosted runner, puis suivre les commandes affichées.
Docker Desktop doit tourner, et le runner doit être lancé (`run.cmd`) pendant le déploiement.

## Sécurité

Aucun secret dans les logs : seul `GITHUB_TOKEN` est utilisé. `permissions` explicites en
tête de chaque workflow. Registry GitHub, pas de registry tiers. `timeout-minutes` partout.
Le job `lint-yaml` valide tous les YAML du dépôt, workflows compris. `concurrency` sur les
deux workflows pour éviter deux déploiements simultanés.

## Limites

Les métriques sont en mémoire du process, d'où le worker unique. Une vraie mise à l'échelle
demanderait le mode multiprocess de `prometheus_client`.

Le job `deploy` s'exécute sur un runner éphémère : `deploy/state` n'y survit pas d'un run à
l'autre. En CI le script repart donc toujours de zéro ; la persistance de l'état se vérifie
en local.

Le déploiement est un `docker compose up -d` sur une machine unique, avec une courte coupure
pendant le redémarrage du conteneur.
