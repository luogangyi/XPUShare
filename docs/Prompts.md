# day 1

由于本身对GPU虚拟化的方式不熟悉，对本项目代码也不了解，所以先不进行开发，而是先让AI对代码进行分析


- 这里是个小技巧，先对代码format一下，后续改动就比较容易对比出来

```
为了后续修改代码的时候，不出现大量因为format问题，导致diff出大量非功能修改，请对所有代码先统一进行一次format
```

- 让AI对代码进行分析、让他完成设计文档


```
你是架构师，需要对libnvshare的架构和实现方案进行详细分析，请分析代码，输出详细的分析问到到docs目录下
```

```
你是架构师，需要对项目中Unified Memory的的架构和实现方案进行详细分析，请分析代码，输出详细的分析问到到docs目录下
```

- 正式干活

```
当前项目仅支持一个gpu，即nvshare currently supports only one GPU per node, as nvshare-scheduler is hardcoded to use the Nvidia GPU with ID 0. 分析项目代码，设计实现支持多GPU方案。注意修改代码的时候，只修改真正改动的行，对没改动的行，不要重新代码或者进行format.
```

- 有了初步版本以后，让AI在对改动的代码进行一些分析，看看有没有问题
```
你是架构师，需要对项目中lib、client、scheduler的部署模式、运行模式进行分析。例如lib是需要在业务使用的GPU容器中preload的吗？还是在Device-plugin中被preload？scheduler和client分别运行在哪？是否是常驻后台的进程？分析结果保存到docs下
```

```
分析在多GPU场景下，DevicePlugin如何调度GPU，例如每个GPU被虚拟化为10个vGPU，节点上有8个GPU，即80个vGPU，那么用户申请的vGPU，是否能优先调度到不同的物理机GPU，如果所有物理机GPU都有任务，是否能按GPU负载进行调度。如果当前代码就可以，请分析实现方案，如果当前代码不可以，请给出设计方案。方案保存到docs下
```

# day 2 原型的测试验证
 

- 不知道该怎么测试验证，那就让AI来分析下怎么测试


```
我的测试环境有2个T4的GPU，每个有16G显存，请结合tests下准备的测试容器，设计一个测试方案，保存到docs下以及对应的测试脚本，放到.tests/scripts下
```

 - 测试效果，第一个版本能跑，但是性能很差，让AI分析原因

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

- 这里我自己根据上面的分析结果，我提出了一个方案，让AI按我的方案改进

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

- 还是不太好，猜测原因，让AI继续修改

```
还有2个疑问：1）nvshare-cross-gpu测试实际调用的是tests/pytorch-add.py，请分析这段代码，是否符合你说的“为什么 nvidia-smi 只显示 1GB 显存？ 驱动采用了按需分页（Demand Paging）策略。只有当 CUDA Kernel 实际访问某块内存时，驱动才会将其搬运到 GPU 显存。
虽然应用 "申请" 了 12GB，但如果没有密集访问所有数据，物理显存占用就会很低。
这也说明当前的负载可能大部分时间在进行数据搬运或 CPU 处理，尚未占满 GPU 显存。” ，2）为啥nvshare-cross-gpu-2完成后，nvshare-cross-gpu-1、nvshare-cross-gpu-3、nvshare-cross-gpu-4没有表现的和 nvshare-cross-gpu-2一样，让他优先得到调度，而不是频繁的切换
```

```
还是有疑问，第一个问题，按你上面分析的“如果时间片只有 60秒，且切换开销占了 10-20秒，那么有效计算时间比例很低，导致整体吞吐量严重下降。”那切换开销也就占比30%不到，性能应该只下降30%左右，为何现在性能从从 1.5s/it 降至 35s/it，下降了95？ 第二个问题:按你分析的，实际活动的显存只有1GB，1GB显存从显存置换到内存，是否需要10-20秒？
```

 - 让AI复盘

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

```
我启动了4个测试容器，分布在2张GPU了，有如下日志，请分析日志，是否符合预期 root@lgy-test-gpu:~# kubectl logs nvshare-cross-gpu-1
[NVSHARE][WARN]: Enabling GPU memory oversubscription for this application
[NVSHARE][DEBUG]: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1: undefined symbol: nvmlDeviceGetHandleByUUID_v2
[NVSHARE][DEBUG]: Could not find NVML
[NVSHARE][DEBUG]: NVSHARE_POD_NAME = nvshare-cross-gpu-1
[NVSHARE][DEBUG]: NVSHARE_POD_NAMESPACE = default
[NVSHARE][DEBUG]: Sent REGISTER
[NVSHARE][DEBUG]: Received SCHED_ON
[NVSHARE][INFO]: Successfully initialized nvshare GPU
[NVSHARE][INFO]: Client ID = 91c417c8e21245df
[NVSHARE][DEBUG]: real_cuMemGetInfo returned free=13904.81 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: nvshare's cuMemGetInfo returning free=13377.69 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fe860000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 2992.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 2992 MB
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fe7a4000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 5984.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 5984 MB
  0%|          | 0/4000 [00:00<?, ?it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fe6e8000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 8976.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 8976 MB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fe62c000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 11968.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 11968 MB
[NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
  1%|          | 32/4000 [00:01<03:54, 16.96it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
  2%|▏         | 96/4000 [00:04<03:09, 20.58it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
  6%|▌         | 224/4000 [00:19<02:40, 23.51it/s][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  6%|▌         | 225/4000 [00:24<09:37,  6.53it/s][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  6%|▌         | 227/4000 [00:26<10:26,  6.02it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
  6%|▌         | 231/4000 [00:26<09:59,  6.29it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
  6%|▌         | 239/4000 [00:26<08:54,  7.03it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
  6%|▋         | 255/4000 [00:27<07:02,  8.87it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
  7%|▋         | 287/4000 [00:28<04:55, 12.58it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
  9%|▉         | 351/4000 [00:30<03:26, 17.68it/s][NVSHARE][DEBUG]: Pending Kernel Window is 512 (warmup=1).
 12%|█▏        | 479/4000 [00:35<02:40, 21.96it/s][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
 18%|█▊        | 735/4000 [00:45<02:14, 24.30it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 18%|█▊        | 738/4000 [00:45<02:14, 24.32it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 19%|█▊        | 742/4000 [00:46<02:13, 24.34it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 19%|█▉        | 750/4000 [00:46<02:13, 24.42it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 19%|█▉        | 766/4000 [00:46<02:11, 24.60it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
 20%|█▉        | 798/4000 [00:48<02:08, 24.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 22%|██▏       | 862/4000 [00:50<02:03, 25.34it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 23%|██▎       | 913/4000 [00:52<02:01, 25.51it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 24%|██▍       | 954/4000 [00:54<01:58, 25.69it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 25%|██▍       | 986/4000 [00:55<01:57, 25.73it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 25%|██▌       | 1011/4000 [00:56<01:56, 25.65it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 27%|██▋       | 1062/4000 [00:58<01:54, 25.73it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 28%|██▊       | 1103/4000 [00:59<01:52, 25.87it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 28%|██▊       | 1135/4000 [01:01<01:50, 25.87it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 29%|██▉       | 1160/4000 [01:02<01:50, 25.75it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 30%|███       | 1211/4000 [01:04<01:48, 25.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 31%|███▏      | 1252/4000 [01:05<01:46, 25.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 32%|███▏      | 1284/4000 [01:06<01:44, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 33%|███▎      | 1309/4000 [01:07<01:44, 25.78it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 34%|███▍      | 1360/4000 [01:09<01:42, 25.81it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 35%|███▌      | 1401/4000 [01:11<01:40, 25.93it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 36%|███▌      | 1433/4000 [01:12<01:39, 25.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 36%|███▋      | 1458/4000 [01:13<01:38, 25.79it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
 38%|███▊      | 1509/4000 [01:30<01:36, 25.82it/s][NVSHARE][DEBUG]: Received LOCK_OK
 38%|███▊      | 1510/4000 [02:11<26:54,  1.54it/s][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 38%|███▊      | 1511/4000 [02:15<28:45,  1.44it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 38%|███▊      | 1515/4000 [02:15<26:31,  1.56it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 38%|███▊      | 1523/4000 [02:15<21:47,  1.89it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 38%|███▊      | 1539/4000 [02:16<14:39,  2.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
 39%|███▉      | 1571/4000 [02:17<08:01,  5.04it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
 41%|████      | 1635/4000 [02:19<04:06,  9.58it/s][NVSHARE][DEBUG]: Pending Kernel Window is 512 (warmup=1).
 44%|████▍     | 1763/4000 [02:24<02:21, 15.82it/s][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
 50%|█████     | 2019/4000 [02:34<01:33, 21.08it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 51%|█████     | 2022/4000 [02:34<01:33, 21.12it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 51%|█████     | 2026/4000 [02:35<01:33, 21.20it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 51%|█████     | 2034/4000 [02:35<01:31, 21.41it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 51%|█████▏    | 2050/4000 [02:35<01:28, 21.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
 52%|█████▏    | 2082/4000 [02:37<01:23, 22.88it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
 54%|█████▎    | 2146/4000 [02:39<01:16, 24.11it/s][NVSHARE][DEBUG]: Pending Kernel Window is 204 (warmup=0).
 57%|█████▋    | 2274/4000 [02:44<01:08, 25.07it/s][NVSHARE][DEBUG]: Pending Kernel Window is 163 (warmup=0).
 59%|█████▉    | 2376/4000 [02:48<01:03, 25.38it/s][NVSHARE][DEBUG]: Pending Kernel Window is 130 (warmup=0).
 61%|██████▏   | 2458/4000 [02:51<01:00, 25.58it/s][NVSHARE][DEBUG]: Pending Kernel Window is 104 (warmup=0).
 63%|██████▎   | 2523/4000 [02:54<00:57, 25.66it/s][NVSHARE][DEBUG]: Pending Kernel Window is 83 (warmup=0).
 64%|██████▍   | 2575/4000 [02:56<00:55, 25.72it/s][NVSHARE][DEBUG]: Pending Kernel Window is 66 (warmup=0).
 65%|██████▌   | 2616/4000 [02:57<00:53, 25.69it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 66%|██████▌   | 2649/4000 [02:59<00:52, 25.73it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 67%|██████▋   | 2675/4000 [03:00<00:51, 25.75it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 67%|██████▋   | 2696/4000 [03:00<00:50, 25.88it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 68%|██████▊   | 2737/4000 [03:02<00:48, 25.88it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 69%|██████▉   | 2769/4000 [03:03<00:47, 25.78it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 70%|██████▉   | 2795/4000 [03:04<00:46, 25.81it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 70%|███████   | 2816/4000 [03:05<00:45, 25.95it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
 70%|███████   | 2816/4000 [03:20<00:45, 25.95it/s][NVSHARE][DEBUG]: Received LOCK_OK
 71%|███████▏  | 2857/4000 [04:02<10:20,  1.84it/s][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 71%|███████▏  | 2859/4000 [04:06<10:55,  1.74it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 72%|███████▏  | 2863/4000 [04:06<10:12,  1.86it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
root@lgy-test-gpu:~#
root@lgy-test-gpu:~#
root@lgy-test-gpu:~#
root@lgy-test-gpu:~#
root@lgy-test-gpu:~# kubectl logs nvshare-cross-gpu-2
[NVSHARE][WARN]: Enabling GPU memory oversubscription for this application
[NVSHARE][DEBUG]: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1: undefined symbol: nvmlDeviceGetHandleByUUID_v2
[NVSHARE][DEBUG]: Could not find NVML
[NVSHARE][DEBUG]: NVSHARE_POD_NAME = nvshare-cross-gpu-2
[NVSHARE][DEBUG]: NVSHARE_POD_NAMESPACE = default
[NVSHARE][DEBUG]: Sent REGISTER
[NVSHARE][DEBUG]: Received SCHED_ON
[NVSHARE][INFO]: Successfully initialized nvshare GPU
[NVSHARE][INFO]: Client ID = edfa74061d6d43aa
[NVSHARE][DEBUG]: real_cuMemGetInfo returned free=13456.81 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: nvshare's cuMemGetInfo returning free=13377.69 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7efc86000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 2992.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 2992 MB
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7efbca000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 5984.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 5984 MB
  0%|          | 0/4000 [00:00<?, ?it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7efb0e000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 8976.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 8976 MB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7efa52000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 11968.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 11968 MB
[NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
  1%|          | 32/4000 [00:01<03:22, 19.60it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
  2%|▏         | 96/4000 [00:04<02:43, 23.89it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
  6%|▌         | 224/4000 [00:09<02:29, 25.20it/s][NVSHARE][DEBUG]: Received LOCK_OK
  6%|▌         | 224/4000 [00:19<02:29, 25.20it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  6%|▌         | 225/4000 [00:23<09:22,  6.71it/s][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  6%|▌         | 227/4000 [00:25<10:10,  6.18it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
  6%|▌         | 231/4000 [00:25<09:43,  6.46it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
  6%|▌         | 239/4000 [00:25<08:41,  7.22it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
  6%|▋         | 255/4000 [00:26<06:52,  9.08it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
  7%|▋         | 287/4000 [00:27<04:49, 12.81it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
  9%|▉         | 351/4000 [00:29<03:24, 17.88it/s][NVSHARE][DEBUG]: Pending Kernel Window is 512 (warmup=1).
 12%|█▏        | 479/4000 [00:34<02:39, 22.08it/s][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
 18%|█▊        | 735/4000 [00:44<02:14, 24.35it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 18%|█▊        | 738/4000 [00:44<02:13, 24.36it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 19%|█▊        | 742/4000 [00:45<02:13, 24.39it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 19%|█▉        | 750/4000 [00:45<02:12, 24.46it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 19%|█▉        | 766/4000 [00:45<02:11, 24.64it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
 20%|█▉        | 798/4000 [00:47<02:08, 24.96it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 22%|██▏       | 862/4000 [00:49<02:03, 25.35it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 23%|██▎       | 913/4000 [00:51<02:00, 25.51it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 24%|██▍       | 954/4000 [00:53<01:58, 25.69it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 25%|██▍       | 986/4000 [00:54<01:57, 25.73it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 25%|██▌       | 1011/4000 [00:55<01:56, 25.66it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 27%|██▋       | 1062/4000 [00:57<01:54, 25.73it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 28%|██▊       | 1103/4000 [00:58<01:51, 25.87it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 28%|██▊       | 1135/4000 [01:00<01:50, 25.86it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 29%|██▉       | 1160/4000 [01:01<01:50, 25.75it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 30%|███       | 1211/4000 [01:03<01:48, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 31%|███▏      | 1252/4000 [01:04<01:46, 25.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 32%|███▏      | 1284/4000 [01:05<01:44, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 33%|███▎      | 1309/4000 [01:06<01:44, 25.78it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 34%|███▍      | 1360/4000 [01:08<01:42, 25.81it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 35%|███▌      | 1401/4000 [01:10<01:40, 25.92it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 36%|███▌      | 1433/4000 [01:11<01:39, 25.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 36%|███▋      | 1458/4000 [01:12<01:38, 25.78it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
 38%|███▊      | 1509/4000 [01:30<01:36, 25.81it/s][NVSHARE][DEBUG]: Received LOCK_OK
 38%|███▊      | 1510/4000 [02:10<26:53,  1.54it/s][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 38%|███▊      | 1511/4000 [02:14<28:44,  1.44it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 38%|███▊      | 1515/4000 [02:14<26:30,  1.56it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 38%|███▊      | 1523/4000 [02:14<21:46,  1.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 38%|███▊      | 1539/4000 [02:15<14:38,  2.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
 39%|███▉      | 1571/4000 [02:16<08:01,  5.05it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
 41%|████      | 1635/4000 [02:18<04:06,  9.58it/s][NVSHARE][DEBUG]: Pending Kernel Window is 512 (warmup=1).
 44%|████▍     | 1763/4000 [02:23<02:21, 15.83it/s][NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
 50%|█████     | 2019/4000 [02:33<01:33, 21.08it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 51%|█████     | 2022/4000 [02:33<01:33, 21.12it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 51%|█████     | 2026/4000 [02:34<01:33, 21.20it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 51%|█████     | 2034/4000 [02:34<01:31, 21.40it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 51%|█████▏    | 2050/4000 [02:34<01:29, 21.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
 52%|█████▏    | 2082/4000 [02:36<01:23, 22.87it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
 54%|█████▎    | 2146/4000 [02:38<01:16, 24.10it/s][NVSHARE][DEBUG]: Pending Kernel Window is 204 (warmup=0).
 57%|█████▋    | 2274/4000 [02:43<01:08, 25.06it/s][NVSHARE][DEBUG]: Pending Kernel Window is 163 (warmup=0).
 59%|█████▉    | 2376/4000 [02:47<01:04, 25.36it/s][NVSHARE][DEBUG]: Pending Kernel Window is 130 (warmup=0).
 61%|██████▏   | 2458/4000 [02:50<01:00, 25.57it/s][NVSHARE][DEBUG]: Pending Kernel Window is 104 (warmup=0).
 63%|██████▎   | 2523/4000 [02:53<00:57, 25.64it/s][NVSHARE][DEBUG]: Pending Kernel Window is 83 (warmup=0).
 64%|██████▍   | 2575/4000 [02:55<00:55, 25.70it/s][NVSHARE][DEBUG]: Pending Kernel Window is 66 (warmup=0).
 65%|██████▌   | 2616/4000 [02:56<00:53, 25.67it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 66%|██████▌   | 2649/4000 [02:58<00:52, 25.71it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 67%|██████▋   | 2675/4000 [02:59<00:51, 25.73it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 67%|██████▋   | 2696/4000 [02:59<00:50, 25.86it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 68%|██████▊   | 2737/4000 [03:01<00:48, 25.86it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 69%|██████▉   | 2769/4000 [03:02<00:47, 25.76it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 70%|██████▉   | 2795/4000 [03:03<00:46, 25.78it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 70%|███████   | 2816/4000 [03:04<00:45, 25.93it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
 70%|███████   | 2816/4000 [03:20<00:45, 25.93it/s][NVSHARE][DEBUG]: Received LOCK_OK
 71%|███████▏  | 2857/4000 [04:01<10:21,  1.84it/s][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 71%|███████▏  | 2859/4000 [04:05<10:56,  1.74it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 72%|███████▏  | 2863/4000 [04:05<10:12,  1.86it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 72%|███████▏  | 2871/4000 [04:05<08:37,  2.18it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 72%|███████▏  | 2887/4000 [04:06<06:02,  3.07it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
 73%|███████▎  | 2919/4000 [04:07<03:24,  5.27it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
root@lgy-test-gpu:~# kubectl logs nvshare-cross-gpu-3
[NVSHARE][WARN]: Enabling GPU memory oversubscription for this application
[NVSHARE][DEBUG]: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1: undefined symbol: nvmlDeviceGetHandleByUUID_v2
[NVSHARE][DEBUG]: Could not find NVML
[NVSHARE][DEBUG]: NVSHARE_POD_NAME = nvshare-cross-gpu-3
[NVSHARE][DEBUG]: NVSHARE_POD_NAMESPACE = default
[NVSHARE][DEBUG]: Sent REGISTER
[NVSHARE][DEBUG]: Received SCHED_ON
[NVSHARE][INFO]: Successfully initialized nvshare GPU
[NVSHARE][INFO]: Client ID = 12dd75dddc98c35e
[NVSHARE][DEBUG]: real_cuMemGetInfo returned free=10466.81 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: nvshare's cuMemGetInfo returning free=13377.69 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f7934000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 2992.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 2992 MB
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f7878000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 5984.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 5984 MB
  0%|          | 0/4000 [00:00<?, ?it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f77bc000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 8976.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 8976 MB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f7700000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 11968.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 11968 MB
[NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
  1%|          | 32/4000 [00:03<07:31,  8.78it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
  2%|▏         | 96/4000 [00:19<03:47, 17.20it/s][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  2%|▏         | 97/4000 [01:04<1:05:08,  1.00s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  2%|▏         | 99/4000 [01:05<1:03:30,  1.02it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
  3%|▎         | 103/4000 [01:05<56:35,  1.15it/s] [NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
  3%|▎         | 111/4000 [01:05<43:20,  1.50it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
  3%|▎         | 127/4000 [01:06<26:28,  2.44it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
  4%|▍         | 159/4000 [01:07<13:25,  4.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
  6%|▌         | 223/4000 [01:09<06:40,  9.44it/s][NVSHARE][DEBUG]: Pending Kernel Window is 512 (warmup=1).
  9%|▉         | 351/4000 [01:14<03:50, 15.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
 15%|█▌        | 607/4000 [01:24<02:40, 21.09it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 15%|█▌        | 610/4000 [01:24<02:40, 21.13it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 15%|█▌        | 614/4000 [01:24<02:39, 21.20it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 16%|█▌        | 622/4000 [01:25<02:37, 21.41it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 16%|█▌        | 638/4000 [01:25<02:33, 21.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
 17%|█▋        | 670/4000 [01:27<02:25, 22.87it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
 18%|█▊        | 734/4000 [01:29<02:15, 24.10it/s][NVSHARE][DEBUG]: Pending Kernel Window is 204 (warmup=0).
 22%|██▏       | 862/4000 [01:34<02:05, 25.05it/s][NVSHARE][DEBUG]: Pending Kernel Window is 163 (warmup=0).
 24%|██▍       | 964/4000 [01:38<01:59, 25.36it/s][NVSHARE][DEBUG]: Pending Kernel Window is 130 (warmup=0).
 26%|██▌       | 1046/4000 [01:41<01:55, 25.56it/s][NVSHARE][DEBUG]: Pending Kernel Window is 104 (warmup=0).
 28%|██▊       | 1111/4000 [01:44<01:52, 25.64it/s][NVSHARE][DEBUG]: Pending Kernel Window is 83 (warmup=0).
 29%|██▉       | 1163/4000 [01:46<01:50, 25.69it/s][NVSHARE][DEBUG]: Pending Kernel Window is 66 (warmup=0).
 30%|███       | 1204/4000 [01:47<01:48, 25.66it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 31%|███       | 1237/4000 [01:49<01:47, 25.70it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 32%|███▏      | 1263/4000 [01:50<01:46, 25.72it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 32%|███▏      | 1284/4000 [01:50<01:45, 25.85it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 33%|███▎      | 1325/4000 [01:52<01:43, 25.85it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 34%|███▍      | 1357/4000 [01:53<01:42, 25.75it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 35%|███▍      | 1383/4000 [01:54<01:41, 25.78it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 35%|███▌      | 1404/4000 [01:55<01:40, 25.92it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
 35%|███▌      | 1404/4000 [02:10<01:40, 25.92it/s][NVSHARE][DEBUG]: Received LOCK_OK
 36%|███▌      | 1445/4000 [02:52<23:07,  1.84it/s][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 36%|███▌      | 1447/4000 [02:56<24:27,  1.74it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 36%|███▋      | 1451/4000 [02:56<22:53,  1.86it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 36%|███▋      | 1459/4000 [02:56<19:23,  2.18it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 37%|███▋      | 1475/4000 [02:57<13:42,  3.07it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
 38%|███▊      | 1507/4000 [02:58<07:52,  5.28it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
 39%|███▉      | 1571/4000 [03:01<04:09,  9.73it/s][NVSHARE][DEBUG]: Pending Kernel Window is 512 (warmup=1).
 42%|████▏     | 1699/4000 [03:05<02:24, 15.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
 49%|████▉     | 1955/4000 [03:15<01:36, 21.10it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 49%|████▉     | 1958/4000 [03:16<01:36, 21.14it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 49%|████▉     | 1962/4000 [03:16<01:36, 21.22it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 49%|████▉     | 1970/4000 [03:16<01:34, 21.43it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 50%|████▉     | 1986/4000 [03:17<01:31, 21.93it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
 50%|█████     | 2018/4000 [03:18<01:26, 22.88it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
 52%|█████▏    | 2082/4000 [03:20<01:19, 24.11it/s][NVSHARE][DEBUG]: Pending Kernel Window is 204 (warmup=0).
 55%|█████▌    | 2210/4000 [03:25<01:11, 25.06it/s][NVSHARE][DEBUG]: Pending Kernel Window is 163 (warmup=0).
 58%|█████▊    | 2312/4000 [03:29<01:06, 25.37it/s][NVSHARE][DEBUG]: Pending Kernel Window is 130 (warmup=0).
 60%|█████▉    | 2393/4000 [03:32<01:03, 25.47it/s][NVSHARE][DEBUG]: Pending Kernel Window is 104 (warmup=0).
 61%|██████▏   | 2458/4000 [03:35<01:00, 25.57it/s][NVSHARE][DEBUG]: Pending Kernel Window is 83 (warmup=0).
 63%|██████▎   | 2510/4000 [03:37<00:58, 25.64it/s][NVSHARE][DEBUG]: Pending Kernel Window is 66 (warmup=0).
 64%|██████▍   | 2552/4000 [03:38<00:56, 25.75it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 65%|██████▍   | 2585/4000 [03:40<00:54, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 65%|██████▌   | 2611/4000 [03:41<00:53, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 66%|██████▌   | 2631/4000 [03:42<00:53, 25.70it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 67%|██████▋   | 2672/4000 [03:43<00:51, 25.75it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 68%|██████▊   | 2705/4000 [03:44<00:50, 25.88it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 68%|██████▊   | 2731/4000 [03:45<00:49, 25.88it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 69%|██████▉   | 2751/4000 [03:46<00:48, 25.75it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
root@lgy-test-gpu:~# kubectl logs nvshare-cross-gpu-4
[NVSHARE][WARN]: Enabling GPU memory oversubscription for this application
[NVSHARE][DEBUG]: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1: undefined symbol: nvmlDeviceGetHandleByUUID_v2
[NVSHARE][DEBUG]: Could not find NVML
[NVSHARE][DEBUG]: NVSHARE_POD_NAME = nvshare-cross-gpu-4
[NVSHARE][DEBUG]: NVSHARE_POD_NAMESPACE = default
[NVSHARE][DEBUG]: Sent REGISTER
[NVSHARE][DEBUG]: Received SCHED_ON
[NVSHARE][INFO]: Successfully initialized nvshare GPU
[NVSHARE][INFO]: Client ID = 42b6b9a4fd08a831
[NVSHARE][DEBUG]: real_cuMemGetInfo returned free=864.81 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: nvshare's cuMemGetInfo returning free=13377.69 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7feb62000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 2992.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 2992 MB
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7feaa6000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 5984.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 5984 MB
  0%|          | 0/4000 [00:00<?, ?it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fe9ea000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 8976.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 8976 MB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fe92e000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 11968.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 11968 MB
[NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
  1%|          | 32/4000 [00:03<07:28,  8.85it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
  2%|▏         | 96/4000 [00:19<03:46, 17.26it/s][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  2%|▏         | 97/4000 [01:04<1:04:59,  1.00it/s][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  2%|▏         | 99/4000 [01:05<1:03:32,  1.02it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
  3%|▎         | 103/4000 [01:05<56:37,  1.15it/s] [NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
  3%|▎         | 111/4000 [01:05<43:21,  1.49it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
  3%|▎         | 127/4000 [01:06<26:29,  2.44it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
  4%|▍         | 159/4000 [01:07<13:26,  4.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
  6%|▌         | 223/4000 [01:09<06:40,  9.43it/s][NVSHARE][DEBUG]: Pending Kernel Window is 512 (warmup=1).
  9%|▉         | 351/4000 [01:14<03:51, 15.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
 15%|█▌        | 607/4000 [01:24<02:40, 21.09it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 15%|█▌        | 610/4000 [01:24<02:40, 21.13it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 15%|█▌        | 614/4000 [01:24<02:39, 21.20it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 16%|█▌        | 622/4000 [01:25<02:37, 21.41it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 16%|█▌        | 638/4000 [01:25<02:33, 21.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
 17%|█▋        | 670/4000 [01:27<02:25, 22.87it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
 18%|█▊        | 734/4000 [01:29<02:15, 24.10it/s][NVSHARE][DEBUG]: Pending Kernel Window is 204 (warmup=0).
 22%|██▏       | 862/4000 [01:34<02:05, 25.05it/s][NVSHARE][DEBUG]: Pending Kernel Window is 163 (warmup=0).
 24%|██▍       | 964/4000 [01:38<01:59, 25.36it/s][NVSHARE][DEBUG]: Pending Kernel Window is 130 (warmup=0).
 26%|██▌       | 1046/4000 [01:41<01:55, 25.56it/s][NVSHARE][DEBUG]: Pending Kernel Window is 104 (warmup=0).
 28%|██▊       | 1111/4000 [01:44<01:52, 25.64it/s][NVSHARE][DEBUG]: Pending Kernel Window is 83 (warmup=0).
 29%|██▉       | 1163/4000 [01:46<01:50, 25.69it/s][NVSHARE][DEBUG]: Pending Kernel Window is 66 (warmup=0).
 30%|███       | 1204/4000 [01:47<01:48, 25.66it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 31%|███       | 1237/4000 [01:49<01:47, 25.70it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 32%|███▏      | 1263/4000 [01:50<01:46, 25.73it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 32%|███▏      | 1284/4000 [01:50<01:45, 25.85it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 33%|███▎      | 1325/4000 [01:52<01:43, 25.86it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 34%|███▍      | 1357/4000 [01:53<01:42, 25.76it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 35%|███▍      | 1383/4000 [01:54<01:41, 25.78it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 35%|███▌      | 1404/4000 [01:55<01:40, 25.93it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
 35%|███▌      | 1404/4000 [02:10<01:40, 25.93it/s][NVSHARE][DEBUG]: Received LOCK_OK
 36%|███▌      | 1445/4000 [02:52<23:07,  1.84it/s][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 36%|███▌      | 1447/4000 [02:56<24:28,  1.74it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 36%|███▋      | 1451/4000 [02:56<22:53,  1.86it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 36%|███▋      | 1459/4000 [02:56<19:24,  2.18it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 37%|███▋      | 1475/4000 [02:57<13:42,  3.07it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
 38%|███▊      | 1507/4000 [02:58<07:52,  5.28it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
 39%|███▉      | 1571/4000 [03:01<04:09,  9.74it/s][NVSHARE][DEBUG]: Pending Kernel Window is 512 (warmup=1).
 42%|████▏     | 1699/4000 [03:05<02:24, 15.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
 49%|████▉     | 1955/4000 [03:15<01:36, 21.12it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 49%|████▉     | 1958/4000 [03:15<01:36, 21.16it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 49%|████▉     | 1962/4000 [03:16<01:35, 21.24it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 49%|████▉     | 1970/4000 [03:16<01:34, 21.45it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 50%|████▉     | 1986/4000 [03:17<01:31, 21.95it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
 50%|█████     | 2018/4000 [03:18<01:26, 22.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
 52%|█████▏    | 2082/4000 [03:20<01:19, 24.14it/s][NVSHARE][DEBUG]: Pending Kernel Window is 204 (warmup=0).
 55%|█████▌    | 2210/4000 [03:25<01:11, 25.09it/s][NVSHARE][DEBUG]: Pending Kernel Window is 163 (warmup=0).
 58%|█████▊    | 2312/4000 [03:29<01:06, 25.40it/s][NVSHARE][DEBUG]: Pending Kernel Window is 130 (warmup=0).
 60%|█████▉    | 2393/4000 [03:32<01:03, 25.50it/s][NVSHARE][DEBUG]: Pending Kernel Window is 104 (warmup=0).
 61%|██████▏   | 2458/4000 [03:35<01:00, 25.61it/s][NVSHARE][DEBUG]: Pending Kernel Window is 83 (warmup=0).
 63%|██████▎   | 2510/4000 [03:37<00:58, 25.67it/s][NVSHARE][DEBUG]: Pending Kernel Window is 66 (warmup=0).
 64%|██████▍   | 2552/4000 [03:38<00:56, 25.78it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 65%|██████▍   | 2585/4000 [03:40<00:54, 25.81it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 65%|██████▌   | 2611/4000 [03:41<00:53, 25.82it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 66%|██████▌   | 2631/4000 [03:41<00:53, 25.73it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 67%|██████▋   | 2672/4000 [03:43<00:51, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 68%|██████▊   | 2705/4000 [03:44<00:49, 25.92it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 68%|██████▊   | 2731/4000 [03:45<00:48, 25.92it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 69%|██████▉   | 2751/4000 [03:46<00:48, 25.79it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
```

