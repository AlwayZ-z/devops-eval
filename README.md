# devops-eval — pipeline CI/CD complet, du code au déploiement

Évaluation DevOps — ESIEA, bloc DevOps.
API HTTP minimale en Flask, conteneurisée, testée, construite et poussée sur GitHub Container
Registry, puis déployée automatiquement sur une machine cible via un runner self-hosted,
avec vérification post-déploiement et rollback.

---

## Démarrage rapide

### Lancer le projet en local

```bash
git clone https://github.com/<OWNER>/devops-eval.git
cd devops-eval
docker compose up -d --build
```

Une seule commande suffit : elle construit l'image, démarre Redis, l'application et Prometheus.

Vérifier que tout est debout :

```bash
docker compose ps
curl http://localhost:8000/health
curl http://localhost:8000/status
curl http://localhost:8000/metrics
```

Arrêter :

```bash
docker compose down          # garde les volumes
docker compose down -v       # supprime aussi les données Redis et Prometheus
```

### Lancer les tests en local

Les tests utilisent un **vrai** Redis, il faut donc le démarrer d'abord :

```bash
docker compose up -d redis
python -m venv .venv
source .venv/Scripts/activate      # Windows / Git Bash
# source .venv/bin/activate        # Linux / macOS
pip install -r requirements-dev.txt
pytest -v
```

Lint :

```bash
flake8 .
yamllint --strict .
```

---

## Architecture

| Service | Image | Port hôte | Rôle |
|---|---|---|---|
| `app` | construite depuis le `Dockerfile` | 8000 → 5000 | l'API Flask servie par gunicorn |
| `redis` | `redis:7-alpine` | 6379 | dépendance applicative, persistée dans un volume |
| `prometheus` | `prom/prometheus:v2.53.0` | 9090 | scrape `/metrics` et évalue les règles d'alerte |

Prometheus est accessible sur <http://localhost:9090> :
onglet **Status → Rules** pour voir les deux alertes chargées,
onglet **Graph** pour interroger les métriques.

### Endpoints

| Endpoint | Réponse | Rôle |
|---|---|---|
| `GET /health` | 200 ou **503** | healthcheck réel : `PING` sur Redis |
| `GET /status` | 200 | nom du service, version semver, SHA du commit déployé |
| `GET /visits` | 200 | compteur de visites persisté dans Redis |
| `GET /metrics` | 200 | métriques au format texte Prometheus |
| `GET /boom` | **500** | erreur simulée, pour déclencher l'alerte `HighErrorRate` |
| `GET /slow?seconds=2` | 200 | réponse lente, pour déclencher l'alerte `HighLatencyP95` |

`/boom` et `/slow` existent uniquement pour pouvoir **démontrer** que les règles d'alerte
se déclenchent réellement. Ils ne sont pas du code applicatif utile.

---

## Docker

### `Dockerfile`

- **Multi-stage** : un stage `builder` sur `python:3.12-slim` installe les dépendances dans
  `/install`, le stage final ne récupère que ce dossier via `COPY --from=builder`. Ni pip
  cache, ni outils de build dans l'image livrée.
- **Image de base précise** : `python:3.12-slim`, jamais `latest`, et variante slim.
- **Pas de root** : l'application tourne sous l'utilisateur `appuser`, créé sans shell de
  connexion. Vérifiable :

  ```bash
  docker run --rm devops-eval-app:local whoami   # appuser
  ```

- **HEALTHCHECK réel** : il interroge `/health`, qui vérifie lui-même Redis. Ce n'est pas un
  `exit 0` déguisé — si Redis tombe, le conteneur passe `unhealthy`. La commande utilise
  `python` et non `curl`, absent de l'image slim.
- **Un seul worker gunicorn** : les métriques Prometheus sont tenues en mémoire du processus.
  Avec plusieurs workers, `/metrics` renverrait les compteurs d'un worker au hasard.

### `.dockerignore`

Exclut `.git`, mais aussi `.github`, `.venv`, les caches Python, les rapports de tests et les
fichiers d'infrastructure inutiles au runtime. Le contexte de build tombe à quelques kilo-octets.

---

## Tests

