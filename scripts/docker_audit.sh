#!/usr/bin/env bash
# Docker 资产巡检：已退出超 N 天容器、虚悬镜像、dangling volume；白名单 + DRY_RUN
# 依赖: docker 命令、GNU date

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/../lib/common.sh"
lab_ops_load_config

DAYS="${LAB_OPS_DOCKER_EXITED_DAYS:-7}"
WL="${LAB_OPS_DOCKER_WHITELIST}"
REPORT="${LAB_OPS_REPORT_DIR}/docker_audit_$(date +%Y-%m-%d).txt"

# 解析 -y 参数
AUTO_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes|--force) AUTO_YES=1; export LAB_OPS_FORCE=1 ;;
  esac
done

lab_ops_log "docker_audit: days=$DAYS dry_run=$LAB_OPS_DRY_RUN report=$REPORT"

command -v docker >/dev/null || {
  lab_ops_log "ERROR: docker not in PATH"
  exit 1
}

is_whitelisted() {
  local id="$1" short="${1:0:12}" name="$2"
  [[ -f "$WL" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    if [[ "$line" == "$id" || "$line" == "$short" || "$line" == "$name" ]]; then
      return 0
    fi
  done <"$WL"
  return 1
}

# 正式模式下的二次确认
if ! lab_ops_is_true "$LAB_OPS_DRY_RUN"; then
  if [[ "$AUTO_YES" == "0" ]]; then
    lab_ops_confirm "Docker 巡检模块: 将对以下资产进行清理:
  - 停止超过 ${DAYS} 天的退出容器 (docker rm)
  - 无标签虚悬镜像 (docker rmi)
  - 未挂载僵尸数据卷 (docker volume rm)
白名单文件: ${WL}
审计报告将保存至: ${REPORT}" 30 || {
      lab_ops_log "docker_audit: 用户取消 Docker 清理操作"
      echo "  Docker 清理操作已取消。" >&2
      exit 0
    }
  else
    lab_ops_log "docker_audit: -y 模式，跳过交互确认"
  fi
fi

cutoff_epoch="$(date -d "-${DAYS} days" +%s 2>/dev/null || date -v-"${DAYS}d" +%s)"

{
  echo "=== Exited containers older than ${DAYS}d (compare FinishedAt epoch) ==="
  while read -r cid name; do
    [[ -z "$cid" ]] && continue
    if is_whitelisted "$cid" "$name"; then
      echo "SKIP whitelist: $cid $name"
      continue
    fi
    fin="$(docker inspect -f '{{.State.FinishedAt}}' "$cid" 2>/dev/null || true)"
    [[ -z "$fin" || "$fin" == "<no value>" ]] && continue
    fin_epoch="$(date -d "$fin" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${fin:0:19}" +%s 2>/dev/null || echo 0)"
    if [[ "$fin_epoch" -eq 0 ]]; then
      echo "SKIP bad timestamp: $cid $name fin=$fin"
      continue
    fi
    if [[ "$fin_epoch" -lt "$cutoff_epoch" ]]; then
      echo "CANDIDATE rm: $cid $name finished=$fin"
      if ! lab_ops_is_true "$LAB_OPS_DRY_RUN"; then
        docker rm "$cid" && lab_ops_log "docker_audit: removed container $cid"
      fi
    fi
  done < <(docker ps -a --filter "status=exited" --format '{{.ID}} {{.Names}}' 2>/dev/null || true)

  echo
  echo "=== Dangling images (docker images -f dangling=true) ==="
  mapfile -t dimgs < <(docker images -f dangling=true -q 2>/dev/null || true)
  if ((${#dimgs[@]} == 0)); then
    echo "(none)"
  else
    printf '%s\n' "${dimgs[@]}"
    if ! lab_ops_is_true "$LAB_OPS_DRY_RUN"; then
      docker rmi "${dimgs[@]}" 2>/dev/null || lab_ops_log "docker_audit: docker rmi had partial failures (see stderr)"
    fi
  fi

  echo
  echo "=== Dangling volumes ==="
  mapfile -t dvols < <(docker volume ls -q -f dangling=true 2>/dev/null || true)
  if ((${#dvols[@]} == 0)); then
    echo "(none)"
  else
    printf '%s\n' "${dvols[@]}"
    if ! lab_ops_is_true "$LAB_OPS_DRY_RUN"; then
      docker volume rm "${dvols[@]}" 2>/dev/null || lab_ops_log "docker_audit: docker volume rm had partial failures"
    fi
  fi
} | tee "$REPORT"

lab_ops_log "docker_audit: report written $REPORT"
