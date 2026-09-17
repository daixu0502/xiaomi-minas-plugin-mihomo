(function () {
  'use strict';

  var state = {
    configLoaded: false,
    currentMode: '',
    proxyProviderNames: [],
    ruleProviderNames: [],
    subscriptionConfigured: false,
    running: false,
    dockerProxyAvailable: false,
    dockerProxyEnabled: false,
    coreUpdateAvailable: false,
    geoDataReady: false,
    currentAccess: 'local'
  };
  var toastTimer;

  function byId(id) { return document.getElementById(id); }

  function toast(message, isError) {
    var element = byId('toast');
    element.textContent = message;
    element.className = 'toast show' + (isError ? ' error' : '');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { element.className = 'toast'; }, 2800);
  }

  var pickerState = {
    currentValue: '',
    onSelect: null,
    options: [],
    trigger: null
  };

  function createSelectTrigger(value, label) {
    var button = document.createElement('button');
    button.type = 'button';
    button.className = 'mi-select-trigger';
    button.setAttribute('aria-haspopup', 'listbox');
    button.setAttribute('aria-expanded', 'false');
    button.setAttribute('aria-label', label || '打开选择器');
    button.appendChild(textElement('span', 'mi-select-value', value || '请选择'));
    button.appendChild(textElement('span', 'mi-select-chevron', ''));
    return button;
  }

  function setSelectTriggerValue(trigger, value) {
    var label = trigger && trigger.querySelector('.mi-select-value');
    if (label) label.textContent = value || '请选择';
  }

  function restoreFocus(element) {
    if (!element || !document.documentElement.contains(element)) return;
    var scrollX = window.pageXOffset;
    var scrollY = window.pageYOffset;
    try { element.focus({ preventScroll: true }); } catch (error) { element.focus(); }
    if (window.pageXOffset !== scrollX || window.pageYOffset !== scrollY) window.scrollTo(scrollX, scrollY);
  }

  function closePicker() {
    var sheet = byId('pickerSheet');
    var backdrop = byId('pickerBackdrop');
    sheet.hidden = true;
    backdrop.hidden = true;
    document.body.classList.remove('mi-picker-open');
    if (pickerState.trigger) {
      pickerState.trigger.setAttribute('aria-expanded', 'false');
      restoreFocus(pickerState.trigger);
    }
    pickerState.currentValue = '';
    pickerState.onSelect = null;
    pickerState.options = [];
    pickerState.trigger = null;
  }

  function renderPickerOptions(filterText) {
    var container = byId('pickerOptions');
    var query = String(filterText || '').trim().toLowerCase();
    var options = pickerState.options.filter(function (option) {
      return !query || option.text.toLowerCase().indexOf(query) >= 0;
    });
    container.textContent = '';
    if (!options.length) {
      container.appendChild(textElement('div', 'mi-picker-empty', '没有匹配的选项'));
      return;
    }
    options.forEach(function (option) {
      var button = document.createElement('button');
      button.type = 'button';
      button.className = 'mi-picker-option' + (option.value === pickerState.currentValue ? ' selected' : '');
      button.setAttribute('role', 'option');
      button.setAttribute('aria-selected', option.value === pickerState.currentValue ? 'true' : 'false');
      button.appendChild(textElement('span', 'mi-picker-option-label', option.text));
      button.appendChild(textElement('span', 'mi-picker-option-check', '✓'));
      button.addEventListener('click', function () {
        var callback = pickerState.onSelect;
        closePicker();
        if (callback) callback(option.value, option.text);
      });
      container.appendChild(button);
    });
  }

  function openPicker(title, options, currentValue, onSelect, trigger) {
    pickerState.options = (options || []).map(function (option) {
      if (typeof option === 'string') return { value: option, text: option };
      return { value: String(option.value), text: String(option.text) };
    });
    pickerState.currentValue = String(currentValue == null ? '' : currentValue);
    pickerState.onSelect = onSelect;
    pickerState.trigger = trigger || null;
    byId('pickerTitle').textContent = title || '选择项目';
    byId('pickerSearch').value = '';
    byId('pickerSearchWrap').hidden = pickerState.options.length <= 8;
    renderPickerOptions('');
    byId('pickerBackdrop').hidden = false;
    byId('pickerSheet').hidden = false;
    document.body.classList.add('mi-picker-open');
    if (trigger) trigger.setAttribute('aria-expanded', 'true');
  }

  function enhanceSelect(select) {
    if (!select || select.dataset.miPicker === 'true') return;
    select.dataset.miPicker = 'true';
    var selected = select.options[select.selectedIndex];
    var externalLabel = select.id ? document.querySelector('label[for="' + select.id + '"]') : null;
    var wrappingLabel = select.closest('label');
    var title = select.getAttribute('aria-label') ||
      (externalLabel ? externalLabel.textContent.trim() : '') ||
      (wrappingLabel && wrappingLabel.querySelector('span') ? wrappingLabel.querySelector('span').textContent.trim() : '') ||
      '选择项目';
    var trigger = createSelectTrigger(selected ? selected.textContent : '', title);
    trigger.id = (select.id || 'select') + 'Picker';
    if (select.classList.contains('policy-select')) trigger.classList.add('policy-picker-trigger');
    select.classList.add('native-select-hidden');
    select.disabled = true;
    select.setAttribute('aria-hidden', 'true');
    select.insertAdjacentElement('afterend', trigger);
    if (externalLabel) externalLabel.setAttribute('for', trigger.id);

    function sync() {
      var option = select.options[select.selectedIndex];
      setSelectTriggerValue(trigger, option ? option.textContent : '请选择');
    }
    select._miSync = sync;
    trigger.addEventListener('click', function (event) {
      event.preventDefault();
      var options = Array.prototype.map.call(select.options, function (option) {
        return { value: option.value, text: option.textContent };
      });
      openPicker(title, options, select.value, function (value) {
        select.value = value;
        sync();
        var changeEvent = document.createEvent('HTMLEvents');
        changeEvent.initEvent('change', true, false);
        select.dispatchEvent(changeEvent);
      }, trigger);
    });
    sync();
  }

  function initPickers() {
    document.querySelectorAll('select').forEach(enhanceSelect);
    byId('pickerBackdrop').addEventListener('click', closePicker);
    byId('pickerClose').addEventListener('click', closePicker);
    byId('pickerCancel').addEventListener('click', closePicker);
    byId('pickerSearch').addEventListener('input', function () { renderPickerOptions(this.value); });
    document.addEventListener('keydown', function (event) {
      if (event.key === 'Escape' && !byId('pickerSheet').hidden) closePicker();
    });
  }

  var confirmState = {
    resolve: null,
    trigger: null
  };

  function closeConfirm(accepted) {
    var dialog = byId('confirmDialog');
    if (dialog.hidden) return;
    var resolve = confirmState.resolve;
    var trigger = confirmState.trigger;
    dialog.hidden = true;
    byId('confirmBackdrop').hidden = true;
    document.body.classList.remove('mi-confirm-open');
    confirmState.resolve = null;
    confirmState.trigger = null;
    restoreFocus(trigger);
    if (resolve) resolve(Boolean(accepted));
  }

  function showConfirm(message, options) {
    var settings = options || {};
    if (confirmState.resolve) closeConfirm(false);
    var dialog = byId('confirmDialog');
    byId('confirmTitle').textContent = settings.title || '确认操作';
    byId('confirmMessage').textContent = message || '是否继续？';
    byId('confirmAccept').textContent = settings.confirmText || '继续';
    byId('confirmCancel').textContent = settings.cancelText || '取消';
    dialog.classList.toggle('danger', Boolean(settings.danger));
    confirmState.trigger = document.activeElement;
    byId('confirmBackdrop').hidden = false;
    dialog.hidden = false;
    document.body.classList.add('mi-confirm-open');
    return new Promise(function (resolve) {
      confirmState.resolve = resolve;
      window.setTimeout(function () {
        if (!dialog.hidden) restoreFocus(settings.danger ? byId('confirmCancel') : byId('confirmAccept'));
      }, 0);
    });
  }

  function initConfirmDialog() {
    byId('confirmBackdrop').addEventListener('click', function () { closeConfirm(false); });
    byId('confirmCancel').addEventListener('click', function () { closeConfirm(false); });
    byId('confirmAccept').addEventListener('click', function () { closeConfirm(true); });
    document.addEventListener('keydown', function (event) {
      if (event.key === 'Escape' && !byId('confirmDialog').hidden) closeConfirm(false);
    });
  }

  function confirmAction(message, options, action) {
    showConfirm(message, options).then(function (accepted) {
      if (accepted) action();
    });
  }

  function request(action, options) {
    var settings = options || {};
    settings.cache = 'no-store';
    settings.credentials = 'same-origin';
    return fetch('mihomo.cgi?action=' + encodeURIComponent(action), settings)
      .then(function (response) {
        return response.json().catch(function () { throw new Error('设备返回了无法解析的数据'); });
      })
      .then(function (data) {
        if (data && data.ok === false) throw new Error(data.error || '操作失败');
        return data;
      });
  }

  function postJson(action, body) {
    return request(action, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body || {})
    });
  }

  function setStatus(running) {
    state.running = running;
    var pill = byId('statusPill');
    pill.className = 'status-pill ' + (running ? 'online' : 'offline');
    pill.innerHTML = '<span></span>' + (running ? '运行中' : '已停止');
    byId('startButton').disabled = running;
    byId('stopButton').disabled = !running;
    byId('restartButton').disabled = !running;
  }

  function normalizeMode(value) {
    return String(value || '').toLowerCase();
  }

  function updateModeButtons(mode) {
    state.currentMode = normalizeMode(mode);
    document.querySelectorAll('#modeSwitch button').forEach(function (button) {
      button.classList.toggle('active', button.dataset.mode === state.currentMode);
    });
  }

  function loadStatus(showMessage) {
    return request('status').then(function (data) {
      setStatus(Boolean(data.running));
      var version = data.version && (data.version.version || data.version.meta);
      byId('versionText').textContent = version ? ('核心 ' + version) : (data.running ? '控制端正在准备' : '核心未运行');
      var configs = data.configs || {};
      var mode = normalizeMode(configs.mode);
      byId('modeMetric').textContent = mode ? ({ rule: '规则', global: '全局', direct: '直连' }[mode] || mode) : '—';
      byId('portMetric').textContent = configs['mixed-port'] || '—';
      byId('lanMetric').textContent = configs['allow-lan'] === true ? '已开放' : '仅本机';
      if (data.pluginVersion) byId('pluginVersion').textContent = '插件版本 ' + data.pluginVersion;
      updateModeButtons(mode);
      if (showMessage) toast('状态已刷新');
      return data;
    }).catch(function (error) {
      setStatus(false);
      byId('versionText').textContent = error.message;
      if (showMessage) toast(error.message, true);
    });
  }

  function loadDockerProxy(showMessage) {
    return request('docker_proxy_status').then(function (data) {
      state.dockerProxyAvailable = Boolean(data.available);
      state.dockerProxyEnabled = Boolean(data.enabled);
      var badge = byId('dockerProxyBadge');
      var summary = byId('dockerProxySummary');
      if (!data.available) {
        badge.className = 'mini-badge';
        badge.textContent = '不可用';
        summary.textContent = '设备上未检测到可用的 Docker 服务。';
      } else if (data.enabled) {
        badge.className = 'mini-badge ready';
        badge.textContent = data.dockerActive ? '已启用' : '服务异常';
        summary.textContent = 'Docker 正在使用 ' + (data.proxy || '127.0.0.1:7890') + '。';
      } else {
        badge.className = 'mini-badge';
        badge.textContent = '未启用';
        summary.textContent = 'Docker 当前未配置 Mihomo 代理。';
      }
      byId('enableDockerProxy').disabled = !data.available || data.enabled || !data.mihomoListening;
      byId('disableDockerProxy').disabled = !data.available || !data.enabled;
      if (showMessage) toast('Docker 代理状态已刷新');
      return data;
    }).catch(function (error) {
      state.dockerProxyAvailable = false;
      state.dockerProxyEnabled = false;
      byId('dockerProxyBadge').className = 'mini-badge';
      byId('dockerProxyBadge').textContent = '读取失败';
      byId('dockerProxySummary').textContent = error.message;
      byId('enableDockerProxy').disabled = true;
      byId('disableDockerProxy').disabled = true;
      if (showMessage) toast(error.message, true);
    });
  }

  function updateAccessButtons(mode) {
    state.currentAccess = mode || 'local';
    document.querySelectorAll('#accessSwitch button').forEach(function (button) {
      button.classList.toggle('active', button.dataset.access === state.currentAccess);
    });
  }

  function loadNetworkAccess(showMessage) {
    return request('network_access_status').then(function (data) {
      updateAccessButtons(data.mode);
      byId('networkAccessSummary').textContent = data.mode === 'lan'
        ? '已监听所有网卡，局域网设备可使用 NAS IP 和 7890 端口。'
        : '只监听 127.0.0.1，局域网设备无法连接。';
      if (showMessage) toast('访问范围已刷新');
      return data;
    }).catch(function (error) {
      byId('networkAccessSummary').textContent = error.message;
      if (showMessage) toast(error.message, true);
    });
  }

  function loadCoreUpdate(showMessage) {
    return request('core_update_status').then(function (data) {
      state.coreUpdateAvailable = Boolean(data.updateAvailable);
      var badge = byId('coreUpdateBadge');
      var current = data.currentVersion || '未知';
      var latest = data.latestVersion || '';
      if (!latest) {
        badge.className = 'mini-badge';
        badge.textContent = '未检查';
        byId('coreUpdateSummary').textContent = '当前 ' + current + ' · 点击检查更新获取官方最新版本。';
      } else if (data.updateAvailable) {
        badge.className = 'mini-badge ready';
        badge.textContent = '可更新';
        byId('coreUpdateSummary').textContent = '当前 ' + current + ' · 最新 ' + latest;
      } else {
        badge.className = 'mini-badge ready';
        badge.textContent = '已是最新';
        byId('coreUpdateSummary').textContent = '当前 ' + current + ' · 已检查 ' + latest;
      }
      byId('applyCoreUpdate').disabled = !data.updateAvailable;
      if (showMessage) toast(data.updateAvailable ? '发现新内核 ' + latest : '当前已是最新稳定版');
      return data;
    }).catch(function (error) {
      state.coreUpdateAvailable = false;
      byId('coreUpdateBadge').className = 'mini-badge';
      byId('coreUpdateBadge').textContent = '读取失败';
      byId('coreUpdateSummary').textContent = error.message;
      byId('applyCoreUpdate').disabled = true;
      if (showMessage) toast(error.message, true);
    });
  }

  function formatBytes(value) {
    var size = Number(value || 0);
    if (!size) return '0 B';
    if (size >= 1048576) return (size / 1048576).toFixed(1) + ' MiB';
    return (size / 1024).toFixed(1) + ' KiB';
  }

  function loadGeoData(showMessage) {
    return request('geodata_status').then(function (data) {
      state.geoDataReady = Boolean(data.geoipPresent && data.geositePresent);
      var badge = byId('geoDataBadge');
      badge.className = 'mini-badge' + (state.geoDataReady ? ' ready' : '');
      badge.textContent = state.geoDataReady ? '数据就绪' : '尚未下载';
      if (state.geoDataReady) {
        var summary = 'GeoIP ' + formatBytes(data.geoipSize) + ' · GeoSite ' + formatBytes(data.geositeSize);
        if (data.updatedAt) summary += ' · 更新于 ' + data.updatedAt;
        byId('geoDataSummary').textContent = summary;
      } else {
        byId('geoDataSummary').textContent = '尚未同时检测到 GeoIP.dat 和 GeoSite.dat。';
      }
      if (data.policy && data.policy !== 'custom') {
        byId('geoPolicy').value = data.policy;
        if (byId('geoPolicy')._miSync) byId('geoPolicy')._miSync();
      }
      if (showMessage) toast('Geo 数据状态已刷新');
      return data;
    }).catch(function (error) {
      state.geoDataReady = false;
      byId('geoDataBadge').className = 'mini-badge';
      byId('geoDataBadge').textContent = '读取失败';
      byId('geoDataSummary').textContent = error.message;
      if (showMessage) toast(error.message, true);
    });
  }

  function textElement(tag, className, text) {
    var element = document.createElement(tag);
    if (className) element.className = className;
    element.textContent = text;
    return element;
  }

  function loadProxies() {
    var container = byId('proxyGroups');
    container.className = 'stack empty-state';
    container.textContent = '正在读取策略组…';
    return request('proxies').then(function (data) {
      var proxies = data.proxies || {};
      var groups = Object.keys(proxies).map(function (name) {
        return { name: name, value: proxies[name] };
      }).filter(function (item) {
        return item.value && Array.isArray(item.value.all) && item.value.all.length > 0;
      });

      container.textContent = '';
      container.className = 'stack';
      if (!groups.length) {
        container.className = 'stack empty-state';
        container.textContent = '当前配置没有可选策略组。';
        return;
      }

      groups.forEach(function (item) {
        var row = document.createElement('div');
        row.className = 'group-row';
        var title = document.createElement('div');
        title.className = 'row-title';
        title.appendChild(textElement('strong', '', item.name));
        title.appendChild(textElement('span', '', item.value.type || 'Selector'));

        var currentNode = item.value.now || item.value.all[0] || '';
        var trigger = createSelectTrigger(currentNode, '选择 ' + item.name + ' 节点');
        trigger.addEventListener('click', function () {
          openPicker('选择 ' + item.name, item.value.all, currentNode, function (node) {
            trigger.disabled = true;
            postJson('select_proxy', { group: item.name, node: node })
            .then(function () {
              currentNode = node;
              setSelectTriggerValue(trigger, node);
              toast(item.name + ' 已切换');
            })
            .catch(function (error) { toast(error.message, true); loadProxies(); })
            .finally(function () { trigger.disabled = false; });
          }, trigger);
        });
        row.appendChild(title);
        row.appendChild(trigger);
        container.appendChild(row);
      });
    }).catch(function (error) {
      container.className = 'stack empty-state';
      container.textContent = error.message;
    });
  }

  function renderProviders(container, providers, kind) {
    var names = Object.keys(providers);
    if (kind === 'proxy') state.proxyProviderNames = names;
    else state.ruleProviderNames = names;
    container.textContent = '';
    container.className = 'stack';
    if (!names.length) {
      container.className = 'stack empty-state';
      container.textContent = kind === 'proxy' ? '当前配置没有 proxy-providers。' : '当前配置没有 rule-providers。';
      return;
    }
    names.forEach(function (name) {
      var provider = providers[name] || {};
      var row = document.createElement('div');
      row.className = 'provider-row';
      var title = document.createElement('div');
      title.className = 'row-title';
      title.appendChild(textElement('strong', '', name));
      var detail;
      if (kind === 'proxy') {
        detail = (provider.vehicleType || 'provider') + ' · ' + ((provider.proxies || []).length) + ' 节点';
      } else {
        var ruleCount = provider.ruleCount || (provider.rules || []).length || 0;
        detail = (provider.vehicleType || 'provider') + ' · ' + ruleCount + ' 条规则';
      }
      title.appendChild(textElement('span', '', detail));
      var button = textElement('button', 'button secondary', '更新');
      button.addEventListener('click', function () {
        button.disabled = true;
        var action = kind === 'proxy' ? 'update_provider' : 'update_rule_provider';
        postJson(action, { provider: name })
          .then(function () {
            toast(name + ' 更新完成');
            return kind === 'proxy' ? loadProxies() : loadRuleProviders();
          })
          .catch(function (error) { toast(error.message, true); })
          .finally(function () { button.disabled = false; });
      });
      row.appendChild(title);
      row.appendChild(button);
      container.appendChild(row);
    });
  }

  function loadProviders() {
    var container = byId('providers');
    container.className = 'stack empty-state';
    container.textContent = '正在读取提供者…';
    return request('providers').then(function (data) {
      renderProviders(container, data.providers || {}, 'proxy');
    }).catch(function (error) {
      state.proxyProviderNames = [];
      container.className = 'stack empty-state';
      container.textContent = error.message;
    });
  }

  function loadRuleProviders() {
    var container = byId('ruleProviders');
    container.className = 'stack empty-state';
    container.textContent = '正在读取规则提供者…';
    return request('rule_providers').then(function (data) {
      renderProviders(container, data.providers || {}, 'rule');
    }).catch(function (error) {
      state.ruleProviderNames = [];
      container.className = 'stack empty-state';
      container.textContent = error.message;
    });
  }

  function loadManualNodes() {
    var container = byId('manualNodes');
    container.className = 'stack empty-state';
    container.textContent = '正在读取手动节点…';
    return request('manual_nodes').then(function (data) {
      var nodes = data.nodes || [];
      container.textContent = '';
      container.className = 'stack';
      if (!nodes.length) {
        container.className = 'stack empty-state';
        container.textContent = '尚未导入手动节点。';
        return;
      }
      nodes.forEach(function (node) {
        var row = document.createElement('div');
        row.className = 'provider-row';
        var title = document.createElement('div');
        title.className = 'row-title';
        title.appendChild(textElement('strong', '', node.name || '未命名节点'));
        title.appendChild(textElement('span', '', String(node.type || 'unknown').toUpperCase()));
        var button = textElement('button', 'button danger compact', '删除');
        button.addEventListener('click', function () {
          confirmAction('确定删除手动节点“' + node.name + '”吗？', { title: '删除节点', confirmText: '删除', danger: true }, function () {
            button.disabled = true;
            postJson('manual_node_delete', { name: node.name }).then(function () {
              toast('节点已删除');
              loadManualNodes();
              loadProviders();
              loadProxies();
            }).catch(function (error) {
              toast(error.message, true);
            }).finally(function () { button.disabled = false; });
          });
        });
        row.appendChild(title);
        row.appendChild(button);
        container.appendChild(row);
      });
    }).catch(function (error) {
      container.className = 'stack empty-state';
      container.textContent = error.message;
    });
  }

  function updateAllProviders(kind, button) {
    var names = kind === 'proxy' ? state.proxyProviderNames.slice() : state.ruleProviderNames.slice();
    if (!names.length) {
      toast(kind === 'proxy' ? '没有可更新的代理提供者' : '没有可更新的规则提供者', true);
      return;
    }
    button.disabled = true;
    var action = kind === 'proxy' ? 'update_provider' : 'update_rule_provider';
    var chain = Promise.resolve();
    names.forEach(function (name) {
      chain = chain.then(function () { return postJson(action, { provider: name }); });
    });
    chain.then(function () {
      toast('全部更新完成');
      if (kind === 'proxy') { loadProviders(); loadProxies(); }
      else loadRuleProviders();
    }).catch(function (error) {
      toast(error.message, true);
    }).finally(function () { button.disabled = false; });
  }

  function loadSubscription() {
    return request('subscription_status').then(function (data) {
      state.subscriptionConfigured = Boolean(data.configured);
      var badge = byId('subscriptionBadge');
      badge.className = 'mini-badge' + (data.configured ? ' ready' : '');
      badge.textContent = data.configured ? '已配置' : '未配置';
      byId('updateSubscription').disabled = !data.configured;
      if (data.configured) {
        var pieces = [];
        if (data.source) pieces.push(data.source);
        pieces.push((data.proxyCount || 0) + ' 个节点');
        if (data.updatedAt) pieces.push('更新于 ' + data.updatedAt);
        byId('subscriptionSummary').textContent = pieces.join(' · ');
      } else {
        byId('subscriptionSummary').textContent = '尚未导入订阅。';
      }
      var nodeContainer = byId('subscriptionNodes');
      var nodes = Array.isArray(data.nodes) ? data.nodes : [];
      nodeContainer.textContent = '';
      nodeContainer.className = 'stack subscription-node-list';
      if (!nodes.length) {
        nodeContainer.className = 'stack subscription-node-list empty-state';
        nodeContainer.textContent = data.configured ? '控制端尚未返回订阅节点。' : '导入订阅后将在这里显示全部节点。';
      } else {
        nodes.forEach(function (node) {
          var row = document.createElement('div');
          row.className = 'provider-row subscription-node';
          var title = document.createElement('div');
          title.className = 'row-title';
          title.appendChild(textElement('strong', '', node.name || '未命名节点'));
          title.appendChild(textElement('span', '', String(node.type || 'unknown').toUpperCase()));
          var stateText = node.alive === false ? '不可用' : (node.alive === true ? '可用' : '未检测');
          row.appendChild(title);
          row.appendChild(textElement('span', 'node-state', stateText));
          nodeContainer.appendChild(row);
        });
      }
    }).catch(function (error) {
      byId('subscriptionSummary').textContent = error.message;
      byId('subscriptionNodes').className = 'stack subscription-node-list empty-state';
      byId('subscriptionNodes').textContent = error.message;
      toast(error.message, true);
    });
  }

  function loadConfig() {
    byId('configHint').textContent = '正在读取…';
    return request('config_get').then(function (data) {
      byId('configEditor').value = data.config || '';
      byId('configHint').textContent = '已载入 · 最大 2 MiB';
      state.configLoaded = true;
    }).catch(function (error) {
      byId('configHint').textContent = error.message;
      toast(error.message, true);
    });
  }

  function loadLogs() {
    byId('logViewer').textContent = '正在读取…';
    return request('logs').then(function (data) {
      byId('logViewer').textContent = data.log || '日志为空。';
    }).catch(function (error) {
      byId('logViewer').textContent = error.message;
    });
  }

  var pageOrder = ['overview', 'proxies', 'subscription', 'config', 'logs'];

  function activatePage(pageName, fromSwipe) {
    var tab = document.querySelector('.tab[data-page="' + pageName + '"]');
    var page = byId('page-' + pageName);
    if (!tab || !page) return;
    document.querySelectorAll('.tab').forEach(function (item) { item.classList.remove('active'); });
    document.querySelectorAll('.page').forEach(function (item) { item.classList.remove('active'); });
    tab.classList.add('active');
    page.classList.add('active');
    if (pageName === 'config' && !state.configLoaded) loadConfig();
    if (pageName === 'subscription') { loadSubscription(); loadManualNodes(); }
    if (pageName === 'proxies') loadGeoData(false);
    if (pageName === 'logs') loadLogs();
    if (fromSwipe) window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  document.querySelectorAll('.tab').forEach(function (tab) {
    tab.addEventListener('click', function () { activatePage(tab.dataset.page, false); });
  });

  var swipeStart = null;
  var shell = document.querySelector('.shell');
  shell.addEventListener('touchstart', function (event) {
    if (event.touches.length !== 1 || event.target.closest('input,textarea,select,button,pre,a')) {
      swipeStart = null;
      return;
    }
    var touch = event.touches[0];
    if (touch.clientX < 24 || touch.clientX > window.innerWidth - 24) {
      swipeStart = null;
      return;
    }
    swipeStart = { x: touch.clientX, y: touch.clientY };
  }, { passive: true });
  shell.addEventListener('touchend', function (event) {
    if (!swipeStart || !event.changedTouches.length) return;
    var touch = event.changedTouches[0];
    var deltaX = touch.clientX - swipeStart.x;
    var deltaY = touch.clientY - swipeStart.y;
    swipeStart = null;
    if (Math.abs(deltaX) < 55 || Math.abs(deltaX) < Math.abs(deltaY) * 1.35) return;
    var activeTab = document.querySelector('.tab.active');
    var currentIndex = pageOrder.indexOf(activeTab ? activeTab.dataset.page : 'overview');
    var nextIndex = deltaX < 0 ? currentIndex + 1 : currentIndex - 1;
    if (nextIndex >= 0 && nextIndex < pageOrder.length) activatePage(pageOrder[nextIndex], true);
  }, { passive: true });

  document.querySelectorAll('#modeSwitch button').forEach(function (button) {
    button.addEventListener('click', function () {
      var mode = button.dataset.mode;
      if (mode === state.currentMode) return;
      postJson('set_mode', { mode: mode }).then(function () {
        updateModeButtons(mode);
        loadStatus(false);
        toast('运行模式已切换');
      }).catch(function (error) { toast(error.message, true); });
    });
  });

  document.querySelectorAll('#accessSwitch button').forEach(function (button) {
    button.addEventListener('click', function () {
      var accessMode = button.dataset.access;
      if (accessMode === state.currentAccess) return;
      var warning = accessMode === 'lan'
        ? '开放后局域网设备可连接 NAS 的 7890 端口。请确认局域网可信，是否继续？'
        : '切换后局域网设备将无法再使用此代理，是否继续？';
      confirmAction(warning, { title: accessMode === 'lan' ? '开放局域网访问' : '仅本机访问' }, function () {
        button.disabled = true;
        postJson('network_access_set', { mode: accessMode }).then(function () {
          state.configLoaded = false;
          toast(accessMode === 'lan' ? '已开放局域网访问' : '已切换为仅本机访问');
          loadNetworkAccess(false);
          loadStatus(false);
          loadDockerProxy(false);
        }).catch(function (error) {
          toast(error.message, true);
          loadNetworkAccess(false);
        }).finally(function () { button.disabled = false; });
      });
    });
  });

  byId('refreshButton').addEventListener('click', function () { loadStatus(true); });
  byId('checkCoreUpdate').addEventListener('click', function () {
    var button = this;
    button.disabled = true;
    request('core_update_check').then(function (data) {
      state.coreUpdateAvailable = Boolean(data.updateAvailable);
      toast(data.updateAvailable ? '发现新内核 ' + data.latestVersion : '当前已是最新稳定版');
      return loadCoreUpdate(false);
    }).catch(function (error) {
      toast(error.message, true);
    }).finally(function () { button.disabled = false; });
  });
  byId('applyCoreUpdate').addEventListener('click', function () {
    var button = this;
    confirmAction('将下载、校验并替换 Mihomo 内核；运行中的内核会自动重启。是否继续？', { title: '更新 Mihomo 内核' }, function () {
      button.disabled = true;
      postJson('core_update_apply', {}).then(function (data) {
        toast(data.updated ? '内核已更新至 ' + data.currentVersion : '当前已是最新稳定版');
        return loadStatus(false);
      }).then(function () {
        return loadCoreUpdate(false);
      }).catch(function (error) {
        toast(error.message, true);
        loadCoreUpdate(false);
        loadStatus(false);
      }).finally(function () { button.disabled = false; });
    });
  });
  byId('updateGeoData').addEventListener('click', function () {
    var button = this;
    confirmAction('将从官方仓库下载并校验 GeoIP、GeoSite；Mihomo 可能自动重启。是否继续？', { title: '更新 Geo 数据' }, function () {
      button.disabled = true;
      postJson('geodata_update', {}).then(function () {
        toast('GeoIP 和 GeoSite 已更新');
        return loadGeoData(false);
      }).then(function () {
        loadStatus(false);
      }).catch(function (error) {
        toast(error.message, true);
        loadGeoData(false);
      }).finally(function () { button.disabled = false; });
    });
  });
  byId('applyGeoPolicy').addEventListener('click', function () {
    var policySelect = byId('geoPolicy');
    var policyName = policySelect.options[policySelect.selectedIndex].text;
    var button = this;
    confirmAction('将备份配置并应用“' + policyName + '”，随后校验并重启 Mihomo。是否继续？', { title: '应用 Geo 策略' }, function () {
      button.disabled = true;
      postJson('geodata_apply_policy', { policy: policySelect.value }).then(function () {
        state.configLoaded = false;
        toast('Geo 规则策略已应用');
        loadGeoData(false);
        loadStatus(false);
        loadProxies();
      }).catch(function (error) {
        toast(error.message, true);
      }).finally(function () { button.disabled = false; });
    });
  });
  byId('refreshDockerProxy').addEventListener('click', function () { loadDockerProxy(true); });
  byId('reloadProxies').addEventListener('click', function () { loadProxies(); loadProviders(); loadRuleProviders(); });
  byId('reloadManualNodes').addEventListener('click', loadManualNodes);
  byId('updateAllProviders').addEventListener('click', function () { updateAllProviders('proxy', this); });
  byId('updateAllRuleProviders').addEventListener('click', function () { updateAllProviders('rule', this); });
  byId('loadConfig').addEventListener('click', loadConfig);
  byId('loadLogs').addEventListener('click', loadLogs);

  byId('importSubscription').addEventListener('click', function () {
    var subscriptionUrl = byId('subscriptionUrl').value.trim();
    if (!/^https:\/\//i.test(subscriptionUrl)) {
      toast('请输入有效的 HTTPS 订阅 URL', true);
      return;
    }
    var button = this;
    confirmAction('首次导入会备份并替换当前 config.yaml，然后重启 Mihomo。是否继续？', { title: '导入订阅' }, function () {
      button.disabled = true;
      postJson('subscription_import', { url: subscriptionUrl }).then(function (data) {
        byId('subscriptionUrl').value = '';
        state.configLoaded = false;
        toast('订阅已导入，共 ' + (data.proxyCount || 0) + ' 个节点');
        loadSubscription();
        loadStatus(false);
        loadProviders();
        loadProxies();
        loadRuleProviders();
      }).catch(function (error) {
        toast(error.message, true);
      }).finally(function () { button.disabled = false; });
    });
  });

  byId('updateSubscription').addEventListener('click', function () {
    if (!state.subscriptionConfigured) return;
    var button = this;
    button.disabled = true;
    postJson('subscription_update', {}).then(function (data) {
      toast('订阅已更新，共 ' + (data.proxyCount || 0) + ' 个节点');
      loadSubscription();
      loadProviders();
      loadProxies();
    }).catch(function (error) {
      toast(error.message, true);
    }).finally(function () { button.disabled = false; });
  });

  byId('importManualNode').addEventListener('click', function () {
    var nodeValue = byId('manualNodeInput').value.trim();
    if (!nodeValue) {
      toast('请输入单节点分享链接或 Clash JSON', true);
      return;
    }
    var button = this;
    confirmAction('节点将写入本地 provider；必要时会备份并切换为受管配置，然后重启 Mihomo。是否继续？', { title: '导入节点' }, function () {
      button.disabled = true;
      postJson('manual_node_import', { node: nodeValue }).then(function (data) {
        byId('manualNodeInput').value = '';
        state.configLoaded = false;
        toast((data.replaced ? '节点已更新：' : '节点已导入：') + (data.name || '未命名节点'));
        loadManualNodes();
        loadStatus(false);
        loadProviders();
        loadProxies();
      }).catch(function (error) {
        toast(error.message, true);
      }).finally(function () { button.disabled = false; });
    });
  });

  byId('importRuleProvider').addEventListener('click', function () {
    var name = byId('ruleProviderName').value.trim();
    var url = byId('ruleProviderUrl').value.trim();
    if (!/^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/.test(name)) {
      toast('名称需以字母或数字开头，且只能包含字母、数字、点、下划线和短横线', true);
      return;
    }
    if (!/^https:\/\//i.test(url)) {
      toast('请输入有效的 HTTPS 规则 URL', true);
      return;
    }
    var button = this;
    confirmAction('将写入规则提供者并重启 Mihomo，是否继续？', { title: '导入规则提供者' }, function () {
      button.disabled = true;
      postJson('rule_provider_import', {
        name: name,
        url: url,
        behavior: byId('ruleProviderBehavior').value,
        format: byId('ruleProviderFormat').value,
        target: byId('ruleProviderTarget').value,
        via: byId('ruleProviderVia').value
      }).then(function () {
        byId('ruleProviderUrl').value = '';
        state.configLoaded = false;
        toast('规则提供者已导入：' + name);
        loadRuleProviders();
        loadStatus(false);
      }).catch(function (error) {
        toast(error.message, true);
      }).finally(function () { button.disabled = false; });
    });
  });

  function runCoreAction(action, button, successMessage) {
    button.disabled = true;
    postJson(action, {}).then(function () {
      toast(successMessage);
      return loadStatus(false);
    }).then(function () {
      loadDockerProxy(false);
      if (action !== 'stop') {
        loadProxies();
        loadProviders();
        loadRuleProviders();
      }
    }).catch(function (error) {
      toast(error.message, true);
      loadStatus(false);
    }).finally(function () { button.disabled = false; });
  }

  byId('startButton').addEventListener('click', function () {
    runCoreAction('start', this, 'Mihomo 已启动');
  });

  byId('stopButton').addEventListener('click', function () {
    var warning = state.dockerProxyEnabled
      ? 'Docker 代理当前已启用；停止 Mihomo 后 Docker 拉取镜像将不可用。仍要停止吗？'
      : '确定停止 Mihomo 核心吗？';
    var button = this;
    confirmAction(warning, { title: '停止 Mihomo', confirmText: '停止', danger: true }, function () {
      runCoreAction('stop', button, 'Mihomo 已停止');
    });
  });

  byId('restartButton').addEventListener('click', function () {
    var button = this;
    confirmAction('确定重启 Mihomo 核心吗？', { title: '重启 Mihomo' }, function () {
      runCoreAction('restart', button, 'Mihomo 已重启');
    });
  });

  byId('enableDockerProxy').addEventListener('click', function () {
    var button = this;
    confirmAction('启用后将重启 docker.service，运行中的容器可能短暂中断。是否继续？', { title: '启用 Docker 代理' }, function () {
      button.disabled = true;
      postJson('docker_proxy_enable', {}).then(function () {
        toast('Docker 代理已启用');
        return loadDockerProxy(false);
      }).catch(function (error) {
        toast(error.message, true);
        loadDockerProxy(false);
      }).finally(function () { button.disabled = false; });
    });
  });

  byId('disableDockerProxy').addEventListener('click', function () {
    var button = this;
    confirmAction('关闭代理会重启 docker.service。是否继续？', { title: '关闭 Docker 代理', confirmText: '关闭', danger: true }, function () {
      button.disabled = true;
      postJson('docker_proxy_disable', {}).then(function () {
        toast('Docker 代理已关闭');
        return loadDockerProxy(false);
      }).catch(function (error) {
        toast(error.message, true);
        loadDockerProxy(false);
      }).finally(function () { button.disabled = false; });
    });
  });

  byId('saveConfig').addEventListener('click', function () {
    var content = byId('configEditor').value;
    if (!content.trim()) { toast('配置不能为空', true); return; }
    var button = this;
    confirmAction('将校验配置并重启 Mihomo，是否继续？', { title: '保存配置' }, function () {
      button.disabled = true;
      byId('configHint').textContent = '正在校验并重启…';
      request('config_save', {
        method: 'POST',
        headers: { 'Content-Type': 'text/yaml; charset=utf-8' },
        body: content
      }).then(function () {
        byId('configHint').textContent = '保存成功 · 已重启';
        toast('配置已生效');
        loadStatus(false);
        loadProxies();
        loadProviders();
        loadRuleProviders();
      }).catch(function (error) {
        byId('configHint').textContent = '保存失败';
        toast(error.message, true);
      }).finally(function () { button.disabled = false; });
    });
  });

  initPickers();
  initConfirmDialog();
  loadStatus(false);
  loadProxies();
  loadProviders();
  loadRuleProviders();
  loadSubscription();
  loadManualNodes();
  loadDockerProxy(false);
  loadNetworkAccess(false);
  loadCoreUpdate(false);
  loadGeoData(false);
}());
