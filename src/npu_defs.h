/*
 * Minimal ACL Runtime declarations needed for NPU interposition.
 * Keep this header self-contained to avoid depending on CANN headers.
 */
#ifndef _NPU_DEFS_H
#define _NPU_DEFS_H

#include <stddef.h>
#include <stdint.h>

typedef int aclError;
typedef void* aclrtStream;
typedef void* aclrtFuncHandle;
typedef void* aclrtContext;
typedef void* aclrtArgsHandle;
typedef void aclrtLaunchKernelCfg;
typedef void aclrtPlaceHolderInfo;
typedef void aclTensorDesc;
typedef void aclDataBuffer;
typedef void aclopAttr;
typedef void aclopHandle;
typedef void aclmdlDataset;
typedef void aclmdlExecConfigHandle;

typedef enum aclrtMemMallocPolicy {
  ACL_MEM_MALLOC_HUGE_FIRST = 0,
  ACL_MEM_MALLOC_HUGE_ONLY = 1,
  ACL_MEM_MALLOC_NORMAL_ONLY = 2,
} aclrtMemMallocPolicy;

typedef enum aclrtMemAttr {
  ACL_DDR_MEM = 0,
  ACL_HBM_MEM = 1,
  ACL_MEM_NORMAL = 12,
} aclrtMemAttr;

typedef enum aclrtMemcpyKind {
  ACL_MEMCPY_HOST_TO_HOST = 0,
  ACL_MEMCPY_HOST_TO_DEVICE = 1,
  ACL_MEMCPY_DEVICE_TO_HOST = 2,
  ACL_MEMCPY_DEVICE_TO_DEVICE = 3,
  ACL_MEMCPY_DEFAULT = 4,
} aclrtMemcpyKind;

typedef enum aclrtDevResLimitType {
  ACL_RT_DEV_RES_CUBE_CORE = 0,
  ACL_RT_DEV_RES_VECTOR_CORE = 1,
} aclrtDevResLimitType;

#define ACL_SUCCESS 0
#define ACL_ERROR_UNINITIALIZE 100001
#define ACL_ERROR_BAD_ALLOC 200000
#define ACL_ERROR_RT_CONTEXT_NULL 107002

typedef aclError (*aclInit_func)(const char* configPath);
typedef aclError (*aclrtMalloc_func)(void** devPtr, size_t size,
                                     aclrtMemMallocPolicy policy);
typedef aclError (*aclrtMallocAlign32_func)(void** devPtr, size_t size,
                                            aclrtMemMallocPolicy policy);
typedef aclError (*aclrtMallocCached_func)(void** devPtr, size_t size,
                                           aclrtMemMallocPolicy policy);
typedef aclError (*aclrtMallocWithCfg_func)(void** devPtr, size_t size,
                                            aclrtMemMallocPolicy policy,
                                            void* cfg);
typedef aclError (*aclrtFree_func)(void* devPtr);
typedef aclError (*aclrtGetMemInfo_func)(aclrtMemAttr attr, size_t* free,
                                         size_t* total);
typedef aclError (*aclrtLaunchKernel_func)(aclrtFuncHandle funcHandle,
                                           uint32_t numBlocks,
                                           const void* argsData, size_t argsSize,
                                           aclrtStream stream);
typedef aclError (*aclrtLaunchKernelWithConfig_func)(
    aclrtFuncHandle funcHandle, uint32_t numBlocks, aclrtStream stream,
    aclrtLaunchKernelCfg* cfg, aclrtArgsHandle argsHandle, void* reserve);
typedef aclError (*aclrtLaunchKernelV2_func)(
    aclrtFuncHandle funcHandle, uint32_t numBlocks, const void* argsData,
    size_t argsSize, aclrtLaunchKernelCfg* cfg, aclrtStream stream);
typedef aclError (*aclrtLaunchKernelWithHostArgs_func)(
    aclrtFuncHandle funcHandle, uint32_t numBlocks, aclrtStream stream,
    aclrtLaunchKernelCfg* cfg, void* hostArgs, size_t argsSize,
    aclrtPlaceHolderInfo* placeHolderArray, size_t placeHolderNum);
