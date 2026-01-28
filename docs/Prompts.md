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

```
我设计了一个方案，这个方案是基于docs/gpu_sharing_performance_analysis.md设计的中期方案，在这个基础上，加一个根据时间强制的强制切换，例如进程A先申请到了全部显存，B申请不到显存，就让B留在内存里，并且也不调度B执行，当A运行超过一定时间后，强行调度B执行，让A等待，这样即保障了不方式过多的内存显存切换，又保障了每个进程都可以得到运行。请对这个方案进行详细分析，并进行改进，分析文档保存到docs下
```

```
调度方案中补充1）强制切换时间做成参数可以配置 2）强制切换的时间如果配置为auto，则建议通过需要显存-内存置换时间的5倍估算，比如估算需要置换10G显存，置换到内存大约需要10秒，那么任务至少应该运行50秒才进行强制切换，让切换时间不成为影响完成时间的主要因素。 如果配置成固定值，则按固定值进行切换。3）如果显存能把多个任务都放进去，则多个任务都应该优先使用显存，而不使用内存 ，这个时候不应该发生显存-内存切换。
```

```
重新测试，创建了4个 nvshare-cross-gpu，从日志看，其中nvshare-cross-gpu-2得到了运行，root@lgy-test-gpu:~# kubectl logs nvshare-cross-gpu-2
[NVSHARE][WARN]: Enabling GPU memory oversubscription for this application
[NVSHARE][DEBUG]: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1: undefined symbol: nvmlDeviceGetHandleByUUID_v2
[NVSHARE][DEBUG]: Could not find NVML
[NVSHARE][DEBUG]: NVSHARE_POD_NAME = nvshare-cross-gpu-2
[NVSHARE][DEBUG]: NVSHARE_POD_NAMESPACE = default
[NVSHARE][DEBUG]: Sent REGISTER
[NVSHARE][DEBUG]: Received SCHED_ON
[NVSHARE][INFO]: Successfully initialized nvshare GPU
[NVSHARE][INFO]: Client ID = 957d0ed8851bcf9a
[NVSHARE][DEBUG]: real_cuMemGetInfo returned free=13904.81 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: nvshare's cuMemGetInfo returning free=13377.69 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7efce0000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 2992.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 2992 MB
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7efc24000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 5984.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 5984 MB
  0%|          | 0/4000 [00:00<?, ?it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7efb68000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 8976.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 8976 MB
[NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 1/4000 [00:00<08:16,  8.06it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7efaac000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 11968.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 11968 MB
[NVSHARE][DEBUG]: Pending Kernel Window is 4.
  0%|          | 2/4000 [00:00<12:26,  5.35it/s][NVSHARE][DEBUG]: Pending Kernel Window is 8.
  0%|          | 4/4000 [00:00<08:14,  8.08it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16.
  0%|          | 8/4000 [00:00<04:36, 14.46it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32.
  0%|          | 16/4000 [00:00<03:16, 20.23it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64.
  1%|          | 32/4000 [00:01<02:48, 23.55it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32.
  2%|▏         | 64/4000 [00:02<02:37, 25.00it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64.
  2%|▏         | 80/4000 [00:03<02:35, 25.26it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32.
  3%|▎         | 112/4000 [00:04<02:32, 25.54it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64.
  3%|▎         | 128/4000 [00:05<02:31, 25.61it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32.
  4%|▍         | 160/4000 [00:06<02:29, 25.71it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64.
  4%|▍         | 176/4000 [00:07<02:28, 25.75it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32.
  5%|▌         | 208/4000 [00:08<02:27, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64.
  6%|▌         | 224/4000 [00:09<02:26, 25.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32.
  6%|▋         | 256/4000 [00:10<02:25, 25.82it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64.
  7%|▋         | 272/4000 [00:10<02:24, 25.83it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32.
  8%|▊         | 304/4000 [00:12<02:23, 25.83it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64.其他三个在等待，如root@lgy-test-gpu:~# kubectl logs nvshare-cross-gpu-3
[NVSHARE][WARN]: Enabling GPU memory oversubscription for this application
[NVSHARE][DEBUG]: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1: undefined symbol: nvmlDeviceGetHandleByUUID_v2
[NVSHARE][DEBUG]: Could not find NVML
[NVSHARE][DEBUG]: NVSHARE_POD_NAME = nvshare-cross-gpu-3
[NVSHARE][DEBUG]: NVSHARE_POD_NAMESPACE = default
[NVSHARE][DEBUG]: Sent REGISTER
[NVSHARE][DEBUG]: Received SCHED_ON
[NVSHARE][INFO]: Successfully initialized nvshare GPU
[NVSHARE][INFO]: Client ID = 67bdcc890495d6cd
[NVSHARE][DEBUG]: real_cuMemGetInfo returned free=9178.81 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: nvshare's cuMemGetInfo returning free=13377.69 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f9682000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 2992.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 2992 MB
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f95c6000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 5984.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 5984 MB
  0%|          | 0/4000 [00:00<?, ?it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f950a000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 8976.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 8976 MB
[NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 1/4000 [00:00<19:46,  3.37it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f944e000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 11968.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 11968 MB
[NVSHARE][DEBUG]: Pending Kernel Window is 4.
  0%|          | 2/4000 [00:00<31:27,  2.12it/s][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 4/4000 [00:03<1:00:39,  1.10it/s][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 5/4000 [00:05<1:23:42,  1.26s/it][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Sent LOCK_RELEASED，看上去工作正常符合预期。从kubetctl top看root@lgy-test-gpu:~# kubectl top po nvshare-cross-gpu-1
NAME                  CPU(cores)   MEMORY(bytes)
nvshare-cross-gpu-1   1m           14480Mi
root@lgy-test-gpu:~# kubectl top po nvshare-cross-gpu-2
NAME                  CPU(cores)   MEMORY(bytes)
nvshare-cross-gpu-2   1001m        2518Mi
root@lgy-test-gpu:~# kubectl top po nvshare-cross-gpu-3
NAME                  CPU(cores)   MEMORY(bytes)
nvshare-cross-gpu-3   1001m        14480Mi
root@lgy-test-gpu:~# kubectl top po nvshare-cross-gpu-4
NAME                  CPU(cores)   MEMORY(bytes)
nvshare-cross-gpu-4   608m         14487Mi，nvshare-cross-gpu-2相对其他容器没有使用大量内存，也符合预期。但是nvidia-smi看，确还是只用了1G显存，|=========================================================================================|
|    0   N/A  N/A          764045      C   python                                 1006MiB |
|    0   N/A  N/A          764485      C   python                                 1006MiB |
|    0   N/A  N/A          764699      C   python                                 1006MiB |
|    1   N/A  N/A          764261      C   python                                 1006MiB |
+-----------------------------------------------------------------------------------------+分析原因
```


