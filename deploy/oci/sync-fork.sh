#!/usr/bin/env bash
set -euo pipefail
umask 077

config_dir=${1:-/etc/docker-platform/apps/nuevamente}
repo=https://github.com/LeandroMelchiori/nuevamente-g10-latam-equipo21.git
registry=ghcr.io/leandromelchiori/nuevamente-g10-latam-equipo21
host=nuevamente.sachadev.me

cd "$config_dir"
exec 9>fork-deploy.lock
flock -n 9 || exit 0

apply_release() {
  docker compose --project-name nuevamente --file compose.backend.yml --env-file "$1" \
    up -d --pull never --wait --wait-timeout 150 || return 1

  local attempt response
  for attempt in {1..6}; do
    if response=$(curl --silent --show-error --max-time 8 --output /dev/null \
        --write-out '%{http_code} %{redirect_url}' "https://$host/") &&
        [[ $response == "303 https://$host/acceso" ]]; then
      return 0
    fi
    sleep 3
  done
  printf 'La demo no redirige al acceso protegido en %s.\n' "$host" >&2
  return 1
}

main_revision() {
  git ls-remote --exit-code "$repo" refs/heads/main | cut -f1
}

registry_image() {
  local package="$registry-$1" tag revision digest
  tag="$package:$2"
  docker pull "$tag" >&2 || return 1
  revision=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$tag") || return 1
  [[ $revision == "$2" ]] || return 1
  digest=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$tag" |
    awk -v prefix="$package@" 'index($0, prefix) == 1 && !found { print; found = 1 }') || return 1
  [[ ${digest#"$package"@} =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

write_release() {
  printf '%s\n' \
    "NUEVAMENTE_BACKEND_IMAGE=$2" \
    "NUEVAMENTE_FRONTEND_IMAGE=$3" \
    "NUEVAMENTE_AUTH_IMAGE=$4" \
    "NUEVAMENTE_PUBLIC_HOST=$host" \
    "NUEVAMENTE_RELEASE_SHA=$1" > "$5"
}

# Registrar el release manual como punto de retorno antes de usar imágenes del fork.
if [[ ! -s active.env ]]; then
  backend=$(docker inspect --format '{{.Config.Image}}' nuevamente-backend-1)
  frontend=$(docker inspect --format '{{.Config.Image}}' nuevamente-frontend-1)
  auth=$(docker inspect --format '{{.Config.Image}}' nuevamente-demo_auth-1)
  write_release manual "$backend" "$frontend" "$auth" candidate.env
  mv candidate.env active.env
fi

# Si se interrumpió un despliegue, reconciliar primero el stack con el estado persistido.
if [[ -f pending ]]; then
  apply_release active.env
  mv pending rejected
fi

revision=$(main_revision)
[[ $revision =~ ^[0-9a-f]{40}$ ]]
if grep -Fxq "NUEVAMENTE_RELEASE_SHA=$revision" active.env; then
  exit 0
fi
if [[ -f rejected ]] && grep -Fxq "$revision" rejected; then
  exit 0
fi

# Se puede desplegar cuando las tres imágenes del mismo commit están disponibles.
backend=$(registry_image backend "$revision")
frontend=$(registry_image frontend "$revision")
auth=$(registry_image auth "$revision")
[[ $(main_revision) == "$revision" ]] || exit 0

write_release "$revision" "$backend" "$frontend" "$auth" candidate.env
printf '%s\n' "$revision" > pending
if apply_release candidate.env; then
  cp active.env previous.env
  mv candidate.env active.env
  rm pending
  printf 'NuevaMente desplegado desde el fork en %s.\n' "$revision"
else
  printf 'Falló %s. Restaurando la versión activa anterior.\n' "$revision" >&2
  apply_release active.env
  mv pending rejected
  exit 1
fi
