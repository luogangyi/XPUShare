# 环境说明
Nvidia GPU T4 * 2 (16G 显存 * 2)

# 测试0，基准测试
修改为原生nvidia的device-plugin，对pytorch-add.py、pytorch-add-small.py、pytorch-add-idle-small.py进行测试。

测试结果：
```

```

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

# 测试2，多个任务串行，共享独占GPU

## 配置为串行模式

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

## 配置为auto模式

```
Analyzing scheduler pod: nvshare-scheduler-vcmhq
Pod Name                       | Client ID          | GPU UUID
--------------------------------------------------------------------------------------------
nvshare-cross-gpu-1            | 590f7404f4a2ee15   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
nvshare-cross-gpu-2            | 907c730df22d942d   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
nvshare-cross-gpu-3            | b03d1525817c98be   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
nvshare-cross-gpu-4            | 7acd81ec86234e36   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e

==========================================================================================
nvshare-cross-gpu-1            | PASS     | 282s         | 24.47 it/s   | 1024
nvshare-cross-gpu-2            | PASS     | 347s         | 21.18 it/s   | 1024
nvshare-cross-gpu-3            | PASS     | 345s         | 6.48 it/s    | 1024
nvshare-cross-gpu-4            | PASS     | 341s         | 25.38 it/s   | 1024
==========================================================================================

📊 统计分析:
  Total: 4, Pass: 4, Fail: 0
  Duration: Min=282s, Max=347s, Avg=328.8s
  Speed   : Min=6.48, Max=25.38, Avg=19.38 (it/s)


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

# 测试4，单个任务占1/4显存，共享使用GPU

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

# 测试5，每个任务占1/4 GPU，独占GPU
试用tests/pytorch-add-idle-small.py 间歇性测试GPU，每个任务GPU显存占用约4GB，算力占用约50%%

remote-test-idle-small.sh --skip-setup 1

测试结果
```
Scheduler Log Analysis (GPU Distribution):
Analyzing scheduler pod: nvshare-scheduler-vcmhq
Pod Name                       | Client ID          | GPU UUID
--------------------------------------------------------------------------------------------
nvshare-idle-small-1           | 6b8926a17f393395   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1

==========================================================================================
nvshare-idle-small-1           | PASS     | 444s         | 9.12 it/s    | 2048
==========================================================================================

📊 统计分析:
  Total: 1, Pass: 1, Fail: 0
  Duration: Min=444s, Max=444s, Avg=444.0s
  Speed   : Min=9.12, Max=9.12, Avg=9.12 (it/s)


==========================================
✅ 测试通过：Idle Small Workload
==========================================
```

# 测试6，每个任务占1/4 GPU，共享GPU
试用tests/pytorch-add-idle-small.py 间歇性测试GPU，每个任务GPU显存占用约4GB，算力占用约10%%，共享GPU，由于本身任务就不需要跑满GPU算力，理论上并行不会影响任务完成时间。

remote-test-idle-small.sh --skip-setup 6

测试结果
```
Scheduler Log Analysis (GPU Distribution):
Analyzing scheduler pod: nvshare-scheduler-8ss4f
Pod Name                       | Client ID          | GPU UUID
--------------------------------------------------------------------------------------------
nvshare-idle-small-3           | d5bd144e36db3ac1   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
nvshare-idle-small-2           | 5303e558781a9411   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
nvshare-idle-small-4           | 4c35e94d799441ab   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
nvshare-idle-small-5           | 78d1a1c85ea5f193   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
nvshare-idle-small-1           | a5fdcec1c148ce27   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
nvshare-idle-small-6           | 478c496370dd9c3f   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e

==========================================================================================
nvshare-idle-small-1           | PASS     | 481s         | 8.32 it/s    | 2048
nvshare-idle-small-2           | PASS     | 483s         | 8.42 it/s    | 2048
nvshare-idle-small-3           | PASS     | 481s         | 8.51 it/s    | 2048
nvshare-idle-small-4           | PASS     | 482s         | 9.05 it/s    | 2048
nvshare-idle-small-5           | PASS     | 483s         | 8.19 it/s    | 2048
nvshare-idle-small-6           | PASS     | 481s         | 9.07 it/s    | 2048
==========================================================================================

📊 统计分析:
  Total: 6, Pass: 6, Fail: 0
  Duration: Min=481s, Max=483s, Avg=481.8s
  Speed   : Min=8.19, Max=9.07, Avg=8.59 (it/s)


==========================================
✅ 测试通过：Idle Small Workload
==========================================
```
