#include "include/AileenLiteRTLMBridge.h"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <string>
#include <strings.h>

#if GEMMA_LITERTLM_LINKED
#import <Foundation/Foundation.h>

#include <LiteRTLM/engine.h>
#include <mach/mach.h>
#endif

struct GemmaBridgeSession {
#if GEMMA_LITERTLM_LINKED
  LiteRtLmEngine* engine = nullptr;
  LiteRtLmConversation* conversation = nullptr;
  std::string extra_context_json;
  uint64_t session_id = 0;
  uint64_t conversation_generation = 0;
#endif
};

namespace {

#if GEMMA_LITERTLM_LINKED
thread_local std::string g_last_error;
thread_local std::string g_last_response_json;
std::atomic<uint64_t> g_next_session_id{1};

bool DebugLoggingEnabled() {
  const char* flag = std::getenv("AILEEN_GEMMA_BRIDGE_DEBUG");
  return flag != nullptr && std::strlen(flag) > 0 && std::strcmp(flag, "0") != 0;
}

int ResolveMaxOutputTokens() {
  const char* override = std::getenv("GEMMA_LITERT_MAX_OUTPUT_TOKENS");
  if (override == nullptr || std::strlen(override) == 0) {
    return 4000;
  }
  char* end = nullptr;
  const long parsed = std::strtol(override, &end, 10);
  if (end == override || parsed <= 0 || parsed > 8192) {
    return 4000;
  }
  return static_cast<int>(parsed);
}

int ResolveMaxNumTokens() {
  const char* override = std::getenv("GEMMA_LITERT_MAX_NUM_TOKENS");
  if (override == nullptr || std::strlen(override) == 0) {
    return 4096;
  }
  char* end = nullptr;
  const long parsed = std::strtol(override, &end, 10);
  if (end == override || parsed <= 0 || parsed > 32768) {
    return 4096;
  }
  return static_cast<int>(parsed);
}

bool ResolveConstrainedDecodingEnabled(const char* tools_json) {
  if (tools_json == nullptr || std::strlen(tools_json) == 0) {
    return false;
  }
  const char* override = std::getenv("GEMMA_LITERT_CONSTRAINED_DECODING");
  if (override == nullptr || std::strlen(override) == 0) {
    return true;
  }
  return std::strcmp(override, "0") != 0 &&
         strcasecmp(override, "false") != 0 &&
         strcasecmp(override, "no") != 0;
}

uint64_t CurrentResidentSizeBytes() {
  mach_task_basic_info_data_t info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  const kern_return_t result =
      task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                reinterpret_cast<task_info_t>(&info), &count);
  if (result != KERN_SUCCESS) {
    return 0;
  }
  return static_cast<uint64_t>(info.resident_size);
}