typedef aclError (*aclrtMemcpy_func)(void* dst, size_t destMax,
                                     const void* src, size_t count,
                                     aclrtMemcpyKind kind);
typedef aclError (*aclrtMemcpyAsync_func)(void* dst, size_t destMax,
                                          const void* src, size_t count,
                                          aclrtMemcpyKind kind,
                                          aclrtStream stream);
typedef aclError (*aclrtSynchronizeDevice_func)(void);
typedef aclError (*aclrtSynchronizeStream_func)(aclrtStream stream);
typedef aclError (*aclrtSetDevice_func)(int32_t deviceId);
typedef aclError (*aclrtGetDeviceCount_func)(uint32_t* count);
typedef aclError (*aclrtGetDevice_func)(int32_t* deviceId);
typedef aclError (*aclrtSetCurrentContext_func)(aclrtContext context);
typedef aclError (*aclrtGetCurrentContext_func)(aclrtContext* context);
typedef aclError (*aclrtGetDeviceResLimit_func)(int32_t deviceId,
                                                aclrtDevResLimitType type,
                                                uint32_t* value);
typedef aclError (*aclrtSetDeviceResLimit_func)(int32_t deviceId,
                                                aclrtDevResLimitType type,
                                                uint32_t value);
typedef aclError (*aclrtGetStreamResLimit_func)(aclrtStream stream,
                                                aclrtDevResLimitType type,
                                                uint32_t* value);
typedef aclError (*aclrtSetStreamResLimit_func)(aclrtStream stream,
                                                aclrtDevResLimitType type,
                                                uint32_t value);
typedef aclError (*aclrtUseStreamResInCurrentThread_func)(aclrtStream stream);
typedef aclError (*aclopExecute_func)(
    const char* opType, int numInputs, const aclTensorDesc* const inputDesc[],
    const aclDataBuffer* const inputs[], int numOutputs,
    const aclTensorDesc* const outputDesc[], aclDataBuffer* const outputs[],
    const aclopAttr* attr, aclrtStream stream);
typedef aclError (*aclopExecuteV2_func)(const char* opType, int numInputs,
                                        aclTensorDesc* inputDesc[],
                                        aclDataBuffer* inputs[],
                                        int numOutputs,
                                        aclTensorDesc* outputDesc[],
                                        aclDataBuffer* outputs[],
                                        aclopAttr* attr, aclrtStream stream);
typedef aclError (*aclopExecWithHandle_func)(
    aclopHandle* handle, int numInputs, const aclDataBuffer* const inputs[],
    int numOutputs, aclDataBuffer* const outputs[], aclrtStream stream);
typedef aclError (*aclmdlExecute_func)(uint32_t modelId,
                                       const aclmdlDataset* input,
                                       aclmdlDataset* output);
typedef aclError (*aclmdlExecuteV2_func)(uint32_t modelId,
                                         const aclmdlDataset* input,
                                         aclmdlDataset* output,
                                         aclrtStream stream,
                                         const aclmdlExecConfigHandle* handle);
typedef aclError (*aclmdlExecuteAsync_func)(uint32_t modelId,
                                            const aclmdlDataset* input,
                                            aclmdlDataset* output,
                                            aclrtStream stream);
typedef aclError (*aclmdlExecuteAsyncV2_func)(
    uint32_t modelId, const aclmdlDataset* input, aclmdlDataset* output,
    aclrtStream stream, const aclmdlExecConfigHandle* handle);
typedef int rtError_t;
#define RT_ERROR_NONE 0
typedef rtError_t (*rtKernelLaunch_func)(const void* stubFunc,
                                         uint32_t numBlocks, void* args,
                                         uint32_t argsSize, void* smDesc,
                                         void* stm);
typedef rtError_t (*rtDeviceSynchronize_func)(void);
typedef rtError_t (*rtDeviceSynchronizeWithTimeout_func)(int32_t timeout);
typedef rtError_t (*rtStreamSynchronize_func)(void* stream);
typedef rtError_t (*rtStreamSynchronizeWithTimeout_func)(void* stream,
                                                         int32_t timeout);
