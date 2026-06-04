╔══════════════════════════════════════════════════════════════════════════╗
║                                                                          ║
║     组员 B — Docker / 日志运维 — 完整交付文档                            ║
║     顾世豪                                                                 ║
║                                                                          ║
╚══════════════════════════════════════════════════════════════════════════╝


一、职责概述
═══════════

  组员 B 负责三项功能：
    ① Docker 资产审计 — 清理退出容器、虚悬镜像、僵尸数据卷（含 24h 预告）
    ② 定期日志清理 — 扫描并清理超过 N 天的过期日志文件
    ③ crontab 定时任务 — 让上述脚本定时自动运行


二、新建文件（2 个）
═══════════════


┌─────────────────────────────────────────────────────────────────────────┐
│ 文件 1：scripts/log_cleanup.sh                                          │
│ 功能：定期日志清理脚本                                                    │
└─────────────────────────────────────────────────────────────────────────┘

  做什么：
    扫描指定目录，找出超过 N 天未修改的日志文件（*.log、*.out、
    core.*、nohup.out 等），生成 TSV 报表，二次确认后删除。

  怎么用：
    ./scripts/log_cleanup.sh [目录] [保留天数] [匹配模式] [-y]
    
    例：./scripts/log_cleanup.sh test/mess 30        # 预览模式
        LAB_OPS_DRY_RUN=0 ./scripts/log_cleanup.sh test/mess/logs 30    # 正式删除

  技术要点：
    - find -mtime +N 做时间过滤
    - 支持管道分隔的多模式匹配（*.log|*.out|core.*）
    - 默认 DRY_RUN=1（只预览不删）
    - 二次确认（30 秒超时自动拒绝）
    - 全部记录到 TSV 报表和执行摘要日志

  运行流程：
    参数解析 → find -mtime 扫描 → 生成 TSV 报表
      → DRY_RUN=1? 停止并显示预览
      → 二次确认（输入 y 继续）
      → 逐文件删除 + 记录日志
      → 输出执行摘要（删除数/释放空间/失败数）


┌─────────────────────────────────────────────────────────────────────────┐
│ 文件 2：scripts/make_mess.sh                                            │
│ 功能：测试数据生成脚本                                                    │
└─────────────────────────────────────────────────────────────────────────┘

  做什么：
    在 test/mess/ 目录下生成 28 个测试文件，模拟真实的"数字垃圾"场景，
    供 log_cleanup.sh 和 docker_audit.sh 测试使用。

  怎么用：
    ./scripts/make_mess.sh              # 生成测试数据
    ./scripts/make_mess.sh clean        # 清理测试数据

  生成 6 类测试数据：
    ① 过期系统日志      syslog.1, kern.log.1, auth.log.1, dpkg.log.1
    ② 训练/服务日志     training_nohup.out, jupyter_old.log, tensorboard_cache.log
    ③ 深层嵌套日志      deep/nested/logs/old_experiment.log
    ④ Core dump 模拟     core.python.31415 (512KB), core.training.28901 (256KB)
    ⑤ 边界情况          文件名含空格、无扩展名文件
    ⑥ 近期文件           验证不会被误删

  技术要点：
    用 touch -t 把文件时间戳伪造成 2024 年（确保"超过 30 天"条件满足）


三、修改文件（5 个）
═══════════════


┌─────────────────────────────────────────────────────────────────────────┐
│ 文件 3：scripts/docker_audit.sh                                         │
│ 改动：24h 预告 + 全部资产明细表格展示                                      │
└─────────────────────────────────────────────────────────────────────────┘

  原有功能（保留）：
    - 清理退出超过 N 天的容器（docker rm）
    - 清理虚悬镜像（docker rmi）
    - 清理僵尸数据卷（docker volume rm）
    - 白名单机制
    - DRY_RUN 预览模式
    - 二次确认

  新增功能（全部资产明细展示）：
    - 列出所有容器（含运行中 + 已退出），表格显示退出时间和状态
    - 列出所有镜像（含正常镜像 + 虚悬镜像）
    - 列出所有数据卷（含正常卷 + 僵尸卷）
    - 每行都有状态图标：✅KEEP / 📝NOTICE / ⏳PENDING / 🗑DELETE
    - 显示"退出 X 分钟/小时/天前"而非原始时间戳

  新增功能（24h 预告）：
    第一次发现候选容器 → NOTICE：写入预告清单，不删除
    第二次运行（≥24h 后）→ 预告期满 → DELETE：真正删除
    容器已被手动删除   → 自动从预告清单清除
    设 PENDING_HOURS=0 可关闭预告，恢复立即删除

  新增 5 个函数：
    pending_add()          — 首次发现，加入预告清单
    pending_contains()     — 检查是否已在清单中
    pending_get_epoch()    — 获取记录时间戳
    pending_is_expired()   — 判断是否已过 24h
    pending_remove()       — 删除成功后从清单移除

  预告清单格式（logs/docker_pending_delete.log）：
    TYPE|ID|NAME|EPOCH|ISO_TIME
    container|abc123|ml-training|1717200000|2026-06-04T15:11:58
    image|def456|<none>:<none>|1717200000|2026-06-04T15:11:58
    volume|ghi789|orphan_data|1717200000|2026-06-04T15:11:58