```
发现nvshare-cross-gpu-2运行完成后，其他任务看上去在频繁的发生切换，其他日志如下root@lgy-test-gpu:~# kubectl logs nvshare-cross-gpu-4
[NVSHARE][WARN]: Enabling GPU memory oversubscription for this application
[NVSHARE][DEBUG]: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1: undefined symbol: nvmlDeviceGetHandleByUUID_v2
[NVSHARE][DEBUG]: Could not find NVML
[NVSHARE][DEBUG]: NVSHARE_POD_NAME = nvshare-cross-gpu-4
[NVSHARE][DEBUG]: NVSHARE_POD_NAMESPACE = default
[NVSHARE][DEBUG]: Sent REGISTER
[NVSHARE][DEBUG]: Received SCHED_ON
[NVSHARE][INFO]: Successfully initialized nvshare GPU
[NVSHARE][INFO]: Client ID = c0bb36b9ab381719
[NVSHARE][DEBUG]: real_cuMemGetInfo returned free=2.81 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: nvshare's cuMemGetInfo returning free=13377.69 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f72be000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 2992.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 2992 MB
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f7202000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 5984.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 5984 MB
  0%|          | 0/4000 [00:00<?, ?it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f7146000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 8976.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 8976 MB
[NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 1/4000 [00:00<20:03,  3.32it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f708a000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 11968.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 11968 MB
[NVSHARE][DEBUG]: Pending Kernel Window is 4.
  0%|          | 2/4000 [00:00<32:13,  2.07it/s][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 4/4000 [00:03<1:01:16,  1.09it/s][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 5/4000 [00:05<1:24:29,  1.27s/it][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
  0%|          | 6/4000 [00:06<1:26:01,  1.29s/it][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  0%|          | 7/4000 [02:00<39:17:04, 35.42s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 8/4000 [02:00<27:30:01, 24.80s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  0%|          | 9/4000 [02:02<19:59:45, 18.04s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 10/4000 [02:03<14:05:41, 12.72s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  0%|          | 11/4000 [02:05<10:39:33,  9.62s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 12/4000 [02:06<7:34:56,  6.84s/it] [NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  0%|          | 13/4000 [02:08<6:06:35,  5.52s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 14/4000 [02:08<4:24:04,  3.97s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  0%|          | 15/4000 [02:11<3:52:49,  3.51s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 16/4000 [02:11<2:50:32,  2.57s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  0%|          | 17/4000 [02:14<2:47:35,  2.52s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 18/4000 [02:14<2:04:54,  1.88s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  0%|          | 19/4000 [02:16<2:15:49,  2.05s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  0%|          | 20/4000 [02:17<1:42:42,  1.55s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 21/4000 [02:19<2:00:04,  1.81s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 22/4000 [02:20<1:31:35,  1.38s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 23/4000 [02:22<1:52:02,  1.69s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 24/4000 [02:22<1:25:59,  1.30s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 25/4000 [02:25<1:48:04,  1.63s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 26/4000 [02:25<1:23:12,  1.26s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 27/4000 [02:28<1:46:09,  1.60s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 28/4000 [02:28<1:22:01,  1.24s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 29/4000 [02:30<1:45:14,  1.59s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 30/4000 [02:31<1:21:12,  1.23s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 31/4000 [02:33<1:44:38,  1.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 32/4000 [02:34<1:20:57,  1.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 33/4000 [02:36<1:44:30,  1.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 34/4000 [02:36<1:20:44,  1.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 35/4000 [02:39<1:44:23,  1.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 36/4000 [02:39<1:20:37,  1.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 37/4000 [02:42<1:44:08,  1.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 38/4000 [02:42<1:20:25,  1.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 39/4000 [02:44<1:44:14,  1.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 40/4000 [02:45<1:20:31,  1.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 41/4000 [02:47<1:44:10,  1.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 42/4000 [02:48<1:20:28,  1.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 43/4000 [02:50<1:44:15,  1.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 44/4000 [02:50<1:20:29,  1.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
  1%|          | 45/4000 [02:53<1:44:06,  1.58s/it][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 46/4000 [04:46<38:31:25, 35.07s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 47/4000 [04:46<27:05:09, 24.67s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|          | 48/4000 [04:49<19:45:02, 17.99s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|          | 49/4000 [04:49<13:56:51, 12.71s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|▏         | 50/4000 [04:52<10:33:21,  9.62s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|▏         | 51/4000 [04:52<7:30:45,  6.85s/it] [NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|▏         | 52/4000 [04:54<6:03:04,  5.52s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|▏         | 53/4000 [04:55<4:21:42,  3.98s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|▏         | 54/4000 [04:57<3:50:56,  3.51s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|▏         | 55/4000 [04:58<2:49:21,  2.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|▏         | 56/4000 [05:00<2:46:28,  2.53s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|▏         | 57/4000 [05:00<2:04:03,  1.89s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  1%|▏         | 58/4000 [05:03<2:14:35,  2.05s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  1%|▏         | 59/4000 [05:03<1:41:45,  1.55s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  2%|▏         | 60/4000 [05:06<1:58:51,  1.81s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  2%|▏         | 61/4000 [05:06<1:30:58,  1.39s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  2%|▏         | 62/4000 [05:08<1:51:16,  1.70s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  2%|▏         | 63/4000 [05:09<1:25:24,  1.30s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  2%|▏         | 64/4000 [05:11<1:47:15,  1.63s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  2%|▏         | 65/4000 [05:12<1:22:44,  1.26s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  2%|▏         | 66/4000 [05:14<1:45:52,  1.61s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  2%|▏         | 67/4000 [05:14<1:21:39,  1.25s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  2%|▏         | 68/4000 [05:17<1:44:31,  1.59s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  2%|▏         | 69/4000 [05:17<1:20:38,  1.23s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  2%|▏         | 70/4000 [05:20<1:43:53,  1.59s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  2%|▏         | 71/4000 [05:20<1:20:11,  1.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  2%|▏         | 72/4000 [05:22<1:43:27,  1.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  2%|▏         | 73/4000 [05:23<1:19:53,  1.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  2%|▏         | 74/4000 [05:25<1:43:19,  1.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  2%|▏         | 75/4000 [05:26<1:19:47,  1.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  2%|▏         | 76/4000 [05:28<1:43:13,  1.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  2%|▏         | 77/4000 [05:28<1:19:41,  1.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  2%|▏         | 78/4000 [05:31<1:42:58,  1.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  2%|▏         | 79/4000 [05:31<1:19:29,  1.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  2%|▏         | 80/4000 [05:34<1:43:01,  1.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  2%|▏         | 81/4000 [05:34<1:19:45,  1.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  2%|▏         | 82/4000 [05:36<1:43:18,  1.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  2%|▏         | 83/4000 [05:37<1:19:44,  1.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
  2%|▏         | 84/4000 [05:39<1:43:09,  1.58s/it][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  2%|▏         | 85/4000 [07:32<38:06:22, 35.04s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  2%|▏         | 86/4000 [07:33<26:47:32, 24.64s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  2%|▏         | 87/4000 [07:35<19:32:16, 17.98s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  2%|▏         | 88/4000 [07:36<13:48:06, 12.70s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  2%|▏         | 89/4000 [07:38<10:27:04,  9.62s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  2%|▏         | 90/4000 [07:38<7:26:17,  6.85s/it] [NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  2%|▏         | 91/4000 [07:41<5:59:29,  5.52s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  2%|▏         | 92/4000 [07:41<4:19:07,  3.98s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  2%|▏         | 93/4000 [07:44<3:48:59,  3.52s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  2%|▏         | 94/4000 [07:44<2:47:59,  2.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  2%|▏         | 95/4000 [07:46<2:44:49,  2.53s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  2%|▏         | 96/4000 [07:47<2:02:47,  1.89s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  2%|▏         | 97/4000 [07:49<2:13:11,  2.05s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  2%|▏         | 98/4000 [07:50<1:40:42,  1.55s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  2%|▏         | 99/4000 [07:52<1:57:41,  1.81s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  2%|▎         | 100/4000 [07:52<1:29:50,  1.38s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  3%|▎         | 101/4000 [07:55<1:49:58,  1.69s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  3%|▎         | 102/4000 [07:55<1:24:34,  1.30s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  3%|▎         | 103/4000 [07:58<1:46:30,  1.64s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  3%|▎         | 104/4000 [07:58<1:22:15,  1.27s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  3%|▎         | 105/4000 [08:00<1:44:52,  1.62s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  3%|▎         | 106/4000 [08:01<1:21:01,  1.25s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  3%|▎         | 107/4000 [08:03<1:43:57,  1.60s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  3%|▎         | 108/4000 [08:04<1:20:13,  1.24s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  3%|▎         | 109/4000 [08:06<1:43:23,  1.59s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  3%|▎         | 110/4000 [08:06<1:19:51,  1.23s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  3%|▎         | 111/4000 [08:09<1:43:02,  1.59s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  3%|▎         | 112/4000 [08:09<1:19:31,  1.23s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  3%|▎         | 113/4000 [08:12<1:42:28,  1.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  3%|▎         | 114/4000 [08:12<1:19:07,  1.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  3%|▎         | 115/4000 [08:14<1:42:16,  1.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  3%|▎         | 116/4000 [08:15<1:18:56,  1.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  3%|▎         | 117/4000 [08:17<1:42:09,  1.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  3%|▎         | 118/4000 [08:18<1:18:56,  1.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  3%|▎         | 119/4000 [08:20<1:42:13,  1.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  3%|▎         | 120/4000 [08:20<1:18:58,  1.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  3%|▎         | 121/4000 [08:23<1:42:06,  1.58s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  3%|▎         | 122/4000 [08:23<1:18:49,  1.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
  3%|▎         | 123/4000 [08:26<1:41:57,  1.58s/it][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  3%|▎         | 124/4000 [10:19<37:41:54, 35.01s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  3%|▎         | 125/4000 [10:19<26:30:17, 24.62s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  3%|▎         | 126/4000 [10:22<19:19:51, 17.96s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  3%|▎         | 127/4000 [10:22<13:39:15, 12.69s/it][NVSHARE][DEBUG]: Pending Kernel Window is 1.
[NVSHARE][DEBUG]: Pending Kernel Window is 1.
  3%|▎         | 128/4000 [10:24<10:20:14,  9.61s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2.
  3%|▎         | 129/4000 [10:25<7:21:26,  6.84s/it] [NVSHARE][DEBUG]: Pending Kernel Window is 1.
```

