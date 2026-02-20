# day 0

- npu这边的变动比较大，并且main分支还在做一些稳定性测试，所以这边新开一个来记录npu相关开发的Prompts

# day 13
- 前面已经让AI分析生成了一个设计文档docs/design/cann_npu_virtualization_analysis.md，接下来就是让AI根据这个设计文档来开发


```
下面开始按按docs/design/cann_npu_virtualization_analysis.md的方案，进行开发（新建一个npusuport分支来做）。你提到的几个需要我补充的问题 1、框架接入层代码：先不管，假定没可以都拦截 2、你当前项目里的 NPU 适配实现：能复用当前项目针对nvida cuda方式的就采用相同方式。3、部署注入链路：采用LD_PRELOAD，和之前针对cuda的方案保持一致。4、你提到的 token 配额实现代码。忽略这个问题
```

- 做一轮smoke

```
我打算先编译运行一下，看看是否对之前的功能有影响，以及现在开发的基础功能是否正常。有个问题，昇腾的GPU一般都是搭配arm芯片的，所以编译的时候，需要打包成multi-arch的镜像，请检查当前的代码是否考虑到了这一点
```

- 写一个测试脚本，方便后续验证

```
请参考tests/remote-test-complex2.sh脚本，创建一个新的tests/remote-test-smoke.sh脚本，用来测试新的代码在cuda和cann中是否都能正常工作。
我的编译环境是一台x86的linux，可以通过ssh root@xxx登录（我已经设置了免密登录），请参考remote-test-complex2.sh，先本地commit，然后把代码syn过去，然后再ssh到这个机器上执行make
我的cuda测试环境，可以在本地通过export KUBECONFIG=~/Code/configs/kubeconfig-xxx-gpu，这个环境有2台A800的GPU机器。
我的cann测试环境，可以在本地通过export KUBECONFIG=~/Code/configs/kubeconfig-xx-npu，这个环境有1台910B的NPU机器。
请编译之后，用新的镜像名称更新这两个测试环境中的scheduler、device-plugin的manifest，然后创建新的scheduler、device-plugin来测试的工作负载（工作负载的镜像如果没有更新，不要更改镜像ID)
```

```
之前cuda架构上测试的时候，发现是lazy loading的，光sleep触发不了加载，请判断是否需要修改你的探针脚本
```

```
增加一轮性能基准测试，对比直接用原生驱动（直接nvidia.com/gpu 、huawei.com/Ascend910）和使用nvshare驱动的的性能。脚本补充到之前的remote-test-smoke.sh中，并增加对应的启动参数
```

# day14 继续冒烟测试
- 第一个小坑，由于npu是基本都是搭配arm的，所以这里就涉及到一些multi arch的镜像编译，不展开了，主要是我环境问题，折腾了一段时间。

- 第二个大坑，就是昇腾的文档太差了，就找不到一个地方说清楚cann和driver、pytorch三者的兼容性关系，导致cann和driver不匹配，测试跑不起来，这里又折腾了挺久，最后我自己做测试的镜像。（driver是25.0.1-RC1，cann是8.2.RC1，pytorch是2.6.0）

```
cann测试的镜像有点问题，需要修改为registry.cn-hangzhou.aliyuncs.com/lgytest1/ascend-pytorch:cann8.2-pt2.6
```

- 经过一番折腾，终于把smoke跑起来了，但是发现没有正确劫持cann的接口


```
针对cann，用nvshare创建的测试任务，没有运行成功，请检查日志，分析原因，你可以通过export KUBECONFIG=~/Code/configs/kubeconfig-xxx-npu来调用kubectl，也可以ssh root@xxx 直接登录npu节点
```

- codex确实牛，自己补充了几轮测试，定位了问题（之前opus定位问题的时候，整了一大堆日志，反反复复用了很多token，codex相比就很清爽）

