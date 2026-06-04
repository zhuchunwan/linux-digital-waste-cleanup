#!/usr/bin/env bash
# ============================================================================
# Docker 资产巡检与安全回收 — 组员 B (Docker / 日志运维)
# ============================================================================
# 功能: 清理退出超 N 天的容器、虚悬镜像、僵尸数据卷。
#       新增 24h 待删除预告：候选资产先进入预告清单，
#       下次运行且超过预告时长后才真正删除。
#       白名单 + DRY_RUN + 二次确认 三层防护。
#
# 用法:
#   docker_audit.sh                      默认配置
#   docker_audit.sh -y                   跳过二次确认
#   docker_audit.sh --force              同 -y
#
# 24h 预告机制:
#   首次发现 → 写入 docker_pending_delete.log (NOTICE)
#   再次运行（≥24h 后）→ 仍在候选列表且预告期满 → 真正删除 (DELETE)
#   容器已被手动删除 → 自动从预告清单移除
#   设置 LAB_OPS_DOCKER_PENDING_HOURS=0 关闭预告（立即删除）
# ============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/../lib/common.sh"
lab_ops_load_config

DAYS="${LAB_OPS_DOCKER_EXITED_DAYS:-7}"
PENDING_HOURS="${LAB_OPS_DOCKER_PENDING_HOURS:-24}"
WL="${LAB_OPS_DOCKER_WHITELIST}"
REPORT="${LAB_OPS_REPORT_DIR}/docker_audit_$(date +%Y-%m-%d).txt"
PENDING_FILE="${LAB_OPS_LOG_DIR}/docker_pending_delete.log"

# 解析 -y 参数
AUTO_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes|--force) AUTO_YES=1; export LAB_OPS_FORCE=1 ;;
  esac
done

lab_ops_log "docker_audit: days=$DAYS pending_hours=${PENDING_HOURS}h dry_run=$LAB_OPS_DRY_RUN report=$REPORT"

command -v docker >/dev/null || {
  lab_ops_log "ERROR: docker not in PATH"
  exit 1
}

# 预告开关
PENDING_ENABLED=1
if [[ "$PENDING_HOURS" -eq 0 ]]; then
  PENDING_ENABLED=0
  lab_ops_log "docker_audit: 24h 预告已关闭 (PENDING_HOURS=0)，将立即删除"
fi

# ── 白名单检查 ──────────────────────────────────────────────────────────────
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

# ── 预告清单管理 ────────────────────────────────────────────────────────────
# 格式: TYPE|ID|NAME|FIRST_NOTICED_EPOCH|FIRST_NOTICED_ISO
# 初始化文件（不存在时创建并写入表头注释）
init_pending_file() {
  if [[ ! -f "$PENDING_FILE" ]]; then
    {
      echo "# lab-ops Docker 待删除预告清单"
      echo "# 格式: TYPE|ID|NAME|FIRST_NOTICED_EPOCH|FIRST_NOTICED_ISO"
      echo "# 资产首次发现后进入此清单，超过 ${PENDING_HOURS}h 后下次运行将真正删除"
      echo "# 生成时间: $(date -Iseconds)"
      echo "#"
    } > "$PENDING_FILE"
  fi
}

pending_contains() {
  local type="$1" id="$2"
  [[ -f "$PENDING_FILE" ]] || return 1
  # 精确匹配 type|id| 前缀
  grep -qF "${type}|${id}|" "$PENDING_FILE" 2>/dev/null
}

pending_get_epoch() {
  local type="$1" id="$2"
  grep -F "${type}|${id}|" "$PENDING_FILE" 2>/dev/null | head -1 | cut -d'|' -f4
}

pending_add() {
  local type="$1" id="$2" name="$3"
  local now_epoch now_iso
  now_epoch=$(date +%s)
  now_iso=$(date -Iseconds)
  # 避免重复添加
  if pending_contains "$type" "$id"; then
    return 0
  fi
  echo "${type}|${id}|${name}|${now_epoch}|${now_iso}" >> "$PENDING_FILE"
}

pending_remove() {
  local type="$1" id="$2"
  [[ -f "$PENDING_FILE" ]] || return 0
  # 精确删除匹配行（Docker ID 为 hex，不含 /，安全使用 / 作为 sed 分隔符）
  sed -i "/^${type}|${id}|/d" "$PENDING_FILE" 2>/dev/null || true
}