┌─────────────────────────────────────────────────────────────────────────┐
│ 文件 4：crontab.example                                                 │
│ 改动：完善定时任务配置                                                    │
└─────────────────────────────────────────────────────────────────────────┘

  原来：只有 1 行定时任务
  现在：5 条定时任务，覆盖完整运维周期

  ┌──────────┬──────────────────────────────────────────────────────┐
  │ 时间     │ 做什么                                                │
  ├──────────┼──────────────────────────────────────────────────────┤
  │ 周一 8:00  │ 仅预览审计报表（不清理）                            │
  │ 周五 18:00 │ Docker 巡检预览                                     │
  │ 周日 3:00  │ 自动清理过期日志                                    │
  │ 周日 4:00  │ 清理自己的旧报表                                    │
  │ 每月 1 号  │ 全量清理流水线                                      │
  └──────────┴──────────────────────────────────────────────────────┘


┌─────────────────────────────────────────────────────────────────────────┐
│ 文件 5：config/lab_ops.conf.example                                     │
│ 改动：新增 5 个配置项                                                    │
└─────────────────────────────────────────────────────────────────────────┘

  新增配置项：
    LAB_OPS_LOG_CLEANUP_DIR     — 日志清理默认目录（/var/log）
    LAB_OPS_LOG_RETENTION_DAYS  — 日志保留天数（30）
    LAB_OPS_LOG_PATTERNS        — 匹配的文件后缀（*.log|*.out|core.*）
    LAB_OPS_RUN_LOG_CLEANUP     — 总流水线是否启用日志清理（0=关闭）
    LAB_OPS_DOCKER_PENDING_HOURS — Docker 删除预告时长（24）


┌─────────────────────────────────────────────────────────────────────────┐
│ 文件 6：lib/common.sh                                                   │
│ 改动：新增 1 行默认值                                                    │
└─────────────────────────────────────────────────────────────────────────┘

  LAB_OPS_DOCKER_PENDING_HOURS="${LAB_OPS_DOCKER_PENDING_HOURS:-24}"


┌─────────────────────────────────────────────────────────────────────────┐
│ 文件 7：scripts/run_all.sh                                              │
│ 改动：集成日志清理为第 4 步                                              │
└─────────────────────────────────────────────────────────────────────────┘

  4 处修改：
    - 头部注释新增"日志清理"
    - 状态展示新增"日志清理: 启用/跳过"
    - 确认清单新增日志清理操作预览
    - 新增步骤 4：if LOG_CLEANUP=1 → log_cleanup.sh


四、所有脚本通用的安全机制
═════════════════════════

  ┌──────────────┬─────────────────────────────────────────────────────┐
  │ 第 1 层      │ DRY_RUN=1（默认）：只生成预览报表，不执行任何修改  │
  │ 第 2 层      │ 二次确认：正式模式必须用户输入 y 才继续            │
  │ 第 3 层      │ 超时自动拒绝：30 秒无输入自动取消                   │
  │ 第 4 层      │ -y/--force 参数：无人值守时跳过确认（供 cron 用）  │
  └──────────────┴─────────────────────────────────────────────────────┘


