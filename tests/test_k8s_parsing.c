#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../src/k8s_api.h"

/* Mock log functions or include common.h?
 * simpler to just declare them or link with common.o logic
 * or simplest: include k8s_api.c but defined out curl stuff?
 * No, let's link against k8s_api.o
 */

/* We need to define logging functions since k8s_api.c uses them */
int __debug = 1;
void log_debug(const char* fmt, ...) {}
void log_info(const char* fmt, ...) {}
void log_warn(const char* fmt, ...) {}
void log_error(const char* fmt, ...) {}
void log_fatal(const char* fmt, ...) { exit(1); }

int main() {
  printf("Running k8s_api JSON parsing tests...\n");

  const char* json_normal =
      "{\"metadata\":{\"annotations\":{\"nvshare.com/"
      "gpu-memory-limit\":\"2Gi\"}}}";
  char* val = extract_json_string(json_normal, "nvshare.com/gpu-memory-limit");
  assert(val != NULL);
  assert(strcmp(val, "2Gi") == 0);
  printf("PASS: Normal annotation\n");

  /* Test with last-applied-configuration (escaped) coming BEFORE the real one
   */
  const char* json_escaped_first =
      "{\"metadata\":{\"annotations\":{"
      "\"kubectl.kubernetes.io/"
      "last-applied-configuration\":\"{\\\"metadata\\\":{\\\"annotations\\\":{"
      "\\\"nvshare.com/gpu-memory-limit\\\":\\\"2Gi\\\"}}}\","
      "\"nvshare.com/gpu-memory-limit\":\"4Gi\"}}}";

  val = extract_json_string(json_escaped_first, "nvshare.com/gpu-memory-limit");
  assert(val != NULL);
  /* Should find 4Gi, not 2Gi */
  if (strcmp(val, "4Gi") != 0) {
    printf("FAIL: Expected 4Gi, got %s\n", val);
    return 1;
  }
  printf("PASS: Escaped key in last-applied-configuration (first)\n");

  /* Test with last-applied-configuration (escaped) coming AFTER the real one */
  const char* json_escaped_last =
      "{\"metadata\":{\"annotations\":{"
      "\"nvshare.com/gpu-memory-limit\":\"8Gi\","
      "\"kubectl.kubernetes.io/"
      "last-applied-configuration\":\"{\\\"metadata\\\":{\\\"annotations\\\":{"
      "\\\"nvshare.com/gpu-memory-limit\\\":\\\"2Gi\\\"}}}\""
      "}}}";

  val = extract_json_string(json_escaped_last, "nvshare.com/gpu-memory-limit");
  assert(val != NULL);
  assert(strcmp(val, "8Gi") == 0);
  printf("PASS: Escaped key in last-applied-configuration (last)\n");

  /* Test not found */
  const char* json_missing =
      "{\"metadata\":{\"annotations\":{\"other\":\"value\"}}}";
  val = extract_json_string(json_missing, "nvshare.com/gpu-memory-limit");
  assert(val == NULL);
  printf("PASS: Missing key\n");

  /* Test null value */
  const char* json_null =
      "{\"metadata\":{\"annotations\":{\"nvshare.com/"
      "gpu-memory-limit\":null}}}";
  val = extract_json_string(json_null, "nvshare.com/gpu-memory-limit");
  assert(val == NULL);
  printf("PASS: Null value\n");

  printf("All parsing tests passed!\n");
  return 0;
}
