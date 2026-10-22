#!/usr/bin/env bash
#
# dt.sh — DTunnel Proto Server (unificado em um único arquivo)
# Combina install-server.sh + proto-server.sh em um só script.
#
#   Instalar/atualizar:  sudo ./dt.sh install
#   Menu interativo:     sudo ./dt.sh          (ou: sudo ./dt.sh menu)
#   Ajuda:               sudo ./dt.sh help

set -euo pipefail

declare -A COLORS=(
    ["INFO"]="\033[1;36m"
    ["WARN"]="\033[1;33m"
    ["ERROR"]="\033[1;31m"
    ["SUCCESS"]="\033[1;32m"
    ["EXIT"]="\033[1;32m"
    ["TITLE"]="\033[1;34m"
    ["PROMPT"]="\033[1;33m"
    ["RESET"]="\033[0m"
)

# ------------------------------------------------------------------
# Variáveis (unificadas de install-server.sh e proto-server.sh)
# ------------------------------------------------------------------
# Única fonte de download: link do Dropbox (somente arm64 por enquanto).
# Se trocar o arquivo no Dropbox, ajuste a versão e o SHA256 abaixo.
DROPBOX_VERSION="v3.2.0"

# instalador
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/proto-server"
SERVICE_FILE="/etc/systemd/system/proto-server.service"
LEGACY_SERVICES=("proto-server.service" "dtproto.service" "proxydt.service" "proxy-443.service" "proxy-80.service")

# comuns
BINARY_PATH="${INSTALL_DIR}/proto-server"
CONFIG_FILE="${CONFIG_DIR}/config.json"
STATS_FILE="${CONFIG_DIR}/stats.json"
PAM_SERVICE_FILE="/etc/pam.d/proto-server"
SERVICE_NAME="proto-server.service"

# menu
INNER_WIDTH=55
COL_WIDTH=27
INPUT_EOF="__DTPROTO_INPUT_EOF__"
TOKEN_VALIDATION_ATTEMPTS=3
TOKEN_VALIDATION_RETRY_DELAY=2
LATEST_VERSION=""
UPDATE_AVAILABLE=false
ensure_dependencies() {
  print_message "INFO" "Instalando dependências do sistema e PAM..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq curl jq libpam0g libpam-modules >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q curl jq pam >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl jq pam >/dev/null
  else
    print_message "ERROR" "Distribuição não suportada. É necessário instalar jq e Linux-PAM."
    exit 1
  fi

  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    print_message "ERROR" "Não foi possível instalar curl e jq."
    exit 1
  fi

  if ! ldconfig -p 2>/dev/null | grep 'libpam\.so\.0' >/dev/null; then
    print_message "ERROR" "A biblioteca libpam.so.0 não está disponível."
    exit 1
  fi

  print_message "SUCCESS" "Dependências PAM instaladas."
}

ensure_glibc() {
  if getconf GNU_LIBC_VERSION >/dev/null 2>&1; then
    return
  fi

  print_message "ERROR" "Esta versão requer uma distribuição glibc. Alpine/musl não é suportado."
  exit 1
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) echo "linux-amd64" ;;
    *)
      print_message "ERROR" "Apenas amd64/x86_64 suportado: ${arch}"
      exit 1
      ;;
  esac
}

fetch_latest_version() {
  echo "v3.2.0"
  return
}

cleanup_legacy_installations() {
  print_message "INFO" "Detectando e removendo versões anteriores, serviços e processos antigos..."

  for svc in "${LEGACY_SERVICES[@]}"; do
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
      print_message "WARN" "Parando serviço antigo: ${svc}"
      systemctl stop "${svc}" 2>/dev/null || true
    fi
    if systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
      systemctl disable "${svc}" 2>/dev/null || true
    fi
    if [[ -f "/etc/systemd/system/${svc}" ]]; then
      rm -f "/etc/systemd/system/${svc}"
    fi
  done

  systemctl daemon-reload 2>/dev/null || true

  pkill -9 -f "proto-server" 2>/dev/null || true
  pkill -9 -f "proxy-server" 2>/dev/null || true

  print_message "SUCCESS" "Limpeza prévia concluída."
}

configure_sysctl() {
  print_message "INFO" "Otimizando parâmetros de rede do Kernel (sysctl, BBR, buffers de 64MB)..."
  local sysctl_file="/etc/sysctl.d/99-dtproto.conf"
  cat <<'EOF' > "${sysctl_file}"
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.core.netdev_max_backlog = 100000
net.ipv4.tcp_fastopen = 3
EOF
  modprobe tcp_bbr 2>/dev/null || true
  sysctl --system >/dev/null 2>&1 || true
  print_message "SUCCESS" "Parâmetros sysctl otimizados com sucesso."
}

setup_config() {
  mkdir -p "${CONFIG_DIR}"
  if [[ -f "${CONFIG_FILE}" ]]; then
    local tmp
    tmp=$(mktemp)
    jq '.server.auth = {"system": true} | .server.tun.buffer_size = 65536' "${CONFIG_FILE}" > "${tmp}"
    mv "${tmp}" "${CONFIG_FILE}"
    print_message "SUCCESS" "Configuração de autenticação migrada para PAM e buffers otimizados."
    return 0
  fi

  print_message "INFO" "Criando arquivo de configuração padrão em ${CONFIG_FILE}..."
  cat <<EOF > "${CONFIG_FILE}"
{
  "server": {
    "virtual_subnet_cidr": "10.10.0.0/16",
    "stats_file": "${STATS_FILE}",
    "auth": {
      "system": true
    },
    "tun": {
      "name": "tun0",
      "buffer_size": 65536
    }
  },
  "proxy": {
    "enabled": true,
    "listen": [
      {
        "host": "0.0.0.0",
        "port": 443,
        "ssl": true
      },
      {
        "host": "0.0.0.0",
        "port": 80,
        "ssl": false
      }
    ]
  }
}
EOF
  print_message "SUCCESS" "Configuração criada em ${CONFIG_FILE}."
}