- 这一版效果赢好了不少，但是还是有优化空间，让AI继续优化

```
优化.tests/scripts下的测试脚本，1）要对执行完成的结果进行统计分析，包括对完成时间的分析，对日志的分析 ，2）对创建多个pod的，创建的数量要作为参数可以输入
```

```
又做了一轮测试，这次4个pod分布到同一个gpu上，但是这次在第一个pod完成后，其他pod的性能没有提上来，有如下日志，请对日志进行详细分析，梳理原因。
root@lgy-test-gpu:~# kubectl logs nvshare-cross-gpu-1
[NVSHARE][WARN]: Enabling GPU memory oversubscription for this application
[NVSHARE][DEBUG]: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1: undefined symbol: nvmlDeviceGetHandleByUUID_v2
[NVSHARE][DEBUG]: Could not find NVML
[NVSHARE][DEBUG]: NVSHARE_POD_NAME = nvshare-cross-gpu-1
[NVSHARE][DEBUG]: NVSHARE_POD_NAMESPACE = default
[NVSHARE][DEBUG]: Sent REGISTER
[NVSHARE][DEBUG]: Received SCHED_ON
[NVSHARE][INFO]: Successfully initialized nvshare GPU
[NVSHARE][INFO]: Client ID = d1f281249bc9efc1
[NVSHARE][DEBUG]: real_cuMemGetInfo returned free=13234.81 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: nvshare's cuMemGetInfo returning free=13377.69 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fb754000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 2992.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 2992 MB
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fb698000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 5984.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 5984 MB
  0%|          | 0/4000 [00:00<?, ?it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fb5dc000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 8976.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 8976 MB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fb520000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 11968.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 11968 MB
[NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
  1%|          | 32/4000 [00:01<04:01, 16.45it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
  2%|▏         | 96/4000 [00:19<05:23, 12.07it/s][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  2%|▏         | 97/4000 [01:11<1:12:59,  1.12s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  2%|▏         | 99/4000 [01:14<1:13:50,  1.14s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
  3%|▎         | 103/4000 [01:20<1:15:53,  1.17s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  3%|▎         | 104/4000 [01:21<1:14:53,  1.15s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  3%|▎         | 106/4000 [01:23<1:16:35,  1.18s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
  3%|▎         | 110/4000 [01:29<1:19:59,  1.23s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  3%|▎         | 111/4000 [01:31<1:23:56,  1.30s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  3%|▎         | 113/4000 [01:34<1:25:19,  1.32s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
  3%|▎         | 117/4000 [01:40<1:27:32,  1.35s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 119/4000 [01:43<1:28:22,  1.37s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 121/4000 [01:45<1:29:09,  1.38s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 123/4000 [01:48<1:29:43,  1.39s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 125/4000 [01:51<1:30:20,  1.40s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 127/4000 [01:54<1:30:48,  1.41s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 129/4000 [01:57<1:31:04,  1.41s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 131/4000 [02:00<1:31:10,  1.41s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 133/4000 [02:02<1:30:56,  1.41s/it][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
  3%|▎         | 135/4000 [02:05<1:30:58,  1.41s/it][NVSHARE][DEBUG]: Received LOCK_OK
  3%|▎         | 136/4000 [03:57<21:51:46, 20.37s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  3%|▎         | 137/4000 [04:00<18:09:04, 16.92s/it][NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
  4%|▎         | 141/4000 [04:06<9:20:06,  8.71s/it] [NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  4%|▎         | 142/4000 [04:08<8:11:57,  7.65s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  4%|▎         | 144/4000 [04:10<6:06:33,  5.70s/it][NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
  4%|▎         | 148/4000 [04:16<3:56:23,  3.68s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  4%|▎         | 149/4000 [04:17<3:29:29,  3.26s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  4%|▍         | 151/4000 [04:20<2:54:55,  2.73s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
  4%|▍         | 155/4000 [04:25<2:16:37,  2.13s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  4%|▍         | 156/4000 [04:27<2:15:50,  2.12s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  4%|▍         | 158/4000 [04:30<2:02:59,  1.92s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  4%|▍         | 160/4000 [04:33<1:53:37,  1.78s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  4%|▍         | 162/4000 [04:36<1:46:54,  1.67s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  4%|▍         | 164/4000 [04:39<1:42:04,  1.60s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  4%|▍         | 166/4000 [04:42<1:38:42,  1.54s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  4%|▍         | 168/4000 [04:45<1:36:17,  1.51s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  4%|▍         | 170/4000 [04:47<1:34:28,  1.48s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  4%|▍         | 172/4000 [04:50<1:33:12,  1.46s/it][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
  4%|▍         | 174/4000 [04:53<1:32:22,  1.45s/it][NVSHARE][DEBUG]: Received LOCK_OK
  4%|▍         | 175/4000 [06:44<22:00:53, 20.72s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  4%|▍         | 176/4000 [06:47<18:11:00, 17.12s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
  4%|▍         | 180/4000 [06:52<9:15:12,  8.72s/it] [NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  5%|▍         | 181/4000 [06:54<8:07:08,  7.65s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  5%|▍         | 183/4000 [06:57<6:02:14,  5.69s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
  5%|▍         | 187/4000 [07:03<3:53:27,  3.67s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  5%|▍         | 188/4000 [07:04<3:26:50,  3.26s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  5%|▍         | 190/4000 [07:07<2:52:41,  2.72s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
  5%|▍         | 194/4000 [07:12<2:15:00,  2.13s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  5%|▍         | 195/4000 [07:14<2:14:22,  2.12s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  5%|▍         | 197/4000 [07:17<2:01:35,  1.92s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  5%|▍         | 199/4000 [07:20<1:52:21,  1.77s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  5%|▌         | 201/4000 [07:23<1:45:46,  1.67s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
root@lgy-test-gpu:~# kubectl logs nvshare-cross-gpu-2
[NVSHARE][WARN]: Enabling GPU memory oversubscription for this application
[NVSHARE][DEBUG]: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1: undefined symbol: nvmlDeviceGetHandleByUUID_v2
[NVSHARE][DEBUG]: Could not find NVML
[NVSHARE][DEBUG]: NVSHARE_POD_NAME = nvshare-cross-gpu-2
[NVSHARE][DEBUG]: NVSHARE_POD_NAMESPACE = default
[NVSHARE][DEBUG]: Sent REGISTER
[NVSHARE][DEBUG]: Received SCHED_ON
[NVSHARE][INFO]: Successfully initialized nvshare GPU
[NVSHARE][INFO]: Client ID = 3dcc78fc6a704ea9
[NVSHARE][DEBUG]: real_cuMemGetInfo returned free=11234.81 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: nvshare's cuMemGetInfo returning free=13377.69 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fcad0000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 2992.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 2992 MB
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fca14000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 5984.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 5984 MB
  0%|          | 0/4000 [00:00<?, ?it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fc958000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 8976.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 8976 MB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fc89c000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 11968.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 11968 MB
[NVSHARE][WARN]: Critical timeout (26 s). AIMD reduced window to 4
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
  1%|          | 32/4000 [00:26<55:38,  1.19it/s][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
  1%|          | 33/4000 [01:54<5:00:52,  4.55s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  1%|          | 34/4000 [01:55<4:48:51,  4.37s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  1%|          | 36/4000 [01:58<4:21:02,  3.95s/it][NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
  1%|          | 40/4000 [02:04<3:32:26,  3.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  1%|          | 41/4000 [02:05<3:21:15,  3.05s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  1%|          | 43/4000 [02:08<2:58:23,  2.70s/it][NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
  1%|          | 47/4000 [02:14<2:26:03,  2.22s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  1%|          | 48/4000 [02:15<2:19:39,  2.12s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  1%|▏         | 50/4000 [02:18<2:08:04,  1.95s/it][NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  1%|▏         | 54/4000 [02:24<1:53:14,  1.72s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  1%|▏         | 56/4000 [02:26<1:48:33,  1.65s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  1%|▏         | 58/4000 [02:29<1:44:29,  1.59s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 60/4000 [02:32<1:41:15,  1.54s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 62/4000 [02:35<1:38:52,  1.51s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 64/4000 [02:38<1:37:04,  1.48s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 66/4000 [02:41<1:35:41,  1.46s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 68/4000 [02:43<1:34:38,  1.44s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 70/4000 [02:46<1:33:47,  1.43s/it][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
[NVSHARE][DEBUG]: Received LOCK_OK
  2%|▏         | 72/4000 [04:41<19:32:08, 17.90s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  2%|▏         | 74/4000 [04:44<14:11:32, 13.01s/it][NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
  2%|▏         | 78/4000 [04:49<8:22:53,  7.69s/it] [NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  2%|▏         | 79/4000 [04:51<7:30:48,  6.90s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  2%|▏         | 81/4000 [04:54<5:47:54,  5.33s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
  2%|▏         | 85/4000 [05:00<3:52:38,  3.57s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  2%|▏         | 86/4000 [05:01<3:27:20,  3.18s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  2%|▏         | 88/4000 [05:03<2:54:22,  2.67s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
  2%|▏         | 92/4000 [05:09<2:17:25,  2.11s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 93/4000 [05:11<2:16:44,  2.10s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 95/4000 [05:14<2:04:03,  1.91s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 97/4000 [05:17<1:54:37,  1.76s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 99/4000 [05:19<1:48:02,  1.66s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 101/4000 [05:22<1:43:16,  1.59s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 103/4000 [05:25<1:39:48,  1.54s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 105/4000 [05:28<1:37:15,  1.50s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 107/4000 [05:31<1:35:34,  1.47s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 109/4000 [05:34<1:34:24,  1.46s/it][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
root@lgy-test-gpu:~# kubectl logs nvshare-cross-gpu-3
[NVSHARE][WARN]: Enabling GPU memory oversubscription for this application
[NVSHARE][DEBUG]: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1: undefined symbol: nvmlDeviceGetHandleByUUID_v2
[NVSHARE][DEBUG]: Could not find NVML
[NVSHARE][DEBUG]: NVSHARE_POD_NAME = nvshare-cross-gpu-3
[NVSHARE][DEBUG]: NVSHARE_POD_NAMESPACE = default
[NVSHARE][DEBUG]: Sent REGISTER
[NVSHARE][DEBUG]: Received SCHED_ON
[NVSHARE][INFO]: Successfully initialized nvshare GPU
[NVSHARE][INFO]: Client ID = 5c3913a58a7d99bd
[NVSHARE][DEBUG]: real_cuMemGetInfo returned free=13904.81 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: nvshare's cuMemGetInfo returning free=13377.69 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f7a3c000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 2992.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 2992 MB
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f7980000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 5984.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 5984 MB
  0%|          | 0/4000 [00:00<?, ?it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f78c4000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 8976.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 8976 MB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f7808000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 11968.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 11968 MB
[NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
  1%|          | 32/4000 [00:01<03:21, 19.65it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
  2%|▏         | 96/4000 [00:04<02:43, 23.89it/s][NVSHARE][DEBUG]: Pending Kernel Window is 512 (warmup=1).
  6%|▌         | 224/4000 [00:09<02:29, 25.19it/s][NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
 12%|█▏        | 480/4000 [00:18<02:17, 25.62it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 12%|█▏        | 483/4000 [00:19<02:17, 25.62it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 12%|█▏        | 487/4000 [00:19<02:17, 25.63it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 12%|█▏        | 495/4000 [00:19<02:16, 25.64it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 13%|█▎        | 511/4000 [00:20<02:15, 25.66it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
 14%|█▎        | 543/4000 [00:21<02:14, 25.71it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
 15%|█▌        | 607/4000 [00:23<02:11, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 204 (warmup=0).
 18%|█▊        | 735/4000 [00:28<02:06, 25.82it/s][NVSHARE][DEBUG]: Pending Kernel Window is 163 (warmup=0).
 21%|██        | 837/4000 [00:32<02:02, 25.83it/s][NVSHARE][DEBUG]: Pending Kernel Window is 130 (warmup=0).
 23%|██▎       | 919/4000 [00:35<01:59, 25.88it/s][NVSHARE][DEBUG]: Pending Kernel Window is 104 (warmup=0).
 25%|██▍       | 984/4000 [00:38<01:56, 25.88it/s][NVSHARE][DEBUG]: Pending Kernel Window is 83 (warmup=0).
 26%|██▌       | 1036/4000 [00:40<01:54, 25.87it/s][NVSHARE][DEBUG]: Pending Kernel Window is 66 (warmup=0).
 27%|██▋       | 1077/4000 [00:42<01:53, 25.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 28%|██▊       | 1110/4000 [00:43<01:51, 25.81it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 28%|██▊       | 1136/4000 [00:44<01:50, 25.82it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 29%|██▉       | 1157/4000 [00:45<01:49, 25.92it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 30%|██▉       | 1198/4000 [00:46<01:48, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 31%|███       | 1230/4000 [00:47<01:47, 25.78it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 31%|███▏      | 1256/4000 [00:48<01:46, 25.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 32%|███▏      | 1277/4000 [00:49<01:44, 25.93it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 33%|███▎      | 1318/4000 [00:51<01:43, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 34%|███▍      | 1350/4000 [00:52<01:42, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 34%|███▍      | 1376/4000 [00:53<01:41, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 35%|███▍      | 1397/4000 [00:54<01:40, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 36%|███▌      | 1438/4000 [00:56<01:38, 25.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 37%|███▋      | 1470/4000 [00:57<01:38, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 37%|███▋      | 1496/4000 [00:58<01:37, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 38%|███▊      | 1517/4000 [00:59<01:35, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 39%|███▉      | 1558/4000 [01:00<01:34, 25.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 40%|███▉      | 1590/4000 [01:01<01:33, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 40%|████      | 1616/4000 [01:02<01:32, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 41%|████      | 1637/4000 [01:03<01:31, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 42%|████▏     | 1678/4000 [01:05<01:29, 25.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 43%|████▎     | 1710/4000 [01:06<01:28, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 43%|████▎     | 1736/4000 [01:07<01:27, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 44%|████▍     | 1757/4000 [01:08<01:26, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 45%|████▍     | 1798/4000 [01:09<01:24, 25.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 46%|████▌     | 1830/4000 [01:11<01:24, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 46%|████▋     | 1856/4000 [01:12<01:23, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 47%|████▋     | 1877/4000 [01:12<01:21, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 48%|████▊     | 1918/4000 [01:14<01:20, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 49%|████▉     | 1950/4000 [01:15<01:19, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 49%|████▉     | 1976/4000 [01:16<01:18, 25.78it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 50%|████▉     | 1997/4000 [01:17<01:17, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 51%|█████     | 2038/4000 [01:19<01:15, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 52%|█████▏    | 2070/4000 [01:20<01:14, 25.76it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 52%|█████▏    | 2096/4000 [01:21<01:13, 25.78it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 53%|█████▎    | 2117/4000 [01:22<01:12, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 54%|█████▍    | 2158/4000 [01:23<01:11, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 55%|█████▍    | 2190/4000 [01:25<01:10, 25.76it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 55%|█████▌    | 2216/4000 [01:26<01:09, 25.78it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 56%|█████▌    | 2237/4000 [01:26<01:07, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 57%|█████▋    | 2278/4000 [01:28<01:06, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 58%|█████▊    | 2310/4000 [01:29<01:05, 25.76it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 58%|█████▊    | 2336/4000 [01:30<01:04, 25.78it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 59%|█████▉    | 2357/4000 [01:31<01:03, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 60%|█████▉    | 2398/4000 [01:33<01:01, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 61%|██████    | 2430/4000 [01:34<01:00, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 61%|██████▏   | 2456/4000 [01:35<00:59, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 62%|██████▏   | 2477/4000 [01:36<00:58, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 63%|██████▎   | 2518/4000 [01:37<00:57, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 64%|██████▍   | 2550/4000 [01:39<00:56, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 64%|██████▍   | 2576/4000 [01:40<00:55, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 65%|██████▍   | 2597/4000 [01:40<00:54, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 66%|██████▌   | 2638/4000 [01:42<00:52, 25.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 67%|██████▋   | 2670/4000 [01:43<00:51, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 67%|██████▋   | 2696/4000 [01:44<00:50, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 68%|██████▊   | 2717/4000 [01:45<00:49, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 69%|██████▉   | 2758/4000 [01:47<00:47, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 70%|██████▉   | 2790/4000 [01:48<00:46, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 70%|███████   | 2816/4000 [01:49<00:45, 25.78it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 71%|███████   | 2837/4000 [01:50<00:44, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 72%|███████▏  | 2878/4000 [01:51<00:43, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 73%|███████▎  | 2910/4000 [01:52<00:42, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 73%|███████▎  | 2936/4000 [01:53<00:41, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 74%|███████▍  | 2957/4000 [01:54<00:40, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 75%|███████▍  | 2998/4000 [01:56<00:38, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 76%|███████▌  | 3030/4000 [01:57<00:37, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 76%|███████▋  | 3056/4000 [01:58<00:36, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 77%|███████▋  | 3077/4000 [01:59<00:35, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 78%|███████▊  | 3118/4000 [02:01<00:34, 25.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 79%|███████▉  | 3150/4000 [02:02<00:32, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 79%|███████▉  | 3176/4000 [02:03<00:31, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 80%|███████▉  | 3197/4000 [02:04<00:30, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 81%|████████  | 3238/4000 [02:05<00:29, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 82%|████████▏ | 3270/4000 [02:06<00:28, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 82%|████████▏ | 3296/4000 [02:07<00:27, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 83%|████████▎ | 3317/4000 [02:08<00:26, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 84%|████████▍ | 3358/4000 [02:10<00:24, 25.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 85%|████████▍ | 3390/4000 [02:11<00:23, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 85%|████████▌ | 3416/4000 [02:12<00:22, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 86%|████████▌ | 3437/4000 [02:13<00:21, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 87%|████████▋ | 3478/4000 [02:14<00:20, 25.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 88%|████████▊ | 3510/4000 [02:16<00:19, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 88%|████████▊ | 3536/4000 [02:17<00:17, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 89%|████████▉ | 3557/4000 [02:17<00:17, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 90%|████████▉ | 3598/4000 [02:19<00:15, 25.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 91%|█████████ | 3630/4000 [02:20<00:14, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 91%|█████████▏| 3656/4000 [02:21<00:13, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 92%|█████████▏| 3677/4000 [02:22<00:12, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 93%|█████████▎| 3718/4000 [02:24<00:10, 25.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 94%|█████████▍| 3750/4000 [02:25<00:09, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 94%|█████████▍| 3776/4000 [02:26<00:08, 25.78it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 95%|█████████▍| 3797/4000 [02:27<00:07, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 96%|█████████▌| 3838/4000 [02:28<00:06, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
 97%|█████████▋| 3870/4000 [02:30<00:05, 25.77it/s][NVSHARE][DEBUG]: Pending Kernel Window is 41 (warmup=0).
 97%|█████████▋| 3896/4000 [02:31<00:04, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 82 (warmup=0).
 98%|█████████▊| 3917/4000 [02:31<00:03, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 65 (warmup=0).
 99%|█████████▉| 3958/4000 [02:33<00:01, 25.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 52 (warmup=0).
100%|██████████| 4000/4000 [02:34<00:00, 25.85it/s]
PASS
--- 162.33857893943787 seconds ---
root@lgy-test-gpu:~# kubectl logs nvshare-cross-gpu-4
[NVSHARE][WARN]: Enabling GPU memory oversubscription for this application
[NVSHARE][DEBUG]: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1: undefined symbol: nvmlDeviceGetHandleByUUID_v2
[NVSHARE][DEBUG]: Could not find NVML
[NVSHARE][DEBUG]: NVSHARE_POD_NAME = nvshare-cross-gpu-4
[NVSHARE][DEBUG]: NVSHARE_POD_NAMESPACE = default
[NVSHARE][DEBUG]: Sent REGISTER
[NVSHARE][DEBUG]: Received SCHED_ON
[NVSHARE][INFO]: Successfully initialized nvshare GPU
[NVSHARE][INFO]: Client ID = 04fa52a1264de52a
[NVSHARE][DEBUG]: real_cuMemGetInfo returned free=2.81 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: nvshare's cuMemGetInfo returning free=13377.69 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fbf3e000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 2992.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 2992 MB
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fbe82000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 5984.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 5984 MB
  0%|          | 0/4000 [00:00<?, ?it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fbdc6000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 8976.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 8976 MB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fbd0a000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 11968.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 11968 MB
[NVSHARE][WARN]: Critical timeout (26 s). AIMD reduced window to 4
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
  1%|          | 32/4000 [00:26<55:23,  1.19it/s][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
  1%|          | 33/4000 [02:19<6:12:34,  5.64s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  1%|          | 34/4000 [02:21<5:56:22,  5.39s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  1%|          | 36/4000 [02:24<5:19:00,  4.83s/it][NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
  1%|          | 40/4000 [02:29<4:13:32,  3.84s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  1%|          | 41/4000 [02:31<3:58:28,  3.61s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  1%|          | 43/4000 [02:33<3:27:42,  3.15s/it][NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
  1%|          | 47/4000 [02:39<2:44:27,  2.50s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  1%|          | 48/4000 [02:40<2:35:56,  2.37s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  1%|▏         | 50/4000 [02:43<2:19:55,  2.13s/it][NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  1%|▏         | 54/4000 [02:49<2:00:01,  1.83s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  1%|▏         | 56/4000 [02:52<1:53:36,  1.73s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  1%|▏         | 58/4000 [02:55<1:48:20,  1.65s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 60/4000 [02:57<1:44:09,  1.59s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 62/4000 [03:00<1:40:45,  1.54s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 64/4000 [03:03<1:38:11,  1.50s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 66/4000 [03:06<1:36:13,  1.47s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 68/4000 [03:09<1:35:08,  1.45s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 70/4000 [03:11<1:34:16,  1.44s/it][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
[NVSHARE][DEBUG]: Received LOCK_OK
  2%|▏         | 72/4000 [05:06<19:31:19, 17.89s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  2%|▏         | 74/4000 [05:09<14:11:02, 13.01s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
  2%|▏         | 78/4000 [05:14<8:22:14,  7.68s/it] [NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  2%|▏         | 79/4000 [05:16<7:30:06,  6.89s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  2%|▏         | 81/4000 [05:19<5:47:05,  5.31s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
  2%|▏         | 85/4000 [05:25<3:51:47,  3.55s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  2%|▏         | 86/4000 [05:25<3:26:31,  3.17s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  2%|▏         | 88/4000 [05:28<2:53:46,  2.67s/it][NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
  2%|▏         | 92/4000 [05:34<2:16:53,  2.10s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 93/4000 [05:36<2:16:14,  2.09s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 95/4000 [05:39<2:03:28,  1.90s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 97/4000 [05:41<1:54:04,  1.75s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 99/4000 [05:44<1:47:11,  1.65s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 101/4000 [05:47<1:42:19,  1.57s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 103/4000 [05:50<1:38:52,  1.52s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 105/4000 [05:53<1:36:24,  1.49s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 107/4000 [05:55<1:34:37,  1.46s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 109/4000 [05:58<1:33:37,  1.44s/it][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED

```

- 还是有一些问题，继续分析

```
根据上面的日志，分析docs/adaptive_kernel_window_design.md设计的机制是否生效？如果生效，为何还出现大量切换，如果没生效，分析为啥没生效
```

- 测试结果记录，nvshare跑单个任务
```

==========================================================================================
Pod Name                       | Status   | Duration     | Avg Speed    | KernelWin
------------------------------------------------------------------------------------------
nvshare-cross-gpu-1            | PASS     | 02:34        | 25.80 it/s   | 128
==========================================================================================

```

