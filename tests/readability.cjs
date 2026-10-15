// Real scoped styles and bridge; synthetic content only, no NAS requests.
const {chromium}=require('playwright');
const fs=require('fs'),path=require('path'),assert=require('assert/strict');
const local=fs.existsSync(path.resolve(__dirname,'../payload/ui'));
const workspace=path.resolve(__dirname,'../..');
const projects=local?[path.basename(path.resolve(__dirname,'..'))]:['task-center-plugin','docker-manager-plugin','download-center-plugin','mihomo-plugin','nas-center-plugin','quickshare-plugin','ssh-recovery-plugin'];
const output=path.resolve(__dirname,local?'../.cache/readability':'../.cache/readability');fs.mkdirSync(output,{recursive:true});
function luminance(c){return c.slice(0,3).map(v=>{v/=255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4}).reduce((s,v,i)=>s+v*[.2126,.7152,.0722][i],0)}
function contrast(a,b){const x=luminance(a),y=luminance(b);return (Math.max(x,y)+.05)/(Math.min(x,y)+.05)}
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.EDGE_PATH||'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'});
 try{for(const project of projects)for(const profile of [{name:'desktop',w:870,h:526},{name:'scaled',w:870,h:526,zoom:.8},{name:'android-dark',w:390,h:844,mobile:true,dark:true},{name:'ios-light',w:390,h:844,mobile:true}]){
  const ui=path.join(workspace,project,'payload/ui'),zoom=profile.zoom||1;
  const context=await browser.newContext({viewport:profile.mobile?{width:profile.w,height:profile.h}:{width:1280,height:900},isMobile:!!profile.mobile,hasTouch:!!profile.mobile,colorScheme:profile.dark?'dark':'light',userAgent:profile.mobile?(profile.dark?'Android Mobile':'iPhone Mobile Safari'):'SmartStorage Electron/35'});
  const page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  if(!profile.mobile)await page.addInitScript(()=>window.__MICRO_APP_ENVIRONMENT__=true);
  await page.route('**/*',route=>{
   const name=path.basename(new URL(route.request().url()).pathname)||'index.html';
   if(!/^[\w.-]+$/.test(name)||!fs.existsSync(path.join(ui,name)))return route.abort();
   let body=fs.readFileSync(path.join(ui,name),'utf8');
   if(name==='index.html'){
    body=body.replace(/<script\b[^>]*src="(?:app|metrics)\.js[^>]*><\/script>/g,'');
    if(!profile.mobile)body=body.replace('<body>',`<body style="margin:0;height:100vh"><button id="host-control" style="font:19px serif">宿主文字</button><micro-app style="display:block;position:absolute;left:${100/zoom}px;top:${160/zoom}px;width:${profile.w/zoom}px;height:${profile.h/zoom}px;zoom:${zoom}">`).replace('</body>','</micro-app></body>');
   }
   return route.fulfill({body,contentType:name.endsWith('.css')?'text/css':name.endsWith('.js')?'text/javascript':'text/html'});
  });
  await page.goto('http://readability.test/index.html');
  const report=await page.evaluate(()=>{
   const root=document.querySelector('[data-minas-plugin]'),body=root.querySelector('.minas-plugin-body');
   const sample=document.createElement('section');sample.className='panel';sample.id='readability-sample';
   sample.innerHTML='<h2>执行输出</h2><p class="note">多个任务将等待 Docker 操作队列；本次未重复执行命令。</p><pre class="log-view">Docker 操作完成。\n中文日志清晰显示 /nas/pool0/example\nERR_TIMEOUT: 等待超过任务时限</pre><small>最近执行 · 计划任务</small><input disabled value="暂不可用">';
   root.querySelector('.shell').prepend(sample);
   const rgb=c=>{c=c.trim();if(/^#[\da-f]{3}$/i.test(c))c='#'+[...c.slice(1)].map(x=>x+x).join('');return /^#[\da-f]{6}$/i.test(c)?[1,3,5].map(i=>parseInt(c.slice(i,i+2),16)):(c.match(/[\d.]+/g)||[]).map(Number)};
   const styles=[...sample.querySelectorAll('pre,p,small')].map(e=>{const s=getComputedStyle(e);return {tag:e.tagName,size:parseFloat(s.fontSize),family:s.fontFamily,weight:s.fontWeight,line:parseFloat(s.lineHeight),color:rgb(s.color),background:rgb(s.backgroundColor)}});
   const rootStyle=getComputedStyle(root),surface=rgb(rootStyle.getPropertyValue('--surface')),bg=rgb(rootStyle.getPropertyValue('--bg'));
   const host=document.querySelector('#host-control');
   const pre=root.querySelector('#logText')||sample.querySelector('pre');pre.textContent='Docker 操作完成，中文日志应清晰显示。\n等待队列不会重试已发送的 Docker 命令。';
   const dialog=pre.closest('dialog,.dialog,.modal');if(dialog){if(dialog.tagName==='DIALOG')window.XiaomiPluginClient.openDialog(dialog);else dialog.hidden=false;}
   return {styles,surface,bg,rootFamily:rootStyle.fontFamily,host:host?getComputedStyle(host).fontSize:null};
  });
  for(const text of report.styles){
   assert(text.size>=(text.tag==='PRE'?15:13),`${project}/${profile.name} tiny ${JSON.stringify(text)}`);
   assert(text.family.includes('Microsoft YaHei')&&text.family.includes('PingFang SC'),`${project} missing CJK fallback`);
   assert(contrast(text.color,text.tag==='PRE'?report.bg:report.surface)>=4.5,`${project}/${profile.name} contrast too low: ${JSON.stringify({text,report})}`);
   if(text.tag==='PRE')assert(text.line/text.size>=1.7,'log line spacing');
  }
  assert.equal(errors.length,0,errors.join('\n'));if(report.host)assert.equal(report.host,'19px','styles leaked into client');
  assert(await page.locator('[data-minas-plugin]').evaluate(e=>e.scrollWidth<=e.clientWidth+1),'plugin horizontal overflow');
  if(project==='task-center-plugin'){
   await page.waitForTimeout(300);
   if(!profile.mobile)assert(await page.locator('#logText').evaluate(e=>{const r=e.getBoundingClientRect(),d=e.closest('.dialog').getBoundingClientRect();return r.top>=d.top&&r.bottom<=d.bottom}), 'log output clipped inside dialog');
   await page.screenshot({path:path.join(output,profile.name+'.png')});
  }
  console.log('PASS '+project+'/'+profile.name+': CJK fonts, readable sizes, contrast, host isolation');
  await context.close();
 }}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1});
