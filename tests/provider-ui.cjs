// Local mocked UI tests; never contacts or modifies a real Mihomo controller.
const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const { chromium } = require('playwright');
const ui = path.resolve(__dirname, '../payload/ui');
const profiles = [
  {name:'desktop', viewport:{width:1440,height:900}, userAgent:'SmartStorage Electron/30'},
  {name:'desktop-small', viewport:{width:850,height:600}, userAgent:'SmartStorage Electron/30'},
  {name:'android-dark', viewport:{width:390,height:844}, isMobile:true, hasTouch:true, colorScheme:'dark', userAgent:'Mozilla/5.0 (Linux; Android 14) Mobile'},
  {name:'ios-light', viewport:{width:390,height:844}, isMobile:true, hasTouch:true, colorScheme:'light', userAgent:'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Mobile Safari'}
];
(async () => {
  const browser = await chromium.launch({headless:true, ...(process.env.EDGE_PATH ? {executablePath:process.env.EDGE_PATH} : {})});
  try {
    for (const {name, ...options} of profiles) {
      const context = await browser.newContext(options);
      const page = await context.newPage();
      const errors = [], calls = [];
      let failRemote = false;
      let providers = {
        'APP-MANUAL':{vehicleType:'File',proxies:[]},
        'APP-SUBSCRIPTION':{vehicleType:'File',proxies:[{name:'example'}]},
        'PROXY':{vehicleType:'Compatible',proxies:[{name:'DIRECT'}]},
        'default':{vehicleType:'Compatible',proxies:[]},
        'empty-http':{vehicleType:'HTTP',proxies:[]},
        'last-provider':{vehicleType:'HTTP',proxies:[{name:'example'}]}
      };
      page.on('pageerror', error => errors.push(error.message));
      await page.exposeFunction('providerTestRequest', q => {
        calls.push(q);
        if (q.action === 'providers') return {providers};
        if (q.action === 'rule_providers') return {providers:{'example-rules':{vehicleType:'HTTP',ruleCount:5}}};
        if (q.action === 'update_provider' && failRemote && JSON.parse(q.options.body).provider === 'empty-http') {
          return {ok:false,error:'模拟网络错误'};
        }
        return {ok:true, running:true, nodes:[], proxies:{}};
      });
      await page.route('**/*', route => {
        const file = path.basename(new URL(route.request().url()).pathname) || 'index.html';
        if (!/^(index\.html|[\w-]+\.(css|js))$/.test(file) || !fs.existsSync(path.join(ui,file))) return route.abort();
        let body = fs.readFileSync(path.join(ui,file),'utf8');
        if (file === 'client-bridge.js') body += '\nwindow.XiaomiPluginClient.request=async q=>new Response(JSON.stringify(await window.providerTestRequest(q)),{headers:{"Content-Type":"application/json"}});';
        return route.fulfill({body, contentType:file.endsWith('.css')?'text/css':file.endsWith('.js')?'application/javascript':'text/html'});
      });
      await page.goto('http://mihomo-test.local/index.html');
      const root = page.locator('[data-minas-plugin="mihomo"]');
      await page.waitForFunction(() => document.querySelectorAll('#providers .provider-row').length === 6);
      await root.locator('.tab[data-page="proxies"]').click();
      const manual = root.locator('#providers .provider-row').filter({hasText:'APP-MANUAL'});
      assert(await manual.locator('button').isDisabled());
      assert.match(await manual.innerText(), /尚无节点/);
      assert.equal(await root.locator('#page-proxies #ruleProviders').count(), 0);
      let start = calls.length;
      await root.locator('#updateAllProviders').click();
      await page.waitForFunction(() => !document.querySelector('#updateAllProviders').disabled);
      assert.deepEqual(calls.slice(start).filter(q=>q.action==='update_provider').map(q=>JSON.parse(q.options.body).provider), ['APP-SUBSCRIPTION','empty-http','last-provider']);
      assert.match(await root.locator('#toast').innerText(), /已更新 3 个，跳过 3 个/);
      assert(!(await root.locator('#toast').getAttribute('class')).includes('error'));
      failRemote = true;
      start = calls.length;
      await root.locator('#updateAllProviders').click();
      await page.waitForFunction(() => !document.querySelector('#updateAllProviders').disabled);
      assert.equal(calls.slice(start).filter(q=>q.action==='update_provider').length, 3);
      assert.match(await root.locator('#toast').innerText(), /已更新 2 个.*失败 1 个.*empty-http/);
      assert((await root.locator('#toast').getAttribute('class')).includes('error'));
      failRemote = false;
      start = calls.length;
      await root.locator('#providers .provider-row').filter({hasText:'APP-SUBSCRIPTION'}).locator('button').click();
      await page.waitForFunction(() => {
        const row = [...document.querySelectorAll('#providers .provider-row')].find(el=>el.textContent.includes('APP-SUBSCRIPTION'));
        return row && !row.querySelector('button').disabled && document.querySelector('#toast').textContent === 'APP-SUBSCRIPTION 更新完成';
      });
      assert(calls.slice(start).some(q=>q.action==='providers'), 'single update refreshes provider list');
      start = calls.length;
      await root.locator('.tab[data-page="subscription"]').click();
      await page.waitForFunction(() => document.querySelector('#ruleProviders').textContent.includes('example-rules'));
      assert(calls.slice(start).some(q=>q.action==='rule_providers'));
      assert(await root.locator('#ruleProviders').evaluate(el=>el.closest('article').previousElementSibling.querySelector('#importRuleProvider') !== null));
      await root.locator('#ruleProviders').scrollIntoViewIfNeeded();
      assert(await root.locator('#ruleProviders').isVisible());
      assert(await root.locator('#page-subscription').evaluate(el=>el.scrollWidth<=el.clientWidth+2));
      if (process.env.MIHOMO_SCREENSHOT_DIR) {
        fs.mkdirSync(process.env.MIHOMO_SCREENSHOT_DIR,{recursive:true});
        await page.screenshot({path:path.join(process.env.MIHOMO_SCREENSHOT_DIR,name+'.png')});
      }
      await root.locator('#updateAllRuleProviders').click();
      await page.waitForFunction(() => !document.querySelector('#updateAllRuleProviders').disabled);
      assert(calls.some(q=>q.action==='update_rule_provider'));
      providers = {'APP-MANUAL':{vehicleType:'File',proxies:[]}};
      await root.locator('.tab[data-page="proxies"]').click();
      await root.locator('#reloadProxies').click();
      await page.waitForFunction(() => document.querySelectorAll('#providers .provider-row').length === 1);
      start = calls.length;
      await root.locator('#updateAllProviders').click();
      assert(!calls.slice(start).some(q=>q.action==='update_provider'));
      assert.match(await root.locator('#toast').innerText(), /没有需要更新/);
      assert.deepEqual(errors, []);
      console.log(name + ': passed');
      await context.close();
    }
  } finally { await browser.close(); }
})().catch(error=>{console.error(error);process.exitCode=1;});
