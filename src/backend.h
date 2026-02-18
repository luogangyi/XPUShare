/*
 * Shared runtime backend mode between hook and client code.
 */
#ifndef _NVSHARE_BACKEND_H_
#define _NVSHARE_BACKEND_H_

enum nvshare_backend_mode {
  NVSHARE_BACKEND_UNKNOWN = 0,
  NVSHARE_BACKEND_CUDA = 1,
  NVSHARE_BACKEND_NPU = 2,
};

extern int nvshare_backend_mode;
extern const char* nvshare_backend_mode_name(int mode);

#endif /* _NVSHARE_BACKEND_H_ */