Les tests sont des tests d'intégration : ils parlent à un vrai Redis, jamais à un double.
La fixture `clean_redis` échoue volontairement si Redis est injoignable — un service déclaré
mais ignoré serait refusé par le sujet, donc ici il est réellement utilisé.

Ce qui est vérifié :

- `/health` renvoie 200 **et** le bon corps de réponse quand Redis répond ;
- `/visits` incrémente, et la valeur est relue **directement dans Redis** (`clean_redis.get("visits") == "2"`) — c'est la preuve de l'interaction réelle avec le service ;
- `/boom` renvoie bien un code 500 ;
- `/metrics` expose les trois familles de métriques exigées ;
- le compteur porte bien les labels `endpoint` et `code`, avec les bonnes valeurs après un appel en succès et un appel en erreur.

Rapports produits : JUnit XML et couverture XML, publiés en artefacts par la CI.

---

## Instrumentation et métriques

`/metrics` expose, au format texte Prometheus :

| Métrique | Type | Labels | Rôle |
|---|---|---|---|
| `http_requests_total` | Counter | `endpoint`, `code` | nombre de requêtes reçues, ventilé par route et par code HTTP |
| `http_request_duration_seconds` | Histogram | `endpoint` | durée des requêtes, en buckets, permet de calculer p95 et p99 |
| `app_build_info` | Gauge | `version`, `commit_sha` | vaut toujours 1 ; porte la version et le SHA actuellement déployés |

Les métriques sont alimentées par deux hooks Flask, `before_request` et `after_request` :
toute route existante ou future est instrumentée sans code supplémentaire.

Calcul du p95 sur une route :

```promql
histogram_quantile(
  0.95,
  sum by (le, endpoint) (rate(http_request_duration_seconds_bucket[5m]))
)
```

### Règles d'alerte

Définies dans `monitoring/alerts.yml`, chargées par Prometheus au démarrage.

**`HighErrorRate` — taux d'erreurs 5xx, seuil 5 %, `for: 5m`**

```promql
sum(rate(http_requests_total{code=~"5.."}[5m]))
/
clamp_min(sum(rate(http_requests_total[5m])), 0.001) > 0.05
```

*Justification du seuil* : sur une API de cette taille, un échec isolé (un redémarrage de
Redis, une requête malformée) fait mécaniquement monter le ratio. En dessous de 5 % sur une
fenêtre glissante de 5 minutes, on est dans le bruit de fond. Au-dessus, c'est une panne.

*Justification du `for: 5m`* : deux fenêtres d'évaluation complètes. Un `for` plus court
réveillerait quelqu'un à chaque redémarrage de conteneur ; un `for` plus long laisserait une
panne réelle passer inaperçue trop longtemps pour une alerte `critical`.

Le `clamp_min` évite une division par zéro quand l'application ne reçoit aucun trafic — sans
lui l'expression renvoie `NaN` et l'alerte ne se déclenche jamais.

**`HighLatencyP95` — latence dégradée, seuil 500 ms, `for: 10m`**

```promql
histogram_quantile(
  0.95,
  sum by (le, endpoint) (rate(http_request_duration_seconds_bucket[5m]))
) > 0.5
```

*Justification du seuil* : l'application répond normalement en quelques millisecondes. Un p95
à 500 ms représente un facteur 100 : ce n'est plus du jitter, c'est une dégradation franche.

*Justification du `for: 10m`* : plus long que pour les erreurs, délibérément. Une latence
élevée est moins urgente qu'une indisponibilité, et bien plus sujette aux faux positifs
(montée en charge ponctuelle, pause GC, scrape manqué). Dix minutes filtrent ces transitoires.

### Démontrer les alertes

```bash
for i in $(seq 1 50); do curl -s http://localhost:8000/boom > /dev/null; done
curl -s "http://localhost:8000/slow?seconds=2" > /dev/null
```

Puis <http://localhost:9090/alerts> : les alertes passent en `PENDING`, puis en `FIRING`
une fois la durée du `for:` écoulée.

---

## CI — `.github/workflows/ci.yml`

Déclenchée sur **toute pull request** et sur **push vers `main`**.
`permissions: contents: read` en tête du workflow : moindre privilège, la CI ne fait que lire.