install_pam_service() {
  print_message "INFO" "Configurando serviço PAM em ${PAM_SERVICE_FILE}..."
  mkdir -p "$(dirname "${PAM_SERVICE_FILE}")"
  cat <<'EOF' > "${PAM_SERVICE_FILE}"
auth required pam_unix.so nodelay
account required pam_unix.so
EOF
  chmod 0644 "${PAM_SERVICE_FILE}"
  print_message "SUCCESS" "Serviço PAM proto-server configurado."
}

install_systemd_service() {
  print_message "INFO" "Instalando serviço systemd em ${SERVICE_FILE}..."
  cat <<EOF > "${SERVICE_FILE}"
[Unit]
Description=DTunnel Protocolo Server
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/proto-server --config ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  print_message "SUCCESS" "Serviço proto-server.service configurado."
}

download_binary() {
  local version=$1
  local arch=$2
  local target_dir=$3
  local artifact="proto-server-${arch}"
  local binary="${target_dir}/${artifact}"

  [[ "${arch}" == "linux-amd64" ]] || { print_message "ERROR" "Apenas amd64/x86_64 suportado."; exit 1; }

  local download_url="https://github.com/zuri294/proto_mod/raw/refs/heads/main/proto-server.bin"
  local expected_sha256="12b4eb5deea0de0a8ed53ed008ec1ff7c1ebe9617f50e4d0fad12093bc858baf"

  print_message "INFO" "Baixando binário sem validação de token (apenas amd64)..."
  if ! curl -fsSL --connect-timeout 15 --max-time 600 -o "${binary}" "${download_url}"; then
    print_message "ERROR" "Erro ao baixar o binário."
    exit 1
  fi

  printf '%s  %s
' "${expected_sha256}" "${artifact}" > "${binary}.sha256"
  if ! (cd "${target_dir}" && sha256sum -c "${artifact}.sha256" >/dev/null); then
    print_message "ERROR" "O checksum do binário baixado é inválido."
    exit 1
  fi

  chmod 0755 "${binary}"
  if ! ldd "${binary}" 2>/dev/null | grep 'libpam\.so\.0' >/dev/null; then
    print_message "ERROR" "O binário baixado não possui suporte PAM válido para esta VPS."
    exit 1
  fi

  if ! "${binary}" --version >/dev/null 2>&1; then
    print_message "ERROR" "O binário PAM não é compatível com a biblioteca C desta VPS."
    exit 1
  fi

  echo "${binary}"
}

download_menu_script() {
  print_message "INFO" "Instalando menu interativo 'proto' (dt.sh unificado)..."

  local self target
  self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  target="${INSTALL_DIR}/proto"

  # Instala este próprio arquivo (dt.sh) como comando 'proto',
  # mantendo instalador e menu no mesmo script.
  if [[ -e "${target}" ]] && [[ "$(readlink -f "${target}" 2>/dev/null || echo '')" == "${self}" ]]; then
    chmod +x "${target}" 2>/dev/null || true
    print_message "SUCCESS" "Menu de gerenciamento já instalado em ${target} (dt.sh)."
    return
  fi

  if [[ -r "${self}" ]] && cat "${self}" > "${target}" 2>/dev/null; then
    chmod +x "${target}"
    print_message "SUCCESS" "Menu de gerenciamento instalado em ${target} (dt.sh)."
    return
  fi

  print_message "WARN" "Não foi possível instalar o menu 'proto'. Rode: sudo ./dt.sh menu"
}

install_binary() {
  local candidate=$1
  cleanup_legacy_installations
  install -m 0755 "${candidate}" "${INSTALL_DIR}/proto-server"
  install_systemd_service
  if systemctl start proto-server.service; then
    systemctl enable proto-server.service >/dev/null 2>&1 || true
    print_message "SUCCESS" "Serviço proto-server.service iniciado."
  else
    print_message "WARN" "O serviço não iniciou. Execute 'proto' para configurar o token e tente novamente."
  fi
}

