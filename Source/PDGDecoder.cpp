// Native port of the relevant MIT-licensed 100apps/pdg_decoder algorithms.
// No executable code or resources are taken from the reference application.
#include "PDGTables.h"
#include <CommonCrypto/CommonDigest.h>
#include <vector>
#include <array>
#include <algorithm>
#include <stdexcept>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cstdio>
using Bytes = std::vector<uint8_t>;
static uint32_t u32(const uint8_t* p) { return uint32_t(p[0]) | uint32_t(p[1])<<8 | uint32_t(p[2])<<16 | uint32_t(p[3])<<24; }
static void put32(uint8_t* p, uint32_t v) { for(int i=0;i<4;i++)p[i]=v>>(8*i); }
static void require(bool ok,const char* message){if(!ok)throw std::runtime_error(message);}
static bool image(const Bytes& b) {
    if(b.size()<4)return false;
    return (b[0]==255&&b[1]==216&&b[2]==255) ||
        !memcmp(b.data(),"\x89PNG",4)||!memcmp(b.data(),"GIF8",4)||
        !memcmp(b.data(),"II*\0",4)||!memcmp(b.data(),"MM\0*",4)||
        (b[0]=='B'&&b[1]=='M') || (b.size()>12&&!memcmp(b.data()+4,"jP  ",4)) ||
        !memcmp(b.data(),"AT&T",4) || (b[0]==255&&b[1]==79&&b[2]==255&&b[3]==81);
}
static void tea(uint8_t* p,const uint32_t* k) {
    uint32_t v[4];for(int i=0;i<4;i++)v[i]=u32(p+4*i);
    uint32_t sum=0xE3779B90,delta=0x61C88647;
    for(int i=0;i<16;i++){
        v[3]-=(v[0]+sum)^(k[1]+(v[0]>>5))^(k[2]+(v[0]<<4));
        v[2]-=(v[3]+sum)^(k[3]+(v[3]>>5))^(k[0]+(v[3]<<4));
        v[1]-=(v[2]+sum)^(k[2]+(v[2]<<4))^(k[3]+(v[2]>>5));
        v[0]-=(v[1]+sum)^(k[1]+(v[1]>>5))^(k[0]+(v[1]<<4));
        sum+=delta;
    }
    for(int i=0;i<4;i++)put32(p+4*i,v[i]);
}
static void legacy(const Bytes& h,Bytes& b,int type) {
    if(type==1){const char* k="3.141592";for(size_t i=0;i<b.size();i++)b[i]^=k[i%8];return;}
    if(type<2||type>5)return;
    uint8_t md[16];CC_MD5(h.data()+64,48,md);
    const char* mix=type==4?"SSREADER":type==5?"e#fgF%3*":type==3?"SUPERSTAR4PDG2.0":nullptr;
    if(mix)for(int i=0;i<8;i++)md[i]^=mix[i];
    uint32_t k[4];for(int i=0;i<4;i++)k[i]=u32(md+4*i);
    for(size_t i=0;i+16<=b.size();i+=16)tea(b.data()+i,k);
}
#include "PDGSeries.h"
static void variant(const Bytes& h,Bytes& out,int type){
    static const Bytes key215=[] {
        const char* hex="3133326a6b73646961753334756b6a617364666c6b6a2140233233346166646a693738232532333441446620761c3d2d0773646b6a3930383334323c4144463e2f2377253474356f387577726f75796f75686a38393334303338703335307c2b5f53444661647772213233346761734d2c2e737066646c705b574565793364667366677366343839305e3a3921402335362638393338343937383930373839303534696f657275615e337e2132262a285f2b2a283830772675696466733967686964666f7765723233392d383974616572432821376100";
        Bytes b;for(size_t i=0;i<strlen(hex);i+=2){unsigned v;sscanf(hex+i,"%2x",&v);b.push_back(v);}return b;
    }();
    static const Bytes key130=[] {const char* s="Afgasdkol!@#$564746Lfat0[9i FDLAas090132!$@##$2354(*^78~*54sdfakl;ml;lak;j2a#$2342!@#128-reg;o[werqPWEQRioADSF1234&*(6908_)55454!";return Bytes(s,s+strlen(s));}();
    std::array<int64_t,32> fib{};fib[0]=fib[1]=1;for(int i=2;i<32;i++)fib[i]=fib[i-1]+fib[i-2];
    std::array<int64_t,64> primes{};primes[0]=2;primes[1]=3;
    for(int cur=5,pos=2,phase=1;pos<64;){
        if(cur!=25&&cur!=49&&cur!=121&&cur!=169&&cur!=289)primes[pos++]=cur;
        phase++;if(phase==3){cur+=4;phase=1;}else cur+=2;
    }
    auto mod=[](int64_t x,int64_t n){return (x%n+n)%n;};
    int64_t v5=h[28]|h[29]<<8,v6=h[16],v7=h[18],v8=(v5>>8)&255;
    int64_t v9=(v7+h[28]+v6)&255,v10=(v6-v7)&255,vo=(v7|v6)&255;
    int64_t v11=(v9*v10)&65535,v12=(v6*v8)&255,v13=(h[94]+v6*v7*v6)&255,vm=(v7*v6)&255;
    int64_t v24=(vo*vm+v8*v12-v11+v13+250)&511,v36=(vo*vo-v12*v13+v11*vm+250)&511;
    int64_t common=v12*v12+v9+v10+vo+vm+v8+v6;
    int64_t v14=key215[(common+key215[v13%215])%215]*key130[(common+key130[v13%130])%130];
    int64_t v15=key215[mod(v10*vm-v8,215)],v25=v14&511,v16=fib[(v5>>8)&31];
    int64_t v37=(key130[v6%130]*v15)&511,v17=primes[(v6*v8)&63],v26=v16&511,v38=v17&511;
    int64_t v28=v24,v29=(v36*(v14&511)-v24)&511,v18=v38*key130[v38%130];
    int64_t v27=primes[((v17&255)*key130[(v26*key215[v26%215])%130])&63]&511;
    int64_t v39=fib[((v16&255)*key215[v18%215])&31]&511,v19=((v14&511)*v39)&65535;
    int64_t v40=(v36*v19-(v17&511)*v27+v37*v37+250)&511;
    int64_t v41=(v24*v24+(v16&511)*(v16&511)-v36*v36)&511;
    int64_t v30=((v17&511)-v24*(v14&511))&511,v43=(v27*v39)&511;
    int64_t v42=(v36*v37+(v16&511)*(v17&511)-v19+v27+250)&511;
    int64_t v32=(v36+v24)&511,v31=(v27-v36*(v17&511))&511;
    int64_t v34=(v30+v42-(v14&511))&511,v44=(key130[v36%130]+key215[v40%215])&511;
    int64_t v33=(v29+v37)&511,v35=(v31+v33-v39)&511;
    int64_t v45=primes[((v14&255)*(((v36&255)*(v14&255)-(v24&255)+(v37&255))&255))&63]&511;
    int64_t v46=primes[key215[v30%215]&63]&511,v47=fib[key130[v30%130]&31]&511;
    int64_t seq[]={v24,v25,v26,v27,v28,v29,v30,v31,v32,v33,v34,v35,v36,v37,v38,v39,v40,v41,v42,v43,v44,v45,v46,v47};
    int a=seq[type-17]&65535,b=seq[type-5]&65535;
    if(a==b)return;
    int lo=std::min(a,b),hi=std::max(a,b);
    if(type<=0x14){
        int off=hi-lo==17?19:17;require(size_t(hi+off)<out.size(),"PDG 预处理数据被截断。");
        uint8_t v=out[hi]^out[hi+off];out[hi]=out[lo]^out[lo+off];out[lo]=v;
    }else if(type<=0x18){
        require(size_t(hi)<out.size(),"PDG 预处理数据被截断。");
        uint8_t x=out[lo]^out[hi];std::reverse(out.begin()+lo+1,out.begin()+hi);
        for(int i=lo+1;i<hi;i++)out[i]^=x;
    }else{
        int mid=(a>>1)+(b>>1);require(size_t(std::max(a,mid))<out.size(),"PDG 预处理数据被截断。");
        uint8_t v=out[a];if(mid!=a)v^=out[mid];out[a]=v-b;
    }
}
struct Bits {
    const Bytes& bytes;size_t bit=0;
    int read(){if(bit>=bytes.size()*8)return -1;int v=(bytes[bit/8]>>(7-bit%8))&1;bit++;return v;}
    size_t remaining() const{return bytes.size()*8-bit;}
    int peek(int count) const {
        if(bit+count>bytes.size()*8)return -1;
        size_t pos=bit/8;uint32_t value=uint32_t(bytes[pos])<<16;
        if(pos+1<bytes.size())value|=uint32_t(bytes[pos+1])<<8;
        if(pos+2<bytes.size())value|=bytes[pos+2];
        return (value>>(24-int(bit%8)-count))&((1<<count)-1);
    }
};
struct Prefix {
    int maximum;std::vector<RunCode> codes,lut;
    template<size_t N> Prefix(const RunCode(&source)[N],int max):maximum(max),codes(source,source+N),lut(1<<max,{0,0,0}) {
        std::sort(codes.begin(),codes.end(),[](auto a,auto b){return a.bits<b.bits;});
        for(auto c:codes){int count=1<<(maximum-c.bits),base=c.code<<(maximum-c.bits);for(int i=0;i<count;i++)if(!lut[base+i].bits)lut[base+i]=c;}
    }
};
static const Prefix whitePrefix(whiteCodes,13),blackPrefix(blackCodes,12),modePrefix(modeCodes,10);
static int code(Bits& bits,const Prefix& table,int fallback){
    int look=bits.peek(table.maximum);
    if(look>=0&&table.lut[look].bits){auto c=table.lut[look];bits.bit+=c.bits;return c.value;}
    int current=0;for(int n=1;n<=table.maximum;n++){int b=bits.read();if(b<0)return fallback;current=(current<<1)|b;for(auto c:table.codes)if(c.bits==n&&c.code==current)return c.value;}return fallback;
}
static int run(Bits& bits,bool black){
    int total=0;for(int i=0;i<256;i++){int v=code(bits,black?blackPrefix:whitePrefix,-1);require(v>=0,"PDG 行程编码异常。");total+=v;if(v<64)return total;}throw std::runtime_error("PDG 行程超限。");
}
static Bytes bitonal(const Bytes& input,int width,int height){
    require(width>0&&height>0&&width<=30000&&height<=30000&&int64_t(width)*height<=60000000,"PDG 页面尺寸异常。");
    Bytes stream=input;stream.resize(stream.size()+8);Bits bits{stream};
    int stride=((width+31)/32)*4;
    Bytes pixels(size_t(stride)*height,0);
    std::vector<int> previous(width*2+8,width),current(width*2+8,width);previous[0]=current[0]=0;
    size_t budget=std::max<size_t>(size_t(width)*height*4,65536);
    for(int y=0;y<height;y++){
        int x=0,index=0,reference=0;bool black=false;
        auto ref=[&](int i){return i<0?0:i>=int(previous.size())?width:previous[i];};
        while(x<width){
            require(budget-->0,"PDG 解码操作超限。");
            int mode=code(bits,modePrefix,13);
            if(mode==1){x=ref(reference+1);reference+=2;}
            else if(mode==2){
                int first=x+run(bits,black),second=first+run(bits,!black);
                require(index+6<int(current.size())&&first>=x&&second>=first&&second<=width,"PDG 水平行程异常。");
                current[index++]=first;current[index++]=second;x=second;
                while(reference<int(previous.size())-2&&ref(reference)<=x)reference+=2;
            }else{
                int delta=mode==4?1:mode==5?2:mode==6?3:mode==7?-1:mode==8?-2:mode==9?-3:0;
                require(mode==3||(mode>=4&&mode<=9)||(mode==13&&bits.remaining()<=64),"PDG 位流模式不支持。");
                int next=std::max(0,ref(reference++)+delta);
                require(next>=x&&next<=width&&index+5<int(current.size()),"PDG 转折点异常。");
                x=next;current[index++]=x;black=!black;
            }
        }
        require(x==width,"PDG 行宽异常。");
        for(int i=0;i<4;i++)current[index+i]=width;
        // In this codec paired transition ranges are white (palette index 1).
        for(int p=0;p+1<index;p+=2){
            int start=current[p],end=current[p+1];require(start>=0&&end>=start&&end<=width,"PDG 行程越界。");
            for(int v=start;v<end;v++)pixels[size_t(height-1-y)*stride+v/8]|=uint8_t(0x80>>(v%8));
        }
        previous.swap(current);
    }
    Bytes bmp(62+pixels.size(),0);bmp[0]='B';bmp[1]='M';put32(bmp.data()+2,bmp.size());put32(bmp.data()+10,62);
    put32(bmp.data()+14,40);put32(bmp.data()+18,width);put32(bmp.data()+22,height);bmp[26]=bmp[28]=1;
    put32(bmp.data()+34,pixels.size());put32(bmp.data()+46,2);bmp[58]=bmp[59]=bmp[60]=255;
    memcpy(bmp.data()+62,pixels.data(),pixels.size());return bmp;
}
extern "C" int lab_pdg_decode(const uint8_t* source,size_t size,uint8_t** output,size_t* length,char* error,size_t capacity){
    *output=nullptr;*length=0;
    try{
        require(source&&size>0&&size<=128*1024*1024,"PDG 页面数据大小异常。");
        Bytes all(source,source+size),result;
        if(size<2||source[0]!='H'||source[1]!='H'){require(image(all),"未识别的页面格式。");result=std::move(all);}
        else{
            if(size>=3&&all[2]==1){
                require(size>=56,"旧版 PDG 头部被截断。");
                uint32_t mode=u32(all.data()+7);require(mode==0||mode==4||mode==5,"不支持这种旧版 PDG 预处理类型。");
                require(all[14]!=0x46,"暂不支持加密旧版文本 PDG。");
                result.assign(all.begin()+56,all.end());
                if(mode){size_t skip=mode==4?1:2;require(result.size()>128+skip,"旧版 PDG 图像被截断。");result.erase(result.begin()+128,result.begin()+128+skip);}
                if(image(result)){size_t n=u32(all.data()+28);require(n>0&&n<=result.size(),"旧版 PDG 图像长度异常。");result.resize(n);}
                else result=bitonal(result,all[3]|all[4]<<8,all[5]|all[6]<<8);
            }else{
            require(size>=140,"PDG 头部被截断。");Bytes h(all.begin(),all.begin()+140);
            require(h[21]==0,"暂不支持分层 PDG 页面。");int type=h[15];
            require(type<=5||type==0x10||type==0x28||(type>=0x11&&type<=0x1c)||(type>=0xaa&&type<=0xac),"不支持这种 PDG 编码类型。");
            size_t offset=u32(h.data()+24),count=u32(h.data()+28);
            require(offset>=140&&offset<=size&&count>0&&count<=size-offset,"PDG 数据范围异常。");
            result.assign(all.begin()+offset,all.begin()+offset+count);
            PDGSeries::preprocess(h,result);type=h[15];
            if(type>=0x11&&type<=0x1c)variant(h,result,type);
            else legacy(h,result,type);
            if(!image(result)){
                require(h[20]!=24,"PDG 彩色页面内容未识别。");
                int width=h[16]|h[17]<<8,height=h[18]|h[19]<<8;
                result=bitonal(result,width,height);
            }
            }
        }
        *output=(uint8_t*)malloc(result.size());require(*output!=nullptr,"解码内存不足。");
        memcpy(*output,result.data(),result.size());*length=result.size();return 0;
    }catch(const std::exception& e){if(capacity)snprintf(error,capacity,"%s",e.what());return -1;}
}
extern "C" void lab_pdg_free(void* bytes){free(bytes);}