void DebugLog(NSString* message) {
  if (!DebugLoggingEnabled()) {
    return;
  }
  NSString* line = [NSString
      stringWithFormat:@"[AileenLiteRT] %@\n",
                       message == nil ? @"(null)" : message];
  const char* path = std::getenv("AILEEN_GEMMA_BRIDGE_LOG_PATH");
  if (path != nullptr && std::strlen(path) > 0) {
    NSString* log_path = [[NSString alloc] initWithUTF8String:path];
    if (log_path != nil) {
      if (![log_path isAbsolutePath]) {
        log_path = [NSHomeDirectory() stringByAppendingPathComponent:log_path];
      }
      NSData* data = [line dataUsingEncoding:NSUTF8StringEncoding];
      if (data != nil) {
        NSString* directory =
            [log_path stringByDeletingLastPathComponent];
        if (directory.length > 0) {
          [[NSFileManager defaultManager]
              createDirectoryAtPath:directory
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
        }
        if (![[NSFileManager defaultManager] fileExistsAtPath:log_path]) {
          [[NSFileManager defaultManager]
              createFileAtPath:log_path contents:nil attributes:nil];
        }
        NSFileHandle* handle =
            [NSFileHandle fileHandleForWritingAtPath:log_path];
        if (handle != nil) {
          @try {
            [handle seekToEndOfFile];
            [handle writeData:data];
          } @catch (__unused NSException* exception) {
          }
          [handle closeFile];
          return;
        }
      }
    }
  }
  fprintf(stderr, "%s", line.UTF8String);
}

void DebugLogSession(const char* phase, GemmaBridgeSession* session,
                     size_t message_length = 0, size_t tools_length = 0,
                     size_t system_length = 0) {
  if (!DebugLoggingEnabled()) {
    return;
  }

  const uint64_t session_id = session == nullptr ? 0 : session->session_id;
  const uint64_t generation =
      session == nullptr ? 0 : session->conversation_generation;
  const void* engine_ptr = session == nullptr ? nullptr : session->engine;
  const void* conversation_ptr =
      session == nullptr ? nullptr : session->conversation;
  const unsigned long long resident_mb =
      CurrentResidentSizeBytes() / (1024ull * 1024ull);
  NSString* log_line = [NSString
      stringWithFormat:
          @"phase=%s session=%llu generation=%llu engine=%p conversation=%p "
           "resident_mb=%llu message_bytes=%zu tools_bytes=%zu system_bytes=%zu "
           "extra_context_bytes=%zu",
          phase, session_id, generation, engine_ptr, conversation_ptr,
          resident_mb, message_length, tools_length, system_length,
          session == nullptr ? 0 : session->extra_context_json.size()];
  DebugLog(log_line);
}

const char* SetLastError(const std::string& message) {
  g_last_error = message;
  if (DebugLoggingEnabled()) {
    DebugLog([NSString stringWithFormat:@"error=%s", g_last_error.c_str()]);
  }
  return g_last_error.c_str();
}

const char* SetLastError(NSString* message) {
  return SetLastError(message == nil ? "Unknown LiteRT-LM error."
                                     : std::string(message.UTF8String));
}

LiteRtLmEngine* CreateEngine(const char* model_path, const char** error_message) {
  @autoreleasepool {
  const char* text_backend = std::getenv("GEMMA_LITERT_TEXT_BACKEND");
  const char* vision_backend = std::getenv("GEMMA_LITERT_VISION_BACKEND");
  const bool has_text_backend_override =
      text_backend != nullptr && std::strlen(text_backend) > 0;
  const bool has_vision_backend_override =
      vision_backend != nullptr && std::strlen(vision_backend) > 0;
  auto* settings = litert_lm_engine_settings_create(
      model_path, has_text_backend_override ? text_backend : "cpu",
      /*vision_backend_str=*/has_vision_backend_override ? vision_backend : "cpu",
      /*audio_backend_str=*/nullptr);
  if (settings == nullptr) {
    if (error_message != nullptr) {
      *error_message = SetLastError("Failed to create LiteRT-LM engine settings.");
    }
    return nullptr;
  }

  litert_lm_engine_settings_set_max_num_tokens(settings,
                                               ResolveMaxNumTokens());
  const char* cache_override = std::getenv("GEMMA_LITERT_CACHE_DIR");
  if (cache_override != nullptr && std::strlen(cache_override) > 0) {
    litert_lm_engine_settings_set_cache_dir(settings, cache_override);
  } else {
    NSArray<NSURL*>* cache_directories = [[NSFileManager defaultManager]
        URLsForDirectory:NSCachesDirectory
               inDomains:NSUserDomainMask];
    NSURL* cache_root = cache_directories.firstObject;
    NSURL* litert_cache_directory =
        [cache_root URLByAppendingPathComponent:@"GemmaLiteRT"
                                     isDirectory:YES];
    NSError* directory_error = nil;
    if (litert_cache_directory == nil ||
        ![[NSFileManager defaultManager] createDirectoryAtURL:litert_cache_directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&directory_error]) {
      if (error_message != nullptr) {
        *error_message = SetLastError(
            directory_error.localizedDescription ?: @"Failed to create LiteRT cache directory.");
      }
      litert_lm_engine_settings_delete(settings);
      return nullptr;
    }
    litert_lm_engine_settings_set_cache_dir(
        settings, litert_cache_directory.fileSystemRepresentation);
  }

  LiteRtLmEngine* engine = litert_lm_engine_create(settings);
  litert_lm_engine_settings_delete(settings);

  if (engine == nullptr && error_message != nullptr) {
    *error_message = SetLastError("Failed to create LiteRT-LM engine.");
  }
  return engine;
  }
}

LiteRtLmConversation* CreateConversation(LiteRtLmEngine* engine,
                                         const char* system_message_json,
                                         const char* tools_json,
                                         const char* messages_json,
                                         const char** error_message) {
  auto* session_config = litert_lm_session_config_create();
  if (session_config == nullptr) {
    if (error_message != nullptr) {
      *error_message = SetLastError("Failed to create LiteRT-LM session config.");
    }
    return nullptr;
  }

  litert_lm_session_config_set_max_output_tokens(session_config,
                                                 ResolveMaxOutputTokens());

  const bool enable_constrained_decoding =
      ResolveConstrainedDecodingEnabled(tools_json);
  auto* conversation_config = litert_lm_conversation_config_create(
      engine, session_config, system_message_json,
      /*tools_json=*/tools_json, /*messages_json=*/messages_json,
      /*enable_constrained_decoding=*/enable_constrained_decoding);

  if (conversation_config == nullptr) {
    if (error_message != nullptr) {
      *error_message =
          SetLastError("Failed to create LiteRT-LM conversation config.");
    }
    if (enable_constrained_decoding) {
      DebugLog(@"Constrained decoding conversation config failed; retrying without constrained decoding.");
      conversation_config = litert_lm_conversation_config_create(
          engine, session_config, system_message_json,
          /*tools_json=*/tools_json, /*messages_json=*/messages_json,
          /*enable_constrained_decoding=*/false);
      if (conversation_config != nullptr && error_message != nullptr) {
        *error_message = nullptr;
      }
    }
  }
  litert_lm_session_config_delete(session_config);

  if (conversation_config == nullptr) {
    return nullptr;
  }

  LiteRtLmConversation* conversation =
      litert_lm_conversation_create(engine, conversation_config);
  litert_lm_conversation_config_delete(conversation_config);

  if (conversation == nullptr && error_message != nullptr) {
    *error_message = SetLastError("Failed to create LiteRT-LM conversation.");
  }
  return conversation;
}

struct StreamContext {
  GemmaBridgeStreamCallback callback;
  void* user_context;
};

void ForwardStreamChunk(void* raw_context,
                        const char* chunk,
                        bool is_final,
                        const char* error_message) {
  auto* context = static_cast<StreamContext*>(raw_context);
  if (context == nullptr) {
    return;
  }

  context->callback(context->user_context, chunk, is_final, error_message);

  if (is_final || error_message != nullptr) {
    delete context;
  }
}

std::string BuildMessageJson(const char* prompt,
                             const void* image_bytes,
                             size_t image_bytes_length,
                             const char** error_message) {
  @autoreleasepool {
  NSString* prompt_string = [[NSString alloc] initWithUTF8String:prompt];
  if (prompt_string == nil || image_bytes == nullptr || image_bytes_length == 0) {
    if (error_message != nullptr) {
      *error_message = SetLastError("Failed to encode multimodal conversation message.");
    }
    return std::string();
  }

  NSData* image_data =
      [NSData dataWithBytes:image_bytes length:image_bytes_length];
  if (image_data == nil) {
    if (error_message != nullptr) {
      *error_message = SetLastError("Failed to load image bytes.");
    }
    return std::string();
  }

  NSString* image_blob = [image_data base64EncodedStringWithOptions:0];
  if (image_blob == nil) {
    if (error_message != nullptr) {
      *error_message = SetLastError("Failed to base64-encode image bytes.");
    }
    return std::string();
  }

  NSDictionary* message = @{
    @"role" : @"user",
    @"content" : @[
      @{
        @"type" : @"image",
        @"blob" : image_blob,
      },
      @{
        @"type" : @"text",
        @"text" : prompt_string,
      },
    ],
  };

  NSError* serialization_error = nil;
  NSData* json_data = [NSJSONSerialization dataWithJSONObject:message
                                                      options:0
                                                        error:&serialization_error];
  if (json_data == nil) {
    if (error_message != nullptr) {
      *error_message = SetLastError(serialization_error.localizedDescription);
    }
    return std::string();
  }

  NSString* json_string =
      [[NSString alloc] initWithData:json_data encoding:NSUTF8StringEncoding];
  if (json_string == nil) {
    if (error_message != nullptr) {
      *error_message =
          SetLastError("Failed to serialize multimodal conversation message.");
    }
    return std::string();
  }

  return std::string(json_string.UTF8String);
  }
}
#endif

}  // namespace