五、速查卡 — 任何时候验证功能就用这些命令
═══════════════════════════════════════


  ┌── 验证日志清理 ──────────────────────────────────────────────────┐
  │                                                                   │
  │  # 1. 生成测试数据                                                 │
  │  ./scripts/make_mess.sh                                           │
  │                                                                   │
  │  # 2. 预览（安全，不删）                                           │
  │  ./scripts/log_cleanup.sh test/mess 30                            │
  │                                                                   │
  │  # 3. 正式删除（输入 y 确认）                                      │
  │  LAB_OPS_DRY_RUN=0 ./scripts/log_cleanup.sh test/mess/logs 30     │
  │                                                                   │
  │  # 4. 确认非日志文件没被误删（应该有 README, dotfile）              │
  │  ls test/mess/logs/                                               │
  │                                                                   │
  │  # 5. 清理测试数据                                                 │
  │  ./scripts/make_mess.sh clean                                     │
  │                                                                   │
  └───────────────────────────────────────────────────────────────────┘


  ┌── 验证 Docker 审计 ──────────────────────────────────────────────┐
  │                                                                   │
  │  # 1. 确认 Docker 在运行                                           │
  │  sudo service docker status                                       │
  │                                                                   │
  │  # 2. 制造测试垃圾                                                 │
  │  docker run --name test_dead alpine echo "done"                   │
  │  docker volume create test_orphan                                 │
  │                                                                   │
  │  # 3. 阈值设为 0（否则要等 7 天才能看到 NOTICE）                    │
  │  LAB_OPS_DOCKER_EXITED_DAYS=0 ./scripts/docker_audit.sh           │
  │                                                                   │
  │  # 4. 查看预告清单                                                 │
  │  cat logs/docker_pending_delete.log                                │
  │                                                                   │
  │  # 5. 模拟 24 小时后（一条命令改时间戳）                            │
  │  python3 -c "import time; p='logs/docker_pending_delete.log'; n=int(time.time()); o=n-26*3600; ls=open(p).readlines(); f=open(p,'w'); [f.write(l) if l.startswith('#') or not l.strip() else (x:=l.strip().split('|'), x.__setitem__(3,str(o)), x.__setitem__(4,time.strftime('%Y-%m-%dT%H:%M:%S',time.localtime(o))), f.write('|'.join(x)+'\n')) for l in ls]; f.close(); print('done')"
  │                                                                   │
  │  # 6. 再跑一次（全部变 DELETE）                                    │
  │  LAB_OPS_DOCKER_EXITED_DAYS=0 ./scripts/docker_audit.sh           │
  │                                                                   │
  │  # 7. 正式删除                                                     │
  │  LAB_OPS_DRY_RUN=0 LAB_OPS_DOCKER_EXITED_DAYS=0 ./scripts/docker_audit.sh -y │
  │                                                                   │
  │  # 8. 确认删掉了                                                   │
  │  docker ps -a                                                     │
  │  docker volume ls -f dangling=true                                │
  │                                                                   │
  └───────────────────────────────────────────────────────────────────┘


  ┌── 验证 crontab ──────────────────────────────────────────────────┐
  │                                                                   │
  │  # 查看已安装的定时任务                                             │
  │  crontab -l                                                       │
  │                                                                   │
  │  # 重新安装                                                        │
  │  crontab crontab.example                                          │
  │                                                                   │
  └───────────────────────────────────────────────────────────────────┘


六、参数含义速查
═══════════════

  log_cleanup.sh 的三个位置参数：

    ./scripts/log_cleanup.sh test/mess 30
                            ^^^^^^^^  ^^
                               │       └─ 保留天数：只清理超过 N 天未修改的文件
                               └───────── 目标目录：要扫描哪个文件夹

    ./scripts/log_cleanup.sh test/mess 7    → 4 号 → 5 月 28 号之前的文件
    ./scripts/log_cleanup.sh test/mess 30   → 超过 30 天
    ./scripts/log_cleanup.sh test/mess 90   → 超过 90 天

  数字越大 → 保留越多 → 删得越少（保守）
  数字越小 → 保留越少 → 删得越多（激进）


  docker_audit.sh 的环境变量：

    LAB_OPS_DOCKER_EXITED_DAYS=0   退出容器阈值（天）。设 0 则不管退出多久都算
    LAB_OPS_DOCKER_PENDING_HOURS=0 预告时长（小时）。设 0 则跳过预告立即删除
    LAB_OPS_DRY_RUN=0              设 0 则正式删除（默认 1 仅预览）

  常用组合：
    LAB_OPS_DOCKER_EXITED_DAYS=0 ./scripts/docker_audit.sh        强制通过阈值，看 NOTICE
    LAB_OPS_DRY_RUN=0 LAB_OPS_DOCKER_EXITED_DAYS=0 ... -y         正式删除所有退出容器


  Docker 审计输出中的状态标签：

    ✅ KEEP       正常使用中 / 未满阈值，不会删除
    🔒 白名单     在白名单里，永久保留
    📝 NOTICE     首次发现垃圾，刚加入预告清单，这次不删
    ⏳ PENDING    已在预告清单但未满 24h，继续等待
    🗑 DELETE     预告期满（≥24h），正式模式下会删除


七、当前完整文件列表（你的项目目录）
═══════════════════════════════

  linux-digital-waste-cleanup/
  ├── config/
  │   ├── lab_ops.conf.example    ← 你加了 5 个配置项
  │   └── docker_whitelist.txt
  ├── lib/
  │   └── common.sh               ← 你加了 1 行默认值
  ├── scripts/
  │   ├── docker_audit.sh         ← 你重写了（24h 预告）
  │   ├── log_cleanup.sh          ← 你新建的（日志清理）
  │   ├── make_mess.sh            ← 你新建的（测试数据）
  │   ├── run_all.sh              ← 你集成了日志清理步骤
  │   ├── disk_audit_tsv.sh       （组员 A）
  │   ├── dedupe_hardlink.sh      （组员 A）
  │   ├── classify_by_magic.sh    （组员 C）
  │   └── fix_crlf.sh             （工具）
  ├── test/                       ← 测试数据
  ├── reports/                    ← 报表输出（自动）
  ├── logs/                       ← 日志输出（自动）
  ├── GSH_README.txt              ← 本文件
  └── crontab.example             ← 你完善的