typedef rtError_t (*rtKernelLaunchWithFlag_func)(const void* stubFunc,
                                                 uint32_t numBlocks,
                                                 const void* argsInfo,
                                                 void* smDesc, void* stm,
                                                 uint32_t flags);
typedef rtError_t (*rtKernelLaunchWithFlagV2_func)(
    const void* stubFunc, uint32_t numBlocks, const void* argsInfo,
    void* smDesc, void* stm, uint32_t flags, const void* cfgInfo);
typedef rtError_t (*rtKernelLaunchEx_func)(void* args, uint32_t argsSize,
                                           uint32_t flags, void* stm);
typedef rtError_t (*rtLaunchKernelByFuncHandleV3_func)(
    void* funcHandle, uint32_t numBlocks, const void* argsInfo, void* stm,
    const void* cfgInfo);
typedef rtError_t (*rtsLaunchKernelWithConfig_func)(
    void* funcHandle, uint32_t numBlocks, void* stm, void* cfg,
    void* argsHandle, void* reserve);
typedef rtError_t (*rtsLaunchKernelWithDevArgs_func)(
    void* funcHandle, uint32_t numBlocks, void* stm, void* cfg,
    const void* args, uint32_t argsSize, void* reserve);
typedef rtError_t (*rtsLaunchKernelWithHostArgs_func)(
    void* funcHandle, uint32_t numBlocks, void* stm, void* cfg, void* hostArgs,
    uint32_t argsSize, void* placeHolderArray, uint32_t placeHolderNum);
typedef rtError_t (*rtVectorCoreKernelLaunch_func)(
    const void* stubFunc, uint32_t numBlocks, const void* argsInfo,
    void* smDesc, void* stm, uint32_t flags, const void* cfgInfo);

/* Hooked ACL runtime functions */
extern aclError aclInit(const char* configPath);
extern aclError aclrtMalloc(void** devPtr, size_t size,
                            aclrtMemMallocPolicy policy);
extern aclError aclrtMallocAlign32(void** devPtr, size_t size,
                                   aclrtMemMallocPolicy policy);
extern aclError aclrtMallocCached(void** devPtr, size_t size,
                                  aclrtMemMallocPolicy policy);
extern aclError aclrtMallocWithCfg(void** devPtr, size_t size,
                                   aclrtMemMallocPolicy policy, void* cfg);
extern aclError aclrtFree(void* devPtr);
extern aclError aclrtGetMemInfo(aclrtMemAttr attr, size_t* free, size_t* total);
extern aclError aclrtLaunchKernel(aclrtFuncHandle funcHandle, uint32_t numBlocks,
                                  const void* argsData, size_t argsSize,
                                  aclrtStream stream);
extern aclError aclrtLaunchKernelWithConfig(aclrtFuncHandle funcHandle,
                                            uint32_t numBlocks,
                                            aclrtStream stream,
                                            aclrtLaunchKernelCfg* cfg,
                                            aclrtArgsHandle argsHandle,
                                            void* reserve);
extern aclError aclrtLaunchKernelV2(aclrtFuncHandle funcHandle,
                                    uint32_t numBlocks, const void* argsData,
                                    size_t argsSize, aclrtLaunchKernelCfg* cfg,
                                    aclrtStream stream);
extern aclError aclrtLaunchKernelWithHostArgs(
    aclrtFuncHandle funcHandle, uint32_t numBlocks, aclrtStream stream,
    aclrtLaunchKernelCfg* cfg, void* hostArgs, size_t argsSize,
    aclrtPlaceHolderInfo* placeHolderArray, size_t placeHolderNum);
extern aclError aclrtMemcpy(void* dst, size_t destMax, const void* src,
                            size_t count, aclrtMemcpyKind kind);
extern aclError aclrtMemcpyAsync(void* dst, size_t destMax, const void* src,
                                 size_t count, aclrtMemcpyKind kind,
                                 aclrtStream stream);
extern aclError aclrtSynchronizeDevice(void);
extern aclError aclrtSynchronizeStream(aclrtStream stream);
extern aclError aclrtGetDeviceCount(uint32_t* count);
extern aclError aclrtSetDevice(int32_t deviceId);
extern aclError aclrtGetDevice(int32_t* deviceId);
extern aclError aclrtGetStreamResLimit(aclrtStream stream,
                                       aclrtDevResLimitType type,
                                       uint32_t* value);
