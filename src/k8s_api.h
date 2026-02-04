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
 * Returns static buffer with value, or NULL if not found.
 */
char* k8s_get_pod_annotation(const char* ns, const char* pod_name,
                             const char* annotation_key);

/* Parse memory size string (e.g., "4Gi") to bytes */
size_t parse_memory_size(const char* str);

/* Extract JSON string value by key (simple parser) - Exposed for testing */
char* extract_json_string(const char* json, const char* key);

#endif /* _NVSHARE_K8S_API_H_ */
