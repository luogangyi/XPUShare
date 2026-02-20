/*
 * Kubernetes API helper header for nvshare-scheduler.
 */

#ifndef _NVSHARE_K8S_API_H_
#define _NVSHARE_K8S_API_H_

#include <stddef.h>

/* Initialize K8s API client (must call before other functions) */
int k8s_api_init(void);

/* Cleanup K8s API client */
void k8s_api_cleanup(void);

/*
 * Get Pod annotation value.
 * Returns malloc'ed string value, or NULL if not found/query failed.
 * If query_success is non-NULL, it is set to:
 *   1 -> API query succeeded (HTTP 200), annotation may be absent.
 *   0 -> API query failed (network/auth/http error).
 */
char* k8s_get_pod_annotation_ex(const char* ns, const char* pod_name,
                                const char* annotation_key,
                                int* query_success);

/*
 * Backward-compatible wrapper.
 * Returns malloc'ed string value, or NULL if not found/query failed.
 */
char* k8s_get_pod_annotation(const char* ns, const char* pod_name,
                             const char* annotation_key);

/* Parse memory size string (e.g., "4Gi") to bytes */
size_t parse_memory_size(const char* str);

/* Extract JSON string value by key (simple parser) - Exposed for testing */
char* extract_json_string(const char* json, const char* key);

#endif /* _NVSHARE_K8S_API_H_ */
