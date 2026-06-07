#!/usr/bin/env bash
# Docker 资产巡检与回收：清理停止容器，并循环回收清理后产生的虚悬镜像和数据卷。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/../lib/common.sh"
lab_ops_load_config

DAYS="${LAB_OPS_DOCKER_EXITED_DAYS:-7}"
WL="${LAB_OPS_DOCKER_WHITELIST}"
DATE="$(date +%Y-%m-%d)"
REPORT="$(lab_ops_report_path "docker_audit.txt" "$DATE")"

if [[ ! "$DAYS" =~ ^[0-9]+$ ]]; then
  echo "错误：LAB_OPS_DOCKER_EXITED_DAYS 必须是大于或等于 0 的整数。" >&2
  exit 1
fi

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

if ! docker info >/dev/null 2>&1; then
  {
    echo ""
    echo "============================================================"
    echo "Docker 资产巡检报告"
    echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "无法连接 Docker 服务，未执行巡检或回收。"
    echo "请确认 Docker 服务已启动，并且当前用户具有 Docker 操作权限。"
  } | tee -a "$REPORT"
  lab_ops_log "docker_audit: docker daemon unavailable or permission denied"
  exit 0
fi

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

to_epoch() {
  local value="$1"
  date -d "$value" +%s 2>/dev/null \
    || date -j -f "%Y-%m-%dT%H:%M:%S" "${value:0:19}" +%s 2>/dev/null \
    || echo 0
}

declare -a containers=()
declare -a container_names=()
declare -a container_states=()
declare -a container_times=()
declare -a images=()
declare -a volumes=()

cutoff_epoch="$(date -d "-${DAYS} days" +%s 2>/dev/null || date -v-"${DAYS}d" +%s)"

collect_container_candidates() {
  local cid name full_id state event_time event_epoch
  containers=()
  container_names=()
  container_states=()
  container_times=()

  while IFS='|' read -r cid name; do
    [[ -z "$cid" ]] && continue
    full_id="$(docker inspect -f '{{.Id}}' "$cid" 2>/dev/null || true)"
    [[ -z "$full_id" ]] && continue

    if is_container_whitelisted "$full_id" "$name"; then
      continue
    fi

    state="$(docker inspect -f '{{.State.Status}}' "$full_id" 2>/dev/null || true)"
    case "$state" in
      created)
        event_time="$(docker inspect -f '{{.Created}}' "$full_id" 2>/dev/null || true)"
        ;;
      exited|dead)
        event_time="$(docker inspect -f '{{.State.FinishedAt}}' "$full_id" 2>/dev/null || true)"
        ;;
      *)
        continue
        ;;
    esac

    [[ -z "$event_time" || "$event_time" == "<no value>" ]] && continue
    event_epoch="$(to_epoch "$event_time")"
    if [[ "$event_epoch" =~ ^-?[0-9]+$ ]] && ((event_epoch > 0 && event_epoch < cutoff_epoch)); then
      containers+=("$full_id")
      container_names+=("$name")
      container_states+=("$state")
      container_times+=("$event_time")
    fi
  done < <(
    docker ps -a \
      --filter "status=created" \
      --filter "status=exited" \
      --filter "status=dead" \
      --format '{{.ID}}|{{.Names}}' 2>/dev/null || true
  )
}

collect_dangling_assets() {
  mapfile -t images < <(docker images -f dangling=true -q 2>/dev/null | awk 'NF' | sort -u || true)
  mapfile -t volumes < <(docker volume ls -q -f dangling=true 2>/dev/null | awk 'NF' | sort -u || true)
}

collect_container_candidates
collect_dangling_assets

{
  echo ""
  echo "============================================================"
  echo "Docker 资产巡检报告"
  echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "停止容器保留天数: $DAYS"
  echo "容器白名单: $WL"
  echo ""
  echo "一、停止超过 ${DAYS} 天的容器"
} | tee -a "$REPORT"

