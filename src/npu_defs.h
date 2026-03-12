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

typedef enum aclrtDevAttr {
  ACL_DEV_ATTR_CUBE_CORE_NUM = 102,
  ACL_DEV_ATTR_VECTOR_CORE_NUM = 201,
} aclrtDevAttr;

#define ACL_SUCCESS 0
#define ACL_ERROR_UNINITIALIZE 100001
#define ACL_ERROR_BAD_ALLOC 200000

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
typedef aclError (*aclrtSetDevice_func)(int32_t deviceId);
typedef aclError (*aclrtLaunchKernel_func)(aclrtFuncHandle funcHandle,
                                           uint32_t numBlocks,
                                           const void* argsData, size_t argsSize,
                                           aclrtStream stream);
typedef aclError (*aclrtMemcpy_func)(void* dst, size_t destMax,
                                     const void* src, size_t count,
                                     aclrtMemcpyKind kind);
typedef aclError (*aclrtMemcpyAsync_func)(void* dst, size_t destMax,
                                          const void* src, size_t count,
                                          aclrtMemcpyKind kind,
                                          aclrtStream stream);
typedef aclError (*aclrtSynchronizeDevice_func)(void);
typedef aclError (*aclrtSynchronizeDeviceWithTimeout_func)(int32_t timeout);
typedef aclError (*aclrtSynchronizeStream_func)(aclrtStream stream);
typedef aclError (*aclrtSetDeviceResLimit_func)(int32_t deviceId,
                                                aclrtDevResLimitType type,
                                                uint32_t value);
typedef aclError (*aclrtSetStreamResLimit_func)(aclrtStream stream,
                                                aclrtDevResLimitType type,
                                                uint32_t value);
typedef aclError (*aclrtUseStreamResInCurrentThread_func)(aclrtStream stream);
typedef aclError (*aclrtGetDeviceInfo_func)(uint32_t deviceId,
                                            aclrtDevAttr attr, int64_t* value);

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
extern aclError aclrtSetDevice(int32_t deviceId);
extern aclError aclrtSynchronizeDevice(void);
extern aclError aclrtSynchronizeDeviceWithTimeout(int32_t timeout);
extern aclError aclrtSynchronizeStream(aclrtStream stream);
extern aclError aclrtLaunchKernel(aclrtFuncHandle funcHandle, uint32_t numBlocks,
                                  const void* argsData, size_t argsSize,
                                  aclrtStream stream);
extern aclError aclrtMemcpy(void* dst, size_t destMax, const void* src,
                            size_t count, aclrtMemcpyKind kind);
extern aclError aclrtMemcpyAsync(void* dst, size_t destMax, const void* src,
                                 size_t count, aclrtMemcpyKind kind,
                                 aclrtStream stream);

/* Real ACL runtime function pointers */
extern aclrtMalloc_func real_aclrtMalloc;
extern aclrtMallocAlign32_func real_aclrtMallocAlign32;
extern aclrtMallocCached_func real_aclrtMallocCached;
extern aclrtMallocWithCfg_func real_aclrtMallocWithCfg;
extern aclrtFree_func real_aclrtFree;
extern aclrtGetMemInfo_func real_aclrtGetMemInfo;
extern aclrtSetDevice_func real_aclrtSetDevice;
extern aclrtLaunchKernel_func real_aclrtLaunchKernel;
extern aclrtMemcpy_func real_aclrtMemcpy;
extern aclrtMemcpyAsync_func real_aclrtMemcpyAsync;
extern aclrtSynchronizeDevice_func real_aclrtSynchronizeDevice;
extern aclrtSynchronizeDeviceWithTimeout_func
    real_aclrtSynchronizeDeviceWithTimeout;
extern aclrtSynchronizeStream_func real_aclrtSynchronizeStream;
extern aclrtSetDeviceResLimit_func real_aclrtSetDeviceResLimit;
extern aclrtSetStreamResLimit_func real_aclrtSetStreamResLimit;
extern aclrtUseStreamResInCurrentThread_func
    real_aclrtUseStreamResInCurrentThread;
extern aclrtGetDeviceInfo_func real_aclrtGetDeviceInfo;

#endif /* _NPU_DEFS_H */