```
这次4个容器，有一个分布在gpu0，另外三个分部到gpu1上，从测试结果看，分布到gpu0上的任务nvshare-cross-gpu-2很快完成了，其他3个都非常慢，请结合日志分析原因。

root@lgy-test-gpu:~# kubectl logs nvshare-cross-gpu-1
[NVSHARE][WARN]: Enabling GPU memory oversubscription for this application
[NVSHARE][DEBUG]: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1: undefined symbol: nvmlDeviceGetHandleByUUID_v2
[NVSHARE][DEBUG]: Could not find NVML
[NVSHARE][DEBUG]: NVSHARE_POD_NAME = nvshare-cross-gpu-1
[NVSHARE][DEBUG]: NVSHARE_POD_NAMESPACE = default
[NVSHARE][DEBUG]: Sent REGISTER
[NVSHARE][DEBUG]: Received SCHED_ON
[NVSHARE][INFO]: Successfully initialized nvshare GPU
[NVSHARE][INFO]: Client ID = 7880c237661942d0
[NVSHARE][DEBUG]: real_cuMemGetInfo returned free=13904.81 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: nvshare's cuMemGetInfo returning free=13377.69 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f3fe4000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 2992.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 2992 MB
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f3f28000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 5984.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 5984 MB
  0%|          | 0/4000 [00:00<?, ?it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f3e6c000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 8976.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 8976 MB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f3db0000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 11968.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 11968 MB
[NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
  1%|          | 32/4000 [00:01<03:54, 16.89it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
  2%|▏         | 96/4000 [00:19<05:14, 12.43it/s][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  2%|▏         | 97/4000 [01:12<1:13:27,  1.13s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  2%|▏         | 99/4000 [01:14<1:14:14,  1.14s/it][NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
  3%|▎         | 103/4000 [01:20<1:16:07,  1.17s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  3%|▎         | 104/4000 [01:21<1:15:06,  1.16s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  3%|▎         | 106/4000 [01:24<1:16:43,  1.18s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
  3%|▎         | 110/4000 [01:29<1:19:55,  1.23s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  3%|▎         | 111/4000 [01:31<1:23:46,  1.29s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  3%|▎         | 113/4000 [01:34<1:25:04,  1.31s/it][NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
  3%|▎         | 117/4000 [01:40<1:27:06,  1.35s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 118/4000 [01:41<1:23:11,  1.29s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 120/4000 [01:43<1:25:02,  1.31s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 122/4000 [01:46<1:26:31,  1.34s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 124/4000 [01:49<1:27:51,  1.36s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 126/4000 [01:52<1:28:53,  1.38s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 128/4000 [01:55<1:29:27,  1.39s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 130/4000 [01:58<1:29:53,  1.39s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 132/4000 [02:00<1:30:06,  1.40s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  3%|▎         | 134/4000 [02:03<1:30:16,  1.40s/it][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
  3%|▎         | 136/4000 [02:06<1:30:25,  1.40s/it][NVSHARE][DEBUG]: Received LOCK_OK
  3%|▎         | 137/4000 [04:01<22:42:09, 21.16s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  3%|▎         | 138/4000 [04:04<18:46:52, 17.51s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
  4%|▎         | 142/4000 [04:09<9:34:55,  8.94s/it] [NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  4%|▎         | 143/4000 [04:11<8:24:00,  7.84s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
root@lgy-test-gpu:~#
root@lgy-test-gpu:~#
root@lgy-test-gpu:~# kubectl logs nvshare-cross-gpu-2
[NVSHARE][WARN]: Enabling GPU memory oversubscription for this application
[NVSHARE][DEBUG]: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1: undefined symbol: nvmlDeviceGetHandleByUUID_v2
[NVSHARE][DEBUG]: Could not find NVML
[NVSHARE][DEBUG]: NVSHARE_POD_NAME = nvshare-cross-gpu-2
[NVSHARE][DEBUG]: NVSHARE_POD_NAMESPACE = default
[NVSHARE][DEBUG]: Sent REGISTER
[NVSHARE][DEBUG]: Received SCHED_ON
[NVSHARE][INFO]: Successfully initialized nvshare GPU
[NVSHARE][INFO]: Client ID = ba2a11e306d2567f
[NVSHARE][DEBUG]: real_cuMemGetInfo returned free=13904.81 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: nvshare's cuMemGetInfo returning free=13377.69 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f50bc000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 2992.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 2992 MB
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f5000000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 5984.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 5984 MB
  0%|          | 0/4000 [00:00<?, ?it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f4f44000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 8976.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 8976 MB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f4e88000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 11968.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 11968 MB
[NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
  1%|          | 32/4000 [00:01<03:18, 19.97it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
  2%|▏         | 96/4000 [00:04<02:42, 24.01it/s][NVSHARE][DEBUG]: Pending Kernel Window is 512 (warmup=1).
  6%|▌         | 224/4000 [00:09<02:29, 25.23it/s][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
 12%|█▏        | 480/4000 [00:18<02:17, 25.64it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 12%|█▏        | 483/4000 [00:19<02:17, 25.64it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 12%|█▏        | 487/4000 [00:19<02:17, 25.64it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 12%|█▏        | 495/4000 [00:19<02:16, 25.65it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 13%|█▎        | 511/4000 [00:20<02:15, 25.67it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
 14%|█▎        | 543/4000 [00:21<02:14, 25.72it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
 15%|█▌        | 607/4000 [00:23<02:11, 25.78it/s][NVSHARE][DEBUG]: Pending Kernel Window is 512 (warmup=1).
 18%|█▊        | 735/4000 [00:28<02:06, 25.82it/s][NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
 25%|██▍       | 991/4000 [00:38<01:56, 25.84it/s][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=0).
[NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=0).
 25%|██▍       | 997/4000 [00:38<01:56, 25.84it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=0).
 25%|██▌       | 1005/4000 [00:39<01:55, 25.84it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 26%|██▌       | 1021/4000 [00:39<01:55, 25.84it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 26%|██▋       | 1053/4000 [00:41<01:54, 25.84it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 27%|██▋       | 1079/4000 [00:42<01:52, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 28%|██▊       | 1130/4000 [00:44<01:50, 25.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 29%|██▉       | 1170/4000 [00:45<01:49, 25.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 30%|███       | 1202/4000 [00:46<01:48, 25.81it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 31%|███       | 1228/4000 [00:47<01:46, 25.93it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 32%|███▏      | 1279/4000 [00:49<01:45, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 33%|███▎      | 1319/4000 [00:51<01:43, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 34%|███▍      | 1351/4000 [00:52<01:42, 25.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 34%|███▍      | 1377/4000 [00:53<01:41, 25.93it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 36%|███▌      | 1428/4000 [00:55<01:39, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 37%|███▋      | 1468/4000 [00:57<01:38, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 38%|███▊      | 1500/4000 [00:58<01:36, 25.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 38%|███▊      | 1526/4000 [00:59<01:35, 25.92it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 39%|███▉      | 1577/4000 [01:01<01:33, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 40%|████      | 1617/4000 [01:02<01:32, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 41%|████      | 1649/4000 [01:04<01:31, 25.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 42%|████▏     | 1675/4000 [01:05<01:29, 25.92it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 43%|████▎     | 1726/4000 [01:07<01:27, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 44%|████▍     | 1766/4000 [01:08<01:26, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 45%|████▍     | 1798/4000 [01:09<01:25, 25.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 46%|████▌     | 1824/4000 [01:10<01:23, 25.92it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 47%|████▋     | 1875/4000 [01:12<01:22, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 48%|████▊     | 1915/4000 [01:14<01:20, 25.78it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 49%|████▊     | 1947/4000 [01:15<01:19, 25.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 49%|████▉     | 1973/4000 [01:16<01:18, 25.93it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 51%|█████     | 2024/4000 [01:18<01:16, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 52%|█████▏    | 2064/4000 [01:20<01:15, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 52%|█████▏    | 2096/4000 [01:21<01:13, 25.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 53%|█████▎    | 2122/4000 [01:22<01:12, 25.93it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 54%|█████▍    | 2173/4000 [01:24<01:10, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 55%|█████▌    | 2213/4000 [01:25<01:09, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 56%|█████▌    | 2245/4000 [01:27<01:08, 25.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 57%|█████▋    | 2271/4000 [01:28<01:06, 25.93it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 58%|█████▊    | 2322/4000 [01:30<01:04, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 59%|█████▉    | 2362/4000 [01:31<01:03, 25.78it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 60%|█████▉    | 2394/4000 [01:32<01:02, 25.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 60%|██████    | 2420/4000 [01:33<01:00, 25.92it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 62%|██████▏   | 2471/4000 [01:35<00:59, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 63%|██████▎   | 2511/4000 [01:37<00:57, 25.78it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 64%|██████▎   | 2543/4000 [01:38<00:56, 25.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 64%|██████▍   | 2569/4000 [01:39<00:55, 25.92it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 66%|██████▌   | 2620/4000 [01:41<00:53, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 66%|██████▋   | 2660/4000 [01:43<00:51, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 67%|██████▋   | 2692/4000 [01:44<00:50, 25.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 68%|██████▊   | 2718/4000 [01:45<00:49, 25.93it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 69%|██████▉   | 2769/4000 [01:47<00:47, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 70%|███████   | 2809/4000 [01:49<00:46, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 71%|███████   | 2841/4000 [01:50<00:44, 25.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 72%|███████▏  | 2867/4000 [01:51<00:43, 25.93it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 73%|███████▎  | 2918/4000 [01:53<00:41, 25.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 74%|███████▍  | 2958/4000 [01:54<00:40, 25.79it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 75%|███████▍  | 2990/4000 [01:56<00:39, 25.81it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 75%|███████▌  | 3016/4000 [01:57<00:37, 25.93it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 77%|███████▋  | 3067/4000 [01:58<00:36, 25.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 78%|███████▊  | 3107/4000 [02:00<00:34, 25.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 78%|███████▊  | 3139/4000 [02:01<00:33, 25.81it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 79%|███████▉  | 3165/4000 [02:02<00:32, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 80%|████████  | 3216/4000 [02:04<00:30, 25.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 81%|████████▏ | 3256/4000 [02:06<00:28, 25.80it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 82%|████████▏ | 3288/4000 [02:07<00:27, 25.82it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 83%|████████▎ | 3314/4000 [02:08<00:26, 25.95it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 84%|████████▍ | 3365/4000 [02:10<00:24, 25.92it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 85%|████████▌ | 3405/4000 [02:12<00:23, 25.81it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 86%|████████▌ | 3437/4000 [02:13<00:21, 25.82it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 87%|████████▋ | 3463/4000 [02:14<00:20, 25.95it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 88%|████████▊ | 3514/4000 [02:16<00:18, 25.92it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 89%|████████▉ | 3554/4000 [02:17<00:17, 25.81it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 90%|████████▉ | 3586/4000 [02:19<00:16, 25.82it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 90%|█████████ | 3612/4000 [02:20<00:14, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 92%|█████████▏| 3663/4000 [02:22<00:13, 25.92it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 93%|█████████▎| 3703/4000 [02:23<00:11, 25.81it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 93%|█████████▎| 3735/4000 [02:24<00:10, 25.82it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 94%|█████████▍| 3761/4000 [02:25<00:09, 25.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
 95%|█████████▌| 3812/4000 [02:27<00:07, 25.92it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=0).
 96%|█████████▋| 3852/4000 [02:29<00:05, 25.81it/s][NVSHARE][DEBUG]: Pending Kernel Window is 51 (warmup=0).
 97%|█████████▋| 3884/4000 [02:30<00:04, 25.82it/s][NVSHARE][DEBUG]: Pending Kernel Window is 102 (warmup=0).
 98%|█████████▊| 3910/4000 [02:31<00:03, 25.95it/s][NVSHARE][DEBUG]: Pending Kernel Window is 81 (warmup=0).
100%|██████████| 4000/4000 [02:33<00:00, 26.05it/s]
PASS
--- 162.78320217132568 seconds ---
root@lgy-test-gpu:~# kubectl logs nvshare-cross-gpu-3
[NVSHARE][WARN]: Enabling GPU memory oversubscription for this application
[NVSHARE][DEBUG]: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1: undefined symbol: nvmlDeviceGetHandleByUUID_v2
[NVSHARE][DEBUG]: Could not find NVML
[NVSHARE][DEBUG]: NVSHARE_POD_NAME = nvshare-cross-gpu-3
[NVSHARE][DEBUG]: NVSHARE_POD_NAMESPACE = default
[NVSHARE][DEBUG]: Sent REGISTER
[NVSHARE][DEBUG]: Received SCHED_ON
[NVSHARE][INFO]: Successfully initialized nvshare GPU
[NVSHARE][INFO]: Client ID = d5dbba5b01e0425d
[NVSHARE][DEBUG]: real_cuMemGetInfo returned free=1736.81 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: nvshare's cuMemGetInfo returning free=13377.69 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fe838000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 2992.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 2992 MB
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fe77c000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 5984.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 5984 MB
  0%|          | 0/4000 [00:00<?, ?it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fe6c0000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 8976.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 8976 MB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fe604000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 11968.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 11968 MB
[NVSHARE][INFO]: Warmup: Ignored critical timeout (27 s), growing window to 2
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
  1%|          | 32/4000 [00:27<55:57,  1.18it/s][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
  1%|          | 33/4000 [01:55<5:04:06,  4.60s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  1%|          | 34/4000 [01:57<4:51:53,  4.42s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  1%|          | 36/4000 [01:59<4:23:41,  3.99s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
  1%|          | 40/4000 [02:05<3:34:33,  3.25s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  1%|          | 41/4000 [02:07<3:23:12,  3.08s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  1%|          | 43/4000 [02:09<2:59:55,  2.73s/it][NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
  1%|          | 47/4000 [02:15<2:27:13,  2.23s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  1%|          | 48/4000 [02:16<2:20:43,  2.14s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  1%|▏         | 50/4000 [02:19<2:08:32,  1.95s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
  1%|▏         | 54/4000 [02:25<1:53:29,  1.73s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  1%|▏         | 55/4000 [02:26<1:50:43,  1.68s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  1%|▏         | 57/4000 [02:29<1:45:42,  1.61s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  1%|▏         | 59/4000 [02:32<1:41:55,  1.55s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 61/4000 [02:35<1:39:18,  1.51s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 63/4000 [02:38<1:37:16,  1.48s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 65/4000 [02:40<1:35:42,  1.46s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 67/4000 [02:43<1:34:34,  1.44s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 69/4000 [02:46<1:33:51,  1.43s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 71/4000 [02:49<1:33:14,  1.42s/it][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
root@lgy-test-gpu:~# kubectl logs nvshare-cross-gpu-4
[NVSHARE][WARN]: Enabling GPU memory oversubscription for this application
[NVSHARE][DEBUG]: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1: undefined symbol: nvmlDeviceGetHandleByUUID_v2
[NVSHARE][DEBUG]: Could not find NVML
[NVSHARE][DEBUG]: NVSHARE_POD_NAME = nvshare-cross-gpu-4
[NVSHARE][DEBUG]: NVSHARE_POD_NAMESPACE = default
[NVSHARE][DEBUG]: Sent REGISTER
[NVSHARE][DEBUG]: Received SCHED_ON
[NVSHARE][INFO]: Successfully initialized nvshare GPU
[NVSHARE][INFO]: Client ID = 48fd7674779b1c5e
[NVSHARE][DEBUG]: real_cuMemGetInfo returned free=2.81 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: nvshare's cuMemGetInfo returning free=13377.69 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fca10000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 2992.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 2992 MB
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fc954000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 5984.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 5984 MB
  0%|          | 0/4000 [00:00<?, ?it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fc898000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 8976.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 8976 MB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7fc7dc000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 11968.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 11968 MB
[NVSHARE][INFO]: Warmup: Ignored critical timeout (27 s), growing window to 2
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
  1%|          | 32/4000 [00:27<55:56,  1.18it/s][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
  1%|          | 33/4000 [02:21<6:18:06,  5.72s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  1%|          | 34/4000 [02:23<6:01:38,  5.47s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  1%|          | 36/4000 [02:26<5:23:35,  4.90s/it][NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
  1%|          | 40/4000 [02:31<4:17:12,  3.90s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  1%|          | 41/4000 [02:33<4:01:55,  3.67s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  1%|          | 43/4000 [02:36<3:30:39,  3.19s/it][NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
  1%|          | 47/4000 [02:41<2:46:36,  2.53s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  1%|          | 48/4000 [02:43<2:37:49,  2.40s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  1%|▏         | 50/4000 [02:46<2:21:28,  2.15s/it][NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
  1%|▏         | 54/4000 [02:51<2:01:04,  1.84s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  1%|▏         | 55/4000 [02:53<1:57:24,  1.79s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  1%|▏         | 57/4000 [02:55<1:50:46,  1.69s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  1%|▏         | 59/4000 [02:58<1:45:39,  1.61s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 61/4000 [03:01<1:41:52,  1.55s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 63/4000 [03:04<1:39:06,  1.51s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 65/4000 [03:07<1:37:06,  1.48s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 67/4000 [03:10<1:35:35,  1.46s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 69/4000 [03:12<1:34:33,  1.44s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
  2%|▏         | 71/4000 [03:15<1:33:50,  1.43s/it][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
```

- 始终有问题，进一步让AI按我要求改

```
这个分析还是有问题，即便调度不合理，但是算上额外切换开销，理论上跑一个任务1分钟完成，跑3个任务，最多也就4-5分钟也应该完成了，不而不是超分3倍以后，60分钟都完不成。说明切换策略还是有问题的，请仔细分析这个现象，从代码层面给出优化，比如检查到频繁切换时，自动增加时间片等。
```

```
我检查过测试的代码版本是正确的 root@lgy-test-gpu:~# kubectl -n nvshare-system get po -oyaml |grep image
      image: registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:libnvshare-130b28b7
      imagePullPolicy: IfNotPresent
      image: registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:nvshare-device-plugin-130b28b7
      imagePullPolicy: IfNotPresent
      image: registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:nvshare-device-plugin-130b28b7
      imageID: registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare@sha256:f1ac9cce0b20a99bcd371055a8d19024e3d2b15f7fd39f3ae0f7e45e9d3ffb1d
      image: registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:libnvshare-130b28b7
      imageID: registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare@sha256:74685e8e89137bacfe7fcf7e47d9b79f9d720cff9edf82c0a79e3cbd41080c8f
    - image: registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:nvshare-scheduler-130b28b7
      imagePullPolicy: IfNotPresent
      image: registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:nvshare-scheduler-130b28b7
```

- 为了提升效率，我让AI编写了一个测试流程自动化的脚本，便于测试

```
编写一个测试脚本，放到.tests/remote-test.sh，同时加到.gitignore中。
测试节点包括：
gpu所在节点：lgy-test-gpu， 可以通过ssh root@139.196.28.96 -p 32027免密登录
K8s脚本执行： 可以通过export KUBECONFIG=~/Code/configs/kubeconfig-fuyao-gpu 
编译环境：iZuf68ydlezz24cxe8gp80Z,可以通过ssh root@139.196.28.96 免密登录 ，在 /root/code/nvshare目录下，可以make all

测试步骤：
1.由于无法直接连接github，所以我只能先本地执行commit，然后把代码复制到编译环境执行，如scp -r nvshare/ root@139.196.28.96:/root/code/ ，然后到/root/code/nvshare目录下，可以make all
make之后，镜像会push到我自己的镜像仓库。
2.然后我会在本地执行nvshare/.tests/update-manifests.sh 更新镜像，然后先删除之前的负载（kubectl delete pod -l app=nvshare-cross-gpu --ignore-not-found=true --wait=false 2>/dev/null || true
sleep 3），然后删除之前的scheduler和device-plugin（
 kubectl -n nvshare-system delete ds nvshare-device-plugin nvshare-scheduler）
 确认pod删除成功、ds删除成功后，创建新的ds，（kubectl create -f ../manifests/scheduler.yaml  -f ../manifests/device-plugin.yaml）

 3.确认新的ds启动成功后，执行/Users/luogangyi/Code/nvshare/.tests/scripts/test-cross-gpu.sh进行测试。
```


# day 3，解决性能瓶颈

- 反复修改了好几次，还是性能很差，和ai深入讨论一下，让他一步一步分析

```
不认可这个结论，虽然是超分300#，但是实际只有一个任务在gpu上，并且这个任务的显存需求并没有超过GPU的物理显存大小，请进一步深入的，一步一步的分析原因，分析报告保存到docs下，先不要修改代码
```

```
+-----------------------------------------------------------------------------------------+
| Processes:                                                                              |
|  GPU   GI   CI              PID   Type   Process name                        GPU Memory |
|        ID   ID                                                               Usage      |
|=========================================================================================|
|    0   N/A  N/A         2512451      C   python                                 1006MiB |
|    0   N/A  N/A         2512460      C   python                                 1006MiB |
|    0   N/A  N/A         2512462      C   python                                 1006MiB |
|    0   N/A  N/A         2512491      C   python                                 1006MiB |
+-----------------------------------------------------------------------------------------实际还有大量显存剩余，请分析是否能做一个简单的预取，例如判断显存还有多少余量，然后一次性通过批量io方式把这些内存页都加载到显存里，而不是靠每次缺页中断来加载。将分析报告补充到docs/deep_analysis_performance_bottleneck.md，整个报告中中文重写。
```

- 经过讨论，AI认为我的方案可行，给了一个新方案，见[deep_analysis_performance_bottleneck。md](./deep_analysis_performance_bottleneck.md)


```
UVM是否可以优先分配GPU的显存，而非优先分配内存？
```

```
deivice-plugin调度正常，可以实现将任务平均分配到多个GPU上。
任务执行速度有一定提升，但是也发现了一些问题，例如我测试的时候，任务1和任务3被调度到GPU0上，任务2被调度到GPU1上。任务2由于是独享的，所以很快就完成，任务3虽然是共享的，然后完成时间也符合预期，而任务1就表现不正常，虽然和他共享的任务3已经完成，但是任务1的速度一直很慢，见下面的日志，请分析原因
root@lgy-test-gpu:~# kubectl logs -f nvshare-cross-gpu-1 --timestamps
2026-01-30T18:24:12.153162551+08:00 [NVSHARE][WARN]: Enabling GPU memory oversubscription for this application
2026-01-30T18:24:12.153382832+08:00 [NVSHARE][DEBUG]: Failed to find nvmlDeviceGetHandleByUUID_v2, falling back to nvmlDeviceGetHandleByUUID
2026-01-30T18:24:12.153398962+08:00 [NVSHARE][DEBUG]: Found NVML
2026-01-30T18:24:12.262882436+08:00 [NVSHARE][DEBUG]: NVSHARE_POD_NAME = nvshare-cross-gpu-1
2026-01-30T18:24:12.262891615+08:00 [NVSHARE][DEBUG]: NVSHARE_POD_NAMESPACE = default
2026-01-30T18:24:12.262894282+08:00 [NVSHARE][DEBUG]: Sent REGISTER
2026-01-30T18:24:12.263122768+08:00 [NVSHARE][DEBUG]: Received SCHED_ON
2026-01-30T18:24:12.263136723+08:00 [NVSHARE][INFO]: Successfully initialized nvshare GPU
2026-01-30T18:24:12.263140815+08:00 [NVSHARE][INFO]: Client ID = bbea6d01100bcaaa
2026-01-30T18:24:15.858633608+08:00 [NVSHARE][DEBUG]: real_cuMemGetInfo returned free=13904.81 MiB, total=14913.69 MiB
2026-01-30T18:24:15.858648749+08:00 [NVSHARE][DEBUG]: nvshare's cuMemGetInfo returning free=13377.69 MiB, total=14913.69 MiB
2026-01-30T18:24:15.858653108+08:00 [NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
2026-01-30T18:24:15.858902369+08:00 [NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f9b00000000
2026-01-30T18:24:15.858912478+08:00 [NVSHARE][DEBUG]: Total allocated memory on GPU is 2992.00 MiB
2026-01-30T18:24:15.858918411+08:00 [NVSHARE][DEBUG]: Reported memory usage: 2992 MB
2026-01-30T18:24:15.859286858+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
2026-01-30T18:24:18.923412920+08:00 [NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
2026-01-30T18:24:18.923465201+08:00 [NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f9a44000000
2026-01-30T18:24:18.923483807+08:00 [NVSHARE][DEBUG]: Total allocated memory on GPU is 5984.00 MiB
2026-01-30T18:24:18.923488485+08:00 [NVSHARE][DEBUG]: Reported memory usage: 5984 MB
  0%|          | 0/4000 [00:00<?, ?it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
2026-01-30T18:24:19.678896266+08:00 [NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f9988000000
2026-01-30T18:24:19.678905261+08:00 [NVSHARE][DEBUG]: Total allocated memory on GPU is 8976.00 MiB
2026-01-30T18:24:19.678909594+08:00 [NVSHARE][DEBUG]: Reported memory usage: 8976 MB
2026-01-30T18:24:19.679254104+08:00 [NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
2026-01-30T18:24:19.679293838+08:00 [NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f98cc000000
2026-01-30T18:24:19.679298410+08:00 [NVSHARE][DEBUG]: Total allocated memory on GPU is 11968.00 MiB
2026-01-30T18:24:19.679304411+08:00 [NVSHARE][DEBUG]: Reported memory usage: 11968 MB
2026-01-30T18:24:21.595196784+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
  1%|          | 32/4000 [00:01<03:57, 16.69it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
  2%|▏         | 96/4000 [00:04<02:53, 22.54it/s][NVSHARE][DEBUG]: Received PREPARE_SWAP_OUT
2026-01-30T18:24:25.859554773+08:00 [NVSHARE][INFO]: Hinting driver to evict memory to Host (preparing for swap-out)
2026-01-30T18:24:25.859582823+08:00 [NVSHARE][DEBUG]: cuMemAdvise failed for allocation at 0x7f9b00000000 (size 3137339392)
2026-01-30T18:24:25.859593510+08:00 [NVSHARE][DEBUG]: cuMemAdvise failed for allocation at 0x7f9a44000000 (size 3137339392)
2026-01-30T18:24:25.859597247+08:00 [NVSHARE][DEBUG]: cuMemAdvise failed for allocation at 0x7f9988000000 (size 3137339392)
2026-01-30T18:24:25.859600007+08:00 [NVSHARE][DEBUG]: cuMemAdvise failed for allocation at 0x7f98cc000000 (size 3137339392)
2026-01-30T18:24:25.859602970+08:00 [NVSHARE][DEBUG]: Received DROP_LOCK
2026-01-30T18:24:29.039574883+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
2026-01-30T18:24:29.039590496+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
  6%|▌         | 224/4000 [00:09<02:32, 24.68it/s][NVSHARE][DEBUG]: Received LOCK_OK
  6%|▌         | 224/4000 [00:19<02:32, 24.68it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  6%|▌         | 225/4000 [00:23<09:13,  6.82it/s][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  6%|▌         | 227/4000 [00:24<09:57,  6.32it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
  6%|▌         | 231/4000 [00:25<09:30,  6.60it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
  6%|▌         | 239/4000 [00:25<08:30,  7.37it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
  6%|▋         | 255/4000 [00:25<06:44,  9.25it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
  7%|▋         | 287/4000 [00:27<04:45, 13.00it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
  9%|▉         | 351/4000 [00:29<03:22, 18.04it/s][NVSHARE][DEBUG]: Pending Kernel Window is 512 (warmup=1).
 12%|█▏        | 479/4000 [00:34<02:38, 22.17it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:24:59.335527595+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:25:04.220417185+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 1024 (warmup=1).
 18%|█▊        | 735/4000 [00:44<02:13, 24.40it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:25:09.242863248+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:25:14.245453894+08:00 [NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:25:14.245506102+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:25:19.248030427+08:00 [NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:25:19.248051643+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
 18%|█▊        | 735/4000 [00:59<02:13, 24.40it/s][NVSHARE][WARN]: Critical timeout (19 s). AIMD reduced window to 512
2026-01-30T18:25:24.012207899+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 512 (warmup=0).
 31%|███       | 1247/4000 [01:04<01:48, 25.33it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:25:29.020858376+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:25:33.908476524+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 409 (warmup=0).
 38%|███▊      | 1503/4000 [01:14<01:37, 25.50it/s][NVSHARE][DEBUG]: Received PREPARE_SWAP_OUT
2026-01-30T18:25:34.561820463+08:00 [NVSHARE][INFO]: Hinting driver to evict memory to Host (preparing for swap-out)
2026-01-30T18:25:41.813786218+08:00 [NVSHARE][INFO]: Swap-out hints sent for 4 allocations (11968.00 MB total)
2026-01-30T18:25:41.813806990+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 327 (warmup=0).
2026-01-30T18:25:41.814616784+08:00 [NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:25:41.814622058+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:25:41.814629551+08:00 [NVSHARE][DEBUG]: Received DROP_LOCK
2026-01-30T18:25:41.814657321+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
 38%|███▊      | 1503/4000 [01:30<01:37, 25.50it/s][NVSHARE][DEBUG]: Received LOCK_OK
2026-01-30T18:26:42.366427382+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
 43%|████▎     | 1708/4000 [02:22<04:29,  8.52it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
 43%|████▎     | 1709/4000 [02:23<04:30,  8.46it/s][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 43%|████▎     | 1711/4000 [02:24<04:35,  8.31it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 43%|████▎     | 1715/4000 [02:26<04:47,  7.93it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 43%|████▎     | 1723/4000 [02:30<05:22,  7.07it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:26:55.086796149+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:26:58.205999371+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 43%|████▎     | 1739/4000 [02:38<06:46,  5.57it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:27:03.230418199+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:27:08.253774561+08:00 [NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:27:08.253799621+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:27:13.276926792+08:00 [NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:27:13.276961639+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:27:14.458828437+08:00 [NVSHARE][WARN]: Critical timeout (16 s). AIMD reduced window to 32
2026-01-30T18:27:14.458847035+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=0).
 44%|████▍     | 1771/4000 [02:54<09:27,  3.93it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:27:19.483243479+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:27:22.586570330+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 25 (warmup=0).
 45%|████▍     | 1787/4000 [03:02<10:42,  3.45it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:27:27.627904445+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:27:28.936443002+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 20 (warmup=0).
 45%|████▌     | 1800/4000 [03:09<11:39,  3.15it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:27:33.960145377+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:27:34.015488856+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=0).
 45%|████▌     | 1810/4000 [03:14<12:31,  2.91it/s][NVSHARE][DEBUG]: Received PREPARE_SWAP_OUT
2026-01-30T18:27:37.085028525+08:00 [NVSHARE][INFO]: Hinting driver to evict memory to Host (preparing for swap-out)
2026-01-30T18:27:38.078769689+08:00 [NVSHARE][INFO]: Swap-out hints sent for 4 allocations (11968.00 MB total)
2026-01-30T18:27:38.078803747+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 12 (warmup=0).
2026-01-30T18:27:38.078808749+08:00 [NVSHARE][DEBUG]: Received DROP_LOCK
2026-01-30T18:27:38.078812297+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-01-30T18:28:35.446789813+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
2026-01-30T18:28:35.700456155+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
 45%|████▌     | 1818/4000 [04:16<47:55,  1.32s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
 45%|████▌     | 1819/4000 [04:16<47:13,  1.30s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 46%|████▌     | 1821/4000 [04:17<45:24,  1.25s/it][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 46%|████▌     | 1825/4000 [04:19<41:16,  1.14s/it][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 46%|████▌     | 1833/4000 [04:23<34:17,  1.05it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:28:48.345302170+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:28:51.448286730+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 46%|████▌     | 1849/4000 [04:31<26:43,  1.34it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:28:56.472823875+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:29:01.496150557+08:00 [NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:29:01.496171968+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:29:06.519235802+08:00 [NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:29:06.519269100+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:29:07.702975768+08:00 [NVSHARE][WARN]: Critical timeout (16 s). AIMD reduced window to 32
2026-01-30T18:29:07.702997608+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=0).
 47%|████▋     | 1881/4000 [04:48<21:33,  1.64it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:29:12.726911883+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:29:15.829582696+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 25 (warmup=0).
 47%|████▋     | 1897/4000 [04:56<20:21,  1.72it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:29:20.853711498+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:29:22.178427028+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 20 (warmup=0).
 48%|████▊     | 1910/4000 [05:02<19:25,  1.79it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:29:27.202771637+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:29:27.257123849+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=0).
 48%|████▊     | 1920/4000 [05:07<18:57,  1.83it/s][NVSHARE][DEBUG]: Received PREPARE_SWAP_OUT
2026-01-30T18:29:30.446940719+08:00 [NVSHARE][INFO]: Hinting driver to evict memory to Host (preparing for swap-out)
2026-01-30T18:29:31.320830545+08:00 [NVSHARE][INFO]: Swap-out hints sent for 4 allocations (11968.00 MB total)
2026-01-30T18:29:31.320852502+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 12 (warmup=0).
2026-01-30T18:29:31.320856918+08:00 [NVSHARE][DEBUG]: Received DROP_LOCK
2026-01-30T18:29:31.320860259+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-01-30T18:30:07.742815354+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
2026-01-30T18:30:07.997125228+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
 48%|████▊     | 1928/4000 [05:48<49:59,  1.45s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
 48%|████▊     | 1929/4000 [05:48<48:51,  1.42s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 48%|████▊     | 1931/4000 [05:49<46:02,  1.33s/it][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 48%|████▊     | 1935/4000 [05:51<40:10,  1.17s/it][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 49%|████▊     | 1943/4000 [05:55<31:44,  1.08it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:30:20.642415466+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:30:23.755496580+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 49%|████▉     | 1959/4000 [06:04<24:13,  1.40it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:30:28.779456038+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:30:33.802335145+08:00 [NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:30:33.802359013+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:30:38.825324942+08:00 [NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:30:38.825349964+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:30:40.009596259+08:00 [NVSHARE][WARN]: Critical timeout (16 s). AIMD reduced window to 32
2026-01-30T18:30:40.009618822+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=0).
 50%|████▉     | 1991/4000 [06:20<19:47,  1.69it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:30:45.033555500+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:30:48.136443965+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 25 (warmup=0).
 50%|█████     | 2007/4000 [06:28<18:48,  1.77it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:30:53.160018188+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:30:54.485628422+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 20 (warmup=0).
 50%|█████     | 2020/4000 [06:34<18:01,  1.83it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T18:30:59.509280720+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T18:30:59.565051191+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=0).
 51%|█████     | 2030/4000 [06:39<17:39,  1.86it/s][NVSHARE][DEBUG]: Pending Kernel Window is 12 (warmup=0).
 51%|█████     | 2038/4000 [06:43<17:23,  1.88it/s][NVSHARE][DEBUG]: Pending Kernel Window is 9 (warmup=0).
 51%|█████     | 2044/4000 [06:46<17:11,  1.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 7 (warmup=0).
 51%|█████     | 2048/4000 [06:49<17:22,  1.87it/s][NVSHARE][DEBUG]: Pending Kernel Window is 5 (warmup=0).
 51%|█████▏    | 2052/4000 [06:51<16:50,  1.93it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
 51%|█████▏    | 2054/4000 [06:52<17:13,  1.88it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
 51%|█████▏    | 2056/4000 [06:53<17:06,  1.89it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
 51%|█████▏    | 2058/4000 [06:54<16:59,  1.91it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
 52%|█████▏    | 2060/4000 [06:55<16:52,  1.92it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
```

