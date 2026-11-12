// Rolling-window adaptation of whisper.cpp examples/stream/stream.cpp,
// commit d2c6f05a46dacf663e357bcf0ed40f542a72825d, MIT license.
// Input: little-endian mono float32 PCM, 16 kHz on stdin. No microphone or files.
// Output: one line per update: P<TAB>text or F<TAB>text.
#include "whisper.h"
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
int main(int argc,char**argv) {
 if(argc!=3) return 2;
 auto cp=whisper_context_default_params(); cp.use_gpu=false;
 whisper_context *ctx=whisper_init_from_file_with_params(argv[1],cp); if(!ctx) return 3;
 constexpr size_t step=2*WHISPER_SAMPLE_RATE, length=10*WHISPER_SAMPLE_RATE, keep=WHISPER_SAMPLE_RATE/5;
 constexpr int commitEvery=4;
 std::vector<float> rolling, incoming(step); int iteration=0;
 for (;;) {
  size_t n=fread(incoming.data(),sizeof(float),step,stdin); if(n==0) break;
  rolling.insert(rolling.end(),incoming.begin(),incoming.begin()+n);
  if(rolling.size()>length+keep) rolling.erase(rolling.begin(),rolling.end()-(length+keep));
  if (std::all_of(rolling.begin(), rolling.end(), [](float value) { return value == 0.0f; })) {
   printf("P\t\n"); fflush(stdout); continue;
  }
  auto p=whisper_full_default_params(WHISPER_SAMPLING_GREEDY); p.print_progress=false; p.print_realtime=false; p.print_special=false; p.print_timestamps=false; p.translate=false; p.single_segment=true; p.no_context=true; p.language=argv[2]; p.n_threads=4;
  if(whisper_full(ctx,p,rolling.data(),(int)rolling.size())!=0) { whisper_free(ctx); return 4; }
  std::string text; for(int i=0;i<whisper_full_n_segments(ctx);i++){ const char*seg=whisper_full_get_segment_text(ctx,i); if(seg) text+=seg; }
  for(char &c:text) if(c=='\n'||c=='\r'||c=='\t') c=' ';
  if(text.find("[BLANK_AUDIO]") != std::string::npos) text.clear();
  bool final=(++iteration%commitEvery)==0 || n<step;
  printf("%c\t%s\n",final?'F':'P',text.c_str()); fflush(stdout);
  if(final && rolling.size()>keep) rolling.erase(rolling.begin(),rolling.end()-keep);
  if(n<step) break;
 }
 whisper_free(ctx); return 0;
}
