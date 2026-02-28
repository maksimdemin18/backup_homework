#!/usr/bin/env bash
set -euo pipefail
SCRIPT_PATH="$(readlink -f "$0")"

default_config_path() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "/etc/pg_backup_manager.conf"
  else
    echo "${HOME}/.config/pg_backup_manager.conf"
  fi
}

CONFIG_FILE="$(default_config_path)"
DB_NAME="mydb"
DB_USER="postgres"
DB_HOST="127.0.0.1"
DB_PORT="5432"
BACKUP_DIR="/backups"
RETENTION_DAYS="14"
CRON_TIME="02:00"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: команда '$1' не найдена. Установите PostgreSQL client utils."
    exit 1
  }
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
  fi
}

save_config() {
  local cfg_dir
  cfg_dir="$(dirname "$CONFIG_FILE")"
  if [[ ! -d "$cfg_dir" ]]; then
    mkdir -p "$cfg_dir"
  fi

  cat >"$CONFIG_FILE" <<EOF
# pg_backup_manager config
DB_NAME="${DB_NAME}"
DB_USER="${DB_USER}"
DB_HOST="${DB_HOST}"
DB_PORT="${DB_PORT}"
BACKUP_DIR="${BACKUP_DIR}"
RETENTION_DAYS="${RETENTION_DAYS}"
CRON_TIME="${CRON_TIME}"
EOF

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    chmod 600 "$CONFIG_FILE" || true
  fi
}

ensure_backup_dir() {
  if [[ ! -d "$BACKUP_DIR" ]]; then
    mkdir -p "$BACKUP_DIR"
  fi
  chmod 700 "$BACKUP_DIR" 2>/dev/null || true
}

validate_time_hhmm() {
  local t="$1"
  [[ "$t" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]]
}

prompt() {
  local var_name="$1"
  local label="$2"
  local current="$3"
  local input

  read -r -p "${label} [${current}]: " input
  if [[ -n "${input}" ]]; then
    printf -v "$var_name" '%s' "$input"
  fi
}

prompt_config() {
  echo "=== Настройка ==="
  echo "Конфиг будет сохранён в: ${CONFIG_FILE}"
  prompt DB_NAME "Имя БД" "$DB_NAME"
  prompt DB_USER "Пользователь БД" "$DB_USER"
  prompt DB_HOST "Хост" "$DB_HOST"
  prompt DB_PORT "Порт" "$DB_PORT"
  prompt BACKUP_DIR "Каталог бэкапов" "$BACKUP_DIR"
  prompt RETENTION_DAYS "Хранить бэкапы (дней)" "$RETENTION_DAYS"

  while true; do
    prompt CRON_TIME "Время ежедневного запуска cron (HH:MM)" "$CRON_TIME"
    if validate_time_hhmm "$CRON_TIME"; then
      break
    fi
    echo "ERROR: время должно быть в формате HH:MM (например 02:00)."
  done

  save_config
  echo "OK: конфиг сохранён."
}

backup_now() {
  require_cmd pg_dump
  require_cmd find
  ensure_backup_dir

  local ts file log
  ts="$(date +'%Y-%m-%d_%H-%M-%S')"
  file="${BACKUP_DIR}/${DB_NAME}_${ts}.dump"
  log="${BACKUP_DIR}/backup.log"

  echo "[$(date --iso-8601=seconds)] START backup: db=${DB_NAME} -> ${file}" | tee -a "$log"

  pg_dump \
    -h "$DB_HOST" -p "$DB_PORT" \
    -U "$DB_USER" \
    -F c \
    -f "$file" \
    "$DB_NAME"

  chmod 600 "$file" 2>/dev/null || true

  find "$BACKUP_DIR" -type f -name "${DB_NAME}_*.dump" -mtime +"$RETENTION_DAYS" -print -delete \
    | tee -a "$log" || true

  echo "[$(date --iso-8601=seconds)] DONE backup" | tee -a "$log"
}

list_backups() {
  ensure_backup_dir
  ls -1t "${BACKUP_DIR}/${DB_NAME}_"*.dump 2>/dev/null || true
}