Cinq jobs, chacun avec un `timeout-minutes` :

| Job | Dépend de | Rôle |
|---|---|---|
| `lint` | — | flake8 |
| `lint-yaml` | — | yamllint `--strict` sur tous les YAML du dépôt |
| `test` | `lint` | pytest sur une matrice Python 3.11 / 3.12, avec un service Redis |
| `build` | `test` | construit l'image et vérifie qu'elle démarre et sert `/metrics` |
| `ci-ok` | tous | porte d'entrée : c'est **ce job** qui est requis pour merger sur `main` |

**Matrice** : `python-version: ["3.11", "3.12"]`, `fail-fast: false` pour que les deux cases
soient rapportées. Si une case échoue, le job `test` échoue, donc `ci-ok` échoue, donc le
merge est bloqué.

**Service Redis** : déclaré dans `services:` avec ses `--health-cmd`, et réellement utilisé —
un step dédié vérifie qu'il répond avant les tests, puis les tests eux-mêmes écrivent et
relisent dans Redis.

**Cache** : géré par le cache natif de `setup-python` (`cache: pip`), avec
`cache-dependency-path` sur les deux fichiers de dépendances. Un second run sur la même
branche affiche `Cache restored from key: ...` dans le step *Installer Python* — c'est la
preuve du cache HIT demandée.

**Rapports** : JUnit XML et couverture XML produits par pytest, publiés par
`actions/upload-artifact` (un artefact par version de Python). Le job `ci-ok` les récupère
avec `actions/download-artifact` et les liste.

**`ci-ok`** tourne avec `if: always()` pour s'exécuter même si un job amont a échoué, et
échoue explicitement si `contains(needs.*.result, 'failure')`. C'est ce job qu'il faut
déclarer en *required status check* dans la protection de branche.

### Réutilisabilité — `.github/actions/setup-app`

Action composite locale de trois steps : installation de Python avec cache pip, installation
des dépendances, affichage de l'environnement. Les jobs `lint`, `lint-yaml` et `test`
l'appellent avec `uses: ./.github/actions/setup-app` ; aucun ne duplique ce bloc.

---

## CD — `.github/workflows/cd.yml`

Déclenché de deux façons seulement :

- `workflow_run` sur la fin du workflow **CI**, restreint à la branche `main`, avec
  `if: github.event.workflow_run.conclusion == 'success'` — autrement dit **uniquement après
  une CI verte sur `main`** ;
- `workflow_dispatch` manuel, avec un input `environment` dont la valeur est `production`.

`permissions: contents: read, packages: write` : le strict nécessaire pour lire le code et
pousser sur le registry GitHub. L'authentification se fait avec `GITHUB_TOKEN`, jamais avec
un secret personnel, et `docker/login-action` le masque dans les logs.

### `build-and-push`

Construit l'image et la pousse sur `ghcr.io/<owner>/devops-eval` avec **trois tags** :

| Tag | Exemple | Rôle |
|---|---|---|
| `latest` | `latest` | dernière version en date |
| SHA court | `a1b2c3d` | **immuable** : identifie exactement un commit, c'est ce tag qui est déployé |
| semver | `1.0.0` | lu dans le fichier `VERSION` |

Se limiter à `latest` interdirait de revenir à une version antérieure précise : c'est
justement ce dont le rollback a besoin.

### `deploy`

Tourne sur un **runner self-hosted** installé sur la machine cible
(`runs-on: self-hosted`), dans l'environnement GitHub `production`, et seulement si
`github.ref == 'refs/heads/main'` ou en déclenchement manuel.

Il appelle `deploy/deploy.sh`, qui :

1. lit le SHA précédemment déployé dans `~/.devops-eval/current_sha` — hors du workspace,
   que le runner efface à chaque run ;
2. `docker pull` de l'image taguée par le SHA court, puis `docker compose up -d --no-build` ;
3. **vérification post-déploiement** : `curl` sur `/health`, **3 tentatives** espacées de
   10 secondes ;
4. vérifie en plus que le `commit_sha` exposé par `/status` correspond bien au commit
   attendu — sans ce contrôle, un déploiement qui aurait silencieusement relancé l'ancienne
   image passerait le healthcheck ;