GemmaBridgeSession* gemma_bridge_session_create(const char* model_path,
                                                const char** error_message) {
  return gemma_bridge_session_create_with_system_and_tools(
      model_path, nullptr, nullptr, error_message);
}

GemmaBridgeSession* gemma_bridge_session_create_with_tools(
    const char* model_path,
    const char* tools_json,
    const char** error_message) {
  return gemma_bridge_session_create_with_system_and_tools(
      model_path, nullptr, tools_json, error_message);
}

GemmaBridgeSession* gemma_bridge_session_create_with_system_and_tools(
    const char* model_path,
    const char* system_message_json,
    const char* tools_json,
    const char** error_message) {
  @autoreleasepool {
  if (error_message != nullptr) {
    *error_message = nullptr;
  }

#if GEMMA_LITERTLM_LINKED
  if (model_path == nullptr || std::strlen(model_path) == 0) {
    if (error_message != nullptr) {
      *error_message = SetLastError("Model path is empty.");
    }
    return nullptr;
  }

  litert_lm_set_min_log_level(1);

  auto* bridge_session = new GemmaBridgeSession();
  bridge_session->session_id = g_next_session_id.fetch_add(1);
  bridge_session->engine = CreateEngine(model_path, error_message);
  if (bridge_session->engine == nullptr) {
    delete bridge_session;
    return nullptr;
  }

  bridge_session->conversation =
      CreateConversation(bridge_session->engine, system_message_json, tools_json,
                         /*messages_json=*/nullptr, error_message);
  if (bridge_session->conversation == nullptr) {
    litert_lm_engine_delete(bridge_session->engine);
    delete bridge_session;
    return nullptr;
  }
  bridge_session->conversation_generation = 1;
  DebugLogSession("create_session", bridge_session, 0,
                  tools_json == nullptr ? 0 : std::strlen(tools_json),
                  system_message_json == nullptr ? 0
                                                 : std::strlen(system_message_json));

  return bridge_session;
#else
  (void)model_path;
  (void)system_message_json;
  (void)tools_json;
  if (error_message != nullptr) {
    *error_message =
        "LiteRT-LM native runtime is not linked yet. Link the iOS runtime and "
        "rebuild with GEMMA_LITERTLM_LINKED=1.";
  }
  return nullptr;
#endif
  }
}

