/*
 * Shared runtime backend mode between hook and client code.
 */
#ifndef _XPUSHARE_BACKEND_H_
#define _XPUSHARE_BACKEND_H_

enum xpushare_backend_mode {
  XPUSHARE_BACKEND_UNKNOWN = 0,
  XPUSHARE_BACKEND_CUDA = 1,
  XPUSHARE_BACKEND_NPU = 2,
};

extern int xpushare_backend_mode;
extern const char* xpushare_backend_mode_name(int mode);

#endif /* _XPUSHARE_BACKEND_H_ */