main() {
  clear
  local title="INSTALADOR DO DTUNNEL PROTOCOLO SERVER"
  local padding=4
  local inner_width=$(( ${#title} + padding * 2 ))
  local border
  printf -v border '%*s' "${inner_width}" ''
  border=${border// /═}
  echo -e "${COLORS[TITLE]}╔${border}╗${COLORS[RESET]}"
  echo -e "${COLORS[TITLE]}║${COLORS[SUCCESS]}$(printf '%*s' "${padding}" '')${title}$(printf '%*s' "${padding}" '')${COLORS[RESET]}${COLORS[TITLE]}║${COLORS[RESET]}"
  echo -e "${COLORS[TITLE]}╚${border}╝${COLORS[RESET]}"
  echo ""

  check_root "instalador"
  ensure_dependencies
  ensure_glibc

  local arch
  arch=$(detect_arch)
  print_message "INFO" "Arquitetura detectada: ${arch}"
  print_message "INFO" "Instalando binário sem validação de token (apenas amd64)..."

  local version="v3.2.0"
  local display_version="3.2.0"

  local download_dir
  download_dir=$(mktemp -d)
  trap "rm -rf '${download_dir}'" EXIT

  local candidate
  candidate=$(download_binary "${version}" "${arch}" "${download_dir}")

  configure_sysctl
  setup_config
  install_pam_service

  print_message "INFO" "Instalando o serviço proto-server..."
  install_binary "${candidate}"

  print_message "SUCCESS" "Binário proto-server instalado em ${INSTALL_DIR}/proto-server."
  download_menu_script

  echo ""
  print_message "SUCCESS" "DTunnel Protocolo Server v${display_version} instalado com sucesso!"
  print_message "INFO" "Para abrir o menu, execute: ${COLORS[ERROR]}proto${COLORS[RESET]}"
  echo ""
}

print_message() {
    local type="$1"
    local message="$2"
    local prefix="[INFO]"
    case "$type" in
        "SUCCESS") prefix="[OK]" ;;
        "WARN")    prefix="[AVISO]" ;;
        "ERROR")   prefix="[ERRO]" ;;
        "PROMPT")  prefix="[>]" ;;
        "EXIT")    prefix="[SAIR]" ;;
    esac
    local color="${COLORS[$type]:-${COLORS[INFO]}}"
    printf '%b%s %s%b\n' "${color}" "${prefix}" "${message}" "${COLORS[RESET]}" >&2
}

format_prompt() {
    echo -e "${COLORS[PROMPT]}[>] $1${COLORS[RESET]}"
}

