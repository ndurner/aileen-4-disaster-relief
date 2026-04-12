#ifndef AILEEN_LITERTLM_BRIDGE_H
#define AILEEN_LITERTLM_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GemmaBridgeSession GemmaBridgeSession;

typedef void (*GemmaBridgeStreamCallback)(void* context,
                                          const char* chunk,
                                          bool is_final,
                                          const char* error_message);

GemmaBridgeSession* gemma_bridge_session_create(const char* model_path,
                                                const char** error_message);
GemmaBridgeSession* gemma_bridge_session_create_with_tools(
    const char* model_path,
    const char* tools_json,
    const char** error_message);
void gemma_bridge_session_destroy(GemmaBridgeSession* session);
int gemma_bridge_session_stream(GemmaBridgeSession* session,
                                const char* prompt,
                                const void* image_bytes,
                                size_t image_bytes_length,
                                GemmaBridgeStreamCallback callback,
                                void* context);
int gemma_bridge_session_send_json(GemmaBridgeSession* session,
                                   const char* message_json,
                                   const char** response_json,
                                   const char** error_message);
void gemma_bridge_session_cancel(GemmaBridgeSession* session);

#ifdef __cplusplus
}
#endif

#endif
