#pragma once
#include <cstdint>
#include <cstring>
#define WHISPER_SAMPLE_RATE 16000
#define WHISPER_SAMPLING_GREEDY 0
struct whisper_context {};
struct whisper_context_params { bool use_gpu; };
struct whisper_full_params { bool print_progress, print_realtime, print_special, print_timestamps, token_timestamps, translate, single_segment, no_context; const char *language; int n_threads; };
struct whisper_token_data { int id; int64_t t0, t1; };
inline whisper_context_params whisper_context_default_params(){ return {}; }
inline whisper_context *whisper_init_from_file_with_params(const char*, whisper_context_params){ static whisper_context c; return &c; }
inline void whisper_free(whisper_context*){}
inline whisper_full_params whisper_full_default_params(int){ return {}; }
inline int whisper_full(whisper_context*,whisper_full_params,const float*,int){return 0;}
inline int whisper_full_n_segments(whisper_context*){return 1;}
inline const char *whisper_full_get_segment_text(whisper_context*,int){return " 智我们人";}
inline int whisper_full_n_tokens(whisper_context*,int){return 4;}
inline whisper_token_data whisper_full_get_token_data(whisper_context*,int,int i){const whisper_token_data t[]={{1,10,20},{2,20,30},{3,30,40},{4,40,40}};return t[i];}
inline const char *whisper_full_get_token_text(whisper_context*,int,int i){const char *const t[]={"\xe6\x99","\xba","\xe6\x88\x91\xe4\xbb\xac","\xe4\xba\xba"};return t[i];}
inline int whisper_token_eot(whisper_context*){return 100;}
