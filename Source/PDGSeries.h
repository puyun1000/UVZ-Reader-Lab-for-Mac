// Native translation of the series-A routines in 100apps/pdg_decoder (MIT).
// Fixed-width unsigned arithmetic deliberately matches the on-disk format.
#pragma once
#include "PDGSeriesTables.h"
namespace PDGSeries {
using Key = std::array<uint32_t,32>;
using Pair = std::array<uint32_t,2>;
using Schedules = std::array<Key,6>;
static uint32_t byte(uint32_t x,int n){return (x>>(n*8))&255;}
static Key schedule(Pair a) {
    uint32_t m=(a[0]^(a[1]>>4))&0x0f0f0f0f, v7=m^a[0],v8=(m<<4)^a[1];
    uint32_t v9=(v8^(v7>>4))&0x01010101,t=(v9<<4)^v7;
    m=(t^(t>>9))&0x550055;uint32_t v10=m^(m<<9)^t;
    t=v9^v8;m=(t^(t>>9))&0x550055;uint32_t v11=m^(m<<9)^t;
    m=(v10^(v10>>18))&0x3333;uint32_t v12=m^(m<<18)^v10;
    m=(v11^(v11>>18))&0x3333;uint32_t v13=m^(m<<18)^v11;
    t=(v13^byte(v13,2))&255;uint32_t v14=t^(t<<16)^v13;
    Key out{};
    for(int i=0;i<16;i++){
        uint32_t v15=v14&0x0fffffff,v16=v12&0x0fffffff;
        int n=seriesRot[i]?2:1;
        v12=(v16>>n)|(v12<<(28-n));uint32_t v18=(v15>>n)|(v15<<(28-n));v14=v18;
        uint32_t v20=byte(v18,2);
        auto d=seriesKS;
        uint32_t v21=d[v12&63]|d[((byte(v12,1)>>1)&63)+64]|
            d[((byte(v12,2)&0x1d)|(((byte(v12,2)&0x40)|((byte(v12,2)>>5)&4))>>1))+128]|
            d[((byte(v12,3)&0xe)|(((byte(v12,1)>>5)|(v12&0xc0))>>2))+192];
        uint32_t v24=d[v18&63|256]|d[(v20&63)+384]|
            d[(((v18>>8)&0x3d)|((byte(v18,1)>>6)&2))+320]|
            d[((byte(v18,3)&0xd)|(((v20&0xc0)|((byte(v18,0)>>4)&8))>>2))+448];
        out[2*i]=(v21&65535)|(v24<<16);out[2*i+1]=(v21>>16)|(v24&0xffff0000);
    }
    return out;
}
static uint32_t f(uint32_t x,uint32_t ka,uint32_t kb){
    uint32_t a=(x^ka)&0x3f3f3f3f,b=(kb^((x>>4)|(x<<28)))&0x3f3f3f3f;
    uint32_t out=0;
    for(int i=0;i<4;i++)out|=u32(seriesSP+4*byte(a,i)+1+512*i)|u32(seriesSP+4*byte(b,i)+257+512*i);
    return out;
}
static Pair enc(Pair a,const Key& k){
    uint32_t m=(a[0]^(a[1]>>4))&0x0f0f0f0f,v5=m^a[0],v6=(m<<4)^a[1];
    m=(v6^(v5>>16))&65535;uint32_t v8=m^v6,v9=(m<<16)^v5;
    m=(v9^(v8>>2))&0x33333333;uint32_t v11=m^v9,v12=(m<<2)^v8;
    m=(v12^(v11>>8))&0x00ff00ff;uint32_t v14=m^v12,v15=(m<<8)^v11;
    m=(v15^(v14>>1))&0x55555555;uint32_t l=m^v15,r=(m<<1)^v14;
    for(int j=0;j<32;j+=4){r^=f(l,k[j],k[j+1]);l^=f(r,k[j+2],k[j+3]);}
    m=(l^(r>>1))&0x55555555;uint32_t v52=m^l,v53=(m<<1)^r;
    m=(v53^(v52>>8))&0x00ff00ff;uint32_t v55=m^v53,v56=(m<<8)^v52;
    m=(v56^(v55>>2))&0x33333333;uint32_t v58=m^v56,v59=(m<<2)^v55;
    m=(v59^(v58>>16))&65535;uint32_t v61=m^v59,v62=(m<<16)^v58;
    m=(v62^(v61>>4))&0x0f0f0f0f;return {v61^(m<<4),v62^m};
}
static Schedules schedules(const std::array<uint32_t,4>& seed){
    Key master=schedule({seriesMaster[0],seriesMaster[1]});Schedules keys;
    Pair p{seed[0],seed[1]};
    for(int i=0;i<6;i++){
        if(i){int at=(i%2)?2:0;p[0]^=seed[at];p[1]^=seed[at+1];if(i>=2)p[0]^=0x80u>>(i-2);}
        p=enc(p,master);keys[i]=schedule(p);
    }
    return keys;
}
static void transform(Bytes& data,const std::array<uint32_t,4>& seed,size_t blocks=17){
    const auto keys=schedules(seed);
    for(size_t off=0;off/32<blocks&&off+16<=data.size();off+=32){
        Pair a{u32(data.data()+off),u32(data.data()+off+4)},b{u32(data.data()+off+8),u32(data.data()+off+12)};
        for(int k=5;k>=0;k--){Pair e=enc(k%2?b:a,keys[k]);Pair& target=k%2?a:b;target[0]^=e[0];target[1]^=e[1];}
        put32(data.data()+off,a[0]);put32(data.data()+off+4,a[1]);put32(data.data()+off+8,b[0]);put32(data.data()+off+12,b[1]);
    }
}
static void preprocess(Bytes& h,Bytes& data){
    auto get16=[&](int at){return uint32_t(h[at])|uint32_t(h[at+1])<<8;};
    auto set16=[&](int at,uint32_t n){h[at]=n;h[at+1]=n>>8;};
    if(h[56]){
        require(h[57]==0x86,"不支持这种 PDG 预处理类型。");
        transform(data,{850670129,941241401,8414468,9568772});set16(16,get16(16)-49);h[56]=0;
    }
    int type=h[15];
    if(type==0x28){
        uint32_t a=u32(h.data()+16),b=u32(h.data()+20),c=u32(h.data()+24),d=u32(h.data()+28),sum=0xe3779b90;
        c-=((a<<4)^(a>>5)^(a+sum));d-=((c<<4)^(c>>5)^(c+sum));
        b-=((d<<4)^(d>>5)^(d+sum));a-=((b<<4)^(b>>5)^(b+sum));
        uint32_t first=0x1c886470-a;
        transform(data,{first,0u-((a+sum)^d),0u-((a+(first>>5))^(b+sum)),0u-(b^(d+sum))},data.size()/32);
        h[15]=0;
    }
    if(type>=0xaa&&type<=0xac){
        std::array<uint32_t,4> seed;
        if(type==0xaa)seed={8520200,19005960,8409144,9568776};
        else{
            int off=type==0xab?12:32;
            if(type==0xab){auto w=get16(16);set16(16,get16(18));set16(18,w);}
            seed={u32(h.data()+off)^0x820208,u32(h.data()+off+4)^0x1220208,u32(h.data()+off+8)^0x805038,u32(h.data()+off+12)^0x920208};
        }
        transform(data,seed);h[15]=0;
        if(type==0xac){set16(16,get16(16)-100);set16(18,get16(18)-1000);}
    }
    if(type==0x10){
        uint32_t v=u32(h.data()+104),hi=v>>16;int32_t signedHi=int16_t(hi);
        uint32_t lo=(int64_t(v&65535)-(signedHi%219)*(signedHi%511)+20718)&65535;
        uint32_t a=hi%131,b=lo%1019,c=(hi*lo)&65535;
        set16(16,a+get16(16)-c-b);set16(18,b+get16(18)-c-a);h[15]=0;
    }
}
}
