"""Create disposable books and exercise the native conversion/reference windows."""
from pathlib import Path
import io,json,subprocess,tempfile,zipfile,sys,os
from PIL import Image
project=Path(__file__).resolve().parents[1]
exe=Path(os.environ.get('UVZ_TEST_EXECUTABLE',str(project/'UVZ Reader Lab.app/Contents/MacOS/UVZReaderLab')))
with tempfile.TemporaryDirectory(prefix='uvz-conversion-ui-') as folder:
    fixture=Path(folder)
    data=io.BytesIO();Image.new('L',(160,240),255).save(data,'JPEG',dpi=(200,200))
    for index in range(2):
        name=f'【学术研究丛书】用于检验长文件名显示与规范命名的测试图书{index}_测试作者著_示例出版社_2020.04_1234567{index}.uvz'
        with zipfile.ZipFile(fixture/name,'w') as archive:
            for page in ['cov001','000001','000002']:archive.writestr(page+'.pdg',data.getvalue())
            archive.writestr('BookInfo.dat',f'书名=测试图书{index}\n作者=测试作者著\n丛书名=学术研究丛书\n出版社=示例出版社\n出版日期=2020.04')
    output=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else fixture/'conversion.png'
    subprocess.run([str(exe),'--conversion-ui-test',str(fixture),str(output)],check=True,timeout=100)
    report=json.loads(output.with_suffix('.json').read_text());assert report['passed']
    print(json.dumps(report,ensure_ascii=False,indent=2))
