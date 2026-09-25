#!/usr/bin/env bash
#
# Deploiement de l'application sur la machine cible.
#
# Attendu dans l'environnement :
#   IMAGE       depot de l'image sans tag, ex. ghcr.io/user/devops-eval
#   SHA_SHORT   tag court du commit a deployer, ex. a1b2c3d
#   COMMIT_SHA  SHA complet, injecte dans le conteneur et verifie apres coup
#   APP_VERSION version semver, injectee dans le conteneur
#   HEALTH_URL  URL du healthcheck, ex. http://localhost:8000/health
#   STATUS_URL  URL de /status, ex. http://localhost:8000/status
#
# En cas d'echec du healthcheck, le script re-pull le SHA precedemment
# deploye et relance la stack dessus, puis sort en erreur.
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="${IMAGE:?IMAGE est obligatoire}"
SHA_SHORT="${SHA_SHORT:?SHA_SHORT est obligatoire}"
COMMIT_SHA="${COMMIT_SHA:-$SHA_SHORT}"
APP_VERSION="${APP_VERSION:-0.0.0}"
HEALTH_URL="${HEALTH_URL:-http://localhost:8000/health}"
STATUS_URL="${STATUS_URL:-http://localhost:8000/status}"

# L'etat vit hors du workspace : le runner efface son repertoire de travail.
STATE_DIR="${HOME}/.devops-eval"
STATE_FILE="${STATE_DIR}/current_sha"
mkdir -p "$STATE_DIR"

RETRIES=3
DELAY=10

log() { printf '[deploy] %s\n' "$*"; }

PREVIOUS_SHA=""
if [ -f "$STATE_FILE" ]; then
    PREVIOUS_SHA="$(tr -d '[:space:]' < "$STATE_FILE")"
fi

start_stack() {
    local tag="$1"
    log "pull de ${IMAGE}:${tag}"
    docker pull "${IMAGE}:${tag}"
    log "demarrage de la stack sur ${IMAGE}:${tag}"
    APP_IMAGE="${IMAGE}:${tag}" \
    APP_VERSION="$APP_VERSION" \
    COMMIT_SHA="$COMMIT_SHA" \
        docker compose up -d --no-build
}

check_health() {
    # Verification post-deploiement : 3 tentatives espacees.
    sleep 5
    local i
    for i in $(seq 1 "$RETRIES"); do
        if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
            log "healthcheck OK a la tentative ${i}/${RETRIES}"
            return 0
        fi
        log "healthcheck KO (${i}/${RETRIES}), nouvelle tentative dans ${DELAY}s"
        sleep "$DELAY"
    done
    return 1
}

check_deployed_sha() {
    local body seen
    body="$(curl -fsS "$STATUS_URL" 2>/dev/null || true)"
    seen="$(printf '%s' "$body" | sed -n 's/.*"commit_sha"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    if [ "$seen" != "$COMMIT_SHA" ]; then
        log "SHA deploye incoherent : attendu ${COMMIT_SHA}, recu '${seen}'"
        return 1
    fi
    log "SHA deploye verifie : ${seen}"
    return 0
}

rollback() {
    if [ -z "$PREVIOUS_SHA" ] || [ "$PREVIOUS_SHA" = "$SHA_SHORT" ]; then
        log "aucune version precedente connue : arret de la stack"
        docker compose down || true
        return
    fi
    log "ROLLBACK vers la version precedente ${PREVIOUS_SHA}"
    if start_stack "$PREVIOUS_SHA" && check_health; then
        log "rollback reussi, la version ${PREVIOUS_SHA} est de nouveau en service"
    else
        log "le rollback a lui aussi echoue, intervention manuelle necessaire"
    fi
}

log "version precedente : ${PREVIOUS_SHA:-aucune}"
log "version a deployer : ${SHA_SHORT} (${COMMIT_SHA}), semver ${APP_VERSION}"

start_stack "$SHA_SHORT"

if ! check_health; then
    log "ECHEC : le healthcheck n'est jamais passe apres ${RETRIES} tentatives"
    rollback
    exit 1
fi

if ! check_deployed_sha; then
    log "ECHEC : la version en service ne correspond pas au commit attendu"
    rollback
    exit 1
fi

printf '%s\n' "$SHA_SHORT" > "$STATE_FILE"
log "deploiement termine avec succes. Version en service : ${SHA_SHORT}"
