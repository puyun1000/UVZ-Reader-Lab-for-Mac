from pathlib import Path
import tempfile,subprocess,json
exe=str(Path(__file__).resolve().parents[1]/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab');checks=[]
with tempfile.TemporaryDirectory(prefix='uvz-rules013-') as td:
 p=Path(td)/'case.json'
 def norm(title,series=''):
  p.write_text(json.dumps(dict(original={'书名':title,'丛书名':series},evidence=[]),ensure_ascii=False));return json.loads(subprocess.check_output([exe,'--batch-merge',str(p)]))
 for title,wanted in [('中国思想史 传统与现代','中国思想史：传统与现代'),('中国城市史 1900-1949','中国城市史（1900-1949）'),('中国思想史:传统与现代','中国思想史：传统与现代'),('山川录,江海集;地方史','山川录，江海集；地方史'),('History of China','History of China'),('日本の文化 文学と歴史','日本の文化 文学と歴史'),('红楼梦 西游记','红楼梦 西游记'),('春华秋实 山高水长','春华秋实 山高水长')]:
  a=norm(title);assert a['metadata']['书名']==wanted,(title,a);checks.append('title: '+title)
 for title,series,book in [('【东亚研究丛书】文献研究','东亚研究丛书','文献研究'),('中國文化文庫 古籍研究','中國文化文庫','古籍研究'),('浙江文叢：淩霞集','浙江文叢','淩霞集')]:
  a=norm(title);assert a['metadata']['丛书名']==series and a['metadata']['书名']==book,a;assert a['suggestedName'].startswith('【'+series+'】');checks.append('series prefix: '+title)
 for title in ['中国文库史研究','红楼梦 西游记']:
  a=norm(title);assert a['metadata']['书名']==title;checks.append('ambiguous series or combined title retained: '+title)
 raw=Path(td)/'book.txt'
 for date,wanted in [('April 2020','2020.04'),('May 5, 2021','2021.05'),('2020-04-02','2020.04'),('民國110年4月','2021.04'),('令和3年4月1日','2021.04'),('平成元年4月','1989.04')]:
  raw.write_text('出版日期：'+date);out=json.loads(subprocess.check_output([exe,'--extract-metadata',str(raw)]));assert out['metadata'].get('出版日期')==wanted,(date,out);checks.append('explicit publication date: '+date)

 for label,text,wanted in [
 ('traditional labels','書名：古籍文獻研究\n作者：張明\n出版者：中華書局\n出版日期：2021年4月\n頁數：268頁',{'书名':'古籍文獻研究','作者':'張明','出版社':'中華書局','出版日期':'2021.04','页数':'268'}),
 ('Japanese labels','タイトル：日本の古典文学\n著者：山田太郎\nシリーズ：日本文学研究\n発行所：東京書房\n発行日：2020年4月1日\nページ数：268',{'书名':'日本の古典文学','作者':'山田太郎','出版社':'東京書房','出版日期':'2020.04','丛书名':'日本文学研究','页数':'268'}),
 ('English labels','Title: Studies in Asian History\nAuthor: Alice Brown\nPublisher: Example Press\nPublication date: 2020.04',{'书名':'Studies in Asian History','作者':'Alice Brown','出版社':'Example Press','出版日期':'2020.04'}),
 ('Taiwan prepublication CIP','國家圖書館出版品預行編目(CIP)資料\n臺灣文化研究 / 張明著. -- 初版. -- 臺北市 : 示例書局, 民國110年4月\nISBN 9780306406157',{'书名':'臺灣文化研究','作者':'張明著','出版社':'示例書局','出版日期':'2021.04'})]:
  raw.write_text(text);out=json.loads(subprocess.check_output([exe,'--extract-metadata',str(raw)]));assert all(out['metadata'].get(k)==v for k,v in wanted.items()),(label,out,wanted);checks.append(label)
print(json.dumps(dict(passed=len(checks),checks=checks),ensure_ascii=False,indent=2))