```
测试发现还是有之前的问题，当任务1和任务2都运行在GPU0上，任务1完成后，任务2的速度却一直提不去来。见日志。root@lgy-test-gpu:~# kubectl logs  nvshare-cross-gpu-2
[NVSHARE][WARN]: Enabling GPU memory oversubscription for this application
[NVSHARE][DEBUG]: Failed to find nvmlDeviceGetHandleByUUID_v2, falling back to nvmlDeviceGetHandleByUUID
[NVSHARE][DEBUG]: Found NVML
[NVSHARE][DEBUG]: NVSHARE_POD_NAME = nvshare-cross-gpu-2
[NVSHARE][DEBUG]: NVSHARE_POD_NAMESPACE = default
[NVSHARE][DEBUG]: Sent REGISTER
[NVSHARE][DEBUG]: Received SCHED_ON
[NVSHARE][INFO]: Successfully initialized nvshare GPU
[NVSHARE][INFO]: Client ID = 9853bf574ec5df59
[NVSHARE][DEBUG]: real_cuMemGetInfo returned free=13418.81 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: nvshare's cuMemGetInfo returning free=13377.69 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f2c6e000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 2992.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 2992 MB
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f2bb2000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 5984.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 5984 MB
  0%|          | 0/4000 [00:00<?, ?it/s][NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f2af6000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 8976.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 8976 MB
[NVSHARE][DEBUG]: cuMemAlloc requested 3137339392 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes at 0x7f2a3a000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 11968.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 11968 MB
[NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
  1%|          | 32/4000 [00:01<03:22, 19.63it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
  2%|▏         | 96/4000 [00:04<02:43, 23.90it/s][NVSHARE][DEBUG]: Received PREPARE_SWAP_OUT
[NVSHARE][INFO]: Hinting driver to evict memory to Host (preparing for swap-out)
[NVSHARE][DEBUG]: cuMemAdvise failed for allocation at 0x7f2c6e000000 (size 3137339392): CUDA_ERROR_INVALID_CONTEXT (201)
[NVSHARE][DEBUG]: cuMemAdvise failed for allocation at 0x7f2bb2000000 (size 3137339392): CUDA_ERROR_INVALID_CONTEXT (201)
[NVSHARE][DEBUG]: cuMemAdvise failed for allocation at 0x7f2af6000000 (size 3137339392): CUDA_ERROR_INVALID_CONTEXT (201)
[NVSHARE][DEBUG]: cuMemAdvise failed for allocation at 0x7f2a3a000000 (size 3137339392): CUDA_ERROR_INVALID_CONTEXT (201)
[NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
  6%|▌         | 224/4000 [00:09<02:29, 25.21it/s][NVSHARE][DEBUG]: Received LOCK_OK
  6%|▌         | 224/4000 [00:19<02:29, 25.21it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
  6%|▌         | 225/4000 [00:23<09:12,  6.83it/s][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
  6%|▌         | 227/4000 [00:24<09:56,  6.32it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
  6%|▌         | 231/4000 [00:24<09:30,  6.61it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
  6%|▌         | 239/4000 [00:25<08:30,  7.37it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
  6%|▋         | 255/4000 [00:25<06:44,  9.26it/s][NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
  7%|▋         | 287/4000 [00:27<04:45, 13.00it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
  9%|▉         | 351/4000 [00:29<03:22, 18.04it/s][NVSHARE][DEBUG]: Pending Kernel Window is 512 (warmup=1).
 12%|█▏        | 479/4000 [00:34<02:38, 22.17it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 1024 (warmup=1).
 18%|█▊        | 735/4000 [00:44<02:13, 24.39it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
 18%|█▊        | 735/4000 [01:00<02:13, 24.39it/s][NVSHARE][WARN]: Critical timeout (19 s). AIMD reduced window to 512
[NVSHARE][DEBUG]: Pending Kernel Window is 512 (warmup=0).
 31%|███       | 1247/4000 [01:04<01:48, 25.32it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 409 (warmup=0).
 38%|███▊      | 1503/4000 [01:14<01:37, 25.49it/s][NVSHARE][DEBUG]: Received PREPARE_SWAP_OUT
[NVSHARE][INFO]: Hinting driver to evict memory to Host (preparing for swap-out)
[NVSHARE][INFO]: Swap-out hints sent for 4 allocations (11968.00 MB total)
[NVSHARE][DEBUG]: Pending Kernel Window is 327 (warmup=0).
[NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
 38%|███▊      | 1503/4000 [01:30<01:37, 25.49it/s][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
 43%|████▎     | 1708/4000 [02:22<04:29,  8.52it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
 43%|████▎     | 1709/4000 [02:23<04:30,  8.46it/s][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 43%|████▎     | 1711/4000 [02:24<04:35,  8.31it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 43%|████▎     | 1715/4000 [02:26<04:47,  7.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 43%|████▎     | 1723/4000 [02:30<05:22,  7.07it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 43%|████▎     | 1739/4000 [02:38<06:46,  5.57it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][WARN]: Critical timeout (16 s). AIMD reduced window to 32
[NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=0).
 44%|████▍     | 1771/4000 [02:54<09:27,  3.93it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 25 (warmup=0).
 45%|████▍     | 1787/4000 [03:02<10:42,  3.45it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 20 (warmup=0).
 45%|████▌     | 1800/4000 [03:09<11:39,  3.14it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=0).
 45%|████▌     | 1810/4000 [03:14<12:32,  2.91it/s][NVSHARE][DEBUG]: Received PREPARE_SWAP_OUT
[NVSHARE][INFO]: Hinting driver to evict memory to Host (preparing for swap-out)
[NVSHARE][INFO]: Swap-out hints sent for 4 allocations (11968.00 MB total)
[NVSHARE][DEBUG]: Pending Kernel Window is 12 (warmup=0).
[NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
 45%|████▌     | 1818/4000 [04:15<47:54,  1.32s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
 45%|████▌     | 1819/4000 [04:16<47:12,  1.30s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 46%|████▌     | 1821/4000 [04:17<45:23,  1.25s/it][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 46%|████▌     | 1825/4000 [04:19<41:16,  1.14s/it][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 46%|████▌     | 1833/4000 [04:23<34:17,  1.05it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 46%|████▌     | 1849/4000 [04:31<26:43,  1.34it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][WARN]: Critical timeout (16 s). AIMD reduced window to 32
[NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=0).
 47%|████▋     | 1881/4000 [04:47<21:33,  1.64it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 25 (warmup=0).
 47%|████▋     | 1897/4000 [04:55<20:21,  1.72it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 20 (warmup=0).
 48%|████▊     | 1910/4000 [05:02<19:25,  1.79it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=0).
 48%|████▊     | 1920/4000 [05:07<18:57,  1.83it/s][NVSHARE][DEBUG]: Received PREPARE_SWAP_OUT
[NVSHARE][INFO]: Hinting driver to evict memory to Host (preparing for swap-out)
[NVSHARE][INFO]: Swap-out hints sent for 4 allocations (11968.00 MB total)
[NVSHARE][DEBUG]: Pending Kernel Window is 12 (warmup=0).
[NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
 48%|████▊     | 1928/4000 [05:48<49:59,  1.45s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
 48%|████▊     | 1929/4000 [05:48<48:51,  1.42s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 48%|████▊     | 1931/4000 [05:49<46:01,  1.33s/it][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 48%|████▊     | 1935/4000 [05:51<40:10,  1.17s/it][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 49%|████▊     | 1943/4000 [05:55<31:44,  1.08it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 49%|████▉     | 1959/4000 [06:03<24:13,  1.40it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][WARN]: Critical timeout (16 s). AIMD reduced window to 32
[NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=0).
 50%|████▉     | 1991/4000 [06:20<19:47,  1.69it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 25 (warmup=0).
 50%|█████     | 2007/4000 [06:28<18:48,  1.77it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 20 (warmup=0).
 50%|█████     | 2020/4000 [06:34<18:01,  1.83it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
[NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
[NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=0).
 51%|█████     | 2030/4000 [06:39<17:39,  1.86it/s][NVSHARE][DEBUG]: Pending Kernel Window is 12 (warmup=0).
 51%|█████     | 2038/4000 [06:43<17:23,  1.88it/s][NVSHARE][DEBUG]: Pending Kernel Window is 9 (warmup=0).
 51%|█████     | 2044/4000 [06:46<17:12,  1.89it/s][NVSHARE][DEBUG]: Pending Kernel Window is 7 (warmup=0).
 51%|█████     | 2048/4000 [06:49<17:22,  1.87it/s][NVSHARE][DEBUG]: Pending Kernel Window is 5 (warmup=0).
 51%|█████▏    | 2052/4000 [06:50<16:50,  1.93it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
 51%|█████▏    | 2054/4000 [06:52<17:14,  1.88it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
 51%|█████▏    | 2056/4000 [06:53<17:07,  1.89it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
 51%|█████▏    | 2058/4000 [06:54<16:59,  1.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
 52%|█████▏    | 2060/4000 [06:55<16:52,  1.92it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
 52%|█████▏    | 2062/4000 [06:56<16:46,  1.93it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
 52%|█████▏    | 2064/4000 [06:57<16:40,  1.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
 52%|█████▏    | 2066/4000 [06:58<16:35,  1.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
 52%|█████▏    | 2068/4000 [06:59<16:31,  1.95it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
 52%|█████▏    | 2070/4000 [07:00<16:27,  1.95it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
 52%|█████▏    | 2072/4000 [07:01<16:24,  1.96it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
 52%|█████▏    | 2074/4000 [07:02<16:22,  1.96it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
```

```
我检查了日志，确认任务1进程确实已经结束，在日志中2026-01-30T19:22:23这个事件点上，而2026-01-30T19:39:57是任务2完成的时间。
root@lgy-test-gpu:~# kubectl -n nvshare-system logs nvshare-scheduler-f65cd --timestamps|grep  -i "removing client"
2026-01-30T19:19:09.747443702+08:00 [NVSHARE][INFO]: Removing client cac3a430eae6f58c
2026-01-30T19:22:23.992633945+08:00 [NVSHARE][INFO]: Removing client c8eab8ea029a236d
2026-01-30T19:39:57.821955376+08:00 [NVSHARE][INFO]: Removing client 9853bf574ec5df59

任务2从2026-01-30T19:22左右的日志：
2026-01-30T19:21:47.592834449+08:00 [NVSHARE][DEBUG]: Received DROP_LOCK
2026-01-30T19:21:47.592838427+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-01-30T19:22:23.992679216+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
2026-01-30T19:22:24.247184219+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
 48%|████▊     | 1928/4000 [05:48<49:59,  1.45s/it][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
 48%|████▊     | 1929/4000 [05:48<48:51,  1.42s/it][NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
 48%|████▊     | 1931/4000 [05:49<46:01,  1.33s/it][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
 48%|████▊     | 1935/4000 [05:51<40:10,  1.17s/it][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
 49%|████▊     | 1943/4000 [05:55<31:44,  1.08it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T19:22:36.898487215+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T19:22:40.014326549+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
 49%|████▉     | 1959/4000 [06:03<24:13,  1.40it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T19:22:45.038859082+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T19:22:50.061834763+08:00 [NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T19:22:50.061864280+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T19:22:55.084795878+08:00 [NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T19:22:55.084815460+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T19:22:56.275677808+08:00 [NVSHARE][WARN]: Critical timeout (16 s). AIMD reduced window to 32
2026-01-30T19:22:56.275705131+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=0).
 50%|████▉     | 1991/4000 [06:20<19:47,  1.69it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T19:23:01.299918750+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T19:23:04.407980671+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 25 (warmup=0).
 50%|█████     | 2007/4000 [06:28<18:48,  1.77it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T19:23:09.431664612+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T19:23:10.760439004+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 20 (warmup=0).
 50%|█████     | 2020/4000 [06:34<18:01,  1.83it/s][NVSHARE][DEBUG]: GPU Utilization = 100 %
2026-01-30T19:23:15.784261658+08:00 [NVSHARE][DEBUG]: Early release timer elapsed but we are not idle
2026-01-30T19:23:15.842827284+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=0).
 51%|█████     | 2030/4000 [06:39<17:39,  1.86it/s][NVSHARE][DEBUG]: Pending Kernel Window is 12 (warmup=0).
 51%|█████     | 2038/4000 [06:43<17:23,  1.88it/s][NVSHARE][DEBUG]: Pending Kernel Window is 9 (warmup=0).
 51%|█████     | 2044/4000 [06:46<17:12,  1.89it/s][NVSHARE][DEBUG]: Pending Kernel Window is 7 (warmup=0).
 51%|█████     | 2048/4000 [06:49<17:22,  1.87it/s][NVSHARE][DEBUG]: Pending Kernel Window is 5 (warmup=0).
 51%|█████▏    | 2052/4000 [06:50<16:50,  1.93it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
 51%|█████▏    | 2054/4000 [06:52<17:14,  1.88it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
 51%|█████▏    | 2056/4000 [06:53<17:07,  1.89it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
 51%|█████▏    | 2058/4000 [06:54<16:59,  1.90it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
 52%|█████▏    | 2060/4000 [06:55<16:52,  1.92it/s][NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=0).
```

- AI给我的回答

```
这个日志非常关键！让我分析：

关键发现
时间线分析
19:21:47 - 任务2 发送 LOCK_RELEASED
19:22:23 - 任务1 退出 (Removing client c8eab8ea029a236d)
19:22:23 - 任务2 收到 LOCK_OK
此后：任务2 没有再收到任何 DROP_LOCK！
好消息：
remove_req()
 的修复生效了！任务1退出后，调度器正确地不再发送 DROP_LOCK。

但为什么速度仍然很慢？
问题是 UVM 页面错误造成的持续性损伤：

在 19:21:47：任务2被换出，12GB 内存被迁移到 Host
在 19:22:23：任务2重新获得锁，但内存仍在 Host
此后：每次 GPU 访问都触发按需分页（page fault）
AIMD 窗口衰减：32→25→20→16→12→9→7→5→4，因为内核执行太慢
窗口稳定在 4：这是最小窗口，但速度仍然只有 ~2 it/s
根本原因：任务2的内存已经被换出到 Host，即使 GPU 现在空闲，内存也不会自动迁移回 GPU。必须等待按需分页。

解决方案：添加 Swap-In 功能
当任务重新获得 LOCK_OK 时，主动将内存预取回 GPU：
```

- 继续追问

```
我有个不理解的地方，当任务1和任务2都在运行的时候，我从日志中看，任务1和任务2大概能各得到1分钟的运行时间，这个1分钟内，得到运行的任务速度还是比较快的，能接近20it/s。这个时候任务2的内存也是先被换出到host，然后再换进内存的，为什么那个时候，没有出现因为大量pagefault造成运行缓慢的情况，为什么那个时候，没有实现预取，内存也能快速置换到显存里。反而是任务1停了，任务2却没有很快置换到显存
```

- AI的回答，看上去比较靠谱

```
这是一个非常好的问题！让我深入分析这个现象。

关键差异分析
场景1：两个任务都在运行时（速度快）
当两个任务轮流运行时：

任务2释放锁后，UVM 按需驱逐（demand eviction）页面到 Host
任务1运行，占用 GPU 显存
任务2重新获得锁时，UVM 按需加载（demand paging）页面回 GPU
由于两个任务交替访问，UVM 驱动有局部性信息，知道哪些页面最近被访问
页面错误是分散的，不是一次性全部加载
场景2：任务1退出后（速度慢）
关键点在于我们调用了 cuMemAdvise 设置 CU_MEM_ADVISE_SET_PREFERRED_LOCATION 为 CU_DEVICE_CPU：

c
real_cuMemAdvise(a->ptr, a->size, CU_MEM_ADVISE_SET_PREFERRED_LOCATION, CU_DEVICE_CPU);
这不是普通的内存驱逐，这是告诉驱动"这块内存的首选位置是 CPU"！

这意味着：

驱动主动将所有 12GB 内存迁移到 Host
更严重的是：首选位置被设为 CPU
当 GPU 访问这些页面时，驱动会加载它们，但因为首选位置是 CPU，驱动可能会再次将它们移回 CPU！
这导致持续的页面错误，即使 GPU 现在有足够空间
正确的解决方案
需要在收到 LOCK_OK 时重置首选位置回 GPU：
```

# day4 主要问题已解决，多验证一些case

- 经过了day3，基本能确定方式是正确的，只是有些case还没验证到，估计还有不少bug，所以今天的任务是多测几个场景

```
我用2个GPU，创建了6个small的任务，请分析日志，判断并行是否生效
root@lgy-test-gpu:~# nvidia-smi
Sat Jan 31 11:16:04 2026
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 570.133.20             Driver Version: 570.133.20     CUDA Version: 12.8     |
|-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|                                         |                        |               MIG M. |
|=========================================+========================+======================|
|   0  Tesla T4                       Off |   00000000:00:06.0 Off |                    0 |
| N/A   50C    P0             67W /   70W |   12109MiB /  15360MiB |    100%      Default |
|                                         |                        |                  N/A |
+-----------------------------------------+------------------------+----------------------+
|   1  Tesla T4                       Off |   00000000:00:07.0 Off |                    0 |
| N/A   52C    P0             65W /   70W |   12109MiB /  15360MiB |    100%      Default |
|                                         |                        |                  N/A |
+-----------------------------------------+------------------------+----------------------+

+-----------------------------------------------------------------------------------------+
| Processes:                                                                              |
|  GPU   GI   CI              PID   Type   Process name                        GPU Memory |
|        ID   ID                                                               Usage      |
|=========================================================================================|
|    0   N/A  N/A         3169246      C   python                                 1006MiB |
|    0   N/A  N/A         3169292      C   python                                 1006MiB |
|    0   N/A  N/A         3169295      C   python                                 1006MiB |
|    1   N/A  N/A         3169239      C   python                                 1006MiB |
|    1   N/A  N/A         3169260      C   python                                 1006MiB |
|    1   N/A  N/A         3169280      C   python                                 1006MiB |
+-----------------------------------------------------------------------------------------+
root@lgy-test-gpu:~#
root@lgy-test-gpu:~#
root@lgy-test-gpu:~# kubectl -n nvshare-system logs nvshare-scheduler-nr869
[NVSHARE][INFO]: nvshare-scheduler started in normal mode
[NVSHARE][INFO]: Switch time mode: AUTO
[NVSHARE][INFO]: Scheduling mode: AUTO (default)
[NVSHARE][INFO]: Max runtime per task: 300 seconds (default)
[NVSHARE][INFO]: nvshare-scheduler listening on /var/run/nvshare/scheduler.sock
[NVSHARE][INFO]: Received REGISTER
[NVSHARE][INFO]: Created new GPU context for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1 (memory: 16384 MB)
[NVSHARE][INFO]: Sent SCHED_ON to client faacb50355fc6666
[NVSHARE][INFO]: Registered client faacb50355fc6666 with Pod name = nvshare-small-1, Pod namespace = default
[NVSHARE][INFO]: Received REGISTER
[NVSHARE][INFO]: Created new GPU context for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e (memory: 16384 MB)
[NVSHARE][INFO]: Sent SCHED_ON to client a3f0b7f914700dd8
[NVSHARE][INFO]: Registered client a3f0b7f914700dd8 with Pod name = nvshare-small-3, Pod namespace = default
[NVSHARE][INFO]: Received REGISTER
[NVSHARE][INFO]: Sent SCHED_ON to client b96b0ee1dd030836
[NVSHARE][INFO]: Registered client b96b0ee1dd030836 with Pod name = nvshare-small-2, Pod namespace = default
[NVSHARE][INFO]: Received REGISTER
[NVSHARE][INFO]: Sent SCHED_ON to client a01423a9292911f6
[NVSHARE][INFO]: Registered client a01423a9292911f6 with Pod name = nvshare-small-5, Pod namespace = default
[NVSHARE][INFO]: Received REGISTER
[NVSHARE][INFO]: Sent SCHED_ON to client 63c54e13987959b0
[NVSHARE][INFO]: Registered client 63c54e13987959b0 with Pod name = nvshare-small-4, Pod namespace = default
[NVSHARE][INFO]: Received REGISTER
[NVSHARE][INFO]: Sent SCHED_ON to client 1e4d8f0a54b639d2
[NVSHARE][INFO]: Registered client 1e4d8f0a54b639d2 with Pod name = nvshare-small-6, Pod namespace = default
[NVSHARE][INFO]: Received REQ_LOCK from faacb50355fc6666
[NVSHARE][INFO]: Sent LOCK_OK to client faacb50355fc6666
[NVSHARE][INFO]: Scheduled client faacb50355fc6666 (mem: 748 MB, total running: 748 MB)
[NVSHARE][INFO]: Received REQ_LOCK from a01423a9292911f6
[NVSHARE][INFO]: Received REQ_LOCK from b96b0ee1dd030836
[NVSHARE][INFO]: Received REQ_LOCK from a3f0b7f914700dd8
[NVSHARE][INFO]: Sent LOCK_OK to client a3f0b7f914700dd8
[NVSHARE][INFO]: Scheduled client a3f0b7f914700dd8 (mem: 748 MB, total running: 748 MB)
[NVSHARE][INFO]: Received REQ_LOCK from 63c54e13987959b0
[NVSHARE][INFO]: Received REQ_LOCK from 1e4d8f0a54b639d2
[NVSHARE][INFO]: Sending PREPARE_SWAP_OUT to client before switch (elapsed: 10 s)
[NVSHARE][INFO]: Sent PREPARE_SWAP_OUT to client faacb50355fc6666
[NVSHARE][INFO]: Sent DROP_LOCK to client faacb50355fc6666
[NVSHARE][INFO]: Sent DROP_LOCK after 10 seconds of runtime
[NVSHARE][INFO]: Sending PREPARE_SWAP_OUT to client before switch (elapsed: 10 s)
[NVSHARE][INFO]: Sent PREPARE_SWAP_OUT to client a3f0b7f914700dd8
[NVSHARE][INFO]: Sent DROP_LOCK to client a3f0b7f914700dd8
[NVSHARE][INFO]: Sent DROP_LOCK after 10 seconds of runtime
[NVSHARE][INFO]: Received LOCK_RELEASED from faacb50355fc6666
[NVSHARE][INFO]: Client faacb50355fc6666 released, running_memory: 0 MB
[NVSHARE][INFO]: Sent LOCK_OK to client a01423a9292911f6
[NVSHARE][INFO]: Scheduled client a01423a9292911f6 (mem: 748 MB, total running: 748 MB)
[NVSHARE][INFO]: Received REQ_LOCK from faacb50355fc6666
[NVSHARE][INFO]: Received LOCK_RELEASED from a3f0b7f914700dd8
[NVSHARE][INFO]: Client a3f0b7f914700dd8 released, running_memory: 0 MB
[NVSHARE][INFO]: Sent LOCK_OK to client 63c54e13987959b0
[NVSHARE][INFO]: Scheduled client 63c54e13987959b0 (mem: 748 MB, total running: 748 MB)
[NVSHARE][INFO]: Received REQ_LOCK from a3f0b7f914700dd8
[NVSHARE][INFO]: Sending PREPARE_SWAP_OUT to client before switch (elapsed: 10 s)
[NVSHARE][INFO]: Sent PREPARE_SWAP_OUT to client a01423a9292911f6
[NVSHARE][INFO]: Sent DROP_LOCK to client a01423a9292911f6
[NVSHARE][INFO]: Sent DROP_LOCK after 10 seconds of runtime
[NVSHARE][INFO]: Sending PREPARE_SWAP_OUT to client before switch (elapsed: 10 s)
[NVSHARE][INFO]: Sent PREPARE_SWAP_OUT to client 63c54e13987959b0
[NVSHARE][INFO]: Sent DROP_LOCK to client 63c54e13987959b0
[NVSHARE][INFO]: Sent DROP_LOCK after 10 seconds of runtime
[NVSHARE][INFO]: Received LOCK_RELEASED from a01423a9292911f6
[NVSHARE][INFO]: Client a01423a9292911f6 released, running_memory: 0 MB
[NVSHARE][INFO]: Sent LOCK_OK to client b96b0ee1dd030836
[NVSHARE][INFO]: Scheduled client b96b0ee1dd030836 (mem: 748 MB, total running: 748 MB)
[NVSHARE][INFO]: Received REQ_LOCK from a01423a9292911f6
[NVSHARE][INFO]: Received LOCK_RELEASED from 63c54e13987959b0
[NVSHARE][INFO]: Client 63c54e13987959b0 released, running_memory: 0 MB
[NVSHARE][INFO]: Sent LOCK_OK to client 1e4d8f0a54b639d2
[NVSHARE][INFO]: Scheduled client 1e4d8f0a54b639d2 (mem: 748 MB, total running: 748 MB)
[NVSHARE][INFO]: Received REQ_LOCK from 63c54e13987959b0
[NVSHARE][INFO]: Sending PREPARE_SWAP_OUT to client before switch (elapsed: 10 s)
[NVSHARE][INFO]: Sent PREPARE_SWAP_OUT to client b96b0ee1dd030836
[NVSHARE][INFO]: Sent DROP_LOCK to client b96b0ee1dd030836
[NVSHARE][INFO]: Sent DROP_LOCK after 10 seconds of runtime
[NVSHARE][INFO]: Sending PREPARE_SWAP_OUT to client before switch (elapsed: 10 s)
[NVSHARE][INFO]: Sent PREPARE_SWAP_OUT to client 1e4d8f0a54b639d2
[NVSHARE][INFO]: Sent DROP_LOCK to client 1e4d8f0a54b639d2
[NVSHARE][INFO]: Sent DROP_LOCK after 10 seconds of runtime
[NVSHARE][INFO]: Received LOCK_RELEASED from b96b0ee1dd030836
[NVSHARE][INFO]: Client b96b0ee1dd030836 released, running_memory: 0 MB
[NVSHARE][INFO]: Sent LOCK_OK to client faacb50355fc6666
[NVSHARE][INFO]: Scheduled client faacb50355fc6666 (mem: 2992 MB, total running: 2992 MB)
[NVSHARE][INFO]: Received REQ_LOCK from b96b0ee1dd030836
[NVSHARE][INFO]: Received LOCK_RELEASED from 1e4d8f0a54b639d2
[NVSHARE][INFO]: Client 1e4d8f0a54b639d2 released, running_memory: 0 MB
[NVSHARE][INFO]: Sent LOCK_OK to client a3f0b7f914700dd8
[NVSHARE][INFO]: Scheduled client a3f0b7f914700dd8 (mem: 2992 MB, total running: 2992 MB)
[NVSHARE][INFO]: Received REQ_LOCK from 1e4d8f0a54b639d2
```

- 这里是我自己看了代码的分析，所以让AI加了一个新的测试代码，不要占满GPU算力

