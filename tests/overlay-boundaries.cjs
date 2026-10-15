// Real plugin markup/styles/bridge in an offset micro-app; no NAS calls or mutations.
const {chromium}=require('playwright');
const fs=require('fs'),path=require('path'),assert=require('assert/strict');
const localProject=fs.existsSync(path.resolve(__dirname,'../payload/ui'))?path.resolve(__dirname,'..'):null;
const workspace=localProject?path.dirname(localProject):path.resolve(__dirname,'..');
const projects=localProject?[path.basename(localProject)]:['ssh-recovery-plugin','docker-manager-plugin','mihomo-plugin','task-center-plugin','nas-center-plugin','quickshare-plugin','download-center-plugin','app-nav-plugin'];
const profiles=[
 {name:'embedded',w:870,h:526}, {name:'compact',w:480,h:320},
 {name:'narrow',w:320,h:460}, {name:'scaled',w:870,h:526,zoom:.8,dark:true},
 {name:'phone',w:360,h:740,mobile:true}, {name:'phone-dark',w:390,h:844,mobile:true,dark:true}
];
const output=process.env.OVERLAY_SCREENSHOT_DIR,failures=[];
function check(value,message){if(!value)failures.push(message);}
function inside(r,b){return r&&r.x>=b.x-1&&r.y>=b.y-1&&r.x+r.width<=b.x+b.width+1&&r.y+r.height<=b.y+b.height+1;}
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.EDGE_PATH});
 if(output)fs.mkdirSync(output,{recursive:true});
 let count=0;
 try{for(const project of projects)for(const p of profiles){
  const ui=path.resolve(workspace,project,'payload/ui'),zoom=p.zoom||1;
  const ctx=await browser.newContext({viewport:p.mobile?{width:p.w,height:p.h}:{width:1280,height:960},isMobile:!!p.mobile,hasTouch:!!p.mobile,colorScheme:p.dark?'dark':'light',userAgent:p.mobile?'Mobile Safari':'SmartStorage Electron/30'});
  const page=await ctx.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  if(!p.mobile)await page.addInitScript(()=>window.__MICRO_APP_ENVIRONMENT__=true);
  await page.route('**/*',route=>{
   const name=path.basename(new URL(route.request().url()).pathname)||'index.html';
   if(!/^(index\.html|[\w-]+\.(css|js))$/.test(name)||!fs.existsSync(path.join(ui,name)))return route.abort();
   let data=fs.readFileSync(path.join(ui,name),'utf8');
   if(name==='index.html'){
    data=data.replace(/<script\b[^>]*src="(?:app|metrics)\.js[^>]*><\/script>/g,'');
    if(!p.mobile)data=data.replace('<body>',`<body style="margin:0;height:100vh"><button id="host-control" style="font-size:19px">宿主按钮</button><micro-app style="position:absolute;display:block;left:${111/zoom}px;top:${230/zoom}px;width:${p.w/zoom}px;height:${p.h/zoom}px;zoom:${zoom}">`).replace('</body>','</micro-app></body>');
   }
   return route.fulfill({body:data,contentType:name.endsWith('.js')?'application/javascript':name.endsWith('.css')?'text/css':'text/html'});
  });
  await page.goto('http://overlay.test/index.html');await page.waitForTimeout(60);
  const root=page.locator('[data-minas-plugin]');
  if(!p.mobile)await root.locator('.shell').evaluate(e=>{const filler=document.createElement('div');filler.style.height='1600px';e.prepend(filler);e.scrollTop=600;});
  const dialogs=root.locator('dialog,.modal,.dialog,.sheet,.detail-sheet,.mi-picker-sheet,.mi-confirm-dialog');
  for(let i=0;i<await dialogs.count();i++){
   const d=dialogs.nth(i),id=await d.getAttribute('id'),label=project+'/'+p.name+'/'+id;
   await d.evaluate(el=>{
    const title=el.querySelector('h2');if(title&&!title.textContent)title.textContent='确认操作';
    const text=el.querySelector('#confirmText,#confirmMessage,.confirm-message,#confirmText');
    if(text)text.textContent='较长的确认说明，用于检查窗口内换行、滚动和按钮可达性。'.repeat(12)+' https://example.test/'+ 'long-path-'.repeat(24);
    if(el.tagName==='DIALOG')window.XiaomiPluginClient.openDialog?window.XiaomiPluginClient.openDialog(el):el.showModal();else el.hidden=false;
   });
   await page.waitForTimeout(200);
   const boundary=p.mobile?{x:0,y:0,width:p.w,height:p.h}:await root.locator('.desktop-frame').boundingBox();
   const rect=await d.boundingBox();check(inside(rect,boundary),label+' outside window '+JSON.stringify({rect,boundary}));
   check(await d.evaluate(e=>e.scrollWidth<=e.clientWidth+1),label+' content horizontal overflow');
   if(!p.mobile)check(await d.evaluate(e=>e.parentElement.classList.contains('desktop-frame')),label+' attached to scrolling content');
   if(!p.mobile&&id==='confirm'){
    check(await d.evaluate(e=>!e.matches(':modal')),label+' escaped to browser top layer');
    check(await root.locator('.shell').evaluate(e=>e.inert),label+' background accepts input');
    await page.keyboard.press('Tab');check(await d.evaluate(e=>e.contains(document.activeElement)),label+' keyboard focus escaped');
   }
   // The dialog must remain inside when its host is resized while open.
   if(!p.mobile){
    await page.locator('micro-app').evaluate(e=>{e.style.width='300px';e.style.height='260px';});await page.waitForTimeout(60);
    check(inside(await d.boundingBox(),await root.locator('.desktop-frame').boundingBox()),label+' outside resized window');
    await page.locator('micro-app').evaluate((e,s)=>{e.style.width=s.w/s.zoom+'px';e.style.height=s.h/s.zoom+'px';},{...p,zoom});await page.waitForTimeout(60);
   }
   if(output&&project==='ssh-recovery-plugin'&&id==='confirm')await page.screenshot({path:path.join(output,p.name+'.png')});
   if(await d.evaluate(e=>e.tagName==='DIALOG')){
    await page.keyboard.press('Escape');await page.waitForTimeout(30);
    check(await d.evaluate(e=>!e.open),label+' Escape did not cancel');
    if(await d.evaluate(e=>e.open))await d.evaluate(e=>e.close());
    if(!p.mobile)check(await root.locator('.shell').evaluate(e=>!e.inert),label+' left background inert');
   }else await d.evaluate(e=>e.hidden=true);
   count++;
  }
  const toast=root.locator('.toast');
  if(await toast.count()){
   await toast.evaluate(e=>{e.hidden=false;e.textContent='操作提示：'+ 'long-diagnostic-text-'.repeat(70);e.classList.add('show');});await page.waitForTimeout(220);
   const boundary=p.mobile?{x:0,y:0,width:p.w,height:p.h}:await root.locator('.desktop-frame').boundingBox();
   check(inside(await toast.boundingBox(),boundary),project+'/'+p.name+'/toast outside window');
   check(await toast.evaluate(e=>e.scrollWidth<=e.clientWidth+1),project+'/'+p.name+'/toast horizontal overflow');
  }
  if(!p.mobile){check(await page.locator('#host-control').isEnabled(),project+' host disabled');assert.equal(await page.locator('#host-control').evaluate(e=>getComputedStyle(e).fontSize),'19px');}
  check(errors.length===0,project+': '+errors.join(';'));await ctx.close();
  console.log(project+' '+p.name+': audited');
 }}finally{await browser.close();}
 console.log(count+' dialogs audited; '+failures.length+' failures');
 if(failures.length)throw Error(failures.join('\n'));
})().catch(e=>{console.error(e);process.exitCode=1;});
