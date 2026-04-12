#include "include/AileenLiteRTLMBridge.h"

#include <cstdlib>
#include <cstring>
#include <string>

#if GEMMA_LITERTLM_LINKED
#import <Foundation/Foundation.h>

#include <LiteRTLM/engine.h>
#endif

struct GemmaBridgeSession {
#if GEMMA_LITERTLM_LINKED
  LiteRtLmEngine* engine = nullptr;
  LiteRtLmConversation* conversation = nullptr;
#endif
};

namespace {

#if GEMMA_LITERTLM_LINKED
thread_local std::string g_last_error;
thread_local std::string g_last_response_json;

const char* SetLastError(const std::string& message) {
  g_last_error = message;
  return g_last_error.c_str();
}

const char* SetLastError(NSString* message) {
  return SetLastError(message == nil ? "Unknown LiteRT-LM error."
                                     : std::string(message.UTF8String));
}

LiteRtLmEngine* CreateEngine(const char* model_path, const char** error_message) {
  const char* text_backend = std::getenv("GEMMA_LITERT_TEXT_BACKEND");
  const char* vision_backend = std::getenv("GEMMA_LITERT_VISION_BACKEND");
  auto* settings = litert_lm_engine_settings_create(
      model_path, text_backend != nullptr ? text_backend : "cpu",
      /*vision_backend_str=*/vision_backend != nullptr ? vision_backend : "cpu",
      /*audio_backend_str=*/nullptr);
  if (settings == nullptr) {
    if (error_message != nullptr) {
      *error_message = SetLastError("Failed to create LiteRT-LM engine settings.");
    }
    return nullptr;
  }

  litert_lm_engine_settings_set_max_num_tokens(settings, 4096);
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

LiteRtLmConversation* CreateConversation(LiteRtLmEngine* engine,
                                         const char* tools_json,
                                         const char** error_message) {
  auto* session_config = litert_lm_session_config_create();
  if (session_config == nullptr) {
    if (error_message != nullptr) {
      *error_message = SetLastError("Failed to create LiteRT-LM session config.");
    }
    return nullptr;
  }

  litert_lm_session_config_set_max_output_tokens(session_config, 1024);

  auto* conversation_config = litert_lm_conversation_config_create(
      engine, session_config, /*system_message_json=*/nullptr,
      /*tools_json=*/tools_json, /*messages_json=*/nullptr,
      /*enable_constrained_decoding=*/false);
  litert_lm_session_config_delete(session_config);

  if (conversation_config == nullptr) {
    if (error_message != nullptr) {
      *error_message =
          SetLastError("Failed to create LiteRT-LM conversation config.");
    }
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
#endif

}  // namespace

GemmaBridgeSession* gemma_bridge_session_create(const char* model_path,
                                                const char** error_message) {
  return gemma_bridge_session_create_with_tools(model_path, nullptr,
                                                error_message);
}

GemmaBridgeSession* gemma_bridge_session_create_with_tools(
    const char* model_path,
    const char* tools_json,
    const char** error_message) {
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
  bridge_session->engine = CreateEngine(model_path, error_message);
  if (bridge_session->engine == nullptr) {
    delete bridge_session;
    return nullptr;
  }

  bridge_session->conversation =
      CreateConversation(bridge_session->engine, tools_json, error_message);
  if (bridge_session->conversation == nullptr) {
    litert_lm_engine_delete(bridge_session->engine);
    delete bridge_session;
    return nullptr;
  }

  return bridge_session;
#else
  (void)model_path;
  (void)tools_json;
  if (error_message != nullptr) {
    *error_message =
        "LiteRT-LM native runtime is not linked yet. Link the iOS runtime and "
        "rebuild with GEMMA_LITERTLM_LINKED=1.";
  }
  return nullptr;
#endif
}

void gemma_bridge_session_destroy(GemmaBridgeSession* session) {
  if (session == nullptr) {
    return;
  }

#if GEMMA_LITERTLM_LINKED
  if (session->conversation != nullptr) {
    litert_lm_conversation_delete(session->conversation);
  }
  if (session->engine != nullptr) {
    litert_lm_engine_delete(session->engine);
  }
#endif

  delete session;
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

  const int result = litert_lm_conversation_send_message_stream(
      session->conversation, message_json.c_str(), /*extra_context=*/nullptr,
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

  LiteRtLmJsonResponse* response =
      litert_lm_conversation_send_message(session->conversation, message_json,
                                          /*extra_context=*/nullptr);
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