```
当前测试的任务是tests/pytorch-add-small.py，他是不停的计算，所以并行执行的时候，只是都放显存里了，看不出并行的效果，请增加一个tests/pytorch-add-idle-small.py，然他不要跑满GPU算力，例如让他只用1/4的算力。然后再tests目录下，添加对应的dockerfile和manifest，在.tests目录下添加使用我自己镜像仓库（aliyun）的manifests，然后添加remote-test-idle-small.sh测试脚本
```


```
我用tests/pytorch-add-idle-small.py创建了6个容器，分布在2个GPU上，虽然他们每个任务占用的GPU只有4G，理论上可以并行在2个GPU上，并且每个任务里我都加了sleep，应该是能够充分并行的。但是实际执行情况看，还是在串行执行，每个GPU上的三个任务加起来的完成时间约等于单个任务的3倍。请检查日志，分析原因，日志在我测试机器上，可以通过ssh root@139.196.28.96 -p 32027免密登录,在他上面执行kubectl或者smi等命令都可以。
```

- 这里我不认可AI的分析，所以补充了一些自己的分析

```
先等一下实现，还需要进一步分析问题，比如实际显存是16G，3个任务加起来也就12G，为什么任务会被swap到内存中，或者说任务第一次被swap到显存后，理论上就可以一直在显存中，因为显存是足够的。
```

```
测试发现了1个问题，如果device-plugin不重启，则第二轮测试的时候，就达不到之前的效果，看上去调度就乱了，见日志[NVSHARE][INFO]: Sent SCHED_ON to client a64c4f77af7fae94
[NVSHARE][INFO]: Registered client a64c4f77af7fae94 on GPU GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e with Pod name = nvshare-small-1, Pod namespace = default
[NVSHARE][INFO]: Received REGISTER
[NVSHARE][INFO]: Sent SCHED_ON to client 555c99e2c8859d4e
[NVSHARE][INFO]: Registered client 555c99e2c8859d4e on GPU GPU-dc895bd6-43d7-a984-b1ee-870332194bd1 with Pod name = nvshare-small-2, Pod namespace = default
[NVSHARE][INFO]: Received REQ_LOCK from a64c4f77af7fae94
[NVSHARE][INFO]: Sent WAIT_FOR_MEM to client a64c4f77af7fae94
[NVSHARE][INFO]: Client a64c4f77af7fae94 moved to wait queue (req: 748 MB, avail: 17592186036864 MB)
[NVSHARE][INFO]: Received REQ_LOCK from 555c99e2c8859d4e
[NVSHARE][INFO]: Sent WAIT_FOR_MEM to client 555c99e2c8859d4e
[NVSHARE][INFO]: Client 555c99e2c8859d4e moved to wait queue (req: 748 MB, avail: 17592186036864 MB)
[NVSHARE][INFO]: Removing client 6546d4d18df298d6
[NVSHARE][INFO]: Client 6546d4d18df298d6 released, running_memory: 11968 MB
[NVSHARE][INFO]: Removing client 79a4f2417a4bd356
[NVSHARE][INFO]: Client 79a4f2417a4bd356 released, running_memory: 11968 MB
[NVSHARE][INFO]: Removing client 99532d79f87cd05a
[NVSHARE][INFO]: Client 99532d79f87cd05a released, running_memory: 0 MB
[NVSHARE][INFO]: Client a64c4f77af7fae94 promoted from wait queue
[NVSHARE][INFO]: Sent MEM_AVAILABLE to client a64c4f77af7fae94
[NVSHARE][INFO]: Sent LOCK_OK to client a64c4f77af7fae94
[NVSHARE][INFO]: Scheduled client a64c4f77af7fae94 (mem: 748 MB, total running: 748 MB)
[NVSHARE][INFO]: Removing client 9784e18127d4b846
[NVSHARE][INFO]: Client 9784e18127d4b846 released, running_memory: 0 MB
[NVSHARE][INFO]: Client 555c99e2c8859d4e promoted from wait queue
[NVSHARE][INFO]: Sent MEM_AVAILABLE to client 555c99e2c8859d4e
[NVSHARE][INFO]: Sent LOCK_OK to client 555c99e2c8859d4e
[NVSHARE][INFO]: Scheduled client 555c99e2c8859d4e (mem: 748 MB, total running: 748 MB)
[NVSHARE][INFO]: Removing client a64c4f77af7fae94
[NVSHARE][INFO]: Client a64c4f77af7fae94 released, running_memory: 0 MB
[NVSHARE][INFO]: Removing client 555c99e2c8859d4e
[NVSHARE][INFO]: Client 555c99e2c8859d4e released, running_memory: 0 MB
[NVSHARE][INFO]: Received REGISTER
[NVSHARE][INFO]: Sent SCHED_ON to client 8c3cdb5d3ab89ca2
[NVSHARE][INFO]: Registered client 8c3cdb5d3ab89ca2 on GPU GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e with Pod name = nvshare-small-1, Pod namespace = default
[NVSHARE][INFO]: Received REGISTER
[NVSHARE][INFO]: Sent SCHED_ON to client 4fd0944a0116b2c1
[NVSHARE][INFO]: Registered client 4fd0944a0116b2c1 on GPU GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e with Pod name = nvshare-small-2, Pod namespace = default
[NVSHARE][INFO]: Received REQ_LOCK from 8c3cdb5d3ab89ca2
[NVSHARE][INFO]: Sent LOCK_OK to client 8c3cdb5d3ab89ca2
[NVSHARE][INFO]: Scheduled client 8c3cdb5d3ab89ca2 (mem: 748 MB, total running: 748 MB)
[NVSHARE][INFO]: Received REQ_LOCK from 4fd0944a0116b2c1
[NVSHARE][INFO]: Sent LOCK_OK to client 4fd0944a0116b2c1
[NVSHARE][INFO]: Scheduled client 4fd0944a0116b2c1 (mem: 748 MB, total running: 3740 MB) 
```

```
我用remote-test.sh 4测试4个pod，发现如果不加--serial，手动指定串行模式，pod运行会特别慢，看上去是调度不太正确，请检查日志并分析原因
```

```
device-plugin多次分配后，出现不平衡的情况，没有让任务均匀分配到所有GPU上，日志如下root@lgy-test-gpu:~# kubectl -n nvshare-system logs nvshare-device-plugin-6fxws nvshare-device-plugin
2026/02/02 11:13:55 Read UUIDs = [GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e GPU-dc895bd6-43d7-a984-b1ee-870332194bd1]
2026/02/02 11:13:55 Starting FS watcher.
2026/02/02 11:13:55 Starting OS watcher.
2026/02/02 11:13:55 Reporting the following DeviceIDs to kubelet:
2026/02/02 11:13:55 [1] Device ID:GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__1
2026/02/02 11:13:55 [2] Device ID:GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__2
2026/02/02 11:13:55 [3] Device ID:GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__3
2026/02/02 11:13:55 [4] Device ID:GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__4
2026/02/02 11:13:55 [5] Device ID:GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__5
2026/02/02 11:13:55 [6] Device ID:GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__6
2026/02/02 11:13:55 [7] Device ID:GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__7
2026/02/02 11:13:55 [8] Device ID:GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__8
2026/02/02 11:13:55 [9] Device ID:GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__9
2026/02/02 11:13:55 [10] Device ID:GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__10
2026/02/02 11:13:55 [1] Device ID:GPU-dc895bd6-43d7-a984-b1ee-870332194bd1__1
2026/02/02 11:13:55 [2] Device ID:GPU-dc895bd6-43d7-a984-b1ee-870332194bd1__2
2026/02/02 11:13:55 [3] Device ID:GPU-dc895bd6-43d7-a984-b1ee-870332194bd1__3
2026/02/02 11:13:55 [4] Device ID:GPU-dc895bd6-43d7-a984-b1ee-870332194bd1__4
2026/02/02 11:13:55 [5] Device ID:GPU-dc895bd6-43d7-a984-b1ee-870332194bd1__5
2026/02/02 11:13:55 [6] Device ID:GPU-dc895bd6-43d7-a984-b1ee-870332194bd1__6
2026/02/02 11:13:55 [7] Device ID:GPU-dc895bd6-43d7-a984-b1ee-870332194bd1__7
2026/02/02 11:13:55 [8] Device ID:GPU-dc895bd6-43d7-a984-b1ee-870332194bd1__8
2026/02/02 11:13:55 [9] Device ID:GPU-dc895bd6-43d7-a984-b1ee-870332194bd1__9
2026/02/02 11:13:55 [10] Device ID:GPU-dc895bd6-43d7-a984-b1ee-870332194bd1__10
2026/02/02 11:13:55 Starting gRPC server for 'nvshare.com/gpu'
2026/02/02 11:13:55 Starting to serve 'nvshare.com/gpu' on /var/lib/kubelet/device-plugins/nvshare-device-plugin.sock
2026/02/02 11:13:55 Registered device plugin for 'nvshare.com/gpu' with Kubelet
2026/02/02 11:13:55 Sent ListAndWatchResponse with DeviceIDs
2026/02/02 11:14:04 GetPreferredAllocation: want 1 devices from 20 available
2026/02/02 11:14:04 GetPreferredAllocation: selected GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__8 (GPU GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e now has 1 allocations)
2026/02/02 11:14:04 Received Allocate request for GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__8
2026/02/02 11:14:04 GetPreferredAllocation: want 1 devices from 19 available
2026/02/02 11:14:04 GetPreferredAllocation: selected GPU-dc895bd6-43d7-a984-b1ee-870332194bd1__8 (GPU GPU-dc895bd6-43d7-a984-b1ee-870332194bd1 now has 1 allocations)
2026/02/02 11:14:04 Received Allocate request for GPU-dc895bd6-43d7-a984-b1ee-870332194bd1__8
2026/02/02 11:14:04 GetPreferredAllocation: want 1 devices from 18 available
2026/02/02 11:14:04 GetPreferredAllocation: selected GPU-dc895bd6-43d7-a984-b1ee-870332194bd1__2 (GPU GPU-dc895bd6-43d7-a984-b1ee-870332194bd1 now has 2 allocations)
2026/02/02 11:14:04 Received Allocate request for GPU-dc895bd6-43d7-a984-b1ee-870332194bd1__2
2026/02/02 11:14:05 GetPreferredAllocation: want 1 devices from 17 available
2026/02/02 11:14:05 GetPreferredAllocation: selected GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__7 (GPU GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e now has 2 allocations)
2026/02/02 11:14:05 Received Allocate request for GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__7
2026/02/02 13:53:05 GetPreferredAllocation: want 1 devices from 20 available
2026/02/02 13:53:05 GetPreferredAllocation: selected GPU-dc895bd6-43d7-a984-b1ee-870332194bd1__5 (GPU GPU-dc895bd6-43d7-a984-b1ee-870332194bd1 now has 3 allocations)
2026/02/02 13:53:05 Received Allocate request for GPU-dc895bd6-43d7-a984-b1ee-870332194bd1__5
2026/02/02 14:03:11 GetPreferredAllocation: want 1 devices from 20 available
2026/02/02 14:03:11 GetPreferredAllocation: selected GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__9 (GPU GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e now has 3 allocations)
2026/02/02 14:03:11 Received Allocate request for GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__9
2026/02/02 14:03:12 GetPreferredAllocation: want 1 devices from 19 available
2026/02/02 14:03:12 GetPreferredAllocation: selected GPU-dc895bd6-43d7-a984-b1ee-870332194bd1__6 (GPU GPU-dc895bd6-43d7-a984-b1ee-870332194bd1 now has 4 allocations)
2026/02/02 14:03:12 Received Allocate request for GPU-dc895bd6-43d7-a984-b1ee-870332194bd1__6
2026/02/02 14:03:13 GetPreferredAllocation: want 1 devices from 18 available
2026/02/02 14:03:13 GetPreferredAllocation: selected GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__7 (GPU GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e now has 4 allocations)
2026/02/02 14:03:13 Received Allocate request for GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__7
2026/02/02 14:03:14 GetPreferredAllocation: want 1 devices from 17 available
2026/02/02 14:03:14 GetPreferredAllocation: selected GPU-dc895bd6-43d7-a984-b1ee-870332194bd1__7 (GPU GPU-dc895bd6-43d7-a984-b1ee-870332194bd1 now has 5 allocations)
2026/02/02 14:03:14 Received Allocate request for GPU-dc895bd6-43d7-a984-b1ee-870332194bd1__7
2026/02/02 14:03:14 GetPreferredAllocation: want 1 devices from 16 available
2026/02/02 14:03:14 GetPreferredAllocation: selected GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__5 (GPU GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e now has 5 allocations)
2026/02/02 14:03:14 Received Allocate request for GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__5
2026/02/02 14:03:15 GetPreferredAllocation: want 1 devices from 15 available
2026/02/02 14:03:15 GetPreferredAllocation: selected GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__2 (GPU GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e now has 6 allocations)
2026/02/02 14:03:15 Received Allocate request for GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e__2
```


```
我针对不同任务类型进行了一些列测试，测试结果见docs/performance/performance_test_for_gpu_share.md，跟对测试结果进行分析总结（请仔细思考一个GPU共享的项目应该关注哪些内容，然后根据这些内容对测试结果进行分析总），总结的内容添加到文档最后，不要覆盖之前的内容
```

- 经过day4的修改，基本目标已经完成，能顾实现GPU超分、任务GPU共享（包括并行调度、串行调度），性能也符合预期，后续就是进一步实现更多的功能了，比如算力的配额管理、监控等等。


# day 5 增加内存配额控制

```
当前只支持虚拟显卡的设置，需要增加对显存的配置，即创建pod的时候，可以指定显存大小（可选，不指定就默认可使用全部显存）。当pod使用超过设置的大小时，拒绝分配显存。GPU物理显存最多可以虚拟多少显存也应该可以在device-plugin中设置。请仔细思考需求，并先完成设计方案，设计方案保存到docs/desigin下
```

```
增加一个tests/remote-test-memlimit.sh脚本来进行测试，请思考如何才能测试出效果，写入脚本
```

```
请分析日志，判断是否符合预期：pod日志[NVSHARE][DEBUG]: nvshare's cuMemGetInfo (with limit): free=276.00 MiB, total=1024.00 MiB
Traceback (most recent call last):
  File "/pytorch-add-small.py", line 51, in <module>
    y = torch.ones([n, n], dtype=torch.float32).to(device)
RuntimeError: CUDA out of memory. Tried to allocate 748.00 MiB (GPU 0; 1024.00 MiB total capacity; 748.00 MiB already allocated; 276.00 MiB free; 748.00 MiB reserved in total by PyTorch) If reserved memory is >> allocated memory try setting max_split_size_mb to avoid fragmentation.  See documentation for Memory Management and PYTORCH_CUDA_ALLOC_CONF scheduler日志：[NVSHARE][INFO]: Switch time mode: AUTO
[NVSHARE][INFO]: Scheduling mode: AUTO (default)
[NVSHARE][INFO]: Max runtime per task: 300 seconds (default)
[NVSHARE][INFO]: nvshare-scheduler listening on /var/run/nvshare/scheduler.sock
[NVSHARE][INFO]: Received REGISTER
[NVSHARE][INFO]: Created new GPU context for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e (memory: 16384 MB)
[NVSHARE][INFO]: Sent SCHED_ON to client c966db3fba54bc0d
[NVSHARE][INFO]: Registered client c966db3fba54bc0d on GPU GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e with Pod name = memlimit-test-1gi, Pod namespace = default
[NVSHARE][INFO]: Received REQ_LOCK from c966db3fba54bc0d
[NVSHARE][INFO]: Sent LOCK_OK to client c966db3fba54bc0d
[NVSHARE][INFO]: Scheduled client c966db3fba54bc0d (mem: 748 MB, total running: 748 MB)
[NVSHARE][INFO]: Removing client c966db3fba54bc0d
[NVSHARE][INFO]: Client c966db3fba54bc0d released from running_list, running_memory: 0 MB
```

# day 6实现内存配额动态调整

```
请深入分析，如果我后期想在不重启pod的情况下，动态调整分配给pod的虚拟现存，如何实现更好？是写到env中，还是写到limit中？还是写到annotation中？分析结果追加到docs/desigin/gpu_memory_quota_design.md
```

```
按annotate方案来实现
```

```
选择完整方案，然后保存plan到docs/desigin下，保存task到docs/tasks下，然后执行
```

# day 7 针对内存配额动态调整进行各项测试

```
tests/remote-test-dynamic-limit.sh在pod起来之后，运行一段时间，然后annotate为1G，然后exec到pod中，再执行一个/pytorch-add-small.py，是否可以触发oom，来验证显存配合是否生效？如何可以的话，修改测试脚本
```

```
请仔细思考，针对显存配额动态调整，设计更复杂的测试用例，比如启动多个pod在多个GPU上，验证oom场景、验证显存调大后，容器中的应用是否能申请到更多的显存，验证多个任务创建删除+反复调整，是否有会异常等等，尽可能覆盖各种情况，然后把测试计划补充到docs/verify/verify_dynamic_memory_limit.md 之后，等我涉审核后再执行
```

```
我有tests/pytorch-add.py（对应  nvshare:pytorch-add镜像），以及tests/pytorch-add.py（对应nvshare:pytorch-add-small镜像），他们两个分别使用4G和12G左右的显存。我不想再创建新镜像了，请根据上面两个已有的镜像来做为工作负载测试（也可以再pod启动后，直接exec到pod中去注入一段新的pytorch代码来执行），请根据以上现状，修改测试计划，让计划更可执行。
```

# day 8 实现GPU算力动态调整

- 正好tokens用完了，让gemini先成一个方案，然后再让opus review方案和执行

```
参考docs/design/dynamic_memory_limit_implementation.md的设计，深度、仔细思考完成对GPU算力的动态调整方案设计，保存到docs/design下
```

```
算力配额的设计，不要以时间为单位，而是要以百分比为单位，默认每个GPU分为100份，用户可以申请份额，即比例，例如用户生气 nvshare.com/gpu-core-limit=40，即他最多可以使用40%的GPU算力
```

前面做memory的时候就考虑到了并行模式，所以请按并行模式进行设计。此外，没有说清楚时间片是如何实现的，比如是要拦截cuLaunchKernel请求吗？
```

- 强行让他做并行方案
```
不要串行的方案，因为我做显存方案的时候已经考虑了并行了，现在做算力配额，又变成串行就等于退回去了。请继续完善并行方案的设计。
```

# day9 进一步优化算力配合调整的效果

- 昨天测试以后，发现效果不太准，配置80%，实际大约为40%的算力。我先用gemini3分析了下

```
经过测试发现GPU算力配额的控制偏差比较大，手动设置GPU利用率为80%，实际利用率是40%左右，我任务这是因为调度器在统计 GPU 使用时间时，错误地将“调度器睡眠的时间”全部记在了由于间歇性运行而实际上并没有全程占用 GPU 的任务头上，客户端会频繁地 **获取锁 -> 运行 -> 释放锁**。。

3. 故障复现流程

假设限制为 80% (8秒)，窗口 10秒。

1. 调度器线程决定睡眠 8 秒（因为它觉得还有 8 秒额度）。
2. 在调度器睡眠的这 8 秒钟的现实时间里，你的 Python 脚本可能进行了几百次“获取锁-释放锁”的循环。
3. **关键点：** 当调度器线程睡醒的那一瞬间（或者被信号唤醒），如果你的 Python 脚本 **恰好** 正在执行 `matmul`（即持有锁，在 `running_list` 中）。
4. 调度器执行 `Step 4` 的代码：`req->client->run_time_in_window_ms += actual_elapsed`。
5. **结果：** 调度器认为这个任务在过去的 8 秒钟里 **一直** 在运行，直接给它记了 8 秒的账！
6. 但实际上，任务可能有 70% 的时间都在 `sleep`（并未持有锁）。
7. 由于计费严重虚高，调度器误以为任务已经用完了 80% 的额度，于是立即发送 `DROP_LOCK` 进行压制（Throttle）。
8. 这就是为什么你设置了 80%，实际却跑不满的原因——调度器“以为”它跑满了。

修改方案

要解决这个问题，必须将计费逻辑从“基于调度器睡眠时长的粗略估计”改为“基于任务实际持有锁时长的精确统计”。

修改思路