select_backup_interactive() {
  local files=()
  while IFS= read -r line; do
    files+=("$line")
  done < <(list_backups)

  if [[ "${#files[@]}" -eq 0 ]]; then
    echo "ERROR: бэкапы не найдены в ${BACKUP_DIR} по маске ${DB_NAME}_*.dump"
    return 1
  fi

  echo "=== Доступные бэкапы (новые сверху) ==="
  local i=1
  for f in "${files[@]}"; do
    echo "  [$i] $f"
    ((i++))
  done

  local n
  read -r -p "Выберите номер файла для восстановления: " n
  if [[ ! "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#files[@]} )); then
    echo "ERROR: неверный выбор."
    return 1
  fi

  echo "${files[$((n-1))]}"
}

db_exists() {
  require_cmd psql
  PGPASSWORD="${PGPASSWORD:-}" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null | grep -q 1
}

create_db_if_missing() {
  require_cmd createdb
  if db_exists; then
    return 0
  fi
  echo "БД '${DB_NAME}' не найдена. Создаю..."
  createdb -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$DB_NAME"
}

restore_interactive() {
  require_cmd pg_restore
  require_cmd psql
  require_cmd createdb

  local dump_file
  dump_file="$(select_backup_interactive)"

  create_db_if_missing

  local clean="n"
  read -r -p "Очистить объекты перед восстановлением? (--clean --if-exists) [y/N]: " clean
  clean="${clean,,}"

  echo "START restore: ${dump_file} -> db=${DB_NAME}"
  if [[ "$clean" == "y" || "$clean" == "yes" ]]; then
    pg_restore -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" --clean --if-exists "$dump_file"
  else
    pg_restore -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" "$dump_file"
  fi
  echo "DONE restore"
}

install_or_update_cron() {
  require_cmd crontab

  if ! validate_time_hhmm "$CRON_TIME"; then
    echo "ERROR: CRON_TIME некорректный: $CRON_TIME"
    exit 1
  fi

  local hh mm
  hh="${CRON_TIME%:*}"
  mm="${CRON_TIME#*:}"

  local cron_line
  cron_line="${mm} ${hh} * * * ${SCRIPT_PATH} --backup --config ${CONFIG_FILE} >> ${BACKUP_DIR}/cron.log 2>&1 # pg_backup_manager"

  local tmp
  tmp="$(mktemp)"

  (crontab -l 2>/dev/null | grep -v "pg_backup_manager" || true) >"$tmp"
  echo "$cron_line" >>"$tmp"
  crontab "$tmp"
  rm -f "$tmp"

  echo "OK: cron установлен/обновлён: ежедневно в ${CRON_TIME}"
}

show_cron() {
  require_cmd crontab
  crontab -l 2>/dev/null | grep "pg_backup_manager" || echo "(строка pg_backup_manager в cron не найдена)"
}

usage() {
  cat <<EOF
Использование:
  $SCRIPT_PATH                 # интерактивное меню
  $SCRIPT_PATH --setup         # интерактивная настройка + сохранение конфига
  $SCRIPT_PATH --backup        # выполнить backup сейчас (для cron)
  $SCRIPT_PATH --restore       # интерактивное восстановление
  $SCRIPT_PATH --install-cron  # установить/обновить cron по CRON_TIME из конфига
  $SCRIPT_PATH --show-cron     # показать строку cron
  $SCRIPT_PATH --config PATH   # указать файл конфига

Примечание по паролю:
  Рекомендуется использовать ~/.pgpass или переменную окружения PGPASSWORD.
EOF
}

menu() {
  while true; do
    echo
    echo "=== pg_backup_manager ==="
    echo "Config: $CONFIG_FILE"
    echo "1) Настроить (ввод с клавиатуры) и сохранить"
    echo "2) Сделать backup сейчас"
    echo "3) Восстановить (restore) из бэкапа"
    echo "4) Установить/обновить cron (по времени из конфига)"
    echo "5) Показать строку cron"
    echo "6) Показать конфиг"
    echo "0) Выход"
    read -r -p "Выбор: " choice

    case "$choice" in
      1) prompt_config ;;
      2) backup_now ;;
      3) restore_interactive ;;
      4) install_or_update_cron ;;
      5) show_cron ;;
      6) load_config; echo "----"; cat "$CONFIG_FILE" 2>/dev/null || echo "(конфиг не найден)"; echo "----" ;;
      0) exit 0 ;;
      *) echo "Неверный выбор." ;;
    esac
  done
}

main() {
  require_cmd date

  local action="menu"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        CONFIG_FILE="$2"
        shift 2
        ;;
      --setup) action="setup"; shift ;;
      --backup) action="backup"; shift ;;
      --restore) action="restore"; shift ;;
      --install-cron) action="cron"; shift ;;
      --show-cron) action="show_cron"; shift ;;
      -h|--help) usage; exit 0 ;;
      *)
        echo "ERROR: неизвестный аргумент: $1"
        usage
        exit 1
        ;;
    esac
  done

  load_config

  case "$action" in
    menu) menu ;;
    setup) prompt_config ;;
    backup) backup_now ;;
    restore) restore_interactive ;;
    cron) install_or_update_cron ;;
    show_cron) show_cron ;;
  esac
}

main "$@"
