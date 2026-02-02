# 环境说明
Nvidia GPU T4 * 2 (16G 显存 * 2)

# 测试1，单个任务占满显存，独占GPU

试用tests/pytorch-add.py 负载满负荷测试GPU，每个任务GPU显存占用约12GB，算力占用100%

remote-test.sh --skip-setup 2

测试结果

```
Scheduler Log Analysis (GPU Distribution):
Analyzing scheduler pod: nvshare-scheduler-g8lhv
Pod Name                       | Client ID          | GPU UUID
--------------------------------------------------------------------------------------------
nvshare-cross-gpu-1            | febebf756a61f686   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
nvshare-cross-gpu-2            | f2a9071d95ed7ff5   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1

==========================================================================================
nvshare-cross-gpu-1            | PASS     | 164s         | 25.83 it/s   | 1024
nvshare-cross-gpu-2            | PASS     | 164s         | 25.80 it/s   | 1024
==========================================================================================

📊 统计分析:
  Total: 2, Pass: 2, Fail: 0
  Duration: Min=164s, Max=164s, Avg=164.0s
  Speed   : Min=25.80, Max=25.83, Avg=25.81 (it/s)


==========================================
✅ 测试通过：跨 GPU 负载分布成功
==========================================
```

# 测试2，多个任务串行，共享独占GPU（手动指定串行）

试用tests/pytorch-add.py 负载满负荷测试GPU，每个任务GPU显存占用约12GB，算力占用100%

remote-test.sh --serial--skip-setup 4 

测试结果

```
Scheduler Log Analysis (GPU Distribution):
Analyzing scheduler pod: nvshare-scheduler-g79d6
Pod Name                       | Client ID          | GPU UUID
--------------------------------------------------------------------------------------------
nvshare-cross-gpu-1            | c6c3068df341e374   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
nvshare-cross-gpu-2            | edbbd0a17e2b8350   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
nvshare-cross-gpu-3            | 622900c037f9ea29   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
nvshare-cross-gpu-4            | d3ce8c7d1b51ded2   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e

==========================================================================================
nvshare-cross-gpu-1            | PASS     | 309s         | 22.24 it/s   | 1024
nvshare-cross-gpu-2            | PASS     | 310s         | 22.21 it/s   | 1024
nvshare-cross-gpu-3            | PASS     | 346s         | 23.62 it/s   | 1024
nvshare-cross-gpu-4            | PASS     | 342s         | 23.65 it/s   | 1024
==========================================================================================

📊 统计分析:
  Total: 4, Pass: 4, Fail: 0
  Duration: Min=309s, Max=346s, Avg=326.8s
  Speed   : Min=22.21, Max=23.65, Avg=22.93 (it/s)


==========================================
✅ 测试通过：跨 GPU 负载分布成功
==========================================
```



# 测试3，单个任务占1/4显存，独占GPU

试用tests/pytorch-add-small.py 负载满负荷测试GPU，每个任务GPU显存占用约4GB，算力占用100%

./remote-test-small.sh --skip-setup 2

测试结果

```
Scheduler Log Analysis (GPU Distribution):
Analyzing scheduler pod: nvshare-scheduler-8hww8
Pod Name                       | Client ID          | GPU UUID
--------------------------------------------------------------------------------------------
nvshare-small-1                | 7168850a95d8871a   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
nvshare-small-2                | ecd31afb7530d21e   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1

==========================================================================================
nvshare-small-1                | PASS     | 392s         | 103.61 it/s  | 2048
nvshare-small-2                | PASS     | 393s         | 103.40 it/s  | 2048
==========================================================================================

📊 统计分析:
  Total: 2, Pass: 2, Fail: 0
  Duration: Min=392s, Max=393s, Avg=392.5s
  Speed   : Min=103.40, Max=103.61, Avg=103.50 (it/s)


==========================================
✅ 测试通过：Small Workload 全部成功
==========================================
```

# 测试3，单个任务占1/4显存，共享使用GPU

试用tests/pytorch-add-small.py 负载满负荷测试GPU，每个任务GPU显存占用约4GB，算力占用100%（由于共享GPU，实际占用约1/2)

./remote-test-small.sh --skip-setup 

测试结果

```
Scheduler Log Analysis (GPU Distribution):
Analyzing scheduler pod: nvshare-scheduler-b66f8
Pod Name                       | Client ID          | GPU UUID
--------------------------------------------------------------------------------------------
nvshare-small-1                | a12c4b64b99e09dc   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
nvshare-small-3                | 3ddc0cbb29e864ce   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
nvshare-small-2                | 8a1187551fc907a3   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
nvshare-small-4                | dc896c93bd23d55f   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1

==========================================================================================
nvshare-small-1                | PASS     | 866s         | 46.43 it/s   | 1024
nvshare-small-2                | PASS     | 869s         | 47.38 it/s   | 1024
nvshare-small-3                | PASS     | 868s         | 46.42 it/s   | 1024
nvshare-small-4                | PASS     | 867s         | 77.21 it/s   | 1024
==========================================================================================

📊 统计分析:
  Total: 4, Pass: 4, Fail: 0
  Duration: Min=866s, Max=869s, Avg=867.5s
  Speed   : Min=46.42, Max=77.21, Avg=54.36 (it/s)


==========================================
✅ 测试通过：Small Workload 全部成功
==========================================
```

# 遗留问题
- 如果不重启device-plugin，调度策略会有问题，导致频繁的任务切换
- 如果不指定Serial模式，当多个任务加起来超过显存大小时，会导致运行特别缓慢