1. **记录开始时间**：在任务被加入 `running_list` 时（`try_schedule`），记录当前时间戳 `last_start_ms`。
2. **精确结算**：在任务从 `running_list` 移除时（`remove_req`），计算 `now - last_start_ms` 并累加到总用时中。
3. **动态检查**：在 `timer_thr_fn` 中检查限额时，不再累加 `actual_elapsed`，而是用 `已累加时间 + (当前时间 - last_start_ms)` 来判断是否超限。
4. **窗口重置**：窗口重置时，更新所有运行中任务的 `last_start_ms` 为当前时间，防止跨窗口重复计费。
```

- 测试了下，还是不太准，提供更多的信息让gemini分析

```
我已经改成了2000，但是观察smi的输出，先配置为30%，30秒后调整当为80%时，大概每17个输出中，有12个0，剩下5个是100。所以这里有两个问题，1是并没有感到切换时间是2000ms，第二个是实际利用率大概在30%，也没达到80%。我检查了scheduler的debug日志，发现一些异常的地方，他会一会说检测到配置了30%的limit，一会又说没检测到，实际我只做了2次annotate。请结合scheduler日志进行分析：[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '30'

[NVSHARE][DEBUG]: k8s_api: Annotation 'nvshare.com/gpu-memory-limit' not found

[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '30'
[NVSHARE][INFO]: Client d3b816dfc7f9e8f6 promoted from wait queue
[NVSHARE][INFO]: Sent MEM_AVAILABLE to client d3b816dfc7f9e8f6
[NVSHARE][INFO]: Sent LOCK_OK to client d3b816dfc7f9e8f6
[NVSHARE][INFO]: Scheduled client d3b816dfc7f9e8f6 (mem: 2992 MB, total running: 2992 MB)
[NVSHARE][INFO]: Throttling client d3b816dfc7f9e8f6 (Used: 600/600 ms)
[NVSHARE][INFO]: Sent DROP_LOCK to client d3b816dfc7f9e8f6
[NVSHARE][INFO]: Received LOCK_RELEASED from d3b816dfc7f9e8f6
[NVSHARE][INFO]: Client d3b816dfc7f9e8f6 released from running_list (ran for 610 ms). Mem: 0 MB
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Received REQ_LOCK from d3b816dfc7f9e8f6
[NVSHARE][INFO]: Sent WAIT_FOR_MEM to client d3b816dfc7f9e8f6
[NVSHARE][INFO]: Client d3b816dfc7f9e8f6 moved to wait queue (req: 2992 MB, avail: 16384 MB)
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1

[NVSHARE][DEBUG]: k8s_api: Annotation 'nvshare.com/gpu-memory-limit' not found

[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '30'

[NVSHARE][DEBUG]: k8s_api: Annotation 'nvshare.com/gpu-memory-limit' not found

[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '80'
[NVSHARE][INFO]: Compute limit changed for pod default/manual-dynamic-test: 30% -> 80%
[NVSHARE][INFO]: Client d3b816dfc7f9e8f6 promoted from wait queue
[NVSHARE][INFO]: Sent MEM_AVAILABLE to client d3b816dfc7f9e8f6
[NVSHARE][INFO]: Sent LOCK_OK to client d3b816dfc7f9e8f6
[NVSHARE][INFO]: Scheduled client d3b816dfc7f9e8f6 (mem: 2992 MB, total running: 2992 MB)
[NVSHARE][INFO]: Throttling client d3b816dfc7f9e8f6 (Used: 1600/1600 ms)
[NVSHARE][INFO]: Sent DROP_LOCK to client d3b816dfc7f9e8f6
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1

[NVSHARE][DEBUG]: k8s_api: Annotation 'nvshare.com/gpu-memory-limit' not found

[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '80'
[NVSHARE][INFO]: Received LOCK_RELEASED from d3b816dfc7f9e8f6
[NVSHARE][INFO]: Client d3b816dfc7f9e8f6 released from running_list (ran for 848 ms). Mem: 0 MB
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Received REQ_LOCK from d3b816dfc7f9e8f6
[NVSHARE][INFO]: Sent LOCK_OK to client d3b816dfc7f9e8f6
[NVSHARE][INFO]: Scheduled client d3b816dfc7f9e8f6 (mem: 2992 MB, total running: 2992 MB)
[NVSHARE][INFO]: Throttling client d3b816dfc7f9e8f6 (Used: 1600/1600 ms)
[NVSHARE][INFO]: Sent DROP_LOCK to client d3b816dfc7f9e8f6
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Received LOCK_RELEASED from d3b816dfc7f9e8f6
[NVSHARE][INFO]: Client d3b816dfc7f9e8f6 released from running_list (ran for 467 ms). Mem: 0 MB
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Received REQ_LOCK from d3b816dfc7f9e8f6
[NVSHARE][INFO]: Sent LOCK_OK to client d3b816dfc7f9e8f6
[NVSHARE][INFO]: Scheduled client d3b816dfc7f9e8f6 (mem: 2992 MB, total running: 2992 MB)
[NVSHARE][INFO]: Throttling client d3b816dfc7f9e8f6 (Used: 1601/1600 ms)
[NVSHARE][INFO]: Sent DROP_LOCK to client d3b816dfc7f9e8f6
[NVSHARE][INFO]: Received LOCK_RELEASED from d3b816dfc7f9e8f6
[NVSHARE][INFO]: Client d3b816dfc7f9e8f6 released from running_list (ran for 86 ms). Mem: 0 MB
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Received REQ_LOCK from d3b816dfc7f9e8f6
[NVSHARE][INFO]: Sent WAIT_FOR_MEM to client d3b816dfc7f9e8f6
[NVSHARE][INFO]: Client d3b816dfc7f9e8f6 moved to wait queue (req: 2992 MB, avail: 16384 MB)
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1


[NVSHARE][DEBUG]: k8s_api: Annotation 'nvshare.com/gpu-memory-limit' not found

[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '80'
```

- gemini觉得是死锁了，我们按他分析的提交给AI，让AI修复代码
```
分析日志和代码后，我发现了导致“利用率低”和“控制周期不准”的 **致命原因**：**线程死锁（Lock Contention）**。

### 核心问题：网络 I/O 阻塞了全局锁

在 `src/scheduler.c` 的 `annotation_watcher_fn` 线程中，你每隔 5 秒会检查一次 K8s 注解。问题在于，代码在**持有全局互斥锁 (`global_mutex`) 的期间**执行了 `k8s_get_pod_annotation`。

```c
/* 错误代码片段 */
true_or_exit(pthread_mutex_lock(&global_mutex) == 0); // <--- 获取全局锁

LL_FOREACH(clients, client) {
  // ...
  // [严重错误] 在持有锁的情况下发起 HTTP 网络请求！
  // 这可能耗时 100ms 到 2s 不等，期间调度器完全“冻结”，
  // 无法处理 LOCK_RELEASED，也无法调度新任务。
  char* limit_str = k8s_get_pod_annotation(...); 
  // ...
}

true_or_exit(pthread_mutex_unlock(&global_mutex) == 0);

```

**现象解释：**

1. **利用率低 (30% vs 80%)**：当 `annotation_watcher` 运行时，它可能卡住调度器 1-2 秒。在这 1-2 秒内，GPU 处于空闲状态（因为调度器没法回复 `LOCK_OK`），但时间窗口（Window）还在继续流逝。这导致实际的“工作时间占比”大幅下降。
2. **周期不准**：由于调度器线程 (`timer_thr_fn`) 也需要获取 `global_mutex` 才能工作，它会被 `annotation_watcher` 阻塞，导致本该在 2000ms 触发的窗口重置被推迟。
3. **日志中的“Wait Queue”**：当任务达到限制时，它被移入 `wait_queue` 并发送 `WAIT_FOR_MEM`。这虽然语义稍有不妥（应为 `WAIT_FOR_TIME`），但在当前架构下勉强可用。主要的性能瓶颈还是在锁。

---

### 修复方案

你需要重构 `annotation_watcher_fn`，将**耗时的网络请求移出临界区（Critical Section）**。

请修改 `src/scheduler.c` 中的 `annotation_watcher_fn` 函数：

```c
/* 定义一个临时结构来存储需要查询的信息，避免长时间持有锁 */
struct client_info {
    uint64_t id;
    char pod_name[POD_NAME_LEN_MAX];
    char pod_namespace[POD_NAMESPACE_LEN_MAX];
    struct client_info *next;
};

void* annotation_watcher_fn(void* arg __attribute__((unused))) {
  log_info("Annotation watcher thread started (interval: %d sec)",
           ANNOTATION_CHECK_INTERVAL_SEC);

  while (1) {
    sleep(ANNOTATION_CHECK_INTERVAL_SEC);

    /* 1. 快速持有锁，快照一份客户端列表 */
    struct client_info *snapshot = NULL;
    struct nvshare_client* client;

    true_or_exit(pthread_mutex_lock(&global_mutex) == 0);
    LL_FOREACH(clients, client) {
      if (client->pod_name[0] != '\0' && client->pod_namespace[0] != '\0') {
          struct client_info* info = malloc(sizeof(struct client_info));
          info->id = client->id;
          strlcpy(info->pod_name, client->pod_name, sizeof(info->pod_name));
          strlcpy(info->pod_namespace, client->pod_namespace, sizeof(info->pod_namespace));
          LL_APPEND(snapshot, info);
      }
    }
    true_or_exit(pthread_mutex_unlock(&global_mutex) == 0);

    /* 2. 在不持有锁的情况下，慢速进行网络查询 */
    struct client_info *info, *tmp;
    LL_FOREACH_SAFE(snapshot, info, tmp) {
        // --- 网络 I/O (耗时操作) ---
        char* mem_limit_str = k8s_get_pod_annotation(
            info->pod_namespace, info->pod_name, MEMORY_LIMIT_ANNOTATION);
        
        char* core_limit_str = k8s_get_pod_annotation(
            info->pod_namespace, info->pod_name, CORE_LIMIT_ANNOTATION);
        
        // --- 再次持有锁，快速更新状态 ---
        true_or_exit(pthread_mutex_lock(&global_mutex) == 0);
        
        // 必须重新查找客户端，因为在释放锁期间它可能已经断开连接
        struct nvshare_client* target_client = NULL;
        LL_FOREACH(clients, client) {
            if (client->id == info->id) {
                target_client = client;
                break;
            }
        }

        if (target_client) {
            // 更新 Memory Limit
            if (mem_limit_str) {
                size_t new_limit = parse_memory_size(mem_limit_str);
                if (new_limit > 0 && new_limit != target_client->memory_limit) {
                     log_info("Memory limit changed for pod %s/%s: %zu -> %zu bytes",
                         target_client->pod_namespace, target_client->pod_name, 
                         target_client->memory_limit, new_limit);
                     target_client->memory_limit = new_limit;
                     send_update_limit(target_client, new_limit);
                }
            }

            // 更新 Core Limit
            int new_core_limit = 100;
            if (core_limit_str) {
                int val = atoi(core_limit_str);
                if (val >= 1 && val <= 100) new_core_limit = val;
            }
            
            if (new_core_limit != target_client->core_limit) {
                log_info("Compute limit changed for pod %s/%s: %d%% -> %d%%",
                     target_client->pod_namespace, target_client->pod_name, 
                     target_client->core_limit, new_core_limit);
                target_client->core_limit = new_core_limit;
                // 唤醒 Timer 进行重算
                if (target_client->is_running && target_client->context) {
                    pthread_cond_broadcast(&target_client->context->timer_cv);
                }
            }
        }
        
        true_or_exit(pthread_mutex_unlock(&global_mutex) == 0);

        if (mem_limit_str) free(mem_limit_str);
        if (core_limit_str) free(core_limit_str);
        
        LL_DELETE(snapshot, info);
        free(info);
    }
  }
  return NULL;
}

```

### 其他修正建议

除了上面的死锁修复，为了让 `wait_queue` 的逻辑更顺畅，建议在 `try_schedule` 中，如果是因为 Compute Limit 而不能运行，不要将其加入通用的 `wait_queue` (这会触发 `WAIT_FOR_MEM` 消息)，而是应该保持在 `requests` 队列中但暂时跳过，或者增加一个专门的 `pending_limit_queue`。

**简易优化 (无需大改结构)**：
在 `try_schedule` 中，如果 `can_run` 返回 0 是因为 Compute Limit，我们**不发送** `WAIT_FOR_MEM`，而是让它留在 `wait_queue` 里静默等待。

修改 `move_to_wait_queue`:

```c
static void move_to_wait_queue(struct gpu_context* ctx,
                               struct nvshare_request* req) {
  // ... (添加到 wait_queue 的代码不变)

  // 修改：只有在内存不足时才发送 WAIT_FOR_MEM
  // 如果是因为算力限制，我们不需要客户端做什么，只需要它在服务端排队
  if (req->client->core_limit < 100 && req->client->is_throttled) {
      // 算力超限，静默等待窗口重置
      log_debug("Client %016" PRIx64 " moved to wait queue (throttled)", req->client->id);
  } else {
      // 内存不足，通知客户端
      out_msg.type = WAIT_FOR_MEM;
      send_message(req->client, &out_msg);
      log_info("Client %016" PRIx64 " moved to wait queue (wait for mem)", req->client->id);
  }
}

```

*(注意：需要修改 `check_and_reset_window` 以确保重置时能从 wait_queue 捞回这些任务)*

但最优先的，请先应用 **`annotation_watcher_fn` 的锁优化**。这应该能立刻解决你观察到的利用率低和波动大的问题。
```

```
我测试了GPU算力动态调整，例如我设置为30%，我发现实际从nvidia-smi dmon 看到的算力大概10%左右，差距比较大，我查看了scheduler日志如下，请结合日志分析原因。[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '30'
[NVSHARE][INFO]: Client c52c387e24e4f68d promoted from wait queue
[NVSHARE][INFO]: Sent MEM_AVAILABLE to client c52c387e24e4f68d
[NVSHARE][INFO]: Sent LOCK_OK to client c52c387e24e4f68d
[NVSHARE][INFO]: Scheduled client c52c387e24e4f68d (mem: 2992 MB, total running: 2992 MB)
[NVSHARE][INFO]: Throttling client c52c387e24e4f68d (Used: 600/600 ms)
[NVSHARE][INFO]: Sent DROP_LOCK to client c52c387e24e4f68d
[NVSHARE][INFO]: Received LOCK_RELEASED from c52c387e24e4f68d
[NVSHARE][INFO]: Client c52c387e24e4f68d released from running_list (ran for 590 ms). Mem: 0 MB
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Received REQ_LOCK from c52c387e24e4f68d
[NVSHARE][DEBUG]: Client c52c387e24e4f68d moved to wait queue (throttled)
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1

[NVSHARE][DEBUG]: k8s_api: Annotation 'nvshare.com/gpu-memory-limit' not found

[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '30'
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e

[NVSHARE][DEBUG]: k8s_api: Annotation 'nvshare.com/gpu-memory-limit' not found

[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '30'
[NVSHARE][INFO]: Client c52c387e24e4f68d promoted from wait queue
[NVSHARE][INFO]: Sent MEM_AVAILABLE to client c52c387e24e4f68d
[NVSHARE][INFO]: Sent LOCK_OK to client c52c387e24e4f68d
[NVSHARE][INFO]: Scheduled client c52c387e24e4f68d (mem: 2992 MB, total running: 2992 MB)
[NVSHARE][INFO]: Throttling client c52c387e24e4f68d (Used: 600/600 ms)
[NVSHARE][INFO]: Sent DROP_LOCK to client c52c387e24e4f68d
[NVSHARE][INFO]: Received LOCK_RELEASED from c52c387e24e4f68d
[NVSHARE][INFO]: Client c52c387e24e4f68d released from running_list (ran for 608 ms). Mem: 0 MB
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Received REQ_LOCK from c52c387e24e4f68d
[NVSHARE][DEBUG]: Client c52c387e24e4f68d moved to wait queue (throttled)
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1

[NVSHARE][DEBUG]: k8s_api: Annotation 'nvshare.com/gpu-memory-limit' not found

[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '30'
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e

[NVSHARE][DEBUG]: k8s_api: Annotation 'nvshare.com/gpu-memory-limit' not found

[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '30'
[NVSHARE][INFO]: Client c52c387e24e4f68d promoted from wait queue
[NVSHARE][INFO]: Sent MEM_AVAILABLE to client c52c387e24e4f68d
[NVSHARE][INFO]: Sent LOCK_OK to client c52c387e24e4f68d
[NVSHARE][INFO]: Scheduled client c52c387e24e4f68d (mem: 2992 MB, total running: 2992 MB)

[NVSHARE][DEBUG]: k8s_api: Annotation 'nvshare.com/gpu-memory-limit' not found

[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '30'
[NVSHARE][INFO]: Throttling client c52c387e24e4f68d (Used: 600/600 ms)
[NVSHARE][INFO]: Sent DROP_LOCK to client c52c387e24e4f68d
[NVSHARE][INFO]: Received LOCK_RELEASED from c52c387e24e4f68d
[NVSHARE][INFO]: Client c52c387e24e4f68d released from running_list (ran for 608 ms). Mem: 0 MB
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Received REQ_LOCK from c52c387e24e4f68d
[NVSHARE][DEBUG]: Client c52c387e24e4f68d moved to wait queue (throttled)
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
```

- 单任务已经比较准确，多任务不太准，继续调试

```
目前单任务已经比较准确，但是我运行2个任务，调度到一个GPU上，其中一个设置为50%，一个60%，但是从smi看，总体利用率还不到70%。scheduler日志如下：[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][INFO]: Received REQ_LOCK from 45da6e976b9e8441
[NVSHARE][DEBUG]: Client 45da6e976b9e8441 moved to wait queue (throttled)
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e

[NVSHARE][DEBUG]: k8s_api: Annotation 'nvshare.com/gpu-memory-limit' not found

[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '50'

[NVSHARE][DEBUG]: k8s_api: Annotation 'nvshare.com/gpu-memory-limit' not found

[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '60'
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Client 4fa456c56d448997 promoted from wait queue
[NVSHARE][INFO]: Sent MEM_AVAILABLE to client 4fa456c56d448997
[NVSHARE][INFO]: Sent LOCK_OK to client 4fa456c56d448997
[NVSHARE][INFO]: Scheduled client 4fa456c56d448997 (mem: 2992 MB, total running: 2992 MB)
[NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
[NVSHARE][INFO]: Client 45da6e976b9e8441 promoted from wait queue
[NVSHARE][INFO]: Sent MEM_AVAILABLE to client 45da6e976b9e8441
[NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
[NVSHARE][INFO]: Sent LOCK_OK to client 45da6e976b9e8441
[NVSHARE][INFO]: Scheduled client 45da6e976b9e8441 (mem: 2992 MB, total running: 5984 MB)
[NVSHARE][INFO]: Throttling client 45da6e976b9e8441 (Used: 1000/1000 ms)
[NVSHARE][INFO]: Sent DROP_LOCK to client 45da6e976b9e8441
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][INFO]: Received LOCK_RELEASED from 45da6e976b9e8441
[NVSHARE][INFO]: Client 45da6e976b9e8441 released from running_list (ran for 263 ms). Mem: 2992 MB
[NVSHARE][INFO]: Received REQ_LOCK from 45da6e976b9e8441
[NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
[NVSHARE][INFO]: Sent LOCK_OK to client 45da6e976b9e8441
[NVSHARE][INFO]: Scheduled client 45da6e976b9e8441 (mem: 2992 MB, total running: 5984 MB)
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Throttling client 45da6e976b9e8441 (Used: 1000/1000 ms)
[NVSHARE][INFO]: Sent DROP_LOCK to client 45da6e976b9e8441
[NVSHARE][INFO]: Throttling client 4fa456c56d448997 (Used: 1202/1200 ms)
[NVSHARE][INFO]: Sent DROP_LOCK to client 4fa456c56d448997
[NVSHARE][INFO]: Received LOCK_RELEASED from 45da6e976b9e8441
[NVSHARE][INFO]: Client 45da6e976b9e8441 released from running_list (ran for 607 ms). Mem: 2992 MB
[NVSHARE][INFO]: Received REQ_LOCK from 45da6e976b9e8441
[NVSHARE][DEBUG]: Client 45da6e976b9e8441 moved to wait queue (throttled)
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][INFO]: Received LOCK_RELEASED from 4fa456c56d448997
[NVSHARE][INFO]: Client 4fa456c56d448997 released from running_list (ran for 418 ms). Mem: 0 MB
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][INFO]: Received REQ_LOCK from 4fa456c56d448997
[NVSHARE][DEBUG]: Client 4fa456c56d448997 moved to wait queue (throttled)
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e

[NVSHARE][DEBUG]: k8s_api: Annotation 'nvshare.com/gpu-memory-limit' not found

[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '50' 请分析原因
```

```
opus分析原因的：根本原因分析
问题核心：时分复用模式下的独立节流导致GPU空闲
从日志和代码分析，问题在于：

1. 两个客户端是同时运行的（并发模式）
[NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
因为内存足够，调度器允许两个任务同时运行。

2. 但节流是独立计算的
每个客户端有自己的配额（在2000ms窗口内）：

客户端1 (50%): 允许运行 1000ms
客户端2 (60%): 允许运行 1200ms
```
- 这里不太好实现，我自己也没想清楚，于是让gemini和opus分别生成了一个方案


```
如果按1做，串行模式下，具体怎么控制时间片呢？请补充说明几个方案的具体实现方式，方案写到docs/design/concurrent_compute_limit_optimization_opus.md中，先不要执行方案
```

- 我自己review了下2个方案，我觉得gemni的方案看上去更靠谱，所以我让opus review geimini的方案，并让他给出评价和对比分析
```
请分析docs/design/concurrent_compute_limit_optimization.md中提到的“加权计费”方案可行性，和你的方案做个对比，分析结果保存到docs/design/concurrent_compute_limit_optimization.md最后。
```

- opus觉得gemini的方案确实挺好，比较好实现，但是他提出一些问题。下面是我自己想的进一步改进方案。

```
超配场景下，是不是做个等比例缩放就行，比如一个周期内，检测到超配合了，加起来是160，那么统一缩小1.6.然后按gemini的加权方式执行。下一个周期也要重新计算下加起来的总和是否超配，以及是否需要缩放。这样是不是更简单一些，也解决了超配问题。
```

- opus的回复，情绪价值给足
```
您的想法非常棒！这是一个更优雅的方案。让我分析一下：

等比例缩放 + 加权计费方案
核心逻辑
1. 每个窗口开始时，计算 total_quota = Σ(所有客户端配额)
2. 如果 total_quota > 100%，计算缩放因子 scale = 100 / total_quota
3. 每个客户端的有效配额 = 原始配额 × scale
4. 计费时使用加权计费（÷ 并发数）
场景验证
场景：A(80%) + B(80%) = 160%

缩放因子 = 100 / 160 = 0.625
A 有效配额 = 80% × 0.625 = 50% → 1000ms
B 有效配额 = 80% × 0.625 = 50% → 1000ms
执行（加权计费）：
T=0~2000ms: A和B同时运行
- A 计费: 2000 / 2 = 1000ms ✓ 恰好用完配额
- B 计费: 2000 / 2 = 1000ms ✓ 恰好用完配额
GPU利用率: 100% ✓
比例公平: A:B = 50:50 = 80:80 ✓
实现（~15行额外代码）
c
/* 计算缩放后的有效配额（毫秒） */
static long get_effective_quota_ms(struct gpu_context* ctx, 
                                    struct nvshare_client* c) {
    int total_quota = calculate_total_quota(ctx);
    long base_quota_ms = (long)COMPUTE_WINDOW_SIZE_MS * c->core_limit / 100;
    
    if (total_quota <= 100) {
        return base_quota_ms;  /* 不超配，原样返回 */
    }
    
    /* 超配：等比例缩放 */
    return base_quota_ms * 100 / total_quota;
}
然后在计费逻辑中使用 get_effective_quota_ms() 替代原来的固定配额计算。

优势
方面	分析
简洁性	✓ 只需一个缩放函数，无需切换调度模式
公平性	✓ 保持原始配额比例（80:80 = 50:50）
利用率	✓ 配额正好等于100%，GPU满载
向后兼容	✓ 不超配时行为不变
语义清晰	⚠️ 需要文档说明"超配时按比例缩放"
结论
这个方案确实更简单、更优雅，结合了：

Gemini的加权计费（解决并发计费问题）
您的等比例缩放（解决超配问题）
实现改动约30-40行代码，逻辑清晰，推荐采用！要我更新设计文档并开始实现吗？
```

- 还是有一些问题，继续调试

```
脚本用的是pytorch-add-small，调度器头100行日志查不到相关信息，任务日志root@lgy-test-gpu:~# kubectl logs complex-test-2 | grep -i nvshare | head -100
[NVSHARE][DEBUG]: Failed to find nvmlDeviceGetHandleByUUID_v2, falling back to nvmlDeviceGetHandleByUUID
[NVSHARE][DEBUG]: Found NVML
[NVSHARE][DEBUG]: NVSHARE_POD_NAME = complex-test-2
[NVSHARE][DEBUG]: NVSHARE_POD_NAMESPACE = default
[NVSHARE][DEBUG]: Sent REGISTER
[NVSHARE][DEBUG]: Received SCHED_ON
[NVSHARE][INFO]: Successfully initialized nvshare GPU
[NVSHARE][INFO]: Client ID = dd39394e4ca0454f
[NVSHARE][DEBUG]: real_cuMemGetInfo returned free=13904.81 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: nvshare's cuMemGetInfo returning free=13377.69 MiB, total=14913.69 MiB
[NVSHARE][DEBUG]: cuMemAlloc requested 784334848 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 784334848 bytes at 0x7fe58c000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 748.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 748 MB
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Reset preferred location for 1 allocations
[NVSHARE][DEBUG]: cuMemAlloc requested 784334848 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 784334848 bytes at 0x7fe55c000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 1496.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 1496 MB
[NVSHARE][INFO][2026-02-06 10:46:19]   0%|          | 0/40000 [00:00<?, ?it/s][NVSHARE][DEBUG]: cuMemAlloc requested 784334848 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 784334848 bytes at 0x7fe52c000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 2244.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 2244 MB
[NVSHARE][DEBUG]: cuMemAlloc requested 784334848 bytes
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 784334848 bytes at 0x7fe4fc000000
[NVSHARE][DEBUG]: Total allocated memory on GPU is 2992.00 MiB
[NVSHARE][DEBUG]: Reported memory usage: 2992 MB
[NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
[NVSHARE][INFO][2026-02-06 10:46:20]   0%|          | 64/40000 [00:00<07:43, 86.11it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
[NVSHARE][INFO][2026-02-06 10:46:21]   0%|          | 192/40000 [00:01<06:45, 98.27it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
[NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][INFO][2026-02-06 10:46:24]   1%|          | 448/40000 [00:04<06:28, 101.69it/s][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Reset preferred location for 4 allocations
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
[NVSHARE][INFO][2026-02-06 10:46:24]   1%|          | 462/40000 [00:04<06:28, 101.73it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
[NVSHARE][INFO][2026-02-06 10:46:24]   1%|          | 478/40000 [00:04<06:28, 101.84it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
[NVSHARE][INFO][2026-02-06 10:46:24]   1%|▏         | 510/40000 [00:05<06:26, 102.09it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
[NVSHARE][INFO][2026-02-06 10:46:25]   1%|▏         | 574/40000 [00:05<06:24, 102.51it/s][NVSHARE][WARN]: Unknown message type (11)
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Reset preferred location for 4 allocations
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
[NVSHARE][INFO][2026-02-06 10:46:27]   1%|▏         | 585/40000 [00:07<15:21, 42.77it/s] [NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
[NVSHARE][INFO][2026-02-06 10:46:27]   2%|▏         | 604/40000 [00:07<14:08, 46.41it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
[NVSHARE][INFO][2026-02-06 10:46:28]   2%|▏         | 636/40000 [00:08<11:58, 54.77it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
[NVSHARE][INFO][2026-02-06 10:46:28]   2%|▏         | 700/40000 [00:08<09:28, 69.12it/s][NVSHARE][WARN]: Unknown message type (11)
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Reset preferred location for 4 allocations
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
[NVSHARE][INFO][2026-02-06 10:46:30]   2%|▏         | 710/40000 [00:10<20:42, 31.62it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
[NVSHARE][INFO][2026-02-06 10:46:30]   2%|▏         | 730/40000 [00:11<17:58, 36.41it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
[NVSHARE][INFO][2026-02-06 10:46:31]   2%|▏         | 762/40000 [00:11<14:15, 45.87it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
[NVSHARE][INFO][2026-02-06 10:46:31]   2%|▏         | 826/40000 [00:12<10:28, 62.38it/s][NVSHARE][WARN]: Unknown message type (11)
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Reset preferred location for 4 allocations
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
[NVSHARE][INFO][2026-02-06 10:46:33]   2%|▏         | 835/40000 [00:14<22:34, 28.92it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
[NVSHARE][INFO][2026-02-06 10:46:34]   2%|▏         | 856/40000 [00:14<19:03, 34.25it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
[NVSHARE][INFO][2026-02-06 10:46:34]   2%|▏         | 888/40000 [00:14<14:50, 43.93it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
[NVSHARE][INFO][2026-02-06 10:46:35]   2%|▏         | 952/40000 [00:15<10:41, 60.89it/s][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Reset preferred location for 4 allocations
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
[NVSHARE][INFO][2026-02-06 10:46:35]   2%|▏         | 966/40000 [00:15<10:06, 64.35it/s][NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
[NVSHARE][INFO][2026-02-06 10:46:35]   2%|▏         | 982/40000 [00:15<09:25, 68.94it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
[NVSHARE][INFO][2026-02-06 10:46:35]   3%|▎         | 1014/40000 [00:15<08:22, 77.61it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
[NVSHARE][INFO][2026-02-06 10:46:36]   3%|▎         | 1078/40000 [00:16<07:20, 88.39it/s][NVSHARE][WARN]: Unknown message type (11)
[NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][DEBUG]: Reset preferred location for 4 allocations
[NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
[NVSHARE][INFO][2026-02-06 10:46:38]   3%|▎         | 1088/40000 [00:18<19:45, 32.83it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
[NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
[NVSHARE][INFO][2026-02-06 10:46:38]   3%|▎         | 1108/40000 [00:18<17:00, 38.10it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
[NVSHARE][INFO][2026-02-06 10:46:38]   3%|▎         | 1140/40000 [00:19<13:24, 48.30it/s][NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
[NVSHARE][INFO][2026-02-06 10:46:39]   3%|▎         | 1204/40000 [00:19<09:54, 65.28it/s][NVSHARE][WARN]: Unknown message type (11)
[NVSHARE][DEBUG]: Received LOCK_OK 任务完成的用时大概14.6分钟（我用100%算力跑的时候6.5分钟）所以实际算力大概是接近一半
```

# day 9 继续解决配额不准的问题

```
我测试各种用例，包括2个任务调度到2个GPU、调度到同一GPU，配置算力配额25%、50%、75%等场景，都基本符合预期，但是有个用例明显不符合预期，这个用例是这样的，我创建了2个任务（tests/pytorch-add-small.py），调度到了2个GPU上，我设置其中一个配额是30%，另一个配额是60%，但是我发现实际两个的速度基本完全一致，实际配额接近50%左右。scheduler日志如下，请分析原因：[NVSHARE][INFO]: Scheduled client 475a7dcc722e64ad (mem: 2992 MB, total running: 2992 MB)

[NVSHARE][DEBUG]: k8s_api: Annotation 'nvshare.com/gpu-memory-limit' not found

[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '30'

[NVSHARE][DEBUG]: k8s_api: Annotation 'nvshare.com/gpu-memory-limit' not found

[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '60'
[NVSHARE][INFO]: Throttling client fcce2b4f55cf5fb1 (Used: 1200/1200 ms, weighted)
[NVSHARE][INFO]: Sent DROP_LOCK to client fcce2b4f55cf5fb1
[NVSHARE][INFO]: Received LOCK_RELEASED from fcce2b4f55cf5fb1
[NVSHARE][DEBUG]: Weighted billing: wall 28 ms / 1 concurrent = 28 ms billed
[NVSHARE][INFO]: Client fcce2b4f55cf5fb1 released from running_list (ran for 28 ms). Mem: 0 MB
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Received REQ_LOCK from fcce2b4f55cf5fb1
[NVSHARE][DEBUG]: Client fcce2b4f55cf5fb1 moved to wait queue (throttled)
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Throttling client 475a7dcc722e64ad (Used: 600/600 ms, weighted)
[NVSHARE][INFO]: Sent DROP_LOCK to client 475a7dcc722e64ad
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][INFO]: Received LOCK_RELEASED from 475a7dcc722e64ad
[NVSHARE][DEBUG]: Weighted billing: wall 88 ms / 1 concurrent = 88 ms billed
[NVSHARE][INFO]: Client 475a7dcc722e64ad released from running_list (ran for 88 ms). Mem: 0 MB
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][INFO]: Received REQ_LOCK from 475a7dcc722e64ad
[NVSHARE][INFO]: Sent LOCK_OK to client 475a7dcc722e64ad
[NVSHARE][INFO]: Scheduled client 475a7dcc722e64ad (mem: 2992 MB, total running: 2992 MB)
[NVSHARE][INFO]: Throttling client 475a7dcc722e64ad (Used: 601/600 ms, weighted)
[NVSHARE][INFO]: Sent DROP_LOCK to client 475a7dcc722e64ad
[NVSHARE][INFO]: Received LOCK_RELEASED from 475a7dcc722e64ad
[NVSHARE][DEBUG]: Weighted billing: wall 88 ms / 1 concurrent = 88 ms billed
[NVSHARE][INFO]: Client 475a7dcc722e64ad released from running_list (ran for 88 ms). Mem: 0 MB
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][INFO]: Received REQ_LOCK from 475a7dcc722e64ad
[NVSHARE][DEBUG]: Client 475a7dcc722e64ad moved to wait queue (throttled)
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][INFO]: Client fcce2b4f55cf5fb1 promoted from wait queue
[NVSHARE][INFO]: Sent MEM_AVAILABLE to client fcce2b4f55cf5fb1
[NVSHARE][INFO]: Sent LOCK_OK to client fcce2b4f55cf5fb1
[NVSHARE][INFO]: Scheduled client fcce2b4f55cf5fb1 (mem: 2992 MB, total running: 2992 MB)
[NVSHARE][INFO]: Throttling client fcce2b4f55cf5fb1 (Used: 1200/1200 ms, weighted)
[NVSHARE][INFO]: Sent DROP_LOCK to client fcce2b4f55cf5fb1
[NVSHARE][INFO]: Received LOCK_RELEASED from fcce2b4f55cf5fb1
[NVSHARE][DEBUG]: Weighted billing: wall 9 ms / 1 concurrent = 9 ms billed
[NVSHARE][INFO]: Client fcce2b4f55cf5fb1 released from running_list (ran for 9 ms). Mem: 0 MB
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Received REQ_LOCK from fcce2b4f55cf5fb1
[NVSHARE][DEBUG]: Client fcce2b4f55cf5fb1 moved to wait queue (throttled)
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Client 475a7dcc722e64ad promoted from wait queue
[NVSHARE][INFO]: Sent MEM_AVAILABLE to client 475a7dcc722e64ad
[NVSHARE][INFO]: Sent LOCK_OK to client 475a7dcc722e64ad
[NVSHARE][INFO]: Scheduled client 475a7dcc722e64ad (mem: 2992 MB, total running: 2992 MB)
[NVSHARE][INFO]: Throttling client 475a7dcc722e64ad (Used: 600/600 ms, weighted)
[NVSHARE][INFO]: Sent DROP_LOCK to client 475a7dcc722e64ad
[NVSHARE][INFO]: Received LOCK_RELEASED from 475a7dcc722e64ad
[NVSHARE][DEBUG]: Weighted billing: wall 610 ms / 1 concurrent = 610 ms billed
[NVSHARE][INFO]: Client 475a7dcc722e64ad released from running_list (ran for 610 ms). Mem: 0 MB
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][INFO]: Received REQ_LOCK from 475a7dcc722e64ad
[NVSHARE][DEBUG]: Client 475a7dcc722e64ad moved to wait queue (throttled)
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e

[NVSHARE][DEBUG]: k8s_api: Annotation 'nvshare.com/gpu-memory-limit' not found

[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '30'

[NVSHARE][DEBUG]: k8s_api: Annotation 'nvshare.com/gpu-memory-limit' not found

[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '60'
[NVSHARE][INFO]: Client fcce2b4f55cf5fb1 promoted from wait queue
[NVSHARE][INFO]: Sent MEM_AVAILABLE to client fcce2b4f55cf5fb1
[NVSHARE][INFO]: Sent LOCK_OK to client fcce2b4f55cf5fb1
[NVSHARE][INFO]: Scheduled client fcce2b4f55cf5fb1 (mem: 2992 MB, total running: 2992 MB)
[NVSHARE][INFO]: Throttling client fcce2b4f55cf5fb1 (Used: 1200/1200 ms, weighted)
[NVSHARE][INFO]: Sent DROP_LOCK to client fcce2b4f55cf5fb1
[NVSHARE][INFO]: Received LOCK_RELEASED from fcce2b4f55cf5fb1
[NVSHARE][DEBUG]: Weighted billing: wall 10 ms / 1 concurrent = 10 ms billed
[NVSHARE][INFO]: Client fcce2b4f55cf5fb1 released from running_list (ran for 10 ms). Mem: 0 MB
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Received REQ_LOCK from fcce2b4f55cf5fb1
[NVSHARE][DEBUG]: Client fcce2b4f55cf5fb1 moved to wait queue (throttled)
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Client 475a7dcc722e64ad promoted from wait queue
[NVSHARE][INFO]: Sent MEM_AVAILABLE to client 475a7dcc722e64ad
[NVSHARE][INFO]: Sent LOCK_OK to client 475a7dcc722e64ad
[NVSHARE][INFO]: Scheduled client 475a7dcc722e64ad (mem: 2992 MB, total running: 2992 MB)
[NVSHARE][INFO]: Throttling client 475a7dcc722e64ad (Used: 601/600 ms, weighted)
[NVSHARE][INFO]: Sent DROP_LOCK to client 475a7dcc722e64ad
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][INFO]: Received LOCK_RELEASED from 475a7dcc722e64ad
[NVSHARE][DEBUG]: Weighted billing: wall 117 ms / 1 concurrent = 117 ms billed
[NVSHARE][INFO]: Client 475a7dcc722e64ad released from running_list (ran for 117 ms). Mem: 0 MB
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][INFO]: Received REQ_LOCK from 475a7dcc722e64ad
[NVSHARE][INFO]: Sent LOCK_OK to client 475a7dcc722e64ad
[NVSHARE][INFO]: Scheduled client 475a7dcc722e64ad (mem: 2992 MB, total running: 2992 MB)
[NVSHARE][INFO]: Throttling client 475a7dcc722e64ad (Used: 600/600 ms, weighted)
[NVSHARE][INFO]: Sent DROP_LOCK to client 475a7dcc722e64ad
[NVSHARE][INFO]: Received LOCK_RELEASED from 475a7dcc722e64ad
[NVSHARE][DEBUG]: Weighted billing: wall 117 ms / 1 concurrent = 117 ms billed
[NVSHARE][INFO]: Client 475a7dcc722e64ad released from running_list (ran for 117 ms). Mem: 0 MB
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][INFO]: Received REQ_LOCK from 475a7dcc722e64ad
[NVSHARE][DEBUG]: Client 475a7dcc722e64ad moved to wait queue (throttled)
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][INFO]: Client fcce2b4f55cf5fb1 promoted from wait queue
[NVSHARE][INFO]: Sent MEM_AVAILABLE to client fcce2b4f55cf5fb1
[NVSHARE][INFO]: Sent LOCK_OK to client fcce2b4f55cf5fb1
[NVSHARE][INFO]: Scheduled client fcce2b4f55cf5fb1 (mem: 2992 MB, total running: 2992 MB)
[NVSHARE][INFO]: Throttling client fcce2b4f55cf5fb1 (Used: 1200/1200 ms, weighted)
[NVSHARE][INFO]: Sent DROP_LOCK to client fcce2b4f55cf5fb1
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Received LOCK_RELEASED from fcce2b4f55cf5fb1
[NVSHARE][DEBUG]: Weighted billing: wall 9 ms / 1 concurrent = 9 ms billed
[NVSHARE][INFO]: Client fcce2b4f55cf5fb1 released from running_list (ran for 9 ms). Mem: 0 MB
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Received REQ_LOCK from fcce2b4f55cf5fb1
[NVSHARE][INFO]: Sent LOCK_OK to client fcce2b4f55cf5fb1
[NVSHARE][INFO]: Scheduled client fcce2b4f55cf5fb1 (mem: 2992 MB, total running: 2992 MB)

[NVSHARE][DEBUG]: k8s_api: Annotation 'nvshare.com/gpu-memory-limit' not found

[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '30'

[NVSHARE][DEBUG]: k8s_api: Annotation 'nvshare.com/gpu-memory-limit' not found

[NVSHARE][DEBUG]: k8s_api: Found annotation 'nvshare.com/gpu-core-limit': '60'
[NVSHARE][INFO]: Client 475a7dcc722e64ad promoted from wait queue
[NVSHARE][INFO]: Sent MEM_AVAILABLE to client 475a7dcc722e64ad
[NVSHARE][INFO]: Sent LOCK_OK to client 475a7dcc722e64ad
[NVSHARE][INFO]: Scheduled client 475a7dcc722e64ad (mem: 2992 MB, total running: 2992 MB)
[NVSHARE][INFO]: Throttling client fcce2b4f55cf5fb1 (Used: 1200/1200 ms, weighted)
[NVSHARE][INFO]: Sent DROP_LOCK to client fcce2b4f55cf5fb1
[NVSHARE][INFO]: Received LOCK_RELEASED from fcce2b4f55cf5fb1
[NVSHARE][DEBUG]: Weighted billing: wall 29 ms / 1 concurrent = 29 ms billed
[NVSHARE][INFO]: Client fcce2b4f55cf5fb1 released from running_list (ran for 29 ms). Mem: 0 MB
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Received REQ_LOCK from fcce2b4f55cf5fb1
[NVSHARE][DEBUG]: Client fcce2b4f55cf5fb1 moved to wait queue (throttled)
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Throttling client 475a7dcc722e64ad (Used: 600/600 ms, weighted)
[NVSHARE][INFO]: Sent DROP_LOCK to client 475a7dcc722e64ad
[NVSHARE][INFO]: Received LOCK_RELEASED from 475a7dcc722e64ad
[NVSHARE][DEBUG]: Weighted billing: wall 610 ms / 1 concurrent = 610 ms billed
[NVSHARE][INFO]: Client 475a7dcc722e64ad released from running_list (ran for 610 ms). Mem: 0 MB
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][INFO]: Received REQ_LOCK from 475a7dcc722e64ad
[NVSHARE][DEBUG]: Client 475a7dcc722e64ad moved to wait queue (throttled)
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
[NVSHARE][INFO]: Client fcce2b4f55cf5fb1 promoted from wait queue
[NVSHARE][INFO]: Sent MEM_AVAILABLE to client fcce2b4f55cf5fb1
[NVSHARE][INFO]: Sent LOCK_OK to client fcce2b4f55cf5fb1
[NVSHARE][INFO]: Scheduled client fcce2b4f55cf5fb1 (mem: 2992 MB, total running: 2992 MB)
[NVSHARE][INFO]: Client 475a7dcc722e64ad promoted from wait queue
[NVSHARE][INFO]: Sent MEM_AVAILABLE to client 475a7dcc722e64ad
[NVSHARE][INFO]: Sent LOCK_OK to client 475a7dcc722e64ad
[NVSHARE][INFO]: Scheduled client 475a7dcc722e64ad (mem: 2992 MB, total running: 2992 MB)
[NVSHARE][INFO]: Throttling client fcce2b4f55cf5fb1 (Used: 1200/1200 ms, weighted)
[NVSHARE][INFO]: Sent DROP_LOCK to client fcce2b4f55cf5fb1
[NVSHARE][INFO]: Received LOCK_RELEASED from fcce2b4f55cf5fb1
[NVSHARE][DEBUG]: Weighted billing: wall 9 ms / 1 concurrent = 9 ms billed
[NVSHARE][INFO]: Client fcce2b4f55cf5fb1 released from running_list (ran for 9 ms). Mem: 0 MB
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Received REQ_LOCK from fcce2b4f55cf5fb1
[NVSHARE][DEBUG]: Client fcce2b4f55cf5fb1 moved to wait queue (throttled)
[NVSHARE][DEBUG]: try_schedule() called with no pending requests for UUID GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
[NVSHARE][INFO]: Throttling client 475a7dcc722e64ad (Used: 600/600 ms, weighted)
[NVSHARE][INFO]: Sent DROP_LOCK to client 47root@lgy-test-gpu:~#
```

```
刚才的日志找不到了，我重新截取了一段，首先是30% 任务的日志：root@lgy-test-gpu:~# kubectl logs  complex-test-1 --timestamps | grep -E "(DROP_LOCK|LOCK_RELEASED|LOCK_OK|Pending Kernel)" | head -50
2026-02-07T22:38:31.742017729+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
2026-02-07T22:38:33.385463214+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 128 (warmup=1).
[NVSHARE][INFO][2026-02-07 14:38:33]   0%|          | 64/40000 [00:00<07:33, 88.05it/s][NVSHARE][DEBUG]: Pending Kernel Window is 256 (warmup=1).
[NVSHARE][INFO][2026-02-07 14:38:34]   0%|          | 192/40000 [00:01<06:42, 98.92it/s][NVSHARE][DEBUG]: Pending Kernel Window is 512 (warmup=1).
[NVSHARE][INFO][2026-02-07 14:38:37]   1%|          | 448/40000 [00:04<06:28, 101.92it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-07T22:38:42.050897661+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
2026-02-07T22:38:42.050921139+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-07T22:38:42.050925331+08:00 [NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-07T22:38:42.050928344+08:00 [NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-07T22:38:42.050930778+08:00 [NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-07T22:38:44.058952608+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
2026-02-07T22:38:44.077807073+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
2026-02-07T22:38:44.115309671+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
[NVSHARE][INFO][2026-02-07 14:38:44]   2%|▏         | 971/40000 [00:11<08:37, 75.46it/s] [NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
2026-02-07T22:38:44.341705629+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
[NVSHARE][INFO][2026-02-07 14:38:44]   2%|▏         | 990/40000 [00:11<08:34, 75.82it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
[NVSHARE][INFO][2026-02-07 14:38:44]   3%|▎         | 1022/40000 [00:11<08:20, 77.94it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-07T22:38:45.269695061+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
2026-02-07T22:38:45.269729223+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-07T22:38:47.273003016+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
2026-02-07T22:38:47.291867023+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
2026-02-07T22:38:47.329299219+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
[NVSHARE][INFO][2026-02-07 14:38:47]   3%|▎         | 1095/40000 [00:14<13:54, 46.61it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
2026-02-07T22:38:47.555770445+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
[NVSHARE][INFO][2026-02-07 14:38:47]   3%|▎         | 1116/40000 [00:14<13:02, 49.71it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
[NVSHARE][INFO][2026-02-07 14:38:47]   3%|▎         | 1148/40000 [00:15<11:34, 55.97it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-07T22:38:48.483385248+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
2026-02-07T22:38:48.483416005+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-07T22:38:50.487056163+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
2026-02-07T22:38:50.505829837+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
2026-02-07T22:38:50.543302755+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
[NVSHARE][INFO][2026-02-07 14:38:50]   3%|▎         | 1221/40000 [00:17<19:21, 33.40it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
2026-02-07T22:38:50.769856187+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
[NVSHARE][INFO][2026-02-07 14:38:50]   3%|▎         | 1242/40000 [00:18<16:58, 38.05it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
[NVSHARE][INFO][2026-02-07 14:38:51]   3%|▎         | 1274/40000 [00:18<13:48, 46.75it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-07T22:38:51.697595887+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
2026-02-07T22:38:51.697648731+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-07T22:38:53.701140560+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
2026-02-07T22:38:53.719921719+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
2026-02-07T22:38:53.757344398+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
[NVSHARE][INFO][2026-02-07 14:38:53]   3%|▎         | 1347/40000 [00:21<21:51, 29.48it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1).
2026-02-07T22:38:53.983840067+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 32 (warmup=1).
[NVSHARE][INFO][2026-02-07 14:38:53]   3%|▎         | 1368/40000 [00:21<18:34, 34.65it/s][NVSHARE][DEBUG]: Pending Kernel Window is 64 (warmup=1).
[NVSHARE][INFO][2026-02-07 14:38:54]   4%|▎         | 1400/40000 [00:21<14:34, 44.13it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-07T22:38:54.911591430+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 2 (warmup=1).
2026-02-07T22:38:54.911627402+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-07T22:38:56.915100216+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
2026-02-07T22:38:56.933860895+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 4 (warmup=1).
2026-02-07T22:38:56.971358078+08:00 [NVSHARE][DEBUG]: Pending Kernel Window is 8 (warmup=1).
[NVSHARE][INFO][2026-02-07 14:38:56]   4%|▎         | 1473/40000 [00:24<22:32, 28.49it/s][NVSHARE][DEBUG]: Pending Kernel Window is 16 (warmup=1). 然后是scheduler的日志： root@lgy-test-gpu:~# tail -f scheduler2.log
2026-02-07T22:38:37.169178974+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 1426/600 ms, weighted)
2026-02-07T22:38:37.769276826+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:38:39.607140123+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:38:41.606040284+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:38:42.196244911+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1781/1200 ms, weighted)
2026-02-07T22:38:43.397756304+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:38:44.659039162+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:38:47.091274795+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1201/1200 ms, weighted)
2026-02-07T22:38:47.873076651+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:38:48.292656285+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:38:51.087100410+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:38:51.523069666+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:38:54.301193387+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 601/600 ms, weighted)
2026-02-07T22:38:54.743506291+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:38:57.515133423+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:38:57.953814562+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:38:58.609538181+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:01.174232608+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1201/1200 ms, weighted)
2026-02-07T22:39:01.330476924+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:02.375752721+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:39:04.544492224+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:05.606172619+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:39:05.607712321+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:08.358916987+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:08.816533844+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:39:11.572774968+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:12.026814180+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:39:12.605915755+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:13.226720370+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:39:15.387317442+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:16.457166578+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:39:18.601605522+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:19.614789880+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:19.667533222+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:39:22.416340148+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:22.877814812+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:39:23.611354359+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:26.088199241+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:39:26.231722399+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:27.289699619+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:39:29.445924824+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:30.520119458+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:39:30.610643922+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:33.261183351+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 601/600 ms, weighted)
2026-02-07T22:39:33.730442604+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:39:36.475443495+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:36.940711920+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:39:37.609507373+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:40.151020358+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:39:40.290400485+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:41.351904267+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:39:43.504549786+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:44.582363593+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:39:44.608796594+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:47.319779835+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:47.792642636+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:39:50.533938753+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:51.002952514+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:39:51.608018797+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:52.211547903+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:39:54.349054237+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:55.431928310+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:39:57.563304396+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:58.608106397+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:39:58.642241701+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:40:01.379484826+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:40:01.852580313+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:40:04.593757422+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:40:05.062889640+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:40:05.608065969+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
2026-02-07T22:40:06.263541289+08:00 [NVSHARE][INFO]: Throttling client 5e2a3766b40461b0 (Used: 1200/1200 ms, weighted)
2026-02-07T22:40:08.409663560+08:00 [NVSHARE][INFO]: Throttling client 1260b1a9280c7d65 (Used: 600/600 ms, weighted)
```

- 继续补充测试结果

```
测试的任务是complex任务（pytorch-small-add），任务占用4G显存，单独运行任务不加任何限制时，完成时间是392s
我补充了如下测试

手动运行2个complex任务，调度到2个GPU上，不设任何配额，分别都是391秒完成。和之前没做GPU算力配额时保持一致（pytorch-small-baseline  392s），证明我们的实现对原有功能没有影响

单独创建1个任务complex任务，运行在一个GPU上
设定75%配额 592秒
设定50%配额 845秒
设定25%配额 1617秒

创建2个任务，调度到同一个GPU上
各 50% 848秒 877秒
各 75% 865秒 864秒
不限制 862秒 865秒

创建2个任务，调度到2个不同GPU上
各 25% 1648秒 1649秒
各 30% 888秒 882秒 
各 50% 866秒 877秒
各 75% 588秒 580秒
一个30%，一个60%  882秒 875秒

总体上看，30%算力的时候，表现就特别不正常
```

- AI展现了非凡的思考能力，我把他的思考贴出来
```
Opus:
非常感谢这些详细的测试数据！我发现了关键模式：

数据分析
计算实际有效算力（= 392秒 / 实际耗时）：

单任务在单GPU：
75% 配额 → 实际 66.2% ✗（偏低9%）
50% 配额 → 实际 46.4% ✗（偏低4%）
25% 配额 → 实际 24.2% ✓（准确！）
两任务不同GPU：
各25% → 实际 23.8% ✓（准确！）
各30% → 实际 44.1% ✗✗（应该30%，实际比50%还低！）
各50% → 实际 45.3% ✗（偏低5%）
各75% → 实际 66.7% ✗（偏低8%）
关键发现
30%配额严重异常：实际给了约44%的算力，比配置的30%多了近50%！

而25%配额非常准确。

这说明问题不是kernel window（那样所有配额都会偏低），而是30%配额的计算或判断逻辑有bug。

怀疑点
让我检查代码中是否有硬编码的阈值或特殊判断：
等等，我注意到了数据中的一个关键细节。让我重新计算：

重要发现
30%配额两个任务在不同GPU：

任务1: 888秒 → 实际算力 = 392/888 = 44.1%
任务2: 882秒 → 实际算力 = 392/882 = 44.4%
60%配额（之前的测试，30%+60%）:

之前您说60%任务也是 14.6分钟 = 876秒 → 实际算力 = 392/876 = 44.7%
关键发现：30%和60%的任务都得到了约44%的算力！

这不是巧合。它们都约等于：（30% + 60%）/ 2 = 45%

新的假设
调度器可能错误地将30%+60%的总配额按平均分配，而不是按比例分配！

让我检查 
calculate_total_quota
 函数：

Analyzed
scheduler.c#L707-722
等一下！我发现了另一个关键问题。

calculate_total_quota
 遍历的是所有clients，不仅是running_list！

在30%+60%的场景中，如果两个任务在不同GPU上：

GPU1有30%任务
GPU2有60%任务
但
calculate_total_quota(GPU1_ctx)
会遍历所有clients，包括GPU2上的60%任务！

让我验证这个假设：

Analyzed
scheduler.c#L702-714
好的！代码确实有 if (c->context == ctx ... 的检查（第708行），所以它只计算当前GPU上的客户端。

这不是原因。让我重新思考...

让我检查一个关键疑问：在30%+60%不同GPU的场景中，调度器日志显示它们几乎同时被节流。这说明什么？

让我重新查看之前的调度器日志模式，特别关注时间间隔：

从之前的日志：

22:38:37.169  Throttling 1260b1a9280c7d65 (Used: 1426/600 ms)  ← 30%任务超额
22:38:42.196  Throttling 5e2a3766b40461b0 (Used: 1781/1200 ms) ← 60%任务超额
等等！60%任务也超额了：1781/1200 = 148%！

这说明什么？计费逻辑有问题！

让我重新检查客户端日志中的关键时间点。从之前30%任务的日志：

22:38:31.742  Received LOCK_OK          ← 获得锁
22:38:42.050  Received DROP_LOCK         ← 10.3秒后收到DROP_LOCK
实际持有锁 10.3秒，但调度器认为只用了1426ms（1.4秒）？

这个差异太大了！问题不在于配额计算，而在于时间计量有严重错误。

让我检查调度器端的时间计算。特别是 
calculate_weighted_usage
 和 
timer_thr_fn
 中的计费逻辑：

Analyzed
scheduler.c#L990-1020
**找到了！**关键Bug在第1000-1001行：

c
long pending_wall_time = now_ms - c->current_run_start_ms;
long pending_billed = pending_wall_time / n_running_now;  /* ← BUG! */
当只有1个任务运行时（n_running_now = 1），pending_billed = pending_wall_time，这是对的。

但问题是：c->current_run_start_ms 可能在窗口重置时被更新！

让我再看窗口重置逻辑：

Analyzed
scheduler.c#L749-778
**完全找到了BUG！**让我解释：

Bug的完整流程
30%任务在不同GPU场景的时间线：

T=0秒: 任务获得锁，current_run_start_ms = 0 T=1.4秒: 累积1426ms，被节流（第1次） T=2秒: 窗口重置，run_time_in_window_ms = 0，但因为is_running = 1，所以 current_run_start_ms 被重置为 T=2秒（第769行） T=2.6秒: 计算pending_wall_time = 0.6秒，累积600ms，被节流（第2次） T=4秒: 又是窗口重置，current_run_start_ms再次重置为 T=4秒 ...循环...

调度器每个窗口都重置current_run_start_ms，所以它永远只计算最近一个窗口内的时间！

而客户端实际持有锁10.3秒，跨越了5个窗口，但调度器只计算了最后一个窗口内的0.6秒！

为什么30%特别明显？
30% = 600ms配额，窗口 = 2000ms

30%任务每个窗口只能运行600ms，所以每个窗口都会被节流1次
窗口重置时 current_run_start_ms 被重置，时间计量重新开始
结果：任务可以在每个窗口内持续运行600ms，然后被节流，然后窗口重置，再运行600ms...
有效算力 = 600ms / 2000ms = 30%...吗？不对！
问题在于客户端收到DROP_LOCK后不立即释放，而是等cuCtxSynchronize()完成，这可能跨越多个窗口！

修复方案
不应该在窗口重置时重置current_run_start_ms。
```

```
50%+50%、75%+75%都是准确的 在不同GPU、同一个GPU都测试过。都相对准确。 你要的日志如下：首先是scheduler日志： root@lgy-test-gpu:~# tail -f scheduler3.log
2026-02-08T00:34:15.889494448+08:00 [NVSHARE][INFO]: Throttling client 8d256f6f775a696d (Used: 8980/600 ms, weighted)
2026-02-08T00:34:15.898494101+08:00 [NVSHARE][INFO]: Throttling client fd28ed2e538238e1 (Used: 8439/1200 ms, weighted)
2026-02-08T00:34:16.489367065+08:00 [NVSHARE][INFO]: Throttling client 8d256f6f775a696d (Used: 600/600 ms, weighted)
2026-02-08T00:34:17.098490658+08:00 [NVSHARE][INFO]: Throttling client fd28ed2e538238e1 (Used: 1200/1200 ms, weighted)
2026-02-08T00:34:17.222745199+08:00 [NVSHARE][INFO]: Received LOCK_RELEASED from 8d256f6f775a696d
2026-02-08T00:34:17.222770517+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 733 ms / 1 concurrent = 733 ms billed
2026-02-08T00:34:17.930496965+08:00 [NVSHARE][INFO]: Received LOCK_RELEASED from fd28ed2e538238e1
2026-02-08T00:34:17.930530407+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 832 ms / 1 concurrent = 832 ms billed
2026-02-08T00:34:19.824109923+08:00 [NVSHARE][INFO]: Throttling client 8d256f6f775a696d (Used: 600/600 ms, weighted)
2026-02-08T00:34:20.435367468+08:00 [NVSHARE][INFO]: Received LOCK_RELEASED from 8d256f6f775a696d
2026-02-08T00:34:20.435392902+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 612 ms / 1 concurrent = 612 ms billed
2026-02-08T00:34:21.134193443+08:00 [NVSHARE][INFO]: Throttling client fd28ed2e538238e1 (Used: 1201/1200 ms, weighted)
2026-02-08T00:34:21.143219989+08:00 [NVSHARE][INFO]: Received LOCK_RELEASED from fd28ed2e538238e1
2026-02-08T00:34:21.143237199+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 9 ms / 1 concurrent = 9 ms billed
2026-02-08T00:34:22.334789527+08:00 [NVSHARE][INFO]: Throttling client fd28ed2e538238e1 (Used: 1200/1200 ms, weighted)
2026-02-08T00:34:22.363436566+08:00 [NVSHARE][INFO]: Received LOCK_RELEASED from fd28ed2e538238e1
2026-02-08T00:34:22.363464649+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 29 ms / 1 concurrent = 29 ms billed
2026-02-08T00:34:23.039578451+08:00 [NVSHARE][INFO]: Throttling client 8d256f6f775a696d (Used: 600/600 ms, weighted)
2026-02-08T00:34:23.650430590+08:00 [NVSHARE][INFO]: Received LOCK_RELEASED from 8d256f6f775a696d
2026-02-08T00:34:23.650462183+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 611 ms / 1 concurrent = 611 ms billed
2026-02-08T00:34:25.565235347+08:00 [NVSHARE][INFO]: Throttling client fd28ed2e538238e1 (Used: 1201/1200 ms, weighted)
2026-02-08T00:34:25.574887018+08:00 [NVSHARE][INFO]: Received LOCK_RELEASED from fd28ed2e538238e1
2026-02-08T00:34:25.574904256+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 9 ms / 1 concurrent = 9 ms billed
2026-02-08T00:34:26.253567974+08:00 [NVSHARE][INFO]: Throttling client 8d256f6f775a696d (Used: 600/600 ms, weighted)
2026-02-08T00:34:26.864568092+08:00 [NVSHARE][INFO]: Received LOCK_RELEASED from 8d256f6f775a696d
2026-02-08T00:34:26.864607180+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 611 ms / 1 concurrent = 611 ms billed
2026-02-08T00:34:28.775638196+08:00 [NVSHARE][INFO]: Throttling client fd28ed2e538238e1 (Used: 1200/1200 ms, weighted)
2026-02-08T00:34:28.785334072+08:00 [NVSHARE][INFO]: Received LOCK_RELEASED from fd28ed2e538238e1
2026-02-08T00:34:28.785349305+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 10 ms / 1 concurrent = 10 ms billed
2026-02-08T00:34:29.467568215+08:00 [NVSHARE][INFO]: Throttling client 8d256f6f775a696d (Used: 600/600 ms, weighted)
2026-02-08T00:34:30.068058771+08:00 [NVSHARE][INFO]: Throttling client 8d256f6f775a696d (Used: 600/600 ms, weighted)
2026-02-08T00:34:30.078499584+08:00 [NVSHARE][INFO]: Received LOCK_RELEASED from 8d256f6f775a696d
2026-02-08T00:34:30.078525332+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 11 ms / 1 concurrent = 11 ms billed
2026-02-08T00:34:31.985924272+08:00 [NVSHARE][INFO]: Throttling client fd28ed2e538238e1 (Used: 1200/1200 ms, weighted)
2026-02-08T00:34:31.995396384+08:00 [NVSHARE][INFO]: Received LOCK_RELEASED from fd28ed2e538238e1
2026-02-08T00:34:31.995424927+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 10 ms / 1 concurrent = 10 ms billed
2026-02-08T00:34:32.688388935+08:00 [NVSHARE][INFO]: Throttling client 8d256f6f775a696d (Used: 600/600 ms, weighted)
2026-02-08T00:34:33.298524311+08:00 [NVSHARE][INFO]: Received LOCK_RELEASED from 8d256f6f775a696d
2026-02-08T00:34:33.298563836+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 610 ms / 1 concurrent = 610 ms billed
2026-02-08T00:34:35.196222194+08:00 [NVSHARE][INFO]: Throttling client fd28ed2e538238e1 (Used: 1201/1200 ms, weighted)
2026-02-08T00:34:35.205484984+08:00 [NVSHARE][INFO]: Received LOCK_RELEASED from fd28ed2e538238e1
2026-02-08T00:34:35.205506444+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 9 ms / 1 concurrent = 9 ms billed
2026-02-08T00:34:35.902526029+08:00 [NVSHARE][INFO]: Throttling client 8d256f6f775a696d (Used: 600/600 ms, weighted)
2026-02-08T00:34:36.397229727+08:00 [NVSHARE][INFO]: Throttling client fd28ed2e538238e1 (Used: 1200/1200 ms, weighted)
2026-02-08T00:34:36.426164172+08:00 [NVSHARE][INFO]: Received LOCK_RELEASED from fd28ed2e538238e1
2026-02-08T00:34:36.426195327+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 30 ms / 1 concurrent = 30 ms billed
2026-02-08T00:34:36.512455900+08:00 [NVSHARE][INFO]: Received LOCK_RELEASED from 8d256f6f775a696d
2026-02-08T00:34:36.512489325+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 610 ms / 1 concurrent = 610 ms billed
2026-02-08T00:34:39.116864757+08:00 [NVSHARE][INFO]: Throttling client 8d256f6f775a696d (Used: 600/600 ms, weighted)
2026-02-08T00:34:39.627651898+08:00 [NVSHARE][INFO]: Throttling client fd28ed2e538238e1 (Used: 1200/1200 ms, weighted)
2026-02-08T00:34:39.637704767+08:00 [NVSHARE][INFO]: Received LOCK_RELEASED from fd28ed2e538238e1
2026-02-08T00:34:39.637723737+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 10 ms / 1 concurrent = 10 ms billed
2026-02-08T00:34:39.726648692+08:00 [NVSHARE][INFO]: Received LOCK_RELEASED from 8d256f6f775a696d
2026-02-08T00:34:39.726669948+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 610 ms / 1 concurrent = 610 ms billed
2026-02-08T00:34:42.331108184+08:00 [NVSHARE][INFO]: Throttling client 8d256f6f775a696d (Used: 600/600 ms, weighted)
2026-02-08T00:34:42.838023813+08:00 [NVSHARE][INFO]: Throttling client fd28ed2e538238e1 (Used: 1200/1200 ms, weighted)
2026-02-08T00:34:42.848164680+08:00 [NVSHARE][INFO]: Received LOCK_RELEASED from fd28ed2e538238e1
2026-02-08T00:34:42.848192499+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 11 ms / 1 concurrent = 11 ms billed
2026-02-08T00:34:42.941581980+08:00 [NVSHARE][INFO]: Received LOCK_RELEASED from 8d256f6f775a696d
2026-02-08T00:34:42.941622451+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 611 ms / 1 concurrent = 611 ms billed
2026-02-08T00:34:45.545411665+08:00 [NVSHARE][INFO]: Throttling client 8d256f6f775a696d (Used: 600/600 ms, weighted)
2026-02-08T00:34:46.058454946+08:00 [NVSHARE][INFO]: Throttling client fd28ed2e538238e1 (Used: 1200/1200 ms, weighted)
2026-02-08T00:34:46.069243297+08:00 [NVSHARE][INFO]: Received LOCK_RELEASED from fd28ed2e538238e1
2026-02-08T00:34:46.069267804+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 11 ms / 1 concurrent = 11 ms billed
2026-02-08T00:34:46.145736425+08:00 [NVSHARE][INFO]: Throttling client 8d256f6f775a696d (Used: 600/600 ms,   然后是30%配额pod日志 root@lgy-test-gpu:~# kubectl logs  complex-test-1 --timestamps | grep -E "(DROP_LOCK|LOCK_RELEASED|LOCK_OK)" | head -100
2026-02-08T00:34:06.910053333+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:12]   1%|          | 448/40000 [00:04<06:27, 102.03it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:17.222763629+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:17.222771780+08:00 [NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:19.224103099+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:19]   3%|▎         | 1022/40000 [00:11<08:19, 78.01it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:20.435355178+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:22.439489552+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:23]   3%|▎         | 1148/40000 [00:15<11:34, 55.97it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:23.650438944+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:25.653513730+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:26]   3%|▎         | 1274/40000 [00:18<13:48, 46.75it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:26.864524031+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:28.867555671+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:29]   4%|▎         | 1400/40000 [00:21<14:34, 44.13it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:30.078478244+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:30.078480528+08:00 [NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:32.088367891+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:32]   4%|▍         | 1526/40000 [00:24<14:46, 43.42it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:33.298487540+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:35.302484822+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:35]   4%|▍         | 1652/40000 [00:28<14:45, 43.31it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:36.512486130+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:38.516813906+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:39]   4%|▍         | 1778/40000 [00:31<14:43, 43.28it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:39.726656064+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:41.731062856+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:42]   5%|▍         | 1904/40000 [00:34<14:40, 43.27it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:42.941581799+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:44.945354063+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:45]   5%|▌         | 2030/40000 [00:37<14:37, 43.27it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:46.155261029+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:46.155263198+08:00 [NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:48.156005680+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:48]   5%|▌         | 2156/40000 [00:40<14:33, 43.30it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:49.366122913+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:51.370292559+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:51]   6%|▌         | 2282/40000 [00:44<14:31, 43.28it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:52.579993577+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:54.584432633+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:55]   6%|▌         | 2408/40000 [00:47<14:28, 43.27it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:55.794374686+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:57.798548506+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:58]   6%|▋         | 2534/40000 [00:50<14:25, 43.28it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:59.007813973+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
[NVSHARE][INFO][2026-02-07 16:34:59]   6%|▋         | 2598/40000 [00:51<10:19, 60.39it/s][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:59]   7%|▋         | 2628/40000 [00:51<09:05, 68.50it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:59.608985973+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:35:01.618586694+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:35:02]   7%|▋         | 2722/40000 [00:54<14:08, 43.95it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:35:02.827533368+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:35:04.832653427+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:35:05]   7%|▋         | 2848/40000 [00:57<14:15, 43.43it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:35:06.041298762+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:35:06.041301453+08:00 [NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:35:08.042782467+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:35:08]   7%|▋         | 2974/40000 [01:00<14:13, 43.36it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:35:09.251093404+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:35:11.256753620+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:35:11]   8%|▊         | 3100/40000 [01:04<14:12, 43.30it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:35:12.465251965+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:35:14.470851975+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:35:15]   8%|▊         | 3226/40000 [01:07<14:09, 43.28it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:35:15.679514390+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:35:17.684944576+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:35:18]   8%|▊         | 3352/40000 [01:10<14:06, 43.29it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:35:18.893152288+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:35:20.898830965+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:35:21]   9%|▊         | 3478/40000 [01:13<14:03, 43.29it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:35:22.106949213+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:35:22.106951882+08:00 [NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:35:24.109268811+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:35:24]   9%|▉         | 3604/40000 [01:16<14:00, 43.32it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:35:25.317619293+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:35:27.323364776+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:35:27]   9%|▉         | 3730/40000 [01:20<13:57, 43.29it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:35:28.531582125+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:35:30.537401007+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:35:31]  10%|▉         | 3856/40000 [01:23<13:55, 43.28it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:35:31.745572959+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED 最后是60%配额pod的日志：
root@lgy-test-gpu:~# kubectl logs  complex-test-2 --timestamps | grep -E "(DROP_LOCK|LOCK_RELEASED|LOCK_OK)" | head -100
2026-02-08T00:34:07.459515068+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:12]   1%|          | 448/40000 [00:04<06:27, 102.10it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:17.930490880+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:17.930493353+08:00 [NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:19.934147872+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:20]   3%|▎         | 1022/40000 [00:11<08:19, 78.03it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:21.143189780+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
[NVSHARE][INFO][2026-02-07 16:34:21]   3%|▎         | 1086/40000 [00:12<07:51, 82.56it/s][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:21]   3%|▎         | 1148/40000 [00:13<07:18, 88.55it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:22.363432996+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:24.365195197+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:24]   3%|▎         | 1274/40000 [00:16<12:27, 51.80it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:25.574868900+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:27.575578034+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:28]   4%|▎         | 1400/40000 [00:19<14:12, 45.25it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:28.785305171+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:30.785887201+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:31]   4%|▍         | 1526/40000 [00:22<14:38, 43.78it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:31.995389775+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:33.996184888+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:34]   4%|▍         | 1652/40000 [00:26<14:43, 43.43it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:35.205467983+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
[NVSHARE][INFO][2026-02-07 16:34:35]   4%|▍         | 1716/40000 [00:26<10:32, 60.51it/s][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:35]   4%|▍         | 1778/40000 [00:27<08:14, 77.34it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:36.426195192+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:38.427606497+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:39]   5%|▍         | 1904/40000 [00:30<13:09, 48.26it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:39.637690858+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:41.637958363+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:42]   5%|▌         | 2030/40000 [00:33<14:17, 44.30it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:42.848129438+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:44.858375311+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:45]   5%|▌         | 2156/40000 [00:36<14:31, 43.44it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:46.069254986+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
[NVSHARE][INFO][2026-02-07 16:34:46]   6%|▌         | 2220/40000 [00:37<10:23, 60.55it/s][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:46]   6%|▌         | 2282/40000 [00:38<08:07, 77.38it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:47.289813758+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:49.299320761+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:49]   6%|▌         | 2408/40000 [00:41<13:00, 48.14it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:50.510626108+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:52.519746561+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:53]   6%|▋         | 2534/40000 [00:44<14:08, 44.18it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:53.730881812+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:55.740092195+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:56]   7%|▋         | 2660/40000 [00:47<14:19, 43.42it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:34:56.950704794+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:34:58.960527560+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:34:59]   7%|▋         | 2786/40000 [00:50<14:20, 43.25it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:35:00.170546829+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
[NVSHARE][INFO][2026-02-07 16:35:00]   7%|▋         | 2850/40000 [00:51<10:15, 60.36it/s][NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:35:00]   7%|▋         | 2912/40000 [00:52<08:00, 77.23it/s][NVSHARE][DEBUG]: Received DROP_LOCK
2026-02-08T00:35:01.391010054+08:00 [NVSHARE][DEBUG]: Sent LOCK_RELEASED
2026-02-08T00:35:03.391628595+08:00 [NVSHARE][DEBUG]: Received LOCK_OK
[NVSHARE][INFO][2026-02-07 16:35:03]   8%|▊         | 3038/40000 [00:55<12:45, 48.28it/s][NVSHARE][DEBUG]: Received DROP_LOCK 
```
- 还是有问题，让AI告诉我怎么看日志

```
我用新的代码测试了下，同样的任务，设置30%配额和60%配额，分布到2个GPU上。60%配额完成 865秒，30%配额完成 1005秒，几乎和上一次修改前一样，我怎么判断修改生效了？有什么日志能确定吗

```

- 反馈信息给AI
```
root@lgy-test-gpu:~# kubectl logs  complex-test-1|grep  -E "(Core limit|Successfully initialized)"
[NVSHARE][INFO]: Successfully initialized nvshare GPU
[NVSHARE][INFO]: Core limit = 100%
root@lgy-test-gpu:~# kubectl logs  complex-test-2|grep  -E "(Core limit|Successfully initialized)"
[NVSHARE][INFO]: Successfully initialized nvshare GPU
[NVSHARE][INFO]: Core limit = 100% 显示的都是100，这个日志如果是新加的，我任务是部署成功了。但是为啥显示的数值不对，需要分析 原因。再补充一个信息，我创建任务pod的时候，没有设置core limit，我是等创建成功以后，通过annotate修改的limit

```

- 这次终于对了

```
用方案1，我测试两个任务（基准是391秒），这两个任务调度到2个GPU上，其中一个设置配额30%，完成时间1278秒另一个配额60% ,完成时间是662s.
```

- 新的问题，这里为了节省一些tokens，主动问一下ai需要同啥日志，而不是让他自己去找日志（太太太费token了）

```我测试了另一个场景，创建4个和之前同样的任务，其中任务1、任务2设置30%配额，任务3和任务4设置60%配合。任务1和任务3调度到GPU0，任务2和任务4调度到GPU1 。我实际测试下来所有任务的得到的算力基本一致。并且完成时间接近了1800s，比之前30%配额的速度还低了不少。需要我提供什么日志来协助你分析？
```

```
scheduler日志如下：
root@lgy-test-gpu:~# cat scheduler5.log |grep -E "Quota scaling|Throttling"
2026-02-08T11:31:05.999967741+08:00 [NVSHARE][INFO]: Throttling client 17f1bfa900acd218 (Used: 600/600 ms, weighted)
2026-02-08T11:31:06.009428309+08:00 [NVSHARE][INFO]: Throttling client b24a097d91ece776 (Used: 600/600 ms, weighted)
2026-02-08T11:31:07.199749597+08:00 [NVSHARE][INFO]: Throttling client 18a77075b382d717 (Used: 1200/1200 ms, weighted)
2026-02-08T11:31:07.209304479+08:00 [NVSHARE][INFO]: Throttling client d589772eb011eba3 (Used: 1200/1200 ms, weighted)
2026-02-08T11:31:07.209782744+08:00 [NVSHARE][INFO]: Throttling client 17f1bfa900acd218 (Used: 604/600 ms, weighted)
2026-02-08T11:31:07.219399847+08:00 [NVSHARE][INFO]: Throttling client b24a097d91ece776 (Used: 604/600 ms, weighted)
2026-02-08T11:31:10.621437887+08:00 [NVSHARE][INFO]: Throttling client 17f1bfa900acd218 (Used: 600/600 ms, weighted)
2026-02-08T11:31:10.631038900+08:00 [NVSHARE][INFO]: Throttling client b24a097d91ece776 (Used: 600/600 ms, weighted)
2026-02-08T11:31:10.722212097+08:00 [NVSHARE][INFO]: Throttling client 18a77075b382d717 (Used: 1300/1200 ms, weighted)
2026-02-08T11:31:10.731772695+08:00 [NVSHARE][INFO]: Throttling client d589772eb011eba3 (Used: 1301/1200 ms, weighted)
2026-02-08T11:31:13.942541560+08:00 [NVSHARE][INFO]: Throttling client 17f1bfa900acd218 (Used: 600/600 ms, weighted)
2026-02-08T11:31:13.952233030+08:00 [NVSHARE][INFO]: Throttling client b24a097d91ece776 (Used: 600/600 ms, weighted)
2026-02-08T11:31:15.142438943+08:00 [NVSHARE][INFO]: Throttling client 18a77075b382d717 (Used: 1200/1200 ms, weighted)
2026-02-08T11:31:15.152178690+08:00 [NVSHARE][INFO]: Throttling client d589772eb011eba3 (Used: 1200/1200 ms, weighted)
2026-02-08T11:31:15.153199052+08:00 [NVSHARE][INFO]: Throttling client 17f1bfa900acd218 (Used: 604/600 ms, weighted)
2026-02-08T11:31:15.162335175+08:00 [NVSHARE][INFO]: Throttling client b24a097d91ece776 (Used: 604/600 ms, weighted)
2026-02-08T11:31:18.554221735+08:00 [NVSHARE][INFO]: Throttling client 17f1bfa900acd218 (Used: 600/600 ms, weighted)
2026-02-08T11:31:18.563884282+08:00 [NVSHARE][INFO]: Throttling client b24a097d91ece776 (Used: 600/600 ms, weighted)
2026-02-08T11:31:18.654871198+08:00 [NVSHARE][INFO]: Throttling client 18a77075b382d717 (Used: 1301/1200 ms, weighted)
2026-02-08T11:31:18.664614276+08:00 [NVSHARE][INFO]: Throttling client d589772eb011eba3 (Used: 1301/1200 ms, weighted)
2026-02-08T11:31:21.875322809+08:00 [NVSHARE][INFO]: Throttling client 17f1bfa900acd218 (Used: 600/600 ms, weighted)
2026-02-08T11:31:21.885031266+08:00 [NVSHARE][INFO]: Throttling client b24a097d91ece776 (Used: 600/600 ms, weighted)
2026-02-08T11:31:21.975943394+08:00 [NVSHARE][INFO]: Throttling client 18a77075b382d717 (Used: 1300/1200 ms, weighted)
2026-02-08T11:31:21.985712576+08:00 [NVSHARE][INFO]: Throttling client d589772eb011eba3 (Used: 1301/1200 ms, weighted)
2026-02-08T11:31:23.206128394+08:00 [NVSHARE][INFO]: Throttling client b24a097d91ece776 (Used: 600/600 ms, weighted)
2026-02-08T11:31:23.306829621+08:00 [NVSHARE][INFO]: Throttling client d589772eb011eba3 (Used: 1301/1200 ms, weighted)
2026-02-08T11:31:25.196374227+08:00 [NVSHARE][INFO]: Throttling client 17f1bfa900acd218 (Used: 600/600 ms, weighted)
2026-02-08T11:31:26.396388632+08:00 [NVSHARE][INFO]: Throttling client 18a77075b382d717 (Used: 1200/1200 ms, weighted)
2026-02-08T11:31:26.406452502+08:00 [NVSHARE][INFO]: Throttling client 17f1bfa900acd218 (Used: 604/600 ms, weighted)
2026-02-08T11:31:26.527287754+08:00 [NVSHARE][INFO]: Throttling client b24a097d91ece776 (Used: 600/600 ms, weighted)

调度器并发日志如下：
root@lgy-test-gpu:~# cat scheduler5.log | grep "concurrent"
2026-02-08T11:31:02.805363007+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 17 ms / 1 concurrent = 17 ms billed
2026-02-08T11:31:04.799896592+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:04.799907279+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:04.809325072+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:04.809341181+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:06.099173544+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 99 ms / 2 concurrent = 49 ms billed
2026-02-08T11:31:06.099536465+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:06.108801122+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 99 ms / 2 concurrent = 49 ms billed
2026-02-08T11:31:06.109197304+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:07.396363089+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 187 ms / 2 concurrent = 93 ms billed
2026-02-08T11:31:07.406661244+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 187 ms / 2 concurrent = 93 ms billed
2026-02-08T11:31:07.413202562+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 214 ms / 1 concurrent = 214 ms billed
2026-02-08T11:31:07.423851363+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 214 ms / 1 concurrent = 214 ms billed
2026-02-08T11:31:09.421409161+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:09.421418744+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:09.430959455+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:09.430971074+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:10.720390566+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 99 ms / 2 concurrent = 49 ms billed
2026-02-08T11:31:10.730075668+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 99 ms / 2 concurrent = 49 ms billed
2026-02-08T11:31:10.741035842+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 19 ms / 1 concurrent = 19 ms billed
2026-02-08T11:31:10.750996188+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 19 ms / 1 concurrent = 19 ms billed
2026-02-08T11:31:12.742469035+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:12.742480301+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:12.752107799+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:12.752119539+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:14.037914851+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 95 ms / 2 concurrent = 47 ms billed
2026-02-08T11:31:14.038258606+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:14.047482400+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 95 ms / 2 concurrent = 47 ms billed
2026-02-08T11:31:14.048049030+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:15.335377879+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 183 ms / 2 concurrent = 91 ms billed
2026-02-08T11:31:15.345371732+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 183 ms / 2 concurrent = 91 ms billed
2026-02-08T11:31:15.352180394+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 210 ms / 1 concurrent = 210 ms billed
2026-02-08T11:31:15.362569642+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 210 ms / 1 concurrent = 210 ms billed
2026-02-08T11:31:17.354097737+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:17.354111078+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:17.363773357+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:17.363800064+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:18.650074979+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 95 ms / 2 concurrent = 47 ms billed
2026-02-08T11:31:18.658921714+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 95 ms / 2 concurrent = 47 ms billed
2026-02-08T11:31:18.670623061+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 16 ms / 1 concurrent = 16 ms billed
2026-02-08T11:31:18.679903020+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 15 ms / 1 concurrent = 15 ms billed
2026-02-08T11:31:20.675225711+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:20.675233106+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:20.684929720+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:20.684957937+08:00 [NVSHARE][DEBUG]: Auto mode: memory fits (2992 + 2992 <= 14745 MB), allowing concurrent
2026-02-08T11:31:21.974138620+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 98 ms / 2 concurrent = 49 ms billed
2026-02-08T11:31:21.983807413+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 99 ms / 2 concurrent = 49 ms billed

任务的释放延迟日志我搜过了，日志是全的，但是没有出现"Weighted billing"

```

```
有新的问题,修改代码后，更慢了，还是创建4个任务，分布在2个GPU，分别是30，60，30，60的场景，4个任务的完成时间都变成了2050秒左右。你需要我提供什么日志协助排查？ 另外，我重新测试了2个任务，一个30，一个60，分布到2个GPU，这个结果是正常的。
```

```
1.缩放日志：
root@lgy-test-gpu:~# cat scheduler7.log | grep "Quota scaling" | head -30
2026-02-08T12:10:54.618603752+08:00 [NVSHARE][INFO]: Quota scaling: client 24ee2c99831591d2 limit 60%, total 90%, n_running 2, effective 180%, base 1200 ms -> scaled 666 ms
2026-02-08T12:10:54.618627302+08:00 [NVSHARE][INFO]: Quota scaling: client e35b89d8bf1c2798 limit 30%, total 90%, n_running 2, effective 180%, base 600 ms -> scaled 333 ms
2026-02-08T12:10:54.618645714+08:00 [NVSHARE][INFO]: Quota scaling: client 24ee2c99831591d2 limit 60%, total 90%, n_running 2, effective 180%, base 1200 ms -> scaled 666 ms
2026-02-08T12:10:54.618667446+08:00 [NVSHARE][INFO]: Quota scaling: client e35b89d8bf1c2798 limit 30%, total 90%, n_running 2, effective 180%, base 600 ms -> scaled 333 ms
2026-02-08T12:10:55.284809915+08:00 [NVSHARE][INFO]: Quota scaling: client 24ee2c99831591d2 limit 60%, total 90%, n_running 2, effective 180%, base 1200 ms -> scaled 666 ms
2026-02-08T12:10:55.284831290+08:00 [NVSHARE][INFO]: Quota scaling: client e35b89d8bf1c2798 limit 30%, total 90%, n_running 2, effective 180%, base 600 ms -> scaled 333 ms
2026-02-08T12:10:55.284863541+08:00 [NVSHARE][INFO]: Quota scaling: client 24ee2c99831591d2 limit 60%, total 90%, n_running 2, effective 180%, base 1200 ms -> scaled 666 ms
2026-02-08T12:10:55.284891837+08:00 [NVSHARE][INFO]: Quota scaling: client e35b89d8bf1c2798 limit 30%, total 90%, n_running 2, effective 180%, base 600 ms -> scaled 333 ms
2026-02-08T12:10:55.294897962+08:00 [NVSHARE][INFO]: Quota scaling: client 24ee2c99831591d2 limit 60%, total 90%, n_running 2, effective 180%, base 1200 ms -> scaled 666 ms
2026-02-08T12:10:55.294922496+08:00 [NVSHARE][INFO]: Quota scaling: client 24ee2c99831591d2 limit 60%, total 90%, n_running 2, effective 180%, base 1200 ms -> scaled 666 ms
2026-02-08T12:10:55.294942727+08:00 [NVSHARE][INFO]: Quota scaling: client e35b89d8bf1c2798 limit 30%, total 90%, n_running 2, effective 180%, base 600 ms -> scaled 333 ms
2026-02-08T12:10:55.305003106+08:00 [NVSHARE][INFO]: Quota scaling: client 24ee2c99831591d2 limit 60%, total 90%, n_running 2, effective 180%, base 1200 ms -> scaled 666 ms
2026-02-08T12:10:55.305021252+08:00 [NVSHARE][INFO]: Quota scaling: client 24ee2c99831591d2 limit 60%, total 90%, n_running 2, effective 180%, base 1200 ms -> scaled 666 ms
2026-02-08T12:10:55.305050867+08:00 [NVSHARE][INFO]: Quota scaling: client e35b89d8bf1c2798 limit 30%, total 90%, n_running 2, effective 180%, base 600 ms -> scaled 333 ms
2026-02-08T12:10:55.315102365+08:00 [NVSHARE][INFO]: Quota scaling: client 24ee2c99831591d2 limit 60%, total 90%, n_running 2, effective 180%, base 1200 ms -> scaled 666 ms
2026-02-08T12:10:55.315117824+08:00 [NVSHARE][INFO]: Quota scaling: client 24ee2c99831591d2 limit 60%, total 90%, n_running 2, effective 180%, base 1200 ms -> scaled 666 ms
2026-02-08T12:10:55.315133807+08:00 [NVSHARE][INFO]: Quota scaling: client e35b89d8bf1c2798 limit 30%, total 90%, n_running 2, effective 180%, base 600 ms -> scaled 333 ms
2026-02-08T12:10:55.325188893+08:00 [NVSHARE][INFO]: Quota scaling: client 24ee2c99831591d2 limit 60%, total 90%, n_running 2, effective 180%, base 1200 ms -> scaled 666 ms
2026-02-08T12:10:55.325206111+08:00 [NVSHARE][INFO]: Quota scaling: client 24ee2c99831591d2 limit 60%, total 90%, n_running 2, effective 180%, base 1200 ms -> scaled 666 ms
2、节流和计费日志
root@lgy-test-gpu:~# cat scheduler7.log | grep -E "Throttling|Weighted billing" | head -50
2026-02-08T12:09:47.216887859+08:00 [NVSHARE][INFO]: Throttling client 8ae95d9e58c832b3 (Used: 600/600 ms, weighted)
2026-02-08T12:09:47.825712029+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 609 ms / 1 concurrent = 609 ms billed
2026-02-08T12:09:48.590507754+08:00 [NVSHARE][INFO]: Throttling client 79250641b222eacd (Used: 1200/1200 ms, weighted)
2026-02-08T12:09:48.600705341+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 10 ms / 1 concurrent = 10 ms billed
2026-02-08T12:09:50.432126420+08:00 [NVSHARE][INFO]: Throttling client 8ae95d9e58c832b3 (Used: 600/600 ms, weighted)
2026-02-08T12:09:51.032091792+08:00 [NVSHARE][INFO]: Throttling client 8ae95d9e58c832b3 (Used: 600/600 ms, weighted)
2026-02-08T12:09:51.040689558+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 9 ms / 1 concurrent = 9 ms billed
2026-02-08T12:09:51.810892827+08:00 [NVSHARE][INFO]: Throttling client 79250641b222eacd (Used: 1200/1200 ms, weighted)
2026-02-08T12:09:51.821318963+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 11 ms / 1 concurrent = 11 ms billed
2026-02-08T12:09:53.642474634+08:00 [NVSHARE][INFO]: Throttling client 8ae95d9e58c832b3 (Used: 600/600 ms, weighted)
2026-02-08T12:09:54.250834747+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 608 ms / 1 concurrent = 608 ms billed
2026-02-08T12:09:54.322621257+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 492 ms / 1 concurrent = 492 ms billed
2026-02-08T12:10:32.795970553+08:00 [NVSHARE][INFO]: Throttling client e35b89d8bf1c2798 (Used: 600/600 ms, weighted)
2026-02-08T12:10:32.796240072+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 1 ms / 1 concurrent = 1 ms billed
2026-02-08T12:10:33.535059206+08:00 [NVSHARE][INFO]: Throttling client e15cfcff9837f2f2 (Used: 600/600 ms, weighted)
2026-02-08T12:10:35.406340374+08:00 [NVSHARE][INFO]: Throttling client e35b89d8bf1c2798 (Used: 600/600 ms, weighted)
2026-02-08T12:10:35.653871023+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 247 ms / 1 concurrent = 247 ms billed
2026-02-08T12:10:36.145320370+08:00 [NVSHARE][INFO]: Throttling client e15cfcff9837f2f2 (Used: 600/600 ms, weighted)
2026-02-08T12:10:36.161206417+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 16 ms / 1 concurrent = 16 ms billed
2026-02-08T12:10:38.258747745+08:00 [NVSHARE][INFO]: Throttling client e35b89d8bf1c2798 (Used: 600/600 ms, weighted)
2026-02-08T12:10:38.521524557+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 263 ms / 1 concurrent = 263 ms billed
2026-02-08T12:10:38.765738362+08:00 [NVSHARE][INFO]: Throttling client e15cfcff9837f2f2 (Used: 600/600 ms, weighted)
2026-02-08T12:10:39.027267128+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 262 ms / 1 concurrent = 262 ms billed
2026-02-08T12:10:41.131384048+08:00 [NVSHARE][INFO]: Throttling client e35b89d8bf1c2798 (Used: 600/600 ms, weighted)
2026-02-08T12:10:41.392421282+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 261 ms / 1 concurrent = 261 ms billed
2026-02-08T12:10:41.628195701+08:00 [NVSHARE][INFO]: Throttling client e15cfcff9837f2f2 (Used: 600/600 ms, weighted)
2026-02-08T12:10:41.890294875+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 263 ms / 1 concurrent = 263 ms billed
2026-02-08T12:10:43.993953586+08:00 [NVSHARE][INFO]: Throttling client e35b89d8bf1c2798 (Used: 600/600 ms, weighted)
2026-02-08T12:10:44.254623656+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 261 ms / 1 concurrent = 261 ms billed
2026-02-08T12:10:44.490714085+08:00 [NVSHARE][INFO]: Throttling client e15cfcff9837f2f2 (Used: 600/600 ms, weighted)
2026-02-08T12:10:44.753225877+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 263 ms / 1 concurrent = 263 ms billed
2026-02-08T12:10:46.856423461+08:00 [NVSHARE][INFO]: Throttling client e35b89d8bf1c2798 (Used: 600/600 ms, weighted)
2026-02-08T12:10:47.117878886+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 261 ms / 1 concurrent = 261 ms billed
2026-02-08T12:10:47.363295490+08:00 [NVSHARE][INFO]: Throttling client e15cfcff9837f2f2 (Used: 601/600 ms, weighted)
2026-02-08T12:10:47.623872868+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 260 ms / 1 concurrent = 260 ms billed
2026-02-08T12:10:49.718742390+08:00 [NVSHARE][INFO]: Throttling client e35b89d8bf1c2798 (Used: 600/600 ms, weighted)
2026-02-08T12:10:49.981669097+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 263 ms / 1 concurrent = 263 ms billed
2026-02-08T12:10:50.225659295+08:00 [NVSHARE][INFO]: Throttling client e15cfcff9837f2f2 (Used: 600/600 ms, weighted)
2026-02-08T12:10:50.486578846+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 261 ms / 1 concurrent = 261 ms billed
2026-02-08T12:10:52.591425299+08:00 [NVSHARE][INFO]: Throttling client e35b89d8bf1c2798 (Used: 600/600 ms, weighted)
2026-02-08T12:10:52.628718275+08:00 [NVSHARE][DEBUG]: Weighted billing: wall 37 ms / 1 concurrent = 37 ms billed
3、并发日志
root@lgy-test-gpu:~# cat scheduler7.log | grep "Concurrent execution" | head -20
2026-02-08T12:10:54.618583214+08:00 [NVSHARE][DEBUG]: Concurrent execution: 2 tasks running, effective total = 90% * 2 = 180%
2026-02-08T12:10:54.618622966+08:00 [NVSHARE][DEBUG]: Concurrent execution: 2 tasks running, effective total = 90% * 2 = 180%
2026-02-08T12:10:54.618641715+08:00 [NVSHARE][DEBUG]: Concurrent execution: 2 tasks running, effective total = 90% * 2 = 180%
2026-02-08T12:10:54.618663470+08:00 [NVSHARE][DEBUG]: Concurrent execution: 2 tasks running, effective total = 90% * 2 = 180%
2026-02-08T12:10:55.284805143+08:00 [NVSHARE][DEBUG]: Concurrent execution: 2 tasks running, effective total = 90% * 2 = 180%
2026-02-08T12:10:55.284827482+08:00 [NVSHARE][DEBUG]: Concurrent execution: 2 tasks running, effective total = 90% * 2 = 180%
2026-02-08T12:10:55.284860871+08:00 [NVSHARE][DEBUG]: Concurrent execution: 2 tasks running, effective total = 90% * 2 = 180%
2026-02-08T12:10:55.284889330+08:00 [NVSHARE][DEBUG]: Concurrent execution: 2 tasks running, effective total = 90% * 2 = 180%
2026-02-08T12:10:55.294893669+08:00 [NVSHARE][DEBUG]: Concurrent execution: 2 tasks running, effective total = 90% * 2 = 180%
2026-02-08T12:10:55.294918221+08:00 [NVSHARE][DEBUG]: Concurrent execution: 2 tasks running, effective total = 90% * 2 = 180%
2026-02-08T12:10:55.294939154+08:00 [NVSHARE][DEBUG]: Concurrent execution: 2 tasks running, effective total = 90% * 2 = 180%
2026-02-08T12:10:55.304999877+08:00 [NVSHARE][DEBUG]: Concurrent execution: 2 tasks running, effective total = 90% * 2 = 180%
2026-02-08T12:10:55.305016439+08:00 [NVSHARE][DEBUG]: Concurrent execution: 2 tasks running, effective total = 90% * 2 = 180%
2026-02-08T12:10:55.305047789+08:00 [NVSHARE][DEBUG]: Concurrent execution: 2 tasks running, effective total = 90% * 2 = 180%
2026-02-08T12:10:55.315099222+08:00 [NVSHARE][DEBUG]: Concurrent execution: 2 tasks running, effective total = 90% * 2 = 180%
2026-02-08T12:10:55.315115338+08:00 [NVSHARE][DEBUG]: Concurrent execution: 2 tasks running, effective total = 90% * 2 = 180%
2026-02-08T12:10:55.315129369+08:00 [NVSHARE][DEBUG]: Concurrent execution: 2 tasks running, effective total = 90% * 2 = 180%
2026-02-08T12:10:55.325186090+08:00 [NVSHARE][DEBUG]: Concurrent execution: 2 tasks running, effective total = 90% * 2 = 180%
2026-02-08T12:10:55.325203062+08:00 [NVSHARE][DEBUG]: Concurrent execution: 2 tasks running, effective total = 90% * 2 = 180%
2026-02-08T12:10:55.325226233+08:00 [NVSHARE][DEBUG]: Concurrent execution: 2 tasks running, effective total = 90% * 2 = 180%
```