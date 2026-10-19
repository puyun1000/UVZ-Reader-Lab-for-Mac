"""Synthetic structural cases, not copied annex text; no sample scans are redistributed."""
from pathlib import Path
import json,subprocess,tempfile,re,unicodedata
ROOT=Path(__file__).resolve().parents[1];EXE=ROOT/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab'
def main():
 checks=[]
 with tempfile.TemporaryDirectory(prefix='uvz-cip-') as folder:
  raw=Path(folder)/'case.txt'
  def extract(text):
   raw.write_text(text);p=subprocess.run([str(EXE),'--extract-metadata',str(raw)],capture_output=True,text=True,timeout=30);assert p.returncode==0,p.stderr;return json.loads(p.stdout)
  def case(label,body,expected,absent=()):
   out=extract(body);m=out['metadata']
   for k,v in expected.items():assert unicodedata.normalize("NFKC",re.sub(r"\s+","",m.get(k,"")))==unicodedata.normalize("NFKC",re.sub(r"\s+","",v)),(label,k,m.get(k),v,out)
   for k in absent:assert k not in m,(label,k,m)
   checks.append(label);return out
  H='图书在版编目（CIP）数据\n';F='\n中国版本图书馆CIP数据核字（2017）第123456号\n'
  base='沿海文献研究 : 资料与方法 / 林明著；周晴译. — 北京 : 示例出版社, 2024.6\n（人文研究丛书 / 陈主编 ; 12）\nISBN 978-0-306-40615-7'
  case('旧式CIP区与核字号隔离，保留副标题与责任说明',H+base+F,{'书名':'沿海文献研究 : 资料与方法','作者':'林明著；周晴译','出版社':'示例出版社','出版日期':'2024.06','丛书名':'人文研究丛书','ISBN':'9780306406157'})
  case('编校与封面设计、地址与定价不进入作者出版日期页数',H+base+F+'责任编辑 张九\n封面设计 李八\n印刷 某地印务公司\n地址 文明路268号\n定价 268元\n2026年7月第3次印刷',{'出版日期':'2024.06','作者':'林明著；周晴译'},('页数',))
  case('新式核字号中的年份不替代仅有出版年，不从重印日期猜月份',H+'山川笔记 / 程青著. — 南京 : 江南书局, 2023（2025.8重印）. — ISBN 9780306406157\nI. K2\n中国国家版本馆CIP数据核字第20251AB234号\n2025年8月第2次印刷',{'书名':'山川笔记','出版日期':'2023','出版社':'江南书局'})
  case('新版次单独剥离，不混入作者',H+'数据方法 / 叶平编著. — 3版, 修订版. — 上海 : 示例出版社, 2025.11. — ISBN 9780306406157'+F,{'作者':'叶平编著','书名':'数据方法','出版日期':'2025.11'})
  case('无责任说明的CIP保留书名而不臆造作者',H+'资料整理工作办法. — 北京 : 示例出版社, 2025. — ISBN 9780306406157'+F,{'书名':'资料整理工作办法','出版日期':'2025'},('作者',))
  case('跨行书名出版社和ISBN拼接',H+'古代文学史.\n第三卷 / 王明著. — 南京 : 江\n南大学出版社, 2025. 3. — ISBN 978-0-306-\n40615-7'+F,{'书名':'古代文学史.第三卷','出版社':'江南大学出版社','ISBN':'9780306406157','出版日期':'2025.03'})
  case('ISBN只印短前缀而剩余数字换行时仍完整校验',H+'海洋史 / 林明著. — 北京 : 示例出版社, 2024.5. — ISBN 978-0-\n306-40615-7'+F,{'ISBN':'9780306406157'})
  case('ISBN标签独占一行时读取下一行完整号码',H+'海洋史 / 林明著. — 北京 : 示例出版社, 2024.5. —\nISBN\n978-0-306-40615-7'+F,{'ISBN':'9780306406157'})
  case('多出版者与书局出版者不会被出版社后缀限制',H+'地方史料 / 黄河编. — 上海 : 示例书局 : 北京 : 学术出版公司, 2020.8. — ISBN 9780306406157'+F,{'出版社':'示例书局 : 北京 : 学术出版公司'})
  case('明确年月标签用于补齐CIP只有年份的出版日期',H+'海港史 / 张青著. — 北京 : 示例出版社, 2023. — ISBN 9780306406157'+F+'出版日期 2023年9月\n2026年1月第2次印刷',{'出版日期':'2023.09'})
  out=case('两区矛盾值均保留证据，CIP年月不被其他年份覆盖',H+base+F+'出版日期 2025年1月\n书名 沿海史',{'出版日期':'2024.06','书名':'沿海文献研究 : 资料与方法'})
  if 'evidence' in out:
   assert {e['value'] for e in out['evidence'] if e['field']=='出版日期'}=={'2024.06','2025.01'}
  case('没有CIP的明确出版信息不受编辑和印刷人员干扰','书名 港口研究\n作者 林明\n责任编辑 陈青\n出版发行\n示例出版社\n2022年8月第1版\n2025年9月第4次印刷\n页数 320页\nISBN 9780306406157',{'书名':'港口研究','作者':'林明','出版社':'示例出版社','出版日期':'2022.08','页数':'320'})
  case('ISBN校验失败保持留空；核字年份不能生成出版日期',H+'无法识别著录\nISBN 9780306406158'+F,{},('ISBN','出版日期','作者','书名'))
  case('出版日期不能取印刷或广告年月','版权所有 2024\n2025年8月第5次印刷\n印刷 北京印务厂\n责任编辑 王三',{},('出版日期','作者','出版社'))
  case('传统字体值与丛书名称保留', '圖書在版編目（CIP）數據\n古籍考證 / 張明著. — 上海 : 中華書局, 2021.4. — （文獻叢刊）. — ISBN 9780306406157\n中國國家版本館CIP数据核字第20211AB234号',{'书名':'古籍考證','作者':'張明著','丛书名':'文獻叢刊','出版社':'中華書局','出版日期':'2021.04'})
  case('并列英文书名与西文人名中的点保留',H+'海图 = Sea Charts / (英) A. Brown著；李明译. — 北京 : 示例出版社, 2020.2. — ISBN 9780306406157'+F,{'书名':'海图 = Sea Charts','作者':'(英) A. Brown著；李明译'})
  out=case('合订多作品关系保留待核对，不把后部作品当作者',H+'山川录 / 张甲著. 江海集 / 李乙著. — 北京 : 示例出版社, 2020.2. — ISBN 9780306406157'+F,{},('作者',))
  if 'notes' in out:assert any('合订' in n for n in out['notes'])
 print(json.dumps(dict(passed=len(checks),checks=checks),ensure_ascii=False,indent=2))
if __name__=='__main__':main()
