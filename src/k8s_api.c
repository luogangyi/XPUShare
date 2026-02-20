/*
 * Kubernetes API helper functions for nvshare-scheduler.
 * Used for reading Pod annotations to support dynamic memory limits.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "k8s_api.h"

#include <curl/curl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "common.h"

/* Buffer for curl response */
struct curl_buffer {
  char* data;
  size_t size;
};

/* Curl write callback */
static size_t k8s_curl_write_cb(void* contents, size_t size, size_t nmemb,
                                void* userp) {
  size_t realsize = size * nmemb;
  struct curl_buffer* buf = (struct curl_buffer*)userp;

  char* ptr = realloc(buf->data, buf->size + realsize + 1);
  if (ptr == NULL) {
    log_warn("k8s_api: realloc failed");
    return 0;
  }

  buf->data = ptr;
  memcpy(&(buf->data[buf->size]), contents, realsize);
  buf->size += realsize;
  buf->data[buf->size] = 0;

  return realsize;
}

/* Read service account token */
static char* read_sa_token(void) {
  static char token[8192];
  static int loaded = 0;

  if (loaded) return token;

  FILE* f = fopen("/var/run/secrets/kubernetes.io/serviceaccount/token", "r");
  if (!f) {
    log_warn("k8s_api: Cannot read service account token");
    return NULL;
  }

  size_t n = fread(token, 1, sizeof(token) - 1, f);
  fclose(f);
  token[n] = '\0';
  loaded = 1;

  return token;
}

/* Parse memory size string (e.g., "4Gi", "512Mi") */
size_t parse_memory_size(const char* str) {
  if (!str || !*str) return 0;

  char* endptr;
  double value = strtod(str, &endptr);

  if (endptr == str) return 0;

  /* Skip whitespace */
  while (*endptr == ' ') endptr++;

  /* Parse suffix */
  if (strcasecmp(endptr, "Gi") == 0 || strcasecmp(endptr, "GiB") == 0) {
    return (size_t)(value * 1024 * 1024 * 1024);
  } else if (strcasecmp(endptr, "Mi") == 0 || strcasecmp(endptr, "MiB") == 0) {
    return (size_t)(value * 1024 * 1024);
  } else if (strcasecmp(endptr, "Ki") == 0 || strcasecmp(endptr, "KiB") == 0) {
    return (size_t)(value * 1024);
  } else if (*endptr == '\0' || strcasecmp(endptr, "B") == 0) {
    return (size_t)value;
  }

  return 0;
}

/* Simple JSON string extraction (avoids full JSON parser dependency) */
/* Caller must free the returned string */
char* extract_json_string(const char* json, const char* key) {
  char search[128];

  snprintf(search, sizeof(search), "\"%s\"", key);
  char* pos = (char*)json;

  /* Loop to find correct key occurrence (skipping escaped keys) */
  while ((pos = strstr(pos, search)) != NULL) {
    /* Check if this is an escaped quote (part of another JSON string) */
    if (pos > json && *(pos - 1) == '\\') {
      pos++; /* Skip this match */
      continue;
    }

    /* Found a real match (un-escaped key) */
    /* Find the colon after the key */
    char* colon = strchr(pos, ':');
    if (!colon) return NULL;

    pos = colon + 1;

    /* Skip whitespace */
    while (*pos == ' ' || *pos == '\t') pos++;

    /* Check if value is a string or null */
    if (*pos == '"') {
      pos++;
      char* end = strchr(pos, '"');
      if (!end) return NULL;
      size_t len = end - pos;

      char* value = malloc(len + 1);
      if (!value) return NULL;

      strncpy(value, pos, len);
      value[len] = '\0';
      return value;
    } else if (strncmp(pos, "null", 4) == 0) {
      return NULL;
    }

    /* If matched key but invalid value format, assume it's the wrong key or
     * unparseable. But since keys are unique in valid JSON (at same level), and
     * we don't have level context, we must be careful. Since we only care about
     * "key":"value", if we find "key":123, we return NULL.
     */
    return NULL;
  }

  return NULL;
}

/*
 * Get Pod annotation value from K8s API.
 * Returns the annotation value or NULL if not found/query failed.
 * Caller MUST free the returned string.
 */
char* k8s_get_pod_annotation_ex(const char* ns, const char* pod_name,
                                const char* annotation_key,
                                int* query_success) {
  CURL* curl;
  CURLcode res;
  long http_code = 0;
  struct curl_buffer response = {0};

  if (query_success) *query_success = 0;

  char* token = read_sa_token();
  if (!token) return NULL;

  curl = curl_easy_init();
  if (!curl) return NULL;

  /* Build API URL */
  char url[512];
  char* api_server = getenv("KUBERNETES_SERVICE_HOST");
  char* api_port = getenv("KUBERNETES_SERVICE_PORT");

  if (!api_server || !api_port) {
    api_server = "kubernetes.default.svc";
    api_port = "443";
  }

  snprintf(url, sizeof(url), "https://%s:%s/api/v1/namespaces/%s/pods/%s",
           api_server, api_port, ns, pod_name);

  /* Set curl options */
  curl_easy_setopt(curl, CURLOPT_URL, url);
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, k8s_curl_write_cb);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 0L);
  curl_easy_setopt(curl, CURLOPT_CAINFO,
                   "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt");
  curl_easy_setopt(curl, CURLOPT_TIMEOUT, 5L);

  /* Set auth header */
  struct curl_slist* headers = NULL;
  char auth_header[8300];
  snprintf(auth_header, sizeof(auth_header), "Authorization: Bearer %s", token);
  headers = curl_slist_append(headers, auth_header);
  curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);

  /* Perform request */
  res = curl_easy_perform(curl);
  if (res == CURLE_OK) {
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
  }

  curl_slist_free_all(headers);
  curl_easy_cleanup(curl);

  if (res != CURLE_OK) {
    log_debug("k8s_api: curl failed: %s", curl_easy_strerror(res));
    free(response.data);
    return NULL;
  }
  if (http_code != 200) {
    log_debug("k8s_api: http failed: %ld for %s/%s", http_code, ns, pod_name);
    free(response.data);
    return NULL;
  }

  /* Parse response for annotation */
  if (response.data) {
    if (query_success) *query_success = 1;

    /* Look for the annotation in the response */
    if (getenv("NVSHARE_DEBUG")) {
      log_debug("k8s_api: Response JSON: %s", response.data);
    }

    /* extract_json_string returns malloc'd string now */
    char* anno_value = extract_json_string(response.data, annotation_key);

    if (getenv("NVSHARE_DEBUG")) {
      if (anno_value) {
        log_debug("k8s_api: Found annotation '%s': '%s'", annotation_key,
                  anno_value);
      } else {
        log_debug("k8s_api: Annotation '%s' not found", annotation_key);
      }
    }

    free(response.data);
    return anno_value;
  }

  return NULL;
}

char* k8s_get_pod_annotation(const char* ns, const char* pod_name,
                             const char* annotation_key) {
  return k8s_get_pod_annotation_ex(ns, pod_name, annotation_key, NULL);
}

/* Initialize K8s API (call curl_global_init) */
int k8s_api_init(void) {
  CURLcode res = curl_global_init(CURL_GLOBAL_DEFAULT);
  if (res != CURLE_OK) {
    log_warn("k8s_api: curl_global_init failed");
    return -1;
  }
  log_info("K8s API client initialized");
  return 0;
}

/* Cleanup K8s API */
void k8s_api_cleanup(void) { curl_global_cleanup(); }
