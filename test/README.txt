本目录为 lab-ops 默认扫描根（LAB_OPS_SCAN_ROOT）。

快速测试
--------
  cd .. && ./scripts/disk_audit_tsv.sh
  ./scripts/dedupe_hardlink.sh          # 需 LAB_OPS_RUN_DEDUPE=1 或单独运行
  ./scripts/classify_by_magic.sh test/images 20

重新生成可重复的大块重复样本（不覆盖已硬链接的 copy_a/copy_b）：
  python3 test/gen_fixtures.py

目录与测试意图
--------------
  papers/          txt, md, bib；notes 无扩展名
  datasets/        csv, json, tsv, txt, bin；含与 dup 相同内容的 backup_copy.bin
  dup/             copy_a.dat + copy_b.dat（已硬链接演示）
                   triple_*.bin 三份相同大块（>1KB，测三组去重）
                   small_dup_*.txt 相同小块（<1KB，默认不去重）
  dup_nested/      三路径相同 result.out（跨目录重复）
  images/          pixel.png、scan_sample.jpg（供 file 魔数识别）
  archives/        part 分片、__MACOSX 碎文件模拟
  mixed/           文件名含逗号 data,with,commas.csv
  no_ext/          无点号文件 README
  code/            py, R, sh
  edge_cases/      空文件、极小文件、尾点文件名
  logs/            日志样例
  scripts/         hello.sh

去重验证
--------
  ls -li test/dup/copy_a.dat test/dup/copy_b.dat
  inode 相同且链接数 nlink=2 表示已合并为一份物理存储。

  对 triple 或 dup_nested 去重后：
  ls -li test/dup/triple_*.bin
  ls -li test/dup_nested/**/result*

注意：/mnt/d (NTFS) 硬链接能力有限；课程答辩可在 WSL ext4 目录再测一轮。