read_input() {
    local prompt_text="$1"
    local default_value="${2:-}"
    local default_label="${3:-$default_value}"
    local value

    if [[ -n "$default_value" && ${#default_label} -gt 15 ]]; then
        printf '%s\n' "$(format_prompt "Padrão: [${default_label}]")" >&2
        if ! read -r -p "$(format_prompt "$prompt_text"): " value; then
            echo "${INPUT_EOF}"
            return 0
        fi
        echo "${value:-$default_value}"
        return
    fi

    if [[ -n "$default_value" ]]; then
        if ! read -r -p "$(format_prompt "$prompt_text") [${default_label}]: " value; then
            echo "${INPUT_EOF}"
            return 0
        fi
        echo "${value:-$default_value}"
        return
    fi

    if ! read -r -p "$(format_prompt "$prompt_text"): " value; then
        echo "${INPUT_EOF}"
        return 0
    fi
    echo "$value"
}

wait_for_enter() {
    read -r -p "$(format_prompt 'Pressione Enter para continuar...')" _ || true
}

clear_screen() {
  if [[ -t 1 ]]; then
    printf '\033[2J\033[H'
  fi
}

trim_input() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

shorten_text() {
  local value="$1"
  local max_length="${2:-42}"
  if (( ${#value} <= max_length )); then
    printf '%s' "${value}"
    return
  fi
  printf '...%s' "${value: -$((max_length - 3))}"
}

normalize_choice() {
  local value
  value=$(trim_input "$1")
  if [[ "${value}" == "${INPUT_EOF}" ]]; then
    printf '0'
    return
  fi
  if [[ -z "${value}" ]]; then
    printf '0'
    return
  fi
  if [[ "${value}" =~ ^[0-9]+$ && ${#value} -le 2 ]]; then
    printf '%d' "$((10#${value}))"
    return
  fi
  printf '%s' "${value}"
}

valid_port() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]+$ ]] || return 1
  (( ${#value} <= 5 )) || return 1
  local decimal=$((10#${value}))
  (( decimal >= 1 && decimal <= 65535 ))
}

valid_positive_integer() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]+$ ]] || return 1
  (( ${#value} <= 10 )) || return 1
  (( 10#${value} > 0 ))
}

update_config() {
  local tmp
  tmp=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")
  if jq "$@" "${CONFIG_FILE}" > "${tmp}"; then
    chmod 0600 "${tmp}"
    mv "${tmp}" "${CONFIG_FILE}"
    return 0
  fi

  unlink "${tmp}"
  print_message "ERROR" "Não foi possível atualizar ${CONFIG_FILE}."
  return 1
}

restart_service() {
  if systemctl restart "${SERVICE_NAME}"; then
    return 0
  fi
  print_message "ERROR" "A configuração foi salva, mas o serviço não reiniciou."
  return 1
}

run_service_action() {
  local action="$1"
  local success_message="$2"
  if systemctl "${action}" "${SERVICE_NAME}"; then
    print_message "SUCCESS" "${success_message}"
    sleep 1.5
    return 0
  fi
  print_message "ERROR" "Falha ao executar '${action}' no serviço."
  sleep 1.5
}

check_dependencies() {
  local command_name
  for command_name in curl jq systemctl; do
    if command -v "${command_name}" >/dev/null 2>&1; then
      continue
    fi
    print_message "ERROR" "Dependência ausente: ${command_name}."
    return 1
  done
}

visible_len() {
  local str="$1"
  local stripped
  stripped=$(echo -e "${str}" | sed -r 's/\x1B\[[0-9;]*[mK]//g')
  LC_ALL=C.UTF-8 echo "${#stripped}"
}

center_text() {
  local text="$1"
  local width="${2:-$INNER_WIDTH}"
  local vlen
  vlen=$(visible_len "$text")
  local pad=$(( (width - vlen) / 2 ))
  if (( pad < 0 )); then
    pad=0
  fi
  printf "%*s%s" $pad "" "$text"
}

draw_box_line() {
  local content="$1"
  local width="${2:-$INNER_WIDTH}"
  local vlen
  vlen=$(visible_len "${content}")
  local pad=$(( width - vlen ))
  if (( pad < 0 )); then
    pad=0
  fi
  local spaces
  spaces=$(printf '%*s' "${pad}" '')

  echo -e "${COLORS[TITLE]}║${COLORS[RESET]} ${content}${spaces} ${COLORS[TITLE]}║${COLORS[RESET]}"
}

draw_two_column_line() {
  local left_str="$1"
  local right_str="${2:-}"
  local col_width="${3:-$COL_WIDTH}"

  local left_vlen
  left_vlen=$(visible_len "${left_str}")
  local right_vlen
  right_vlen=$(visible_len "${right_str}")

  local left_pad=$(( col_width - left_vlen ))
  if (( left_pad < 0 )); then
    left_pad=0
  fi
  local left_spaces
  left_spaces=$(printf '%*s' "${left_pad}" '')

  local right_pad=$(( col_width - right_vlen ))
  if (( right_pad < 0 )); then
    right_pad=0
  fi
  local right_spaces
  right_spaces=$(printf '%*s' "${right_pad}" '')

  local line_content="${left_str}${left_spaces} ${right_str}${right_spaces}"
  draw_box_line "${line_content}" $INNER_WIDTH
}

draw_header() {
  local title="$1"
  local subtitle="${2:-}"
  local inner_width="${3:-$INNER_WIDTH}"
  local bar_width=$(( inner_width + 2 ))

  local line_bar
  line_bar=$(printf '═%.0s' $(seq 1 $bar_width))

  echo -e "${COLORS[TITLE]}╔${line_bar}╗${COLORS[RESET]}"
  draw_box_line "${COLORS[SUCCESS]}$(center_text "$title" $inner_width)${COLORS[RESET]}" $inner_width
  if [[ -n "$subtitle" ]]; then
    draw_box_line "${COLORS[INFO]}$(center_text "$subtitle" $inner_width)${COLORS[RESET]}" $inner_width
  fi
  echo -e "${COLORS[TITLE]}╠${line_bar}╣${COLORS[RESET]}"
}

draw_separator() {
  local inner_width="${1:-$INNER_WIDTH}"
  local bar_width=$(( inner_width + 2 ))
  local line_bar
  line_bar=$(printf '═%.0s' $(seq 1 $bar_width))
  echo -e "${COLORS[TITLE]}╠${line_bar}╣${COLORS[RESET]}"
}

draw_footer() {
  local inner_width="${1:-$INNER_WIDTH}"
  local bar_width=$(( inner_width + 2 ))
  local line_bar
  line_bar=$(printf '═%.0s' $(seq 1 $bar_width))
  echo -e "${COLORS[TITLE]}╚${line_bar}╝${COLORS[RESET]}"
}

draw_menu_option() {
  local num="$1"
  local label="$2"
  local inner_width="${3:-$INNER_WIDTH}"
  local line_str="${COLORS[INFO]}[${COLORS[SUCCESS]}${num}${COLORS[INFO]}] ${COLORS[SUCCESS]}• ${COLORS[ERROR]}${label}${COLORS[RESET]}"
  draw_box_line "${line_str}" $inner_width
}

format_option_str() {
  local num="$1"
  local label="$2"
  echo -e "${COLORS[INFO]}[${COLORS[SUCCESS]}${num}${COLORS[INFO]}] ${COLORS[SUCCESS]}• ${COLORS[ERROR]}${label}${COLORS[RESET]}"
}

get_installed_version() {
  if [[ ! -x "${BINARY_PATH}" ]]; then
    echo "v3.0.0"
    return
  fi

  local ver
  ver=$("${BINARY_PATH}" -v 2>/dev/null | awk '{print $NF}' | sed 's/^v//i' || true)
  if [[ -n "${ver}" ]]; then
    echo "v${ver}"
    return
  fi

  echo "v3.0.0"
}

version_is_newer() {
  local candidate="${1#v}"
  local current="${2#v}"
  local candidate_major candidate_minor candidate_patch
  local current_major current_minor current_patch

  if [[ ! "${candidate}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    return 1
  fi
  candidate_major=$((10#${BASH_REMATCH[1]}))
  candidate_minor=$((10#${BASH_REMATCH[2]}))
  candidate_patch=$((10#${BASH_REMATCH[3]}))

  if [[ ! "${current}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    return 1
  fi
  current_major=$((10#${BASH_REMATCH[1]}))
  current_minor=$((10#${BASH_REMATCH[2]}))
  current_patch=$((10#${BASH_REMATCH[3]}))

  (( candidate_major > current_major )) ||
    (( candidate_major == current_major && candidate_minor > current_minor )) ||
    (( candidate_major == current_major && candidate_minor == current_minor && candidate_patch > current_patch ))
}

check_for_available_update() {
  UPDATE_AVAILABLE=false
  LATEST_VERSION=""
  return 0
}

get_online_users() {
  local stats_file
  stats_file=$(get_stats_file_path)
  if [[ ! -f "${stats_file}" ]]; then
    echo "0"
    return
  fi
  jq -r 'if type == "object" then length else 0 end' "${stats_file}" 2>/dev/null || echo "0"
}

get_service_status() {
  if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    echo -e "${COLORS[SUCCESS]}EM EXECUÇÃO (ONLINE)${COLORS[RESET]}"
    return
  fi

  echo -e "${COLORS[ERROR]}DESLIGADO (OFFLINE)${COLORS[RESET]}"
}

get_config_value() {
  local key="$1"
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo ""
    return
  fi

  if [[ "${key}" == "proxy.listen" ]]; then
    jq -r '.proxy.listen // .proxy.ports // [] | map(if type == "object" then (if .ssl then "ssl:" else "" end) + (.port | tostring) else tostring end) | join(",")' "${CONFIG_FILE}" 2>/dev/null || echo ""
    return
  fi

  local val
  val=$(jq -r ".${key} // empty" "${CONFIG_FILE}" 2>/dev/null || echo "")
  if [[ -z "${val}" || "${val}" == "null" ]]; then
    echo ""
    return
  fi

  echo "${val}"
}

get_stats_file_path() {
  local configured_path
  configured_path=$(get_config_value "server.stats_file")
  echo "${configured_path:-${STATS_FILE}}"
}

get_auth_description() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Não configurada"
    return
  fi

  jq -r '
    .server.auth // {} |
    if .system then "PAM (proto-server)"
    elif (.file // "") != "" then "Arquivo de credenciais"
    elif (.url // "") != "" then "URL externa"
    else "Não configurada" end
  ' "${CONFIG_FILE}" 2>/dev/null || echo "Não configurada"
}

write_pam_service() {
  if ! cat <<'EOF' > "${PAM_SERVICE_FILE}"
auth required pam_unix.so nodelay
account required pam_unix.so
EOF
  then
    print_message "ERROR" "Não foi possível gravar a configuração PAM."
    return 1
  fi
  chmod 0644 "${PAM_SERVICE_FILE}"
}

save_token_to_config() {
  local new_token="$1"
  update_config --arg token "${new_token}" '.server.token = $token'
}

validate_token_with_binary() {
  return 0
}

validate_token_with_retry() {
  return 0
}

ensure_valid_token() {
  return 0
}

display_main_menu() {
  local status version online_users proxy_ports stats_file
  status=$(get_service_status)
  version=$(get_installed_version)
  online_users=$(get_online_users)
  proxy_ports=$(get_config_value "proxy.listen")
  stats_file=$(get_stats_file_path)

  if [[ -z "${proxy_ports}" ]]; then
    proxy_ports="Nenhuma"
  fi

  draw_header "DTPROTO 3.2.0 cracked • ${version}"
  draw_box_line "Status:      ${status}"
  draw_box_line "Conectados:  ${COLORS[SUCCESS]}${online_users}${COLORS[RESET]}"
  draw_box_line "Stats:       $(shorten_text "${stats_file}")"
  draw_box_line "Portas:      ${COLORS[WARN]}${proxy_ports}${COLORS[RESET]}"
  if [[ "${UPDATE_AVAILABLE}" == "true" ]]; then
    draw_box_line "${COLORS[WARN]}Nova versão ${LATEST_VERSION} disponível • opção 06${COLORS[RESET]}"
  fi

  draw_separator

  local opt01 opt02 opt03 opt04 opt05 opt06 opt07 opt08 opt00
  opt01=$(format_option_str "01" "GERENCIAR SERVIÇO")
  opt02=$(format_option_str "02" "GERENCIAR PORTAS")
  opt03=$(format_option_str "03" "AUTENTICAÇÃO")
  opt04=$(format_option_str "04" "ALTERAR TOKEN")
  opt05=$(format_option_str "05" "VER LOGS")
  opt06=$(format_option_str "06" "ATUALIZAR")
  opt07=$(format_option_str "07" "DESINSTALAR")
  opt08=$(format_option_str "08" "STATS")
  opt00=$(format_option_str "00" "SAIR")

  draw_two_column_line "${opt01}" "${opt05}"
  draw_two_column_line "${opt02}" "${opt06}"
  draw_two_column_line "${opt03}" "${opt07}"
  draw_two_column_line "${opt04}" "${opt08}"
  draw_two_column_line "${opt00}"

  draw_footer
}

menu_service_control() {
  while true; do
    clear_screen
    local status
    status=$(get_service_status)

    draw_header "GERENCIAMENTO DO SERVIÇO"
    draw_box_line "Status Atual: ${status}"
    draw_separator
    draw_menu_option "01" "INICIAR SERVIÇO"
    draw_menu_option "02" "PARAR SERVIÇO"
    draw_menu_option "03" "REINICIAR SERVIÇO"
    draw_menu_option "00" "VOLTAR"
    draw_footer
    echo ""

    local choice
    choice=$(normalize_choice "$(read_input "Escolha uma opção")")

    case "${choice}" in
      1) run_service_action start "Serviço iniciado com sucesso!" ;;
      2) run_service_action stop "Serviço parado com sucesso!" ;;
      3) run_service_action restart "Serviço reiniciado com sucesso!" ;;
      0) break ;;
      *)
        print_message "ERROR" "Opção inválida."
        sleep 1
        ;;
    esac
  done
}

add_port_flow() {
  echo ""
  print_message "INFO" "Configuração de Porta do Servidor"
  echo ""

  local host="0.0.0.0" port ssl_choice is_ssl custom_msg custom_ssh_port ssh_choice is_ssh_only custom_buf custom_cert

  while true; do
    port=$(read_input "Número da porta (1-65535)")
    [[ "${port}" == "${INPUT_EOF}" ]] && return 0
    port=$(trim_input "${port}")
    if valid_port "${port}"; then
      port=$((10#${port}))
      break
    fi
    print_message "ERROR" "Porta inválida. Digite um número entre 1 e 65535."
  done

  ssl_choice=$(read_input "Ativar SSL? (s/n)")
  [[ "${ssl_choice}" == "${INPUT_EOF}" ]] && return 0
  is_ssl=false
  if [[ "${ssl_choice,,}" =~ ^(s|sim)$ ]]; then
    is_ssl=true
  fi

  custom_msg=$(read_input "Mensagem HTTP (vazio = padrão)")
  [[ "${custom_msg}" == "${INPUT_EOF}" ]] && return 0
  custom_msg=$(trim_input "${custom_msg}")

  custom_ssh_port=$(read_input "Porta SSH (vazio = 22)")
  [[ "${custom_ssh_port}" == "${INPUT_EOF}" ]] && return 0
  custom_ssh_port=$(trim_input "${custom_ssh_port}")
  if [[ -n "${custom_ssh_port}" ]] && ! valid_port "${custom_ssh_port}"; then
    print_message "ERROR" "Porta SSH inválida. Use um número entre 1 e 65535."
    return 1
  fi

  ssh_choice=$(read_input "Usar somente SSH? (s/n)")
  [[ "${ssh_choice}" == "${INPUT_EOF}" ]] && return 0
  is_ssh_only=false
  if [[ "${ssh_choice,,}" =~ ^(s|sim)$ ]]; then
    is_ssh_only=true
  fi

  custom_buf=$(read_input "Buffer em bytes (vazio = 32768)")
  [[ "${custom_buf}" == "${INPUT_EOF}" ]] && return 0
  custom_buf=$(trim_input "${custom_buf}")
  if [[ -n "${custom_buf}" ]] && ! valid_positive_integer "${custom_buf}"; then
    print_message "ERROR" "Buffer inválido. Use um número maior que zero."
    return 1
  fi

  custom_cert=$(read_input "Certificado SSL (vazio = padrão)")
  [[ "${custom_cert}" == "${INPUT_EOF}" ]] && return 0
  custom_cert=$(trim_input "${custom_cert}")

  local obj
  obj=$(jq -n \
    --arg host "${host}" \
    --argjson port "${port}" \
    --argjson ssl "${is_ssl}" \
    --arg msg "${custom_msg}" \
    --arg ssh_port "${custom_ssh_port}" \
    --argjson ssh_only "${is_ssh_only}" \
    --arg buf "${custom_buf}" \
    --arg cert "${custom_cert}" \
    '{
      host: $host,
      port: $port,
      ssl: $ssl
    }
    + (if $msg != "" then {message: $msg} else {} end)
    + (if $ssh_port != "" and ($ssh_port | test("^[0-9]+$")) then {ssh_port: ($ssh_port | tonumber)} else {} end)
    + (if $ssh_only then {ssh_only: true} else {} end)
    + (if $buf != "" and ($buf | test("^[0-9]+$")) then {buffer_size: ($buf | tonumber)} else {} end)
    + (if $cert != "" then {cert_file: $cert} else {} end)'
  )

  update_config --argjson new_obj "${obj}" --argjson port_num "${port}" '
    .proxy = (.proxy // {}) |
    .proxy.listen = (
      [(.proxy.listen // .proxy.ports // [])[] | select(
        if type == "object" then .port != $port_num
        else (try (tostring | split(":") | last | tonumber) catch -1) != $port_num end
      )] + [$new_obj]
    ) |
    del(.proxy.listener, .proxy.listeners, .proxy.ports)
  '

  restart_service || true
  print_message "SUCCESS" "Porta '${host}:${port}' configurada com sucesso!"
  sleep 1.5
}

remove_port_flow() {
  local count
  count=$(jq -r '.proxy.listen // .proxy.ports // [] | length' "${CONFIG_FILE}" 2>/dev/null || echo "0")

  if [[ "${count}" -eq 0 ]]; then
    print_message "WARN" "Não há portas cadastradas."
    sleep 1.5
    return
  fi

  clear_screen
  draw_header "REMOVER PORTA"

  local idx=1
  while read -r p; do
    if [[ -n "${p}" ]]; then
      local num_str
      printf -v num_str "%02d" "${idx}"
      draw_menu_option "${num_str}" "${p}"
      idx=$((idx + 1))
    fi
  done < <(jq -r '.proxy.listen // .proxy.ports // [] | .[] | if type == "object" then (.host // "0.0.0.0") + ":" + (if .ssl then "ssl:" else "" end) + (.port | tostring) else tostring end' "${CONFIG_FILE}" 2>/dev/null)

  draw_menu_option "00" "CANCELAR"
  draw_footer
  echo ""

  local rem_choice
  rem_choice=$(normalize_choice "$(read_input "Escolha o número da porta")")

  if [[ "${rem_choice}" == "0" ]]; then
    return
  fi

  if [[ ! "${rem_choice}" =~ ^[0-9]+$ ]] || (( rem_choice < 1 || rem_choice > count )); then
    print_message "ERROR" "Seleção inválida. Escolha uma porta da lista."
    sleep 1.5
    return 0
  fi

  local index=$((rem_choice - 1))
  update_config --argjson idx "${index}" '
    (.proxy.listen // .proxy.ports // []) as $ports |
    .proxy = (.proxy // {}) |
    .proxy.listen = [$ports | to_entries[] | select(.key != $idx) | .value] |
    del(.proxy.listener, .proxy.listeners, .proxy.ports)
  '

  restart_service || true
  print_message "SUCCESS" "Porta removida com sucesso!"
  sleep 1.5
}

menu_ports() {
  while true; do
    clear_screen
    local proxy_ports
    proxy_ports=$(get_config_value "proxy.listen")

    if [[ -z "${proxy_ports}" ]]; then
      proxy_ports="Nenhuma"
    fi

    draw_header "GERENCIAMENTO DE PORTAS"
    draw_box_line "Portas: ${COLORS[WARN]}${proxy_ports}${COLORS[RESET]}"
    draw_separator
    draw_menu_option "01" "ABRIR PORTA"
    draw_menu_option "02" "FECHAR PORTA"
    draw_menu_option "00" "VOLTAR"
    draw_footer
    echo ""

    local choice
    choice=$(normalize_choice "$(read_input "Escolha uma opção")")

    case "${choice}" in
      1) add_port_flow || true ;;
      2) remove_port_flow || true ;;
      0) break ;;
      *) print_message "ERROR" "Opção inválida."; sleep 1 ;;
    esac
  done
}

menu_auth() {
  while true; do
    clear_screen
    local current_auth
    current_auth=$(get_auth_description)

    draw_header "AUTENTICAÇÃO DE USUÁRIOS"
    draw_box_line "Modo Atual: ${COLORS[INFO]}${current_auth}${COLORS[RESET]}"
    draw_separator
    draw_menu_option "01" "PAM / SISTEMA"
    draw_menu_option "02" "ARQUIVO (JSON)"
    draw_menu_option "03" "URL EXTERNA"
    draw_menu_option "00" "VOLTAR"
    draw_footer
    echo ""

    local choice
    choice=$(normalize_choice "$(read_input "Escolha uma opção")")

    case "${choice}" in
      1)
        if ! update_config '.server.auth = {"system": true}'; then
          sleep 1.5
          continue
        fi
        if ! write_pam_service; then
          sleep 1.5
          continue
        fi
        restart_service || true
        print_message "SUCCESS" "Autenticação PAM dos usuários da máquina configurada!"
        sleep 1.5
        ;;
      2)
        local auth_file auth_file_default
        auth_file_default=$(get_config_value "server.auth.file")
        auth_file_default="${auth_file_default:-/etc/proto-server/credentials.json}"
        auth_file=$(read_input "Arquivo JSON (ex.: credentials.json)" "${auth_file_default}" "${auth_file_default}")
        [[ "${auth_file}" == "${INPUT_EOF}" ]] && continue
        auth_file=$(trim_input "${auth_file}")
        if [[ ! -f "${auth_file}" || ! -r "${auth_file}" ]]; then
          print_message "ERROR" "O arquivo não existe ou não pode ser lido."
          sleep 1.5
          continue
        fi
        if ! update_config --arg file "${auth_file}" '.server.auth = {"file": $file}'; then
          sleep 1.5
          continue
        fi
        restart_service || true
        print_message "SUCCESS" "Autenticação por arquivo configurada!"
        sleep 1.5
        ;;
      3)
        local auth_url auth_url_default
        auth_url_default=$(get_config_value "server.auth.url")
        auth_url_default="${auth_url_default:-https://auth.example.com/validate}"
        auth_url=$(read_input "URL HTTP/HTTPS (ex.: https://auth...)" "${auth_url_default}" "${auth_url_default}")
        [[ "${auth_url}" == "${INPUT_EOF}" ]] && continue
        auth_url=$(trim_input "${auth_url}")
        if [[ ! "${auth_url}" =~ ^https?://[^[:space:]]+$ ]]; then
          print_message "ERROR" "Informe uma URL HTTP ou HTTPS válida."
          sleep 1.5
          continue
        fi
        if ! update_config --arg url "${auth_url}" '.server.auth = {"url": $url}'; then
          sleep 1.5
          continue
        fi
        restart_service || true
        print_message "SUCCESS" "Autenticação por URL configurada!"
        sleep 1.5
        ;;
      0) break ;;
      *) print_message "ERROR" "Opção inválida."; sleep 1 ;;
    esac
  done
}

menu_stats() {
  while true; do
    clear_screen
    local current_path
    current_path=$(get_stats_file_path)

    draw_header "ARQUIVO DE STATS"
    draw_box_line "Arquivo: $(shorten_text "${current_path}")"
    draw_box_line "Usuários: ${COLORS[SUCCESS]}$(get_online_users)${COLORS[RESET]}"
    draw_separator
    draw_menu_option "01" "ALTERAR CAMINHO"
    draw_menu_option "00" "VOLTAR"
    draw_footer
    echo ""

    local choice
    choice=$(normalize_choice "$(read_input "Escolha uma opção")")
    case "${choice}" in
      1)
        local new_path parent_path
        new_path=$(read_input "Novo caminho do arquivo" "${current_path}" "$(shorten_text "${current_path}")")
        [[ "${new_path}" == "${INPUT_EOF}" ]] && continue
        new_path=$(trim_input "${new_path}")
        if [[ ! "${new_path}" =~ ^/ || -z "${new_path}" ]]; then
          print_message "ERROR" "Informe um caminho absoluto, por exemplo /var/lib/proto-server/stats.json."
          sleep 1.5
          continue
        fi
        parent_path=$(dirname -- "${new_path}")
        if [[ ! -d "${parent_path}" || ! -w "${parent_path}" ]]; then
          print_message "ERROR" "O diretório pai não existe ou não pode ser gravado."
          sleep 1.5
          continue
        fi
        if ! update_config --arg stats_file "${new_path}" '.server.stats_file = $stats_file'; then
          sleep 1.5
          continue
        fi
        restart_service || true
        print_message "SUCCESS" "Arquivo de stats configurado em ${new_path}."
        sleep 1.5
        ;;
      0) break ;;
      *) print_message "ERROR" "Opção inválida."; sleep 1 ;;
    esac
  done
}

menu_token() {
  clear_screen
  draw_header "ALTERAR TOKEN DE AUTENTICAÇÃO"
  draw_box_line "${COLORS[INFO]}Validação de token desativada.${COLORS[RESET]}"
  draw_footer
  echo ""
  local new_token
  new_token=$(read_input "Digite o novo token (opcional)")
  [[ "${new_token}" == "${INPUT_EOF}" ]] && return 0
  new_token=$(trim_input "${new_token}")
  if [[ -z "${new_token}" ]]; then
    return 0
  fi
  save_token_to_config "${new_token}" 2>/dev/null || true
  restart_service || true
  print_message "SUCCESS" "Token salvo!"
  sleep 1.5
}

view_logs() {
  clear_screen
  print_message "INFO" "Exibindo logs em tempo real (Pressione Ctrl+C para voltar ao menu)..."
  echo ""
  trap 'trap - INT; return 0' INT
  journalctl -u "${SERVICE_NAME}" -f -n 50 2>/dev/null || true
  trap - INT
}

update_server() {
  clear_screen
  print_message "INFO" "Atualizando para a versão mais recente (instalador embutido)..."

  # Reexecuta este mesmo arquivo como processo filho (instalador embutido):
  # um 'exit 1' lá dentro encerra apenas a atualização, não o menu inteiro.
  local self
  self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  if bash "${self}" install; then
    LATEST_VERSION=""
    UPDATE_AVAILABLE=false
    print_message "SUCCESS" "Atualização concluída!"
  else
    print_message "ERROR" "A atualização falhou."
  fi
  wait_for_enter
}

uninstall_server() {
  clear_screen
  draw_header "DESINSTALAR SERVIDOR" "Atenção: Ação Destrutiva"
  draw_box_line "${COLORS[ERROR]}Esta ação removerá completamente o${COLORS[RESET]}"
  draw_box_line "${COLORS[ERROR]}DTunnel Protocolo Server,${COLORS[RESET]}"
  draw_box_line "${COLORS[ERROR]}serviços systemd e arquivos de configuração.${COLORS[RESET]}"
  draw_footer
  echo ""

  confirm=$(read_input "Confirmar desinstalação? (s/n)")
  if [[ ! "${confirm,,}" =~ ^(s|sim)$ ]]; then
    return
  fi

  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}"
  rm -f "${PAM_SERVICE_FILE}"
  systemctl daemon-reload 2>/dev/null || true
  rm -f /usr/local/bin/proto-server /usr/local/bin/proto
  rm -rf /etc/proto-server
  print_message "SUCCESS" "DTunnel Protocolo Server desinstalado com sucesso!"
  exit 0
}

main_menu() {
  check_root "menu"
  check_dependencies
  ensure_valid_token || true
  check_for_available_update

  while true; do
    clear_screen
    display_main_menu
    echo ""
    local choice
    choice=$(normalize_choice "$(read_input "Escolha uma opção")")

    case "${choice}" in
      1) menu_service_control ;;
      2) menu_ports ;;
      3) menu_auth ;;
      4) menu_token ;;
      5) view_logs ;;
      6) update_server ;;
      7) uninstall_server ;;
      8) menu_stats ;;
      0)
        print_message "EXIT" "Saindo. Até logo!"
        exit 0
        ;;
      *)
        print_message "ERROR" "Opção inválida."
        sleep 1
        ;;
    esac
  done
}


# ------------------------------------------------------------------
# Verificação de root com contexto ("instalador" / "menu")
# (substitui as duas cópias anteriores de check_root)
# ------------------------------------------------------------------
check_root() {
  local contexto="${1:-script}"
  if [[ "${EUID}" -ne 0 ]]; then
    print_message "ERROR" "Este ${contexto} deve ser executado como root (use sudo)."
    exit 1
  fi
}

# ------------------------------------------------------------------
# Despachador único: um só ponto de entrada para tudo
# ------------------------------------------------------------------
usage() {
  echo "Uso: sudo $0 [comando]"
  echo ""
  echo "Comandos:"
  echo "  install    Instala/atualiza o proto-server (binário, serviço systemd e menu)"
  echo "  menu       Abre o menu interativo (padrão)"
  echo "  help       Mostra esta ajuda"
  echo ""
  echo "Exemplos:"
  echo "  sudo $0 install"
  echo "  sudo $0"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-menu}" in
    install|--install)
      main
      ;;
    menu|--menu|"")
      main_menu
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "Comando desconhecido: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
fi