int gemma_bridge_session_recreate_conversation(GemmaBridgeSession* session,
                                               const char* system_message_json,
                                               const char* tools_json,
                                               const char** error_message) {
  return gemma_bridge_session_recreate_conversation_with_history(
      session, system_message_json, tools_json, /*messages_json=*/nullptr,
      error_message);
}

int gemma_bridge_session_recreate_conversation_with_history(
    GemmaBridgeSession* session,
    const char* system_message_json,
    const char* tools_json,
    const char* messages_json,
    const char** error_message) {
  @autoreleasepool {
  if (error_message != nullptr) {
    *error_message = nullptr;
  }

#if GEMMA_LITERTLM_LINKED
  if (session == nullptr || session->engine == nullptr) {
    if (error_message != nullptr) {
      *error_message = SetLastError("LiteRT-LM engine is not initialized.");
    }
    return 1;
  }

  if (session->conversation != nullptr) {
    litert_lm_conversation_delete(session->conversation);
    session->conversation = nullptr;
  }

  session->conversation = CreateConversation(session->engine, system_message_json,
                                             tools_json, messages_json,
                                             error_message);
  if (session->conversation != nullptr) {
    session->conversation_generation += 1;
  }
  DebugLogSession("recreate_conversation", session,
                  messages_json == nullptr ? 0 : std::strlen(messages_json),
                  tools_json == nullptr ? 0 : std::strlen(tools_json),
                  system_message_json == nullptr ? 0
                                                 : std::strlen(system_message_json));
  return session->conversation == nullptr ? 1 : 0;
#else
  (void)session;
  (void)system_message_json;
  (void)tools_json;
  if (error_message != nullptr) {
    *error_message = "LiteRT-LM native runtime is not linked yet.";
  }
  return 1;
#endif
  }
}

void gemma_bridge_session_set_extra_context(GemmaBridgeSession* session,
                                            const char* extra_context_json) {
  if (session == nullptr) {
    return;
  }

#if GEMMA_LITERTLM_LINKED
  session->extra_context_json =
      extra_context_json == nullptr ? "" : std::string(extra_context_json);
#else
  (void)extra_context_json;
#endif
}

