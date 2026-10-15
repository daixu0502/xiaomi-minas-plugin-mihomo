// Real plugin markup/bridge with mocked jobs; no NAS or live subscriptions.
const fs=require('fs'),path=require('path'),assert=require('assert/strict');
const {chromium}=require('playwright');
const ui=path.resolve(__dirname,'../payload/ui');
const profiles=[
 {name:'desktop',viewport:{width:1440,height:900},userAgent:'SmartStorage Electron/35'},
 {name:'desktop-small',viewport:{width:850,height:600},userAgent:'SmartStorage Electron/35'},
 {name:'android-dark',viewport:{width:390,height:844},isMobile:true,hasTouch:true,colorScheme:'dark',userAgent:'Android Mobile'},
 {name:'ios-light',viewport:{width:390,height:844},isMobile:true,hasTouch:true,colorScheme:'light',userAgent:'iPhone Mobile Safari'}
];
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.EDGE_PATH});
 try {for(const {name,...options} of profiles){
  const context=await browser.newContext(options),page=await context.newPage(),errors=[];
  let active=null,hold=true,fail=false,gateway=false,sequence=0;
  page.on('pageerror',error=>errors.push(error.message));
  await page.exposeFunction('jobFixture',q=>{
   if(q.action==='subscription_update'){
    if(gateway)return {raw:'<html>Gateway timeout</html>',status:504};
    active={id:String(++sequence).padStart(32,'0'),action:q.action,title:'更新订阅',status:'queued',stage:'queued',percent:0,message:'准备更新',createdAt:Date.now()/1000};
    return {ok:true,accepted:true,task:active};
   }
   if(q.action==='update_task_status'){
    if(!active)return {ok:true,task:null};
    return {ok:true,task:{...active,status:hold?'running':(fail?'failed':'succeeded'),percent:hold?35:100,
     stage:hold?'downloading':(fail?'failed':'done'),message:hold?'正在下载订阅':'已完成',
     error:!hold&&fail?'订阅下载失败：HTTP 403':null,result:{ok:true,proxyCount:2,restarted:false},elapsedSeconds:7}};
   }
   if(q.action==='subscription_status')return {ok:true,configured:true,proxyCount:2,nodes:[]};
   if(q.action==='status')return {ok:true,running:true,version:{version:'v1.19.31'},configs:{mode:'rule'}};
   if(q.action==='providers')return {providers:{'APP-SUBSCRIPTION':{vehicleType:'File',proxies:[{name:'test'}]}}};
   if(q.action==='rule_providers')return {providers:{}};
   return {ok:true,running:true,nodes:[],proxies:{}};
  });
  await page.route('**/*',route=>{
   const file=path.basename(new URL(route.request().url()).pathname)||'index.html';
   if(!/^(index\.html|[\w-]+\.(css|js))$/.test(file)||!fs.existsSync(path.join(ui,file)))return route.abort();
   let data=fs.readFileSync(path.join(ui,file),'utf8');
   if(file==='client-bridge.js')data+='\nwindow.XiaomiPluginClient.request=async q=>{const d=await window.jobFixture(q);return new Response(d.raw||JSON.stringify(d),{status:d.status||200,headers:{"Content-Type":d.raw?"text/html":"application/json"}})};';
   return route.fulfill({body:data,contentType:file.endsWith('.css')?'text/css':file.endsWith('.js')?'application/javascript':'text/html'});
  });
  await page.goto('http://jobs-test.invalid/');
  await page.locator('.tab[data-page="subscription"]').click();
  await page.locator('#updateSubscription').click();
  await page.waitForFunction(()=>document.querySelector('#updateTaskMessage').textContent.includes('正在下载'));
  assert(await page.locator('#updateSubscription').isDisabled());
  assert(await page.locator('#updateGeoData').isDisabled());
  await page.locator('.tab[data-page="overview"]').click();
  await page.locator('.tab[data-page="subscription"]').click();
  assert(await page.locator('#updateSubscription').isDisabled(),'status refresh cannot unlock in-flight subscription');
  await page.reload();
  await page.waitForFunction(()=>!document.querySelector('#updateTaskPanel').hidden&&document.querySelector('#updateTaskProgress').value===35);
  assert(await page.locator('#updateGeoData').isDisabled(),'refresh resumes existing job');
  assert(await page.locator('#updateTaskPanel').evaluate(el=>el.scrollWidth<=el.clientWidth+1));
  if(process.env.MIHOMO_SCREENSHOT_DIR){fs.mkdirSync(process.env.MIHOMO_SCREENSHOT_DIR,{recursive:true});await page.screenshot({path:path.join(process.env.MIHOMO_SCREENSHOT_DIR,'jobs-'+name+'.png')});}
  hold=false;
  await page.waitForFunction(()=>document.querySelector('#updateTaskStage').textContent==='完成');
  await page.locator('.tab[data-page="subscription"]').click();
  hold=false;fail=true;
  await page.locator('#updateSubscription').click();
  await page.waitForFunction(()=>document.querySelector('#updateTaskMessage').textContent.includes('HTTP 403'));
  await page.waitForFunction(()=>!document.querySelector('#updateSubscription').disabled);
  gateway=true;
  await page.locator('#updateSubscription').click();
  await page.waitForFunction(()=>document.querySelector('#toast').textContent.includes('HTTP 504'));
  assert(!((await page.locator('#toast').textContent()).includes('无法解析')));
  assert.deepEqual(errors,[],name+' has no JavaScript errors');
  console.log(name+': progress, reload recovery, shared busy state and HTTP error UI passed');
  await context.close();
 }}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
