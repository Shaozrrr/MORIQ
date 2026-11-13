// Rolling-window adaptation of whisper.cpp examples/stream/stream.cpp,
// commit d2c6f05a46dacf663e357bcf0ed40f542a72825d, MIT license.
// Input: little-endian mono float32 PCM, 16 kHz on stdin. No microphone or files.
// Output: P/F text lines. With --word-timestamps, additionally emit B/W/E
// records containing sample offsets relative to this process's stdin stream.
#include "whisper.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
int main(int argc,char**argv) {
 if(argc!=3 && !(argc==4 && std::strcmp(argv[3],"--word-timestamps")==0)) return 2;
 const bool timed=argc==4;
 auto cp=whisper_context_default_params(); cp.use_gpu=false;
 whisper_context *ctx=whisper_init_from_file_with_params(argv[1],cp); if(!ctx) return 3;
 constexpr size_t step=2*WHISPER_SAMPLE_RATE, length=10*WHISPER_SAMPLE_RATE, keep=WHISPER_SAMPLE_RATE/5;
 constexpr int commitEvery=4;
 std::vector<float> rolling, incoming(step); int iteration=0; uint64_t totalSamples=0;
 for (;;) {
  size_t n=fread(incoming.data(),sizeof(float),step,stdin); if(n==0) break; totalSamples+=n;
  rolling.insert(rolling.end(),incoming.begin(),incoming.begin()+n);
  if(rolling.size()>length+keep) rolling.erase(rolling.begin(),rolling.end()-(length+keep));
  if (std::all_of(rolling.begin(), rolling.end(), [](float value) { return value == 0.0f; })) {
   printf("P\t\n"); fflush(stdout); continue;
  }
  auto p=whisper_full_default_params(WHISPER_SAMPLING_GREEDY); p.print_progress=false; p.print_realtime=false; p.print_special=false; p.print_timestamps=false; p.token_timestamps=timed; p.translate=false; p.single_segment=true; p.no_context=true; p.language=argv[2]; p.n_threads=4;
  if(whisper_full(ctx,p,rolling.data(),(int)rolling.size())!=0) { whisper_free(ctx); return 4; }
  std::string text; for(int i=0;i<whisper_full_n_segments(ctx);i++){ const char*seg=whisper_full_get_segment_text(ctx,i); if(seg) text+=seg; }
  for(char &c:text) if(c=='\n'||c=='\r'||c=='\t') c=' ';
  if(text.find("[BLANK_AUDIO]") != std::string::npos) text.clear();
  bool final=(++iteration%commitEvery)==0 || n<step;
  printf("%c\t%s\n",final?'F':'P',text.c_str()); fflush(stdout);
  // English BPE tokens beginning with a space form a word. Do not pretend this
  // is word segmentation for Chinese or other scripts. Offsets use the input
  // sample clock, not wall time or the clock of a different capture source.
  if(timed && std::strncmp(argv[2],"en",2)==0) {
   const uint64_t base=totalSamples-rolling.size();
   printf("B\t%c\t%llu\t%llu\n",final?'F':'P',(unsigned long long)base,(unsigned long long)totalSamples);
   std::string word; int64_t begin=-1,end=-1;
   auto flush=[&]() {
    if(!word.empty() && begin>=0 && end>begin && (uint64_t)end<=rolling.size()) {
     printf("W\t%llu\t%llu\t",(unsigned long long)(base+begin),(unsigned long long)(base+end));
     static const char hex[]="0123456789abcdef";
     for(unsigned char c:word) { putchar(hex[c>>4]); putchar(hex[c&15]); }
     putchar('\n');
    }
    word.clear(); begin=end=-1;
   };
   for(int si=0;si<whisper_full_n_segments(ctx);++si) for(int ti=0;ti<whisper_full_n_tokens(ctx,si);++ti) {
    auto d=whisper_full_get_token_data(ctx,si,ti); const char *token=whisper_full_get_token_text(ctx,si,ti);
    if(d.id>=whisper_token_eot(ctx) || !token || !*token) continue;
    if(token[0]==' ' && !word.empty()) flush();
    if(d.t0>=0 && d.t1>=d.t0 && d.t1 <= (int64_t)(rolling.size()/160)) {
     const int64_t s=d.t0*160, e=d.t1*160;
     if(begin<0 || s<begin) begin=s; if(e>end) end=e;
    }
    word+=token;
   }
   flush(); puts("E"); fflush(stdout);
  }
  if(final && rolling.size()>keep) rolling.erase(rolling.begin(),rolling.end()-keep);
  if(n<step) break;
 }
 whisper_free(ctx); return 0;
}
