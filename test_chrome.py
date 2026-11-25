"""Live regression through MCP, using a temporary page and dedicated Chrome instance."""
import subprocess as s, json,tempfile,time,os,signal
from pathlib import Path
def call(cmd,*args):
 msg={'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'vd','arguments':{'command':cmd,'arguments':list(map(str,args))}}}
 r=json.loads(s.check_output([Path(__file__).with_name('vd_mcp.py')],input=json.dumps(msg)+'\n',text=True))['result']
 assert not r.get('isError'),r
 return json.loads(r['content'][0]['text'])
with tempfile.TemporaryDirectory() as d:
 page=Path(d)/'demo.html'
 page.write_text("""<meta charset=utf-8><title>VD input test</title><input autofocus oninput="document.title='Typed '+this.value" onkeydown="if(event.key==='Enter'){document.title='Submitted '+this.value}">""")
 before=s.check_output(['lsappinfo','front'])
 w=call('launch','Chrome',page);pid,win=w['pid'],w['window']
 try:
  def wait_title(expected):
   for _ in range(35):
    rows=call('windows')['windows']
    if any(r['pid']==pid and r['window']==win and expected in r['title'] for r in rows):return
    time.sleep(.12)
   raise ValueError((expected,[r for r in rows if r['pid']==pid]))
  wait_title('VD input test')
  input_front=s.check_output(['lsappinfo','front'])
  call('type',pid,win,'café ✓')
  wait_title('Typed café ✓')
  call('key',pid,win,'Enter')
  wait_title('Submitted café ✓')
  after=s.check_output(['lsappinfo','front'])
  assert after==input_front, 'Foreground changed during input verification'
  print('Verified Unicode, Enter, and foreground during input. Same foreground across launch:',after==before)
 finally:os.kill(pid,signal.SIGTERM)