void gemma_bridge_session_destroy(GemmaBridgeSession* session) {
  @autoreleasepool {
  if (session == nullptr) {
    return;
  }

#if GEMMA_LITERTLM_LINKED
  DebugLogSession("destroy_session", session);
  if (session->conversation != nullptr) {
    litert_lm_conversation_delete(session->conversation);
  }
  if (session->engine != nullptr) {
    litert_lm_engine_delete(session->engine);
  }
#endif

  delete session;
  }
}

int gemma_bridge_session_stream(GemmaBridgeSession* session,
                                const char* prompt,
                                const void* image_bytes,
                                size_t image_bytes_length,
                                GemmaBridgeStreamCallback callback,
                                void* context) {
  if (session == nullptr || callback == nullptr || prompt == nullptr) {
    return 1;
  }

#if GEMMA_LITERTLM_LINKED
  if (session->conversation == nullptr) {
    callback(context, nullptr, true,
             "LiteRT-LM conversation is not initialized.");
    return 1;
  }
  if (image_bytes == nullptr || image_bytes_length == 0) {
    callback(context, nullptr, true, "Image bytes are empty.");
    return 1;
  }

  const char* error_message = nullptr;
  std::string message_json =
      BuildMessageJson(prompt, image_bytes, image_bytes_length, &error_message);
  if (message_json.empty()) {
    callback(context, nullptr, true,
             error_message == nullptr ? "Failed to build message JSON."
                                      : error_message);
    return 1;
  }

  auto* stream_context = new StreamContext{
      .callback = callback,
      .user_context = context,
  };

  const char* extra_context = session->extra_context_json.empty()
                                  ? nullptr
                                  : session->extra_context_json.c_str();
  const int result = litert_lm_conversation_send_message_stream(
      session->conversation, message_json.c_str(), extra_context,
      ForwardStreamChunk, stream_context);

  if (result != 0) {
    delete stream_context;
  }
  return result;
#else
  (void)image_bytes;
  (void)image_bytes_length;
  callback(context, nullptr, true,
           "LiteRT-LM native runtime is not linked yet.");
  return 1;
#endif
}

int gemma_bridge_session_send_json(GemmaBridgeSession* session,
                                   const char* message_json,
                                   const char** response_json,
                                   const char** error_message) {
  @autoreleasepool {
  if (response_json != nullptr) {
    *response_json = nullptr;
  }
  if (error_message != nullptr) {
    *error_message = nullptr;
  }

#if GEMMA_LITERTLM_LINKED
  if (session == nullptr || session->conversation == nullptr ||
      message_json == nullptr) {
    if (error_message != nullptr) {
      *error_message = SetLastError("LiteRT-LM conversation is not initialized.");
    }
    return 1;
  }

  const char* extra_context = session->extra_context_json.empty()
                                  ? nullptr
                                  : session->extra_context_json.c_str();
  DebugLogSession("send_json_start", session, std::strlen(message_json));
  LiteRtLmJsonResponse* response =
      litert_lm_conversation_send_message(session->conversation, message_json,
                                          extra_context);
  if (response == nullptr) {
    if (error_message != nullptr) {
      *error_message = SetLastError("LiteRT-LM failed to send message.");
    }
    return 1;
  }

  const char* raw_response = litert_lm_json_response_get_string(response);
  if (raw_response == nullptr) {
    litert_lm_json_response_delete(response);
    if (error_message != nullptr) {
      *error_message = SetLastError("LiteRT-LM returned an empty response.");
    }
    return 1;
  }

  g_last_response_json = raw_response;
  if (response_json != nullptr) {
    *response_json = g_last_response_json.c_str();
  }
  litert_lm_json_response_delete(response);
  DebugLogSession("send_json_success", session, std::strlen(message_json));
  return 0;
#else
  (void)session;
  (void)message_json;
  if (error_message != nullptr) {
    *error_message = "LiteRT-LM native runtime is not linked yet.";
  }
  return 1;
#endif
  }
}

void gemma_bridge_session_cancel(GemmaBridgeSession* session) {
  if (session == nullptr) {
    return;
  }

#if GEMMA_LITERTLM_LINKED
  if (session->conversation != nullptr) {
    litert_lm_conversation_cancel_process(session->conversation);
  }
#endif
}
