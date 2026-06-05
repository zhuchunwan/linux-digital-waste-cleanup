#!/usr/bin/env bash
# Docker 资产巡检与回收：显示候选容器、镜像、数据卷，用户确认后回收。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/../lib/common.sh"
lab_ops_load_config

DAYS="${LAB_OPS_DOCKER_EXITED_DAYS:-7}"
WL="${LAB_OPS_DOCKER_WHITELIST}"
DATE="$(date +%Y-%m-%d)"
REPORT="$(lab_ops_report_path "docker_audit.txt" "$DATE")"

lab_ops_log "docker_audit: days=$DAYS report=$REPORT"

command -v docker >/dev/null || {
  {
    echo ""
    echo "============================================================"
    echo "Docker 资产巡检报告"
    echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Docker 命令不存在，本机跳过 Docker 巡检。"
    echo "请在安装 Docker 的 Linux/WSL2/服务器环境运行此功能。"
  } | tee -a "$REPORT"
  lab_ops_log "docker_audit: docker not in PATH"
  exit 0
}

is_container_whitelisted() {
  local id="$1" short="${1:0:12}" name="$2"
  [[ -f "$WL" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" == "$id" || "$line" == "$short" || "$line" == "$name" ]] && return 0
  done <"$WL"
  return 1
}

cutoff_epoch="$(date -d "-${DAYS} days" +%s 2>/dev/null || date -v-"${DAYS}d" +%s)"
containers=()
images=()
volumes=()

{
  echo ""
  echo "============================================================"
  echo "Docker 资产巡检报告"
  echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "容器白名单: $WL"
  echo ""
  echo "一、退出超过 ${DAYS} 天的容器"
} | tee -a "$REPORT"

while read -r cid name; do
  [[ -z "$cid" ]] && continue
  if is_container_whitelisted "$cid" "$name"; then
    echo "跳过白名单容器: $cid $name" | tee -a "$REPORT"
    continue
  fi
  fin="$(docker inspect -f '{{.State.FinishedAt}}' "$cid" 2>/dev/null || true)"
  [[ -z "$fin" || "$fin" == "<no value>" ]] && continue
  fin_epoch="$(date -d "$fin" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${fin:0:19}" +%s 2>/dev/null || echo 0)"
  if [[ "$fin_epoch" -gt 0 && "$fin_epoch" -lt "$cutoff_epoch" ]]; then
    containers+=("$cid")
    echo "候选容器: $cid $name finished=$fin" | tee -a "$REPORT"
  fi
done < <(docker ps -a --filter "status=exited" --format '{{.ID}} {{.Names}}' 2>/dev/null || true)

((${#containers[@]} == 0)) && echo "无" | tee -a "$REPORT"

echo "" | tee -a "$REPORT"
echo "二、虚悬镜像 dangling images" | tee -a "$REPORT"
mapfile -t images < <(docker images -f dangling=true -q 2>/dev/null | sort -u || true)
if ((${#images[@]} == 0)); then
  echo "无" | tee -a "$REPORT"
else
  printf '候选镜像: %s\n' "${images[@]}" | tee -a "$REPORT"
fi

echo "" | tee -a "$REPORT"
echo "三、僵尸数据卷 dangling volumes" | tee -a "$REPORT"
mapfile -t volumes < <(docker volume ls -q -f dangling=true 2>/dev/null | sort -u || true)
if ((${#volumes[@]} == 0)); then
  echo "无" | tee -a "$REPORT"
else
  printf '候选数据卷: %s\n' "${volumes[@]}" | tee -a "$REPORT"
fi

total=$(( ${#containers[@]} + ${#images[@]} + ${#volumes[@]} ))
echo "" | tee -a "$REPORT"
echo "候选回收资产总数: $total" | tee -a "$REPORT"
echo "报告已保存: $REPORT"

if ((total == 0)); then
  lab_ops_log "docker_audit: no docker assets to remove"
  exit 0
fi

if [[ ! -t 0 ]]; then
  echo "当前不是交互式终端，自动返回，不回收任何 Docker 资产。"
  lab_ops_log "docker_audit: non-interactive terminal, cancelled"
  exit 0
fi

answer=""
read -r -t 30 -p "确认回收以上 Docker 资产吗？请输入 y 确认，30 秒未确认自动返回: " answer || true
echo ""
case "$answer" in
  y|Y|yes|YES)
    for cid in "${containers[@]}"; do
      docker rm "$cid" && lab_ops_log "docker_audit: removed container $cid"
    done
    ((${#images[@]} > 0)) && docker rmi "${images[@]}" 2>/dev/null || true
    ((${#volumes[@]} > 0)) && docker volume rm "${volumes[@]}" 2>/dev/null || true
    echo "Docker 资产回收完成。"
    lab_ops_log "docker_audit: removed containers=${#containers[@]} images=${#images[@]} volumes=${#volumes[@]}"
    ;;
  *)
    echo "未确认或超时，已返回，不回收 Docker 资产。"
    lab_ops_log "docker_audit: cancelled or timeout"
    ;;
esac