pending_count() {
  [[ -f "$PENDING_FILE" ]] || { echo 0; return; }
  grep -cv '^#' "$PENDING_FILE" 2>/dev/null || echo 0
}

# 检查是否预告期满（返回 0 = 期满可删除）
pending_is_expired() {
  local type="$1" id="$2"
  local pending_epoch
  pending_epoch=$(pending_get_epoch "$type" "$id")
  [[ -z "$pending_epoch" ]] && return 1
  local cutoff
  cutoff=$(date -d "-${PENDING_HOURS} hours" +%s 2>/dev/null) || return 1
  [[ "$pending_epoch" -lt "$cutoff" ]]
}

# 格式化预告到期时间
pending_expiry_time() {
  local type="$1" id="$2"
  local pending_epoch
  pending_epoch=$(pending_get_epoch "$type" "$id")
  [[ -z "$pending_epoch" ]] && { echo "unknown"; return; }
  local expiry=$((pending_epoch + PENDING_HOURS * 3600))
  date -d "@$expiry" -Iseconds 2>/dev/null || echo "unknown"
}

# ── 二次确认（正式模式下）───────────────────────────────────────────────────
if ! lab_ops_is_true "$LAB_OPS_DRY_RUN"; then
  if [[ "$AUTO_YES" == "0" ]]; then
    local pending_count_val
    pending_count_val=$(pending_count)
    local confirm_msg="Docker 巡检模块: 将对以下资产进行清理:
  - 停止超过 ${DAYS} 天的退出容器 (docker rm)
  - 无标签虚悬镜像 (docker rmi)
  - 未挂载僵尸数据卷 (docker volume rm)
白名单文件: ${WL}
预告清单: ${PENDING_FILE} (当前 ${pending_count_val} 条)
审计报告: ${REPORT}"
    if [[ "$PENDING_ENABLED" -eq 1 ]]; then
      confirm_msg="$confirm_msg

⚠ 24h 预告模式已开启: 新发现的候选资产本次仅记录预告，需下次运行(≥${PENDING_HOURS}h后)才真正删除。"
    fi
    lab_ops_confirm "$confirm_msg" 30 || {
      lab_ops_log "docker_audit: 用户取消 Docker 清理操作"
      echo "  Docker 清理操作已取消。" >&2
      exit 0
    }
  else
    lab_ops_log "docker_audit: -y 模式，跳过交互确认"
  fi
fi

# ── 初始化预告文件 ──────────────────────────────────────────────────────────
init_pending_file

# ── 计算时间阈值 ────────────────────────────────────────────────────────────
cutoff_epoch="$(date -d "-${DAYS} days" +%s 2>/dev/null || date -v-"${DAYS}d" +%s)"
pending_cutoff_epoch="$(date -d "-${PENDING_HOURS} hours" +%s 2>/dev/null || echo 0)"

# ── 清理计数器 ──────────────────────────────────────────────────────────────
NOTICED_CONTAINERS=0
DELETED_CONTAINERS=0
NOTICED_IMAGES=0
DELETED_IMAGES=0
NOTICED_VOLUMES=0
DELETED_VOLUMES=0

