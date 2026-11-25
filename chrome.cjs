// One private debugging pipe per VD-launched Chrome. No debugging TCP listener.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { spawn } = require('node:child_process');
const { setTimeout: delay } = require('node:timers/promises');
const root = path.join(os.homedir(), 'Library', 'Caches', 'local.vd.host', 'chrome');
fs.mkdirSync(root, { mode: 0o700, recursive: true });

async function serve(binary, url, bounds) {
  const profile = fs.mkdtempSync(path.join(root, 'profile-'));
  const child = spawn(binary, ['--user-data-dir='+profile,'--remote-debugging-pipe','--no-first-run',
    '--no-default-browser-check','--disable-background-timer-throttling','--disable-renderer-backgrounding','--disable-backgrounding-occluded-windows','--disable-background-mode','--no-startup-window'], {
    stdio:['ignore','ignore','ignore','pipe','pipe']
  });
  let seq=0, pending=new Map(), buffer=Buffer.alloc(0), socketPath=path.join(root,child.pid+'.sock');
  child.once('exit',()=>{fs.rmSync(socketPath,{force:true});fs.rmSync(profile,{recursive:true,force:true});process.exit()});
  child.stdio[4].on('data',data=>{
    buffer=Buffer.concat([buffer,data]);
    let end;
    while((end=buffer.indexOf(0))>=0){
      const msg=JSON.parse(buffer.subarray(0,end));buffer=buffer.subarray(end+1);
      if(pending.has(msg.id)){pending.get(msg.id)(msg);pending.delete(msg.id)}
    }
  });
  function call(method,params={},sessionId){
    return new Promise((ok,fail)=>{
      const id=++seq;
      const timer=setTimeout(()=>{pending.delete(id);fail(Error(method+' timed out'))},6000);
      pending.set(id,m=>{clearTimeout(timer);m.error?fail(Error(m.error.message)):ok(m.result)});
      child.stdio[3].write(JSON.stringify({id,method,params,sessionId})+'\0');
    });
  }
  try {
    const {targetId}=await call('Target.createTarget',{url:'about:blank',newWindow:true,background:true});
    const {windowId}=await call('Browser.getWindowForTarget',{targetId});
    await call('Browser.setWindowBounds',{windowId,bounds});
    const {sessionId}=await call('Target.attachToTarget',{targetId,flatten:true});
    const nav=await call('Page.navigate',{url},sessionId);
    if(nav.errorText && !url.startsWith('chrome://dino'))throw Error('Navigation failed: '+nav.errorText);
    for(let i=0;url!=='about:blank' && i<50;i++){
      const {frameTree}=await call('Page.getFrameTree',{},sessionId);
      if(frameTree.frame.url!=='about:blank')break;
      if(i===49)throw Error('Chrome did not commit the requested navigation');
      await delay(100);
    }
    const keys={49:[' ','Space',32],36:['Enter','Enter',13],126:['ArrowUp','ArrowUp',38],125:['ArrowDown','ArrowDown',40],
      123:['ArrowLeft','ArrowLeft',37],124:['ArrowRight','ArrowRight',39],48:['Tab','Tab',9],53:['Escape','Escape',27],51:['Backspace','Backspace',8]};
    async function input({op,value}){
      const {targetInfos}=await call('Target.getTargets');
      const pages=targetInfos.filter(t=>t.type==='page');
      if(pages.length!==1 || pages[0].targetId!==targetId)throw Error('Chrome tabs changed; launch a dedicated VD page to target it safely.');
      if(op==='type')await call('Input.insertText',{text:value},sessionId);
      else if(op==='key'){
        const k=keys[value];
        if(!k)throw Error('Unsupported Chrome key. Use vd type for text.');
        const [key,code,windowsVirtualKeyCode]=k;
        const params={key,code,windowsVirtualKeyCode};
        const text=code==='Space'?' ':code==='Enter'?'\r':undefined;
        await call('Input.dispatchKeyEvent',{...params,type:text?'keyDown':'rawKeyDown',text},sessionId);
        await delay(45);
        await call('Input.dispatchKeyEvent',{...params,type:'keyUp'},sessionId);
      }else throw Error('Unknown input operation');
      return {delivered:true,transport:'chrome-page'};
    }
    const server=net.createServer(socket=>{
      socket.setEncoding('utf8');let line='';
      socket.on('error',()=>{});
      socket.on('data',async chunk=>{
        line+=chunk;if(line.length>100000){socket.destroy();return}
        if(!line.includes('\n'))return;
        socket.pause();
        try{socket.end(JSON.stringify(await input(JSON.parse(line))))}
        catch(e){socket.end(JSON.stringify({error:e.message}))}
      });
    });
    await new Promise((ok,fail)=>{server.once('error',fail);server.listen(socketPath,ok)});
    fs.chmodSync(socketPath,0o600);
    console.log(child.pid);process.stdout.end();
  } catch(e){console.error(e.message);child.kill();process.exitCode=1}
}
serve(process.argv[2],process.argv[3],JSON.parse(process.argv[4])).catch(e=>{console.error(e.message);process.exit(1)});
