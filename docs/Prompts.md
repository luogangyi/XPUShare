为了后续修改代码的时候，不出现大量因为format问题，导致diff出大量非功能修改，请对所有代码先统一进行一次format


当前项目仅支持一个gpu，即nvshare currently supports only one GPU per node, as nvshare-scheduler is hardcoded to use the Nvidia GPU with ID 0. 分析项目代码，设计实现支持多GPU方案。注意修改代码的时候，只修改真正改动的行，对没改动的行，不要重新代码或者进行format.

你是架构师，需要对libnvshare的架构和实现方案进行详细分析，请分析代码，输出详细的分析问到到docs目录下

你是架构师，需要对项目中Unified Memory的的架构和实现方案进行详细分析，请分析代码，输出详细的分析问到到docs目录下

你是架构师，需要对项目中lib、client、scheduler的部署模式、运行模式进行分析。例如lib是需要在业务使用的GPU容器中preload的吗？还是在Device-plugin中被preload？scheduler和client分别运行在哪？是否是常驻后台的进程？分析结果保存到docs下

分析在多GPU场景下，DevicePlugin如何调度GPU，例如每个GPU被虚拟化为10个vGPU，节点上有8个GPU，即80个vGPU，那么用户申请的vGPU，是否能优先调度到不同的物理机GPU，如果所有物理机GPU都有任务，是否能按GPU负载进行调度。如果当前代码就可以，请分析实现方案，如果当前代码不可以，请给出设计方案。方案保存到docs下