5. en cas de succès, écrit le nouveau SHA dans le fichier d'état ;
6. **en cas d'échec**, re-pull le SHA précédent, relance la stack dessus, et sort en erreur.
   Le job GitHub est donc rouge, et la machine cible tourne de nouveau sur la dernière
   version saine.

### Installer le runner self-hosted

Dans le dépôt : **Settings → Actions → Runners → New self-hosted runner**, puis suivre les
commandes affichées (elles contiennent un token à usage unique). Sur Windows, PowerShell
en administrateur :

```powershell
mkdir actions-runner; cd actions-runner
# les trois commandes exactes sont données par la page GitHub
./config.cmd --url https://github.com/<OWNER>/devops-eval --token <TOKEN>
./run.cmd
```

Docker Desktop doit tourner sur cette machine, et le runner doit rester ouvert pendant le
déploiement.

---

## Qualité et sécurité

- Aucun secret n'est affiché : seul `GITHUB_TOKEN` est utilisé, passé à
  `docker/login-action` qui le masque. Aucun `echo` de variable sensible.
- `permissions` déclarées explicitement en tête de **chaque** workflow, au plus juste.
- Registry GitHub (`ghcr.io`), pas de registry tiers ni d'identifiants externes.
- `timeout-minutes` sur **tous** les jobs : un job bloqué ne consomme pas indéfiniment.
- Le job `lint-yaml` valide tous les fichiers YAML du dépôt, workflows compris.
- `concurrency` sur les deux workflows : pas de déploiements concurrents sur la même cible.

---

## Où trouver quoi

| Exigence du sujet | Emplacement |
|---|---|
| Dockerfile multi-stage, base précise, non-root, HEALTHCHECK | `Dockerfile` |
| `.dockerignore` excluant `.git` | `.dockerignore` |
| Compose, 2 services minimum, port mappé, healthcheck | `docker-compose.yml` (3 services) |
| Test automatisé pertinent | `test_app.py` |
| `ci.yml` sur PR et push main | `.github/workflows/ci.yml` |
| 4 jobs minimum + `ci-ok` bloquant | `ci.yml` (5 jobs) |
| `strategy.matrix` deux versions de runtime | job `test` |
| `services:` réellement utilisé | job `test` + fixture `clean_redis` |
| Cache des dépendances | action composite, `cache: pip` |
| Rapports JUnit / coverage + download-artifact | jobs `test` et `ci-ok` |
| `timeout-minutes` sur chaque job | les deux workflows |
| `cd.yml` sur push main après CI verte | `.github/workflows/cd.yml`, `workflow_run` |
| `workflow_dispatch` avec input environment | `cd.yml` |
| Trois tags d'image | job `build-and-push` |
| Déploiement réel sur la machine cible | job `deploy`, `runs-on: self-hosted` |
| Healthcheck post-déploiement, 3 retries | `deploy/deploy.sh`, `check_health()` |
| Rollback par re-pull du SHA précédent | `deploy/deploy.sh`, `rollback()` |
| Action locale réutilisable | `.github/actions/setup-app/action.yml` |
| Lint YAML | job `lint-yaml` |
| `permissions` explicites | en tête de `ci.yml` et `cd.yml` |
| `/metrics` : counter, histogram, gauge | `app.py` |
| Alerte taux d'erreurs 5xx | `monitoring/alerts.yml`, `HighErrorRate` |
| Alerte latence p95 | `monitoring/alerts.yml`, `HighLatencyP95` |

---

## Limites assumées

- Les métriques sont en mémoire du processus : l'application tourne donc avec **un seul
  worker** gunicorn. Une vraie mise à l'échelle demanderait le mode multiprocess de
  `prometheus_client`, avec un répertoire partagé entre workers.
- Le déploiement est un `docker compose up -d` sur une machine unique. Il y a une courte
  interruption pendant le redémarrage du conteneur — un vrai zéro-downtime demanderait un
  schéma blue/green avec un frontal, hors du périmètre de cette évaluation.
- `/boom` et `/slow` sont des endpoints de démonstration ; ils n'auraient pas leur place
  dans une application réelle.