```
还有2个疑问：1）nvshare-cross-gpu测试实际调用的是tests/pytorch-add.py，请分析这段代码，是否符合你说的“为什么 nvidia-smi 只显示 1GB 显存？ 驱动采用了按需分页（Demand Paging）策略。只有当 CUDA Kernel 实际访问某块内存时，驱动才会将其搬运到 GPU 显存。
虽然应用 "申请" 了 12GB，但如果没有密集访问所有数据，物理显存占用就会很低。
这也说明当前的负载可能大部分时间在进行数据搬运或 CPU 处理，尚未占满 GPU 显存。” ，2）为啥nvshare-cross-gpu-2完成后，nvshare-cross-gpu-1、nvshare-cross-gpu-3、nvshare-cross-gpu-4没有表现的和 nvshare-cross-gpu-2一样，让他优先得到调度，而不是频繁的切换
```

```
还是有疑问，第一个问题，按你上面分析的“如果时间片只有 60秒，且切换开销占了 10-20秒，那么有效计算时间比例很低，导致整体吞吐量严重下降。”那切换开销也就占比30%不到，性能应该只下降30%左右，为何现在性能从从 1.5s/it 降至 35s/it，下降了95？ 第二个问题:按你分析的，实际活动的显存只有1GB，1GB显存从显存置换到内存，是否需要10-20秒？
```

