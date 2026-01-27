为了后续修改代码的时候，不出现大量因为format问题，导致diff出大量非功能修改，请对所有代码先统一进行一次format


当前项目仅支持一个gpu，即nvshare currently supports only one GPU per node, as nvshare-scheduler is hardcoded to use the Nvidia GPU with ID 0. 分析项目代码，设计实现支持多GPU方案。注意修改代码的时候，只修改真正改动的行，对没改动的行，不要重新代码或者进行format.

你是架构师，需要对libnvshare的架构和实现方案进行详细分析，请分析代码，输出详细的分析问到到docs目录下

你是架构师，需要对项目中Unified Memory的的架构和实现方案进行详细分析，请分析代码，输出详细的分析问到到docs目录下

你是架构师，需要对项目中lib、client、scheduler的部署模式、运行模式进行分析。例如lib是需要在业务使用的GPU容器中preload的吗？还是在Device-plugin中被preload？scheduler和client分别运行在哪？是否是常驻后台的进程？分析结果保存到docs下

分析在多GPU场景下，DevicePlugin如何调度GPU，例如每个GPU被虚拟化为10个vGPU，节点上有8个GPU，即80个vGPU，那么用户申请的vGPU，是否能优先调度到不同的物理机GPU，如果所有物理机GPU都有任务，是否能按GPU负载进行调度。如果当前代码就可以，请分析实现方案，如果当前代码不可以，请给出设计方案。方案保存到docs下

我的测试环境有2个T4的GPU，每个有16G显存，请结合tests下准备的测试容器，设计一个测试方案，保存到docs下以及对应的测试脚本，放到.tests/scripts下


```
我测试test-cross-gpu（设置了创建4个GPU），发现运行特别慢，检查日志发现如下日志：root@lgy-test-gpu:~# kubectl logs nvshare-cross-gpu-3
[NVSHARE][WARN]: Enabling GPU memory oversubscription for this application
[NVSHARE][DEBUG]: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1: undefined symbol: nvmlDeviceGetHandleByUUID_v2
[NVSHARE][DEBUG]: Could not find NVML
[NVSHARE][DEBUG]: NVSHARE_POD_NAME = nvshare-cross-gpu-3
[NVSHARE][DEBUG]: NVSHARE_POD_NAMESPACE = default
[NVSHARE][DEBUG]: Sent REGISTER
[NVSHARE][DEBUG]: Received SCHED_ON
[NVSHARE][INFO]: Successfully initialized nvshare GPU
[NVSHARE][INFO]: Client ID = a982b99a7cd7153d
[NVSHARE][DEBUG]: real_cuMemGetInfo returned free=11670.81 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: nvshare's cuMemGetInfo returning free=13377.69 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f0d58000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 2992.00 MiB
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f0c9c000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 5984.00 MiB
  0%|          | 0/4000 [00:00<?, ?it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f0be0000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 8976.00 MiB
[NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 1/4000 [00:00<19:34,  3.40it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f0b24000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 11968.00 MiB
[NVSHARE][DEBUG]: Pending Kernel Window is 4.
  0%|          | 2/4000 [00:00<31:27,  2.12it/s][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 4/4000 [00:03<1:01:00,  1.09it/s][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 5/4000 [00:05<1:23:57,  1.26s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
  0%|          | 6/4000 [00:06<1:25:35,  1.29s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 7/4000 [00:07<1:07:17,  1.01s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4.
  0%|          | 8/4000 [00:07<1:02:42,  1.06it/s][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 10/4000 [00:09<57:44,  1.15it/s] [NVSHARE][DEBUG]: Pending Kernel Window is 4.
  0%|          | 11/4000 [00:10<56:17,  1.18it/s][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 13/4000 [00:11<54:30,  1.22it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4.
  0%|          | 14/4000 [00:12<53:50,  1.23it/s][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 16/4000 [00:14<53:09,  1.25it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4.
  0%|          | 17/4000 [00:14<52:52,  1.26it/s][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 19/4000 [00:16<52:25,  1.27it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4.
  0%|          | 20/4000 [00:17<52:20,  1.27it/s][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 22/4000 [00:18<52:05,  1.27it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4.
  1%|          | 23/4000 [00:19<51:55,  1.28it/s][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 25/4000 [00:21<51:45,  1.28it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4.
  1%|          | 26/4000 [00:21<51:41,  1.28it/s][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 28/4000 [00:23<51:33,  1.28it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4.
  1%|          | 29/4000 [00:24<51:34,  1.28it/s][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 31/4000 [00:25<51:29,  1.28it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 2.
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
[NVSHARE][DEBUG]: Received LOCK_OK
  1%|          | 32/4000 [01:27<15:02:36, 13.65s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 33/4000 [01:29<12:09:30, 11.03s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 34/4000 [01:30<9:30:23,  8.63s/it] [NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 35/4000 [01:32<7:24:42,  6.73s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 36/4000 [01:33<5:48:33,  5.28s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 37/4000 [01:35<4:36:51,  4.19s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 38/4000 [01:36<3:44:14,  3.40s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 39/4000 [01:37<3:06:01,  2.82s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 40/4000 [01:39<2:38:36,  2.40s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 41/4000 [01:40<2:19:12,  2.11s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 42/4000 [01:42<2:05:34,  1.90s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 43/4000 [01:43<1:55:52,  1.76s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 44/4000 [01:44<1:49:03,  1.65s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 45/4000 [01:46<1:44:11,  1.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 46/4000 [01:47<1:40:53,  1.53s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 47/4000 [01:49<1:38:22,  1.49s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 48/4000 [01:50<1:36:47,  1.47s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 49/4000 [01:51<1:35:36,  1.45s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|▏         | 50/4000 [01:53<1:34:42,  1.44s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|▏         | 51/4000 [01:54<1:34:08,  1.43s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|▏         | 52/4000 [01:56<1:33:34,  1.42s/it][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|▏         | 53/4000 [02:58<21:37:53, 19.73s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|▏         | 54/4000 [03:00<15:36:02, 14.23s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|▏         | 55/4000 [03:01<11:22:49, 10.39s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.

检查容器内存占用发现如下（nvshare-cross-gpu-4很快就完成了）：
  root@lgy-test-gpu:~# kubectl top po
NAME                  CPU(cores)   MEMORY(bytes)
nvshare-cross-gpu-1   1m           14499Mi
nvshare-cross-gpu-2   1m           14486Mi
nvshare-cross-gpu-3   979m         14486Mi
， 检查GPU显存使用发现如下：+-----------------------------------------------------------------------------------------+
| Processes:                                                                              |
|  GPU   GI   CI              PID   Type   Process name                        GPU Memory |
|        ID   ID                                                               Usage      |
|=========================================================================================|
|    1   N/A  N/A           80513      C   python                                 1006MiB |
|    1   N/A  N/A           80514      C   python                                 1006MiB |
|    1   N/A  N/A           80515      C   python                                 1006MiB |
+-----------------------------------------------------------------------------------------+ 请分析原因，将分析报告和改进方案放到docs下 

```