```
codex的分析如下：
结论：cann 下用 nvshare.com/gpu 创建任务失败的根因已定位，不是脚本命令问题，而是 Ascend 运行时注入链路缺失。

关键结论

nvshare Pod 日志报错：ImportError: libascend_hal.so: cannot open shared object file.
同镜像同脚本下，native(huawei.com/Ascend910:1) 成功，gpu (line 1) 失败。
即使在 nvshare Pod 内手动 unset LD_PRELOAD，仍然同样失败，说明不是 LD_PRELOAD 本身导致。
我做的对照验证（已清理临时 Pod）

cann-verify-native：PASS_NATIVE，torch_npu 可导入。
cann-verify-nvshare：稳定失败，libascend_hal.so 缺失。
cann-devcheck-native：有 /dev/davinci0、/dev/devmm_svm、/dev/hisi_hdc，且有 libascend_hal.so。
cann-devcheck-nvshare：上述设备节点和 driver 目录内容都没有。
原因分析

你现在的 nvshare 资源请求不再带 huawei.com/Ascend910 后，Ascend 官方 device-plugin 不会为 Pod 注入 NPU 设备节点与 driver 库。
当前 nvshare device-plugin 仍是 NVIDIA 风格注入逻辑：server.go (line 245) 只注入 LD_PRELOAD 和 NVIDIA_VISIBLE_DEVICES，没有 Ascend 所需设备/库注入。
因此 torch_npu 在加载依赖时找不到可用的 libascend_hal.so（native 模式可用是因为 Ascend plugin 做了注入）。
修复建议

短期绕过：测试中继续同时申请 huawei.com/Ascend910（能跑通，但会占用原生卡，失去真正共享意义）。
正式修复（推荐）：在 nvshare 的 NPU Allocate 流程补齐 Ascend 注入能力。
注入 ASCEND_VISIBLE_DEVICES（而不是 NVIDIA_VISIBLE_DEVICES）。
下发 Ascend 设备节点（DeviceSpecs：/dev/davinci*、/dev/devmm_svm、/dev/hisi_hdc、/dev/davinci_manager）。
挂载 host driver 库目录（至少 /usr/local/Ascend/driver/lib64/...）到容器可见路径。
需要时补齐 ASCEND_RUNTIME_OPTIONS 等运行时变量。
在 remote-test-smoke.sh 给 CANN 增一个开关（例如 XP_CANN_REQUIRE_NATIVE_RESOURCE_FOR_RUNTIME），在修复前可控地回退到“可跑通”模式。
```

- 修复后，报了一个新的错误，继续让codex自己去分析

```
cann的nvshare测试还是报NPU not available，请分析原因，日志见.tmplog/20260219-225007
```

- codex分析后，发现是npu逻辑序号和物理序号的问题，这里再看下codex的分析,真的是行云流水

```
结论：这次 NPU not available 的根因是 nvshare 注入了不正确的 ASCEND_RT_VISIBLE_DEVICES 值（用了物理卡号 3），导致 CANN runtime 判定设备不可用。

证据：

失败日志：nvshare-perf-cann-nvshare-1.log
只有 NPU not available，退出码 3。
device-plugin 日志：检测到 ASCEND_VISIBLE_DEVICES=3，并分配 3__3。
（当前运行日志中可见）
我做的 nvshare 探针 Pod 输出（同集群）显示：
ASCEND_RT_VISIBLE_DEVICES=3
ASCEND_VISIBLE_DEVICES=3
/dev/davinci3 存在
但 torch.npu.is_available=False, device_count=0
CANN 报错：set ASCEND_RT_VISIBLE_DEVICES:3 error, input data rang[0-1)（错误码 207004）
对照 native 探针：
ASCEND_VISIBLE_DEVICES=1
is_available=True, device_count=1
关键验证：在 nvshare Pod 里仅 unset ASCEND_RT_VISIBLE_DEVICES 后，is_available=True, device_count=1。
根因位置：

server.go
Allocate 里同时设置了 ASCEND_RT_VISIBLE_DEVICES / ASCEND_VISIBLE_DEVICES / NPU_VISIBLE_DEVICES 为物理 token（如 3）。
其中 ASCEND_RT_VISIBLE_DEVICES=3 在单卡容器场景不合法。
修复方向：

不要给 ASCEND_RT_VISIBLE_DEVICES 传物理卡号。
推荐：先不注入 ASCEND_RT_VISIBLE_DEVICES（只保留 ASCEND_VISIBLE_DEVICES/NPU_VISIBLE_DEVICES），可直接恢复可用性。
或者改成容器内逻辑索引（单卡设为 0），但这要求设备节点映射策略同时一致。
```

- 致此，基本功能已经跑通，不过做了一轮简单的性能测试，发现npu这边，损耗是比较大的，大概有20%的损耗，后续需要继续优化

# day 15 功能完善

- 性能问题codex分析了一下，不是npu本身的造成的，是pod启动时间的差异，npu本身在原生和nvshare模式下差异不大，所以性能问题就先放下了

- 先验证下之前的一些配额管理能力
```
接下来我想验证下cann nvshare模式下，之前的内存配额、算力配额、以及配额动态调整能力，首先分析当前代码版本是否支持这些能力，以及我如何验证
```