```
### 故障复盘
1. **触发点**: 当任务 4 正在运行且需要进行上下文切换时，或者刚获得锁开始运行时，由于系统正处于严重的显存抖动（Thrashing）状态，驱动程序需要处理复杂的页表更新和内存搬运。
2. **超时**:某次同步操作受到这些系统开销的干扰，耗时超过了 10 秒（这在已分配超大 Unified Memory 的情况下容易发生）。
3. **降级**: `nvshare` 检测到超时，误判为恶意占用，将 `Pending Kernel Window` 重置为 **1**。
4. **性能崩溃**:
    - 窗口为 1 意味着：Python 发射 1 个 Kernel -> 等待 GPU 执行完 -> 再发射下一个。
    - **流水线彻底断裂**。
    - 此时，原本被掩盖的 CPU-GPU 通信延迟、Python 开销、PCIe 握手延迟全部暴露出来，并且还要叠加 Unified Memory 的页缺失开销。
    - 这就是为什么速度变成了极慢的 35s/it（完全同步执行模式）。
请根据上面的根因分析，给出一个更合理的动态流控机制 (Pending Kernel Window)设计方案，而不是简单的把切换时间调的很长，这会导致客户的体验很差。
方案保存到docs下
```

```
请review docs/gpu_sharing_performance_analysis.md提到的根因以及docs/adaptive_kernel_window_design.md的改进方案，将review的结果保存到docs下的一个新的文件中
```

```
请根据docs/adaptive_kernel_window_design.md的改进方案和/Users/luogangyi/Code/nvshare/docs/adaptive_kernel_window_review.md得review结果，设计具体的实现计划，保存到docs/tasks下，然后执行计划
```