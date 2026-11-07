// PDZ container compatibility adapted from Axu UVZReader 0.3.11, supplied by the user.
// Uses macOS CommonCrypto in place of the reference mbedTLS adapter.
#include "PDZContainer.h"
#include "PDZTables.h"
#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonCryptor.h>



#include <zlib.h>
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using Bytes = std::vector<uint8_t>;
constexpr size_t limit = 512u * 1024u * 1024u;
void need(bool condition, const char *message) { if (!condition) throw std::runtime_error(message); }
uint32_t u32(const uint8_t *p) { return p[0] | uint32_t(p[1])<<8 | uint32_t(p[2])<<16 | uint32_t(p[3])<<24; }
void put32(uint8_t *p,uint32_t n) { for(int i=0;i<4;++i)p[i]=uint8_t(n>>(8*i)); }
void append(Bytes &b,uint32_t n,int count) { for(int i=0;i<count;++i)b.push_back(uint8_t(n>>(8*i))); }
std::string hex(const uint8_t *b,size_t n) { static const char h[]="0123456789ABCDEF";std::string s;for(size_t i=0;i<n;++i){s+=h[b[i]>>4];s+=h[b[i]&15];}return s; }
Bytes unhex(const std::string &s) {
    need(s.size()%2==0,"PDZ 证书编码损坏"); Bytes out;out.reserve(s.size()/2);
    auto digit=[](unsigned char c)->int {if(c>='0'&&c<='9')return c-'0';if(c>='a'&&c<='f')return c-'a'+10;if(c>='A'&&c<='F')return c-'A'+10;return -1;};
    for(size_t i=0;i<s.size();i+=2){int a=digit(s[i]),b=digit(s[i+1]);need(a>=0&&b>=0,"PDZ 证书编码损坏");out.push_back(uint8_t(a*16+b));}return out;
}
std::string expand(const std::string &s,const uint8_t *salt,const uint8_t *alphabet) {
    // The official routine appends one-character C strings. The alphabet's
    // trailing NUL entries append nothing, rather than becoming key bytes.
    // Keeping them shifted AES keys for otherwise valid local certificates.
    Bytes b;for(size_t i=0;i<s.size()&&b.size()<32;++i){
        b.push_back(uint8_t(s[i]));auto ch=alphabet[(salt[i%4]*i)%96];if(ch)b.push_back(ch);
    }
    for(size_t i=0;b.size()<32&&i<96;++i)if(alphabet[i])b.push_back(alphabet[i]);
    need(b.size()>=32,"PDZ 密钥扩展数据损坏");return hex(b.data(),32);
}
std::array<uint8_t,16> key(const std::string &s) {
    std::array<uint8_t,16> k;CC_MD5(s.data(),s.size(),k.data());
    const uint32_t mask[]={0x820208,0x1220208,0x805038,0x920208};
    for(int i=0;i<16;++i)k[i]^=uint8_t(mask[i/4]>>(8*(i%4)));return k;
}
void tea(Bytes &b,const std::array<uint8_t,16>&keyBytes) {
    uint32_t k[4];for(int i=0;i<4;++i)k[i]=u32(keyBytes.data()+4*i);
    for(size_t i=0;i+16<=b.size();i+=16){uint32_t a=u32(&b[i]),bb=u32(&b[i+4]),c=u32(&b[i+8]),d=u32(&b[i+12]),sum=0xe3779b90;
        auto mix=[&](uint32_t x,int l,int r){return ((x<<4)+k[l])^(x+sum)^((x>>5)+k[r]);};
        for(int j=0;j<16;++j){d-=mix(a,2,1);c-=mix(d,0,3);bb-=mix(c,2,3);a-=mix(bb,0,1);sum-=0x9e3779b9;}
        put32(&b[i],a);put32(&b[i+4],bb);put32(&b[i+8],c);put32(&b[i+12],d);
    }
}
// Parse the bounded, text-only certificate dialect. Required fields must occur at
// their actual paths; substring matches in comments, wrong parents or damaged XML
// cannot silently supply an expiry/key. DTDs, extra processing instructions,
// CDATA and entity expansion are deliberately outside this local certificate type.
// Match the official local-time deadline: YYYY-MM-DD at 00:00:01.
// Compare calendar fields instead of mktime(expiry), which would overflow for
// valid 2060s certificates on platforms with a 32-bit time_t.
void checkCertificateExpiryAt(const std::string &expiry,const std::tm *now) {
    if(expiry=="0")return;
    need(expiry.size()==10&&expiry[4]=='-'&&expiry[7]=='-',"PDZ 证书有效期格式不支持");
    for(size_t i=0;i<expiry.size();++i)if(i!=4&&i!=7)need(expiry[i]>='0'&&expiry[i]<='9',"PDZ 证书有效期格式不支持");
    int year=(expiry[0]-'0')*1000+(expiry[1]-'0')*100+(expiry[2]-'0')*10+expiry[3]-'0';
    int month=(expiry[5]-'0')*10+expiry[6]-'0',day=(expiry[8]-'0')*10+expiry[9]-'0';
    bool leap=year%4==0&&(year%100!=0||year%400==0);const int days[]={31,28,31,30,31,30,31,31,30,31,30,31};
    need(year>=1900&&month>=1&&month<=12&&day>=1&&day<=days[month-1]+(month==2&&leap),"PDZ 证书有效期日期无效");
    need(now&&now->tm_year>=0&&now->tm_year<=8099&&now->tm_mon>=0&&now->tm_mon<12&&now->tm_mday>=1&&now->tm_mday<=31&&now->tm_hour>=0&&now->tm_hour<24&&now->tm_min>=0&&now->tm_min<60&&now->tm_sec>=0&&now->tm_sec<=60,"无法读取系统日期，无法校验 PDZ 证书有效期");
    int current=(now->tm_year+1900)*10000+(now->tm_mon+1)*100+now->tm_mday,deadline=year*10000+month*100+day;
    bool expired=current>deadline||(current==deadline&&(now->tm_hour!=0||now->tm_min!=0||now->tm_sec>1));
    need(!expired,"此 PDZ 证书已到期，请使用官方阅读器更新授权");
}
void checkCertificateExpiry(const std::string &expiry) {
    if(expiry=="0")return;
    std::time_t stamp=std::time(nullptr);std::tm now{};bool available=stamp!=std::time_t(-1);
#if defined(_WIN32)
    available=available&&localtime_s(&now,&stamp)==0;
#else
    available=available&&localtime_r(&stamp,&now)!=nullptr;
#endif
    checkCertificateExpiryAt(expiry,available?&now:nullptr);
}
struct CertificateFields { std::string expiry, bookKey; };
CertificateFields parseCertificate(const std::string &xml) {
    auto space=[](unsigned char c){return c==' '||c=='\t'||c=='\r'||c=='\n';};
    auto nameChar=[](unsigned char c){return (c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_'||c=='-';};
    auto whitespace=[&](const std::string &v){return std::all_of(v.begin(),v.end(),space);};
    for(unsigned char c:xml)need(c>=32||space(c),"PDZ 证书 XML 字符损坏");
    size_t at=0;if(xml.compare(0,3,"\xEF\xBB\xBF")==0)at=3;
    while(at<xml.size()&&space(xml[at]))++at;
    if(xml.compare(at,5,"<?xml")==0){
        need(at+5<xml.size()&&space(xml[at+5]),"PDZ 证书 XML 声明损坏");
        auto end=xml.find("?>",at+5);need(end!=std::string::npos,"PDZ 证书 XML 声明损坏");
        need(xml.substr(at+5,end-at-5).find_first_of("<>")==std::string::npos,"PDZ 证书 XML 声明损坏");at=end+2;
    }
    std::vector<std::string> stack;std::set<std::string> seen;CertificateFields fields;bool rootSeen=false,rootClosed=false;
    std::string expiryPath="/cert/certexpdate",keyPath="/cert/rightinfo/bookkey";
    while(at<xml.size()){
        if(xml[at]!='<'){
            auto end=xml.find('<',at);if(end==std::string::npos)end=xml.size();auto value=xml.substr(at,end-at);
            if(stack.empty())need(whitespace(value),"PDZ 证书 XML 根节点损坏");
            else {
                std::string path;for(const auto &part:stack)path+="/"+part;
                if(path==expiryPath||path==keyPath){
                    need(value.find_first_of("&>")==std::string::npos,"不支持此 PDZ 证书字段编码");
                    (path==expiryPath?fields.expiry:fields.bookKey)+=value;
                }
                // Accept escaped text in unused account fields without expanding it.
                for(size_t i=0;(i=value.find('&',i))!=std::string::npos;){
                    auto semi=value.find(';',i+1);need(semi!=std::string::npos&&semi-i<=16,"PDZ 证书 XML 实体损坏");
                    auto entity=value.substr(i+1,semi-i-1);bool valid=entity=="amp"||entity=="lt"||entity=="gt"||entity=="apos"||entity=="quot";
                    if(!entity.empty()&&entity[0]=='#'){
                        size_t start=1;bool hex=false;if(entity.size()>1&&entity[1]=='x'){start=2;hex=true;}
                        valid=entity.size()>start;
                        for(size_t j=start;j<entity.size();++j){auto c=entity[j];valid=valid&&((c>='0'&&c<='9')||(hex&&((c>='a'&&c<='f')||(c>='A'&&c<='F'))));}
                    }
                    need(valid,"PDZ 证书 XML 实体不支持");i=semi+1;
                }
            }
            at=end;continue;
        }
        auto end=xml.find('>',at+1);need(end!=std::string::npos,"PDZ 证书 XML 标签损坏");
        auto token=xml.substr(at+1,end-at-1);bool closing=!token.empty()&&token[0]=='/';if(closing)token.erase(0,1);
        bool empty=!closing&&!token.empty()&&token.back()=='/';if(empty)token.pop_back();
        while(!token.empty()&&space(token.back()))token.pop_back();
        size_t nameEnd=0;while(nameEnd<token.size()&&nameChar(token[nameEnd]))++nameEnd;
        need(nameEnd>0&&!(token[0]>='0'&&token[0]<='9'),"PDZ 证书 XML 标签损坏");
        std::set<std::string> attributes;size_t cursor=nameEnd;
        while(cursor<token.size()){
            need(!closing&&space(token[cursor]),"PDZ 证书 XML 属性损坏");while(cursor<token.size()&&space(token[cursor]))++cursor;
            if(cursor==token.size())break;size_t begin=cursor;while(cursor<token.size()&&nameChar(token[cursor]))++cursor;
            need(cursor>begin&&attributes.insert(token.substr(begin,cursor-begin)).second,"PDZ 证书 XML 属性重复或损坏");
            while(cursor<token.size()&&space(token[cursor]))++cursor;need(cursor<token.size()&&token[cursor++]=='=',"PDZ 证书 XML 属性损坏");
            while(cursor<token.size()&&space(token[cursor]))++cursor;need(cursor<token.size()&&(token[cursor]=='\"'||token[cursor]=='\''),"PDZ 证书 XML 属性损坏");
            char quote=token[cursor++];auto finish=token.find(quote,cursor);need(finish!=std::string::npos&&token.substr(cursor,finish-cursor).find('<')==std::string::npos,"PDZ 证书 XML 属性损坏");cursor=finish+1;
        }
        token.resize(nameEnd);
        if(closing){need(!stack.empty()&&stack.back()==token,"PDZ 证书 XML 标签不匹配");stack.pop_back();if(stack.empty())rootClosed=true;}
        else {
            need(!rootClosed&&stack.size()<16,"PDZ 证书 XML 结构损坏");
            if(stack.empty()){need(!rootSeen&&token=="cert","PDZ 证书 XML 根节点损坏");rootSeen=true;}
            std::string parent;for(const auto &part:stack)parent+="/"+part;
            need(parent!=expiryPath&&parent!=keyPath,"PDZ 证书字段不能包含子节点");
            stack.push_back(token);auto path=parent+"/"+token;
            need(seen.insert(path).second,"PDZ 证书 XML 字段重复");
            if(empty){stack.pop_back();if(stack.empty())rootClosed=true;}
        }
        at=end+1;
    }
    need(rootSeen&&rootClosed&&stack.empty()&&seen.count(expiryPath)&&seen.count(keyPath),"PDZ 证书缺少必要字段");
    return fields;
}
void clearSecret(void* data,size_t count) { volatile uint8_t* bytes=static_cast<volatile uint8_t*>(data);while(count--)*bytes++=0; }
struct Secret { std::string text; ~Secret(){if(!text.empty())clearSecret(&text[0],text.size());} };
std::array<uint8_t,16> certificateKey(const uint8_t *p,size_t n) {
    need(n>=64&&n<=65536,"PDZ 证书长度异常");std::string cert(reinterpret_cast<const char*>(p),n);
    need(cert.compare(0,4,"SSCT")==0&&cert.compare(n-4,4,"SSCE")==0,"PDZ 证书标记损坏");
    auto marker=cert.find("[p?");need(marker!=std::string::npos&&marker>=42,"PDZ 证书信息损坏");
    std::string query=cert.substr(marker+3,n-4-marker-3);need(!query.empty()&&query.back()==']',"PDZ 证书信息损坏");query.pop_back();
    std::string type,ver;std::set<std::string> fields;
    for(size_t at=0;at<=query.size();){auto end=query.find('&',at);if(end==std::string::npos)end=query.size();auto item=query.substr(at,end-at);auto eq=item.find('=');need(eq!=std::string::npos,"PDZ 证书参数损坏");auto name=item.substr(0,eq);need(fields.insert(name).second,"PDZ 证书参数重复");if(name=="type")type=item.substr(eq+1);if(name=="ver")ver=item.substr(eq+1);at=end+1;}
    need(ver=="2"&&type=="0","此 PDZ 需要其他授权方式，请使用官方阅读器打开");
    std::string payload=cert.substr(4,marker-4),password="*s{P2a_1mP^?";
    need(payload.size()>40,"PDZ 证书内容损坏");std::string encoded=payload.substr(0,payload.size()-32);std::string signedText=encoded+password;
    uint8_t md5[16];CC_MD5(signedText.data(),signedText.size(),md5);need(hex(md5,16)==payload.substr(payload.size()-32),"PDZ 证书校验失败");
    uint8_t salt[4];memcpy(salt,encoded.data()+encoded.size()-6,4);encoded.erase(encoded.size()-6,4);
    auto aesKey=unhex(expand(password,salt,certificateAlphabet));auto raw=unhex(encoded);
    need(raw.size()>=32&&raw.size()%16==0,"PDZ 证书密文损坏");size_t count=raw.size()-16;uint8_t iv[16];memcpy(iv,raw.data()+count,16);
    Secret plain;plain.text.resize(count);
    size_t written=0;
    const auto status=CCCrypt(kCCDecrypt,kCCAlgorithmAES,0,aesKey.data(),aesKey.size(),iv,
                             raw.data(),count,&plain.text[0],count,&written);
    clearSecret(aesKey.data(),aesKey.size());
    need(status==kCCSuccess && written==count,"PDZ 证书解码失败");
    auto padding=uint8_t(plain.text.back());need(padding>=1&&padding<=16&&padding<=count,"PDZ 证书填充损坏");
    for(size_t i=count-padding;i<count;++i)need(uint8_t(plain.text[i])==padding,"PDZ 证书填充损坏");plain.text.resize(count-padding);
    auto parsed=parseCertificate(plain.text);
    checkCertificateExpiry(parsed.expiry);
    Secret bookKey;bookKey.text=std::move(parsed.bookKey);need(!bookKey.text.empty()&&bookKey.text.size()<=256,"PDZ 页面密钥无效");return key(bookKey.text);
}
struct Member {std::string name;uint32_t pos,size,crc=0,zipOffset=0;};
struct Blowfish {
    std::array<uint8_t,16> key{};
    ~Blowfish(){clearSecret(key.data(),key.size());}
};
void decryptPagePrefix(Bytes &content,Blowfish &cipher) {
    size_t encrypted=std::min(content.size(),size_t(1024))/8*8;
    for(size_t i=0;i<encrypted;i+=8) {
        uint8_t input[8],output[8];
        for(int j=0;j<8;++j)input[j]=content[i+(j/4)*4+3-j%4];
        size_t written=0;
        auto status=CCCrypt(kCCDecrypt,kCCAlgorithmBlowfish,kCCOptionECBMode,
                            cipher.key.data(),cipher.key.size(),nullptr,input,8,output,8,&written);
        need(status==kCCSuccess && written==8,"PDZ 页面解码失败");
        for(int j=0;j<8;++j)content[i+j]=output[(j/4)*4+3-j%4];
    }
}
bool pagePrefixRecognized(const Bytes &page) {
    if(page.size()>=2&&page[0]=='H'&&page[1]=='H')return true;
    size_t n=std::min(page.size(),size_t(1024));
    for(size_t i=0;i+5<=n;++i)if(memcmp(page.data()+i,"%PDF-",5)==0)return true;
    return false;
}
bool validLegacyScanPage(const Bytes &prefix,size_t total) {
    if(prefix.size()<140||memcmp(prefix.data(),"HH\x02",3)!=0)return false;
    size_t offset=u32(prefix.data()+24),length=u32(prefix.data()+28);
    return offset>=140&&offset<=total&&length>0&&length<=total-offset;
}
Bytes convert(const uint8_t *b,size_t n) {
    need(b&&n>=96&&n<=limit,"PDZ 文件为空、过大或不完整");need(memcmp(b,"%pdg",4)==0,"不是 PDZ 文件");
    // Verified scan-book containers use the same directory/CRC layout in 1.00
    // and 1.01. Type 0x667a/bookType 2 occurs in older locally certified books.
    bool knownVersion=memcmp(b+8,"1.00",4)==0||memcmp(b+8,"1.01",4)==0;
    bool knownKind=(u32(b+4)==0x7a&&b[15]==1)||(u32(b+4)==0x667a&&b[15]==2);
    need(knownVersion&&knownKind,"暂不支持此 PDZ 容器版本");need(b[13]==4,"暂不支持此 PDZ 页面加密类型");
    size_t end=size_t(u32(b+16))+96,offset=u32(b+20),size=u32(b+24);
    need(end<=n&&offset>=96&&offset<=end&&size<=end-offset&&size>0&&size%20==0&&size/20<65534,"PDZ 文件目录损坏");
    Bytes checksum(b,b+std::min(end,size_t(1024)));std::fill(checksum.begin()+60,checksum.begin()+64,0);
    uLong crc=crc32(0,checksum.data(),uInt(checksum.size()));
    if(end>2048)crc=crc32(crc,b+end-1024,1024);else if(end>1024)crc=crc32(crc,b+1024,uInt(end-1024));
    need(uint32_t(crc)==u32(b+60),"PDZ 文件校验失败，文件可能损坏或尚未传输完整");
    auto pageKey=certificateKey(b+end,n-end);Blowfish cipher;
    cipher.key=pageKey;clearSecret(pageKey.data(),pageKey.size());
    std::string marker(reinterpret_cast<const char*>(b+28),32);marker.resize(marker.find('\0')==std::string::npos?32:marker.find('\0'));
    const uint8_t salt[]={'l','j','h','d'};Bytes catalog(b+offset,b+offset+size);tea(catalog,key(expand(marker,salt,catalogAlphabet)));
    std::vector<Member> members;std::set<std::string> names;size_t outputEstimate=22;size_t pages=0;
    for(size_t i=0;i<size;i+=20){auto p=&catalog[i];size_t namelen=0;while(namelen<12&&p[namelen])++namelen;need(namelen>0,"PDZ 页面名称损坏");std::string name(reinterpret_cast<char*>(p),namelen);
        for(unsigned char ch:name)need((ch>='a'&&ch<='z')||(ch>='A'&&ch<='Z')||(ch>='0'&&ch<='9')||ch=='.'||ch=='_'||ch=='!'||ch=='-',"PDZ 页面名称不支持");
        std::transform(name.begin(),name.end(),name.begin(),[](unsigned char c){return c>='A'&&c<='Z'?c+32:c;});
        need(name!="."&&name!="..","PDZ 页面名称损坏");if(name=="contents.dat")name="bookcontents.dat";
        need(names.insert(name).second,"PDZ 包含重复页面");uint32_t pos=u32(p+12),len=u32(p+16);
        need(pos>=96&&pos<=end&&len<=end-pos,"PDZ 页面数据超出文件范围");need(pos+size_t(len)<=offset||pos>=offset+size,"PDZ 页面与文件目录重叠");
        outputEstimate+=size_t(len)+76+name.size()*2;need(outputEstimate<=limit,"PDZ 解码后过大");
        if(name.size()>4&&name.substr(name.size()-4)==".pdg")++pages;
        members.push_back({name,pos,len});
    }
    need(pages>0,"PDZ 中没有可阅读的页面");Bytes zip;zip.reserve(outputEstimate);
    Blowfish legacyCipher;bool legacyReady=false;
    for(auto &m:members){Bytes content(b+m.pos,b+m.pos+m.size);bool pdg=m.name.size()>4&&m.name.substr(m.name.size()-4)==".pdg";
        if(pdg){
            decryptPagePrefix(content,cipher);
            // Some locally certified older books retain the official legacy
            // scan-page key. Never use this before certificate/expiry checks.
            // Accept it only when the primary key has no recognizable page and
            // the alternate yields a bounded V2 PDG image payload.
            if(!pagePrefixRecognized(content)){
                if(!legacyReady){auto legacyKey=key("#$FVU&T)(*&^$#");
                    legacyCipher.key=legacyKey;clearSecret(legacyKey.data(),legacyKey.size());legacyReady=true;}
                size_t prefixSize=std::min(content.size(),size_t(1024));Bytes alternate(b+m.pos,b+m.pos+prefixSize);
                decryptPagePrefix(alternate,legacyCipher);
                if(validLegacyScanPage(alternate,content.size()))std::copy(alternate.begin(),alternate.end(),content.begin());
            }
        }
        m.crc=uint32_t(crc32(0,content.data(),uInt(content.size())));m.zipOffset=uint32_t(zip.size());
        append(zip,0x04034b50,4);append(zip,20,2);append(zip,0x800,2);append(zip,0,2);append(zip,0,2);append(zip,0x21,2);append(zip,m.crc,4);append(zip,m.size,4);append(zip,m.size,4);append(zip,uint32_t(m.name.size()),2);append(zip,0,2);
        zip.insert(zip.end(),m.name.begin(),m.name.end());zip.insert(zip.end(),content.begin(),content.end());
    }
    uint32_t central=uint32_t(zip.size());for(auto &m:members){append(zip,0x02014b50,4);append(zip,20,2);append(zip,20,2);append(zip,0x800,2);append(zip,0,2);append(zip,0,2);append(zip,0x21,2);append(zip,m.crc,4);append(zip,m.size,4);append(zip,m.size,4);append(zip,uint32_t(m.name.size()),2);append(zip,0,2);append(zip,0,2);append(zip,0,2);append(zip,0,2);append(zip,0,4);append(zip,m.zipOffset,4);zip.insert(zip.end(),m.name.begin(),m.name.end());}
    uint32_t centralSize=uint32_t(zip.size())-central;append(zip,0x06054b50,4);append(zip,0,2);append(zip,0,2);append(zip,uint32_t(members.size()),2);append(zip,uint32_t(members.size()),2);append(zip,centralSize,4);append(zip,central,4);append(zip,0,2);return zip;
}
}
extern "C" int pdz_to_uvz(const uint8_t *input,size_t length,uint8_t **output,size_t *outputLength,char *error,size_t errorCapacity) {
    if(output)*output=nullptr;if(outputLength)*outputLength=0;if(error&&errorCapacity)*error=0;
    try {need(output&&outputLength,"PDZ 输出参数无效");Bytes zip=convert(input,length);auto p=static_cast<uint8_t*>(malloc(zip.size()));need(p!=nullptr,"内存不足，无法打开 PDZ");memcpy(p,zip.data(),zip.size());*output=p;*outputLength=zip.size();return 0;}
    catch(const std::exception &e){if(error&&errorCapacity)snprintf(error,errorCapacity,"%s",e.what());return -1;}
    catch(...){if(error&&errorCapacity)snprintf(error,errorCapacity,"PDZ 解码失败");return -1;}
}