{
  echo "═══════════════════════════════════════════════════════════════"
  echo "  Docker 资产巡检报告 — $(date '+%Y-%m-%d %H:%M:%S')"
  echo "═══════════════════════════════════════════════════════════════"
  echo "  退出容器阈值    : ${DAYS} 天"
  echo "  预告时长        : ${PENDING_HOURS} 小时"
  echo "  运行模式        : $([[ "$LAB_OPS_DRY_RUN" == "1" ]] && echo 'DRY-RUN (仅预览)' || echo '正式模式')"
  echo "  预告清单        : ${PENDING_FILE} ($(pending_count) 条)"
  echo ""

  # ══════════════════════════════════════════════════════════════════════
  # 1. 全部容器（运行中 + 已退出）
  # ══════════════════════════════════════════════════════════════════════
  echo "── [1/4] 全部容器 (docker ps -a) ──"
  echo ""

  # 辅助函数：计算"距离现在多久"的可读字符串
  human_age() {
    local epoch="$1"
    local now
    now=$(date +%s)
    local diff=$(( now - epoch ))
    if [[ $diff -lt 60 ]]; then
      echo "${diff} 秒前"
    elif [[ $diff -lt 3600 ]]; then
      echo "$(( diff / 60 )) 分钟前"
    elif [[ $diff -lt 86400 ]]; then
      echo "$(( diff / 3600 )) 小时前"
    else
      echo "$(( diff / 86400 )) 天前"
    fi
  }

  # 先列出运行中的容器
  RUNNING_COUNT=0
  while read -r cid name; do
    [[ -z "$cid" ]] && continue
    RUNNING_COUNT=$((RUNNING_COUNT + 1))
    short_id="${cid:0:12}"
    echo "  [运行中] $short_id  $name"
  done < <(docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null || true)

  if [[ "$RUNNING_COUNT" -eq 0 ]]; then
    echo "  (无运行中的容器)"
  fi
  echo ""

  # 再列出已退出的容器（逐个分析）
  echo "  已退出容器:"
  echo "  ┌────────────┬────────────────────┬──────────────────┬────────────────────────────────┐"
  echo "  │ 状态       │ 容器名             │ 退出时间         │ 说明                           │"
  echo "  ├────────────┼────────────────────┼──────────────────┼────────────────────────────────┤"

  EXITED_COUNT=0
  while read -r cid name; do
    [[ -z "$cid" ]] && continue
    EXITED_COUNT=$((EXITED_COUNT + 1))
    short_id="${cid:0:12}"

    # 白名单过滤
    if is_whitelisted "$cid" "$name"; then
      printf "  │ %-10s │ %-18s │ %-16s │ %-30s │\n" \
        "🔒 白名单" "$name" "—" "在白名单中，永久保留"
      continue
    fi

    # 获取退出时间
    fin="$(docker inspect -f '{{.State.FinishedAt}}' "$cid" 2>/dev/null || true)"
    [[ -z "$fin" || "$fin" == "<no value>" ]] && continue

    fin_epoch="$(date -d "$fin" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${fin:0:19}" +%s 2>/dev/null || echo 0)"
    if [[ "$fin_epoch" -eq 0 ]]; then
      printf "  │ %-10s │ %-18s │ %-16s │ %-30s │\n" \
        "⚠ 异常" "$name" "$fin" "时间戳无法解析"
      continue
    fi

    age=$(human_age "$fin_epoch")
    fin_date=$(date -d "@$fin_epoch" "+%m-%d %H:%M" 2>/dev/null || echo "$fin")

    # 未超过退出天数阈值 → 保留
    if [[ "$fin_epoch" -ge "$cutoff_epoch" ]]; then
      printf "  │ %-10s │ %-18s │ %-16s │ %-30s │\n" \
        "✅ KEEP" "$name" "$fin_date" "退出${age}，未满${DAYS}天阈值，保留"
      continue
    fi

    # ── 超过阈值，核心逻辑：两阶段预告 ──
    if [[ "$PENDING_ENABLED" -eq 1 ]]; then
      if pending_contains "container" "$cid"; then
        if pending_is_expired "container" "$cid"; then
          printf "  │ %-10s │ %-18s │ %-16s │ %-30s │\n" \
            "🗑 DELETE" "$name" "$fin_date" "预告期满(>${PENDING_HOURS}h)，即将删除"
          if ! lab_ops_is_true "$LAB_OPS_DRY_RUN"; then
            if docker rm "$cid" 2>/dev/null; then
              pending_remove "container" "$cid"
              lab_ops_log "docker_audit: removed container $cid ($name)"
              DELETED_CONTAINERS=$((DELETED_CONTAINERS + 1))
            else
              lab_ops_log "docker_audit: FAILED to remove container $cid"
            fi
          else
            DELETED_CONTAINERS=$((DELETED_CONTAINERS + 1))
          fi
        else
          printf "  │ %-10s │ %-18s │ %-16s │ %-30s │\n" \
            "⏳ PENDING" "$name" "$fin_date" "预告中，${PENDING_HOURS}h后可删除"
        fi
      else
        printf "  │ %-10s │ %-18s │ %-16s │ %-30s │\n" \
          "📝 NOTICE" "$name" "$fin_date" "首次发现，已加入预告清单"
        pending_add "container" "$cid" "$name"
        NOTICED_CONTAINERS=$((NOTICED_CONTAINERS + 1))
      fi
    else
      printf "  │ %-10s │ %-18s │ %-16s │ %-30s │\n" \
        "🗑 待删除" "$name" "$fin_date" "预告关闭，直接删除"
      if ! lab_ops_is_true "$LAB_OPS_DRY_RUN"; then
        docker rm "$cid" 2>/dev/null && {
          lab_ops_log "docker_audit: removed container $cid ($name)"
          DELETED_CONTAINERS=$((DELETED_CONTAINERS + 1))
        }
      else
        DELETED_CONTAINERS=$((DELETED_CONTAINERS + 1))
      fi
    fi
  done < <(docker ps -a --filter "status=exited" --format '{{.ID}} {{.Names}}' 2>/dev/null || true)

  if [[ "$EXITED_COUNT" -eq 0 ]]; then
    echo "  │ (无已退出容器)                                                                              │"
  fi
  echo "  └────────────┴────────────────────┴──────────────────┴────────────────────────────────┘"

  # 清理预告清单中已不存在的容器（已被手动删除）
  clean_stale_pending() {
    local type="$1"
    local id="$2"
    case "$type" in
      container)
        docker ps -a --format '{{.ID}}' 2>/dev/null | grep -qF "$id" || return 1
        ;;
      image)
        docker images -q 2>/dev/null | grep -qF "$id" || return 1
        ;;
      volume)
        docker volume ls -q 2>/dev/null | grep -qF "$id" || return 1
        ;;
    esac
    return 0
  }

  # 清理预告清单中的过期条目（对应 Docker 资产已不存在）
  if [[ -f "$PENDING_FILE" ]]; then
    while IFS='|' read -r ptype pid pname pepoch piso; do
      [[ "$ptype" =~ ^# ]] && continue
      [[ -z "$ptype" ]] && continue
      if ! clean_stale_pending "$ptype" "$pid"; then
        pending_remove "$ptype" "$pid"
        echo "CLEANUP pending: $ptype $pid ($pname) — no longer exists in Docker"
        lab_ops_log "docker_audit: cleaned stale pending entry: $ptype $pid"
      fi
    done < "$PENDING_FILE"
  fi

  echo "  → 本次通知: ${NOTICED_CONTAINERS} | 本次删除: ${DELETED_CONTAINERS}"

  # ══════════════════════════════════════════════════════════════════════
  # 2. 全部镜像
  # ══════════════════════════════════════════════════════════════════════
  echo ""
  echo "── [2/4] 全部镜像 (docker images -a) ──"
  echo ""

  TOTAL_IMG=0
  while read -r img_id repo tag size; do
    [[ -z "$img_id" ]] && continue
    TOTAL_IMG=$((TOTAL_IMG + 1))
    short_id="${img_id:0:12}"

    if [[ "$repo" == "<none>" && "$tag" == "<none>" ]]; then
      # 虚悬镜像 → 检查预告状态
      if [[ "$PENDING_ENABLED" -eq 1 ]]; then
        if pending_contains "image" "$img_id"; then
          if pending_is_expired "image" "$img_id"; then
            printf "  [🗑 DELETE] %s  <none>:<none>  %s  (预告期满，即将删除)\n" "$short_id" "$size"
            if ! lab_ops_is_true "$LAB_OPS_DRY_RUN"; then
              docker rmi "$img_id" 2>/dev/null && { pending_remove "image" "$img_id"; DELETED_IMAGES=$((DELETED_IMAGES + 1)); }
            else
              DELETED_IMAGES=$((DELETED_IMAGES + 1))
            fi
          else
            printf "  [⏳ PENDING] %s  <none>:<none>  %s  (预告中，%sh后可删除)\n" "$short_id" "$size" "$PENDING_HOURS"
          fi
        else
          printf "  [📝 NOTICE] %s  <none>:<none>  %s  (首次发现，已加入预告)\n" "$short_id" "$size"
          pending_add "image" "$img_id" "<none>:<none>"
          NOTICED_IMAGES=$((NOTICED_IMAGES + 1))
        fi
      else
        printf "  [🗑 待删除] %s  <none>:<none>  %s  (虚悬镜像)\n" "$short_id" "$size"
        if ! lab_ops_is_true "$LAB_OPS_DRY_RUN"; then
          docker rmi "$img_id" 2>/dev/null && DELETED_IMAGES=$((DELETED_IMAGES + 1))
        else
          DELETED_IMAGES=$((DELETED_IMAGES + 1))
        fi
      fi
    else
      printf "  [✅ KEEP] %s  %s:%s  %s  (正常镜像，保留)\n" "$short_id" "$repo" "$tag" "$size"
    fi
  done < <(docker images -a --format '{{.ID}} {{.Repository}} {{.Tag}} {{.Size}}' 2>/dev/null || true)

  if [[ "$TOTAL_IMG" -eq 0 ]]; then
    echo "  (无镜像)"
  fi

  echo "  → 本次通知: ${NOTICED_IMAGES} | 本次删除: ${DELETED_IMAGES}"

  # ══════════════════════════════════════════════════════════════════════
  # 3. 全部数据卷
  # ══════════════════════════════════════════════════════════════════════
  echo ""
  echo "── [3/4] 全部数据卷 (docker volume ls) ──"
  echo ""

  # 获取 dangling 卷 ID 列表
  mapfile -t dangling_vols < <(docker volume ls -q -f dangling=true 2>/dev/null || true)

  TOTAL_VOL=0
  while read -r vol_name; do
    [[ -z "$vol_name" ]] && continue
    TOTAL_VOL=$((TOTAL_VOL + 1))

    # 判断是否 dangling
    is_dangling=0
    for dv in "${dangling_vols[@]}"; do
      [[ "$dv" == "$vol_name" ]] && { is_dangling=1; break; }
    done

    if [[ "$is_dangling" -eq 1 ]]; then
      # 僵尸卷 → 检查预告状态
      if [[ "$PENDING_ENABLED" -eq 1 ]]; then
        if pending_contains "volume" "$vol_name"; then
          if pending_is_expired "volume" "$vol_name"; then
            printf "  [🗑 DELETE] %s  (僵尸卷，预告期满，即将删除)\n" "$vol_name"
            if ! lab_ops_is_true "$LAB_OPS_DRY_RUN"; then
              docker volume rm "$vol_name" 2>/dev/null && { pending_remove "volume" "$vol_name"; DELETED_VOLUMES=$((DELETED_VOLUMES + 1)); }
            else
              DELETED_VOLUMES=$((DELETED_VOLUMES + 1))
            fi
          else
            printf "  [⏳ PENDING] %s  (僵尸卷，预告中，%sh后可删除)\n" "$vol_name" "$PENDING_HOURS"
          fi
        else
          printf "  [📝 NOTICE] %s  (僵尸卷，首次发现，已加入预告)\n" "$vol_name"
          pending_add "volume" "$vol_name" "$vol_name"
          NOTICED_VOLUMES=$((NOTICED_VOLUMES + 1))
        fi
      else
        printf "  [🗑 待删除] %s  (僵尸卷)\n" "$vol_name"
        if ! lab_ops_is_true "$LAB_OPS_DRY_RUN"; then
          docker volume rm "$vol_name" 2>/dev/null && DELETED_VOLUMES=$((DELETED_VOLUMES + 1))
        else
          DELETED_VOLUMES=$((DELETED_VOLUMES + 1))
        fi
      fi
    else
      printf "  [✅ KEEP] %s  (正常卷，有容器在用，保留)\n" "$vol_name"
    fi
  done < <(docker volume ls --format '{{.Name}}' 2>/dev/null || true)

  if [[ "$TOTAL_VOL" -eq 0 ]]; then
    echo "  (无数据卷)"
  fi

  echo "  → 本次通知: ${NOTICED_VOLUMES} | 本次删除: ${DELETED_VOLUMES}"

  # ══════════════════════════════════════════════════════════════════════
  # 摘要
  # ══════════════════════════════════════════════════════════════════════
  TOTAL_NOTICED=$((NOTICED_CONTAINERS + NOTICED_IMAGES + NOTICED_VOLUMES))
  TOTAL_DELETED=$((DELETED_CONTAINERS + DELETED_IMAGES + DELETED_VOLUMES))

  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  执行摘要"
  echo "═══════════════════════════════════════════════════════════════"
  echo "  新加入预告    : ${TOTAL_NOTICED} 项"
  echo "  本次删除      : ${TOTAL_DELETED} 项"
  echo "  预告清单存量  : $(pending_count) 项"
  echo "  运行模式      : $([[ "$LAB_OPS_DRY_RUN" == "1" ]] && echo 'DRY-RUN' || echo '正式模式')"
  if [[ "$PENDING_ENABLED" -eq 1 ]]; then
    echo "  预告时长      : ${PENDING_HOURS} 小时"
    echo "  ℹ 新发现的候选资产已加入预告清单，需下次运行(≥${PENDING_HOURS}h后)才会真正删除"
    echo "  预告清单位置  : ${PENDING_FILE}"
  fi
  echo "═══════════════════════════════════════════════════════════════"
  lab_ops_log "docker_audit: done. noticed=$TOTAL_NOTICED deleted=$TOTAL_DELETED pending=$(pending_count)"
} | tee "$REPORT"