if ((${#containers[@]} == 0)); then
  echo "无" | tee -a "$REPORT"
else
  for index in "${!containers[@]}"; do
    echo "候选容器: ${containers[$index]:0:12} ${container_names[$index]} status=${container_states[$index]} time=${container_times[$index]}" | tee -a "$REPORT"
  done
fi

echo "" | tee -a "$REPORT"
echo "二、当前虚悬镜像 dangling images" | tee -a "$REPORT"
if ((${#images[@]} == 0)); then
  echo "无" | tee -a "$REPORT"
else
  printf '候选镜像: %s\n' "${images[@]}" | tee -a "$REPORT"
fi

echo "" | tee -a "$REPORT"
echo "三、当前僵尸数据卷 dangling volumes" | tee -a "$REPORT"
if ((${#volumes[@]} == 0)); then
  echo "无" | tee -a "$REPORT"
else
  printf '候选数据卷: %s\n' "${volumes[@]}" | tee -a "$REPORT"
fi

initial_total=$((${#containers[@]} + ${#images[@]} + ${#volumes[@]}))
{
  echo ""
  echo "当前候选回收资产总数: $initial_total"
  echo "说明: 删除停止容器后，新产生的虚悬镜像和数据卷也会在本次操作中继续回收。"
  echo "报告已保存: $REPORT"
} | tee -a "$REPORT"

if ((initial_total == 0)); then
  lab_ops_log "docker_audit: no docker assets to remove"
  exit 0
fi

if ! lab_ops_confirm "确认回收以上 Docker 资产，并继续回收删除容器后产生的虚悬镜像和数据卷吗？" 30; then
  echo "未确认或超时，已返回，不回收 Docker 资产。" | tee -a "$REPORT"
  lab_ops_log "docker_audit: cancelled or timeout"
  exit 0
fi

removed_containers=0
removed_images=0
removed_volumes=0
failed_containers=0
failed_images=0
failed_volumes=0

echo "" | tee -a "$REPORT"
echo "四、执行回收" | tee -a "$REPORT"

for index in "${!containers[@]}"; do
  cid="${containers[$index]}"
  name="${container_names[$index]}"
  if output="$(docker rm "$cid" 2>&1)"; then
    echo "已删除容器: ${cid:0:12} $name" | tee -a "$REPORT"
    lab_ops_log "docker_audit: removed container id=$cid name=$name"
    removed_containers=$((removed_containers + 1))
  else
    echo "容器删除失败: ${cid:0:12} $name；原因: $output" | tee -a "$REPORT" >&2
    lab_ops_log "docker_audit: container remove failed id=$cid name=$name reason=$output"
    failed_containers=$((failed_containers + 1))
  fi
done

# 删除容器可能让此前仍被引用的镜像和数据卷变成 dangling，因此循环复扫并回收。
for round in 1 2 3 4 5; do
  collect_dangling_assets
  if ((${#images[@]} == 0 && ${#volumes[@]} == 0)); then
    break
  fi

  echo "第 ${round} 轮虚悬资产复扫: 镜像 ${#images[@]} 个，数据卷 ${#volumes[@]} 个" | tee -a "$REPORT"
  progress=0

  for image in "${images[@]}"; do
    if output="$(docker rmi "$image" 2>&1)"; then
      echo "已删除虚悬镜像: $image" | tee -a "$REPORT"
      lab_ops_log "docker_audit: removed image id=$image"
      removed_images=$((removed_images + 1))
      progress=$((progress + 1))
    else
      echo "镜像删除失败: $image；原因: $output" | tee -a "$REPORT" >&2
      lab_ops_log "docker_audit: image remove failed id=$image reason=$output"
      failed_images=$((failed_images + 1))
    fi
  done

  for volume in "${volumes[@]}"; do
    if output="$(docker volume rm "$volume" 2>&1)"; then
      echo "已删除僵尸数据卷: $volume" | tee -a "$REPORT"
      lab_ops_log "docker_audit: removed volume name=$volume"
      removed_volumes=$((removed_volumes + 1))
      progress=$((progress + 1))
    else
      echo "数据卷删除失败: $volume；原因: $output" | tee -a "$REPORT" >&2
      lab_ops_log "docker_audit: volume remove failed name=$volume reason=$output"
      failed_volumes=$((failed_volumes + 1))
    fi
  done

  ((progress == 0)) && break
done

collect_container_candidates
collect_dangling_assets
remaining_total=$((${#containers[@]} + ${#images[@]} + ${#volumes[@]}))

{
  echo ""
  echo "五、清理后复检"
  echo "成功删除容器: $removed_containers"
  echo "成功删除虚悬镜像: $removed_images"
  echo "成功删除僵尸数据卷: $removed_volumes"
  echo "删除失败: 容器 $failed_containers，镜像 $failed_images，数据卷 $failed_volumes"
  echo "复检剩余候选资产: $remaining_total"
} | tee -a "$REPORT"

if ((remaining_total == 0)); then
  echo "Docker 资产回收完成，复检未发现残留候选资产。" | tee -a "$REPORT"
else
  echo "警告：仍有候选资产未能删除，请根据下方清单和失败原因处理。" | tee -a "$REPORT" >&2
  for index in "${!containers[@]}"; do
    echo "剩余容器: ${containers[$index]:0:12} ${container_names[$index]} status=${container_states[$index]}" | tee -a "$REPORT" >&2
  done
  ((${#images[@]} > 0)) && printf '剩余虚悬镜像: %s\n' "${images[@]}" | tee -a "$REPORT" >&2
  ((${#volumes[@]} > 0)) && printf '剩余僵尸数据卷: %s\n' "${volumes[@]}" | tee -a "$REPORT" >&2
fi

lab_ops_log "docker_audit: done removed_containers=$removed_containers removed_images=$removed_images removed_volumes=$removed_volumes failed_containers=$failed_containers failed_images=$failed_images failed_volumes=$failed_volumes remaining=$remaining_total"
