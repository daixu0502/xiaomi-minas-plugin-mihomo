// Mocked status checks only: never call real enable/disable or any NAS endpoint.
const fs=require('fs'),path=require('path'),assert=require('assert/strict');
const {chromium}=require('playwright');
const ui=path.resolve(__dirname,'../payload/ui');
const base={ok:true,available:true,configured:true,dockerActive:true,runtimeKnown:true,effective:true,runtimeUsesProxy:true,mihomoListening:true,proxyReachable:true,probeStatus:'ok',proxy:'http://127.0.0.1:7890',state:'effective'};
const cases=[
 ['effective',{},'已生效',true,false],
 ['pending_apply',{effective:false,runtimeUsesProxy:false},'已配置 · 未生效',false,false],
 ['unreachable',{mihomoListening:false,proxyReachable:false},'代理不可达',true,false],
 ['upstream_failed',{proxyReachable:false},'代理出口异常',true,false],
 ['unknown',{runtimeKnown:false,effective:false,runtimeUsesProxy:false},'状态待确认',false,false],
 ['bypassed',{effective:false,registryBypassed:true},'已配置 · 被绕过',false,false],
 ['pending_disable',{configured:false},'关闭待生效',false,false],
 ['disabled',{configured:false,effective:false,runtimeUsesProxy:false,proxyReachable:null},'未配置',false,true],
 ['docker_stopped',{dockerActive:false,effective:false,runtimeKnown:false},'Docker 未运行',false,false],
 ['probe_unknown',{proxyReachable:null,probeStatus:'probe_unavailable'},'已加载 · 待验证',true,false]
];
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.EDGE_PATH});
 try{for(const profile of [
  {name:'desktop',width:1440,height:900}, {name:'desktop-small',width:800,height:600},
  {name:'ios-light',width:390,height:844,mobile:true}, {name:'ios-dark',width:390,height:844,mobile:true,dark:true},
  {name:'android-light',width:360,height:740,mobile:true}, {name:'android-dark',width:360,height:740,mobile:true,dark:true}
 ]){
  const context=await browser.newContext({viewport:{width:profile.width,height:profile.height},isMobile:!!profile.mobile,hasTouch:!!profile.mobile,colorScheme:profile.dark?'dark':'light',userAgent:profile.mobile?(profile.name.startsWith('ios')?'Mozilla/5.0 iPhone Mobile Safari':'Mozilla/5.0 Android Mobile Chrome'):'SmartStorage Electron/30'});
  const page=await context.newPage();const errors=[],calls=[];let status={...base},fail=false;
  page.on('pageerror',e=>errors.push(e.message));
  await page.exposeFunction('proxyTest',q=>{
   calls.push(q.action);
   if(q.action==='docker_proxy_status')return fail?{ok:false,error:'模拟读取失败'}:status;
   return {ok:true,running:true,nodes:[],proxies:{},providers:{}};
  });
  await page.route('**/*',route=>{
   const name=path.basename(new URL(route.request().url()).pathname)||'index.html';
   if(!/^(index\.html|[\w-]+\.(js|css))$/.test(name)||!fs.existsSync(path.join(ui,name)))return route.abort();
   let body=fs.readFileSync(path.join(ui,name),'utf8');
   if(name==='client-bridge.js')body+='\nwindow.XiaomiPluginClient.request=async q=>new Response(JSON.stringify(await window.proxyTest(q)));';
   route.fulfill({body,contentType:name.endsWith('.js')?'application/javascript':name.endsWith('.css')?'text/css':'text/html'});
  });
  await page.goto('http://proxy.test/index.html');
  const root=page.locator('[data-minas-plugin="mihomo"]');
  await page.waitForFunction(()=>document.querySelector('#dockerProxyBadge').textContent==='已生效');
  for(const [state,fields,label,enableDisabled,disableDisabled] of cases){
   status={...base,...fields,state};
   await root.locator('#refreshDockerProxy').click();
   await page.waitForFunction(label=>document.querySelector('#dockerProxyBadge').textContent===label,label);
   assert.equal(await root.locator('#enableDockerProxy').isDisabled(),enableDisabled,state);
   assert.equal(await root.locator('#disableDockerProxy').isDisabled(),disableDisabled,state);
   const card=root.locator('#dockerProxyBadge').locator('..').locator('..');
   assert(await card.evaluate(e=>e.scrollWidth<=e.clientWidth+1),'horizontal overflow '+state);
   assert(await root.locator('.docker-proxy-details').evaluate(e=>e.scrollWidth<=e.clientWidth+1));
   if(state==='pending_apply'){
    assert.equal(await root.locator('#enableDockerProxy').innerText(),'重新应用代理');
    await root.locator('#enableDockerProxy').click();
    const dialog=root.locator('.mi-confirm-dialog');await dialog.waitFor();
    assert((await dialog.innerText()).includes('重启 Docker'));
    await dialog.getByRole('button',{name:'取消',exact:true}).click();
    if(process.env.MIHOMO_SCREENSHOT_DIR){fs.mkdirSync(process.env.MIHOMO_SCREENSHOT_DIR,{recursive:true});await card.screenshot({path:path.join(process.env.MIHOMO_SCREENSHOT_DIR,profile.name+'-proxy.png')});}
   }
  }
  fail=true;await root.locator('#refreshDockerProxy').click();
  await page.waitForFunction(()=>document.querySelector('#dockerProxyBadge').textContent==='读取失败');
  assert.equal(await root.locator('#dockerProxyRuntime').innerText(),'待确认');
  assert(await root.locator('#enableDockerProxy').isDisabled());
  assert(!calls.some(c=>c==='docker_proxy_enable'||c==='docker_proxy_disable'),'status check must not mutate Docker');
  assert.deepEqual(errors,[]);console.log(profile.name+': 10 states, failure, confirmation and layout passed');await context.close();
 }}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
