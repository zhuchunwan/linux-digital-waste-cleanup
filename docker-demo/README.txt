功能 5 Docker 演示资产
====================

本目录中的 Dockerfile.v1 和 Dockerfile.v2 用于连续构建同一个标签，
从而让旧版本镜像变成虚悬镜像，供功能 5 巡检与回收。

演示资产统一使用 lab_ops_demo_ 前缀：
  lab_ops_demo_exited_1、lab_ops_demo_exited_2：待回收的退出容器
  lab_ops_demo_protected：写入 Docker 白名单的退出容器
  lab_ops_demo_unused_volume_1、lab_ops_demo_unused_volume_2：未使用数据卷
  lab_ops_demo_image:latest：最新演示镜像，功能 5 不会删除

运行项目总程序并选择功能 5，即可看到候选资产和白名单容器。