extern aclError aclrtSetStreamResLimit(aclrtStream stream,
                                       aclrtDevResLimitType type,
                                       uint32_t value);
extern aclError aclrtUseStreamResInCurrentThread(aclrtStream stream);
extern aclError aclopExecute(const char* opType, int numInputs,
                             const aclTensorDesc* const inputDesc[],
                             const aclDataBuffer* const inputs[],
                             int numOutputs,
                             const aclTensorDesc* const outputDesc[],
                             aclDataBuffer* const outputs[],
                             const aclopAttr* attr, aclrtStream stream);
extern aclError aclopExecuteV2(const char* opType, int numInputs,
                               aclTensorDesc* inputDesc[],
                               aclDataBuffer* inputs[], int numOutputs,
                               aclTensorDesc* outputDesc[],
                               aclDataBuffer* outputs[], aclopAttr* attr,
                               aclrtStream stream);
extern aclError aclopExecWithHandle(aclopHandle* handle, int numInputs,
                                    const aclDataBuffer* const inputs[],
                                    int numOutputs,
                                    aclDataBuffer* const outputs[],
                                    aclrtStream stream);
extern aclError aclmdlExecute(uint32_t modelId, const aclmdlDataset* input,
                              aclmdlDataset* output);
extern aclError aclmdlExecuteV2(uint32_t modelId, const aclmdlDataset* input,
                                aclmdlDataset* output, aclrtStream stream,
                                const aclmdlExecConfigHandle* handle);
extern aclError aclmdlExecuteAsync(uint32_t modelId,
                                   const aclmdlDataset* input,
                                   aclmdlDataset* output, aclrtStream stream);
extern aclError aclmdlExecuteAsyncV2(uint32_t modelId,
                                     const aclmdlDataset* input,
                                     aclmdlDataset* output, aclrtStream stream,
                                     const aclmdlExecConfigHandle* handle);
extern void nvshare_apply_npu_core_limit(void);
extern void nvshare_apply_npu_core_limit_for_stream(aclrtStream stream,
                                                    const char* api_name);
extern int nvshare_prepare_npu_sync_context(void);
extern rtError_t rtDeviceSynchronize(void);
extern rtError_t rtDeviceSynchronizeWithTimeout(int32_t timeout);
extern rtError_t rtStreamSynchronize(void* stream);
extern rtError_t rtStreamSynchronizeWithTimeout(void* stream,
                                                int32_t timeout);
extern rtError_t rtKernelLaunch(const void* stubFunc, uint32_t numBlocks,
                                void* args, uint32_t argsSize, void* smDesc,
                                void* stm);
extern rtError_t rtKernelLaunchWithFlag(const void* stubFunc,
                                        uint32_t numBlocks,
                                        const void* argsInfo, void* smDesc,
                                        void* stm, uint32_t flags);
extern rtError_t rtKernelLaunchWithFlagV2(const void* stubFunc,
                                          uint32_t numBlocks,
                                          const void* argsInfo, void* smDesc,
                                          void* stm, uint32_t flags,
                                          const void* cfgInfo);
extern rtError_t rtKernelLaunchEx(void* args, uint32_t argsSize, uint32_t flags,
                                  void* stm);
extern rtError_t rtLaunchKernelByFuncHandleV3(void* funcHandle,
                                              uint32_t numBlocks,
                                              const void* argsInfo, void* stm,
                                              const void* cfgInfo);
extern rtError_t rtsLaunchKernelWithConfig(void* funcHandle,
                                           uint32_t numBlocks, void* stm,
                                           void* cfg, void* argsHandle,
                                           void* reserve);
extern rtError_t rtsLaunchKernelWithDevArgs(void* funcHandle,
                                            uint32_t numBlocks, void* stm,
                                            void* cfg, const void* args,
                                            uint32_t argsSize, void* reserve);
extern rtError_t rtsLaunchKernelWithHostArgs(
    void* funcHandle, uint32_t numBlocks, void* stm, void* cfg,
    void* hostArgs, uint32_t argsSize, void* placeHolderArray,
    uint32_t placeHolderNum);
