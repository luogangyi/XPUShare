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
typedef aclError (*aclrtSetDevice_func)(int32_t deviceId);
typedef aclError (*aclrtGetDevice_func)(int32_t* deviceId);
typedef aclError (*aclrtSetCurrentContext_func)(aclrtContext context);
typedef aclError (*aclrtGetCurrentContext_func)(aclrtContext* context);
typedef aclError (*aclrtGetDeviceResLimit_func)(int32_t deviceId,
                                                aclrtDevResLimitType type,
                                                uint32_t* value);
typedef aclError (*aclrtSetDeviceResLimit_func)(int32_t deviceId,
                                                aclrtDevResLimitType type,
                                                uint32_t value);
typedef int rtError_t;
#define RT_ERROR_NONE 0
typedef rtError_t (*rtKernelLaunch_func)(const void* stubFunc,
                                         uint32_t numBlocks, void* args,
                                         uint32_t argsSize, void* smDesc,
                                         void* stm);
typedef rtError_t (*rtKernelLaunchWithFlag_func)(const void* stubFunc,
                                                 uint32_t numBlocks,
                                                 const void* argsInfo,
                                                 void* smDesc, void* stm,
                                                 uint32_t flags);
typedef rtError_t (*rtLaunchKernelByFuncHandleV3_func)(
    void* funcHandle, uint32_t numBlocks, const void* argsInfo, void* stm,
    const void* cfgInfo);
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
extern void nvshare_apply_npu_core_limit(void);
extern int nvshare_prepare_npu_sync_context(void);
extern rtError_t rtKernelLaunch(const void* stubFunc, uint32_t numBlocks,
                                void* args, uint32_t argsSize, void* smDesc,
                                void* stm);
extern rtError_t rtKernelLaunchWithFlag(const void* stubFunc,
                                        uint32_t numBlocks,
                                        const void* argsInfo, void* smDesc,
                                        void* stm, uint32_t flags);
extern rtError_t rtLaunchKernelByFuncHandleV3(void* funcHandle,
                                              uint32_t numBlocks,
                                              const void* argsInfo, void* stm,
                                              const void* cfgInfo);
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
extern aclrtMalloc_func real_aclrtMalloc;
extern aclrtMallocAlign32_func real_aclrtMallocAlign32;
extern aclrtMallocCached_func real_aclrtMallocCached;
extern aclrtMallocWithCfg_func real_aclrtMallocWithCfg;
extern aclrtFree_func real_aclrtFree;
extern aclrtGetMemInfo_func real_aclrtGetMemInfo;
extern aclrtLaunchKernel_func real_aclrtLaunchKernel;
extern aclrtLaunchKernelWithConfig_func real_aclrtLaunchKernelWithConfig;
extern aclrtLaunchKernelV2_func real_aclrtLaunchKernelV2;
extern aclrtLaunchKernelWithHostArgs_func real_aclrtLaunchKernelWithHostArgs;
extern aclrtMemcpy_func real_aclrtMemcpy;
extern aclrtMemcpyAsync_func real_aclrtMemcpyAsync;
extern aclrtSynchronizeDevice_func real_aclrtSynchronizeDevice;
extern aclrtSetDevice_func real_aclrtSetDevice;
extern aclrtGetDevice_func real_aclrtGetDevice;
extern aclrtSetCurrentContext_func real_aclrtSetCurrentContext;
extern aclrtGetCurrentContext_func real_aclrtGetCurrentContext;
extern aclrtGetDeviceResLimit_func real_aclrtGetDeviceResLimit;
extern aclrtSetDeviceResLimit_func real_aclrtSetDeviceResLimit;
extern rtKernelLaunch_func real_rtKernelLaunch;
extern rtKernelLaunchWithFlag_func real_rtKernelLaunchWithFlag;
extern rtLaunchKernelByFuncHandleV3_func real_rtLaunchKernelByFuncHandleV3;
extern rtsLaunchKernelWithDevArgs_func real_rtsLaunchKernelWithDevArgs;
extern rtsLaunchKernelWithHostArgs_func real_rtsLaunchKernelWithHostArgs;
extern rtVectorCoreKernelLaunch_func real_rtVectorCoreKernelLaunch;

#endif /* _NPU_DEFS_H */
