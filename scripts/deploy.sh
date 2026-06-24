#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$PROJECT_ROOT/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Не найден $ENV_FILE. Скопируйте .env.example в .env и заполните его." >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required_variables=(DEPLOY_HOST DEPLOY_USER DEPLOY_PATH)
for variable in "${required_variables[@]}"; do
    if [[ -z "${!variable:-}" ]]; then
        echo "В $ENV_FILE не заполнена переменная $variable." >&2
        exit 1
    fi
done

DEPLOY_PORT="${DEPLOY_PORT:-22}"
DEPLOY_DELETE="${DEPLOY_DELETE:-false}"
DEPLOY_PASSWORD="${DEPLOY_PASSWORD:-}"
DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-}"

if [[ ! "$DEPLOY_HOST" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "DEPLOY_HOST содержит недопустимые символы." >&2
    exit 1
fi

if [[ ! "$DEPLOY_USER" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "DEPLOY_USER содержит недопустимые символы." >&2
    exit 1
fi

if [[ ! "$DEPLOY_PORT" =~ ^[0-9]+$ ]] || (( DEPLOY_PORT < 1 || DEPLOY_PORT > 65535 )); then
    echo "DEPLOY_PORT должен быть числом от 1 до 65535." >&2
    exit 1
fi

if [[ ! "$DEPLOY_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]] || [[ "$DEPLOY_PATH" == "/" ]]; then
    echo "DEPLOY_PATH должен быть безопасным абсолютным путём и не может быть корнем /." >&2
    exit 1
fi

for command_name in ssh rsync; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Для деплоя требуется команда $command_name." >&2
        exit 1
    fi
done

if [[ -z "$DEPLOY_PASSWORD" && -z "$DEPLOY_SSH_KEY" ]]; then
    echo "Укажите DEPLOY_PASSWORD или DEPLOY_SSH_KEY в $ENV_FILE." >&2
    exit 1
fi

auth_prefix=()
batch_mode_option="-o BatchMode=yes"

if [[ -n "$DEPLOY_PASSWORD" ]]; then
    if ! command -v sshpass >/dev/null 2>&1; then
        echo "Для подключения по паролю установите sshpass." >&2
        exit 1
    fi
    export SSHPASS="$DEPLOY_PASSWORD"
    auth_prefix=(sshpass -e)
    batch_mode_option=""
fi

for asset in index.html favicon.svg nginx.conf vendor; do
    if [[ ! -e "$PROJECT_ROOT/$asset" ]]; then
        echo "Не найден файл для публикации: $asset" >&2
        exit 1
    fi
done

ssh_arguments=(-p "$DEPLOY_PORT")
rsync_shell="ssh -p $DEPLOY_PORT"

if [[ -n "$batch_mode_option" ]]; then
    ssh_arguments+=(-o BatchMode=yes)
    rsync_shell+=" -o BatchMode=yes"
fi

if [[ -n "$DEPLOY_SSH_KEY" ]]; then
    ssh_key="${DEPLOY_SSH_KEY/#\~/$HOME}"
    if [[ ! -f "$ssh_key" ]]; then
        echo "SSH-ключ не найден: $ssh_key" >&2
        exit 1
    fi
    ssh_arguments+=(-i "$ssh_key")
    printf -v quoted_ssh_key '%q' "$ssh_key"
    rsync_shell+=" -i $quoted_ssh_key"
fi

remote="$DEPLOY_USER@$DEPLOY_HOST"
printf -v quoted_deploy_path '%q' "$DEPLOY_PATH"

echo "Подготавливаю каталог $remote:$DEPLOY_PATH"
"${auth_prefix[@]}" ssh "${ssh_arguments[@]}" "$remote" "mkdir -p -- $quoted_deploy_path"

rsync_arguments=(-az --checksum --human-readable --itemize-changes)
if [[ "$DEPLOY_DELETE" == "true" ]]; then
    rsync_arguments+=(--delete)
elif [[ "$DEPLOY_DELETE" != "false" ]]; then
    echo "DEPLOY_DELETE может быть только true или false." >&2
    exit 1
fi

echo "Публикую airep"
"${auth_prefix[@]}" rsync "${rsync_arguments[@]}" \
    -e "$rsync_shell" \
    "$PROJECT_ROOT/index.html" \
    "$PROJECT_ROOT/favicon.svg" \
    "$PROJECT_ROOT/nginx.conf" \
    "$PROJECT_ROOT/vendor" \
    "$remote:$DEPLOY_PATH/"

echo "Готово: airep опубликован в $remote:$DEPLOY_PATH"