extern rtError_t rtVectorCoreKernelLaunch(const void* stubFunc,
                                          uint32_t numBlocks,
                                          const void* argsInfo, void* smDesc,
                                          void* stm, uint32_t flags,
                                          const void* cfgInfo);

/* Real ACL runtime function pointers */
extern aclInit_func real_aclInit;
extern aclrtMalloc_func real_aclrtMalloc;
extern aclrtMallocAlign32_func real_aclrtMallocAlign32;
extern aclrtMallocCached_func real_aclrtMallocCached;
extern aclrtMallocWithCfg_func real_aclrtMallocWithCfg;
extern aclrtFree_func real_aclrtFree;
extern aclrtGetMemInfo_func real_aclrtGetMemInfo;
extern aclrtGetDeviceCount_func real_aclrtGetDeviceCount;
extern aclrtLaunchKernel_func real_aclrtLaunchKernel;
extern aclrtLaunchKernelWithConfig_func real_aclrtLaunchKernelWithConfig;
extern aclrtLaunchKernelV2_func real_aclrtLaunchKernelV2;
extern aclrtLaunchKernelWithHostArgs_func real_aclrtLaunchKernelWithHostArgs;
extern aclrtMemcpy_func real_aclrtMemcpy;
extern aclrtMemcpyAsync_func real_aclrtMemcpyAsync;
extern aclrtSynchronizeDevice_func real_aclrtSynchronizeDevice;
extern aclrtSynchronizeStream_func real_aclrtSynchronizeStream;
extern aclrtSetDevice_func real_aclrtSetDevice;
extern aclrtGetDevice_func real_aclrtGetDevice;
extern aclrtSetCurrentContext_func real_aclrtSetCurrentContext;
extern aclrtGetCurrentContext_func real_aclrtGetCurrentContext;
extern aclrtGetDeviceResLimit_func real_aclrtGetDeviceResLimit;
extern aclrtSetDeviceResLimit_func real_aclrtSetDeviceResLimit;
extern aclrtGetStreamResLimit_func real_aclrtGetStreamResLimit;
extern aclrtSetStreamResLimit_func real_aclrtSetStreamResLimit;
extern aclrtUseStreamResInCurrentThread_func
    real_aclrtUseStreamResInCurrentThread;
extern aclopExecute_func real_aclopExecute;
extern aclopExecuteV2_func real_aclopExecuteV2;
extern aclopExecWithHandle_func real_aclopExecWithHandle;
extern aclmdlExecute_func real_aclmdlExecute;
extern aclmdlExecuteV2_func real_aclmdlExecuteV2;
extern aclmdlExecuteAsync_func real_aclmdlExecuteAsync;
extern aclmdlExecuteAsyncV2_func real_aclmdlExecuteAsyncV2;
extern rtDeviceSynchronize_func real_rtDeviceSynchronize;
extern rtDeviceSynchronizeWithTimeout_func real_rtDeviceSynchronizeWithTimeout;
extern rtStreamSynchronize_func real_rtStreamSynchronize;
extern rtStreamSynchronizeWithTimeout_func real_rtStreamSynchronizeWithTimeout;
extern rtKernelLaunch_func real_rtKernelLaunch;
extern rtKernelLaunchWithFlag_func real_rtKernelLaunchWithFlag;
extern rtKernelLaunchWithFlagV2_func real_rtKernelLaunchWithFlagV2;
extern rtKernelLaunchEx_func real_rtKernelLaunchEx;
extern rtLaunchKernelByFuncHandleV3_func real_rtLaunchKernelByFuncHandleV3;
extern rtsLaunchKernelWithConfig_func real_rtsLaunchKernelWithConfig;
extern rtsLaunchKernelWithDevArgs_func real_rtsLaunchKernelWithDevArgs;
extern rtsLaunchKernelWithHostArgs_func real_rtsLaunchKernelWithHostArgs;
extern rtVectorCoreKernelLaunch_func real_rtVectorCoreKernelLaunch;

#endif /* _NPU_DEFS_H */
