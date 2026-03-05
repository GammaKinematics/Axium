(async function() {
  var defaults = {};
  var domains = [];
  var currentDomain = '';
  var currentSite = {};

  // Boolean fields that can be per-site
  var boolFields = [
    'javascript','popups','adblock','webrtc','webgl','media_stream',
    'geolocation','notifications','camera','microphone','clipboard',
    'device_info','media_keys','data_access','tls_enforce'
  ];

  // Defaults-only boolean fields
  var defaultsBoolFields = ['itp','credential_persistence'];

  async function msg(data) {
    var raw = await window.webkit.messageHandlers.axium.postMessage(data);
    return typeof raw === 'string' ? JSON.parse(raw) : raw;
  }

  function showStatus(text) {
    var s = document.getElementById('status');
    s.textContent = text;
    s.style.display = 'block';
    setTimeout(function() { s.style.display = 'none'; }, 2000);
  }

  // --- Toggle helpers ---

  function setToggle(btn, val) {
    btn.classList.remove('on', 'off');
    btn.classList.add(val ? 'on' : 'off');
  }

  function applyToPanel(panel, data) {
    var rows = panel.querySelectorAll('.row[data-key]');
    rows.forEach(function(row) {
      var key = row.dataset.key;
      if (!(key in data)) return;
      var val = data[key];
      var toggle = row.querySelector('.toggle');
      if (toggle) { setToggle(toggle, val); return; }
      var sel = row.querySelector('select');
      if (sel) { sel.value = String(val); return; }
      var inp = row.querySelector('input');
      if (inp) { inp.value = val || ''; }
    });
  }

  // --- Defaults ---

  async function loadDefaults() {
    try { defaults = await msg({action:'get-defaults'}); } catch(e) { defaults = {}; }
    applyToPanel(document.getElementById('defaults-panel'), defaults);
  }

  window.toggleDefault = function(btn, key) {
    defaults[key] = !defaults[key];
    setToggle(btn, defaults[key]);
    msg({action:'set-defaults', data: defaults});
  };

  window.setDefault = function(key, val) {
    defaults[key] = val;
    msg({action:'set-defaults', data: defaults});
  };

  // --- Domains ---

  async function loadDomains() {
    try { domains = await msg({action:'get-domains'}); } catch(e) { domains = []; }
    var sel = document.getElementById('domain-select');
    sel.innerHTML = '<option value="">Select domain...</option>';
    domains.sort();
    domains.forEach(function(d) {
      var opt = document.createElement('option');
      opt.value = d;
      opt.textContent = d;
      sel.appendChild(opt);
    });
  }

  // --- Per-site ---

  window.loadSite = async function() {
    var sel = document.getElementById('domain-select');
    currentDomain = sel.value;
    var panel = document.getElementById('site-settings');
    if (!currentDomain) { panel.style.display = 'none'; return; }
    panel.style.display = '';
    try { currentSite = await msg({action:'get-site', domain: currentDomain}); } catch(e) { currentSite = {}; }
    applyToPanel(panel, currentSite);
  };

  function saveSite() {
    msg({action:'set-site', domain: currentDomain, data: currentSite});
  }

  window.toggleSite = function(btn, key) {
    currentSite[key] = !currentSite[key];
    setToggle(btn, currentSite[key]);
    saveSite();
  };

  window.setSiteField = function(key, val) {
    currentSite[key] = val;
    saveSite();
  };

  window.addDomain = function() {
    var inp = document.getElementById('new-domain');
    var d = inp.value.trim();
    if (!d) return;
    inp.value = '';
    if (domains.indexOf(d) < 0) { domains.push(d); }
    // Select it in dropdown
    var sel = document.getElementById('domain-select');
    var exists = false;
    for (var i = 0; i < sel.options.length; i++) {
      if (sel.options[i].value === d) { exists = true; break; }
    }
    if (!exists) {
      var opt = document.createElement('option');
      opt.value = d;
      opt.textContent = d;
      sel.appendChild(opt);
    }
    sel.value = d;
    loadSite();
  };

  // --- Tab switching ---

  window.switchTab = function(tab) {
    document.querySelectorAll('.tab').forEach(function(b) { b.classList.remove('active'); });
    event.target.classList.add('active');
    document.getElementById('defaults-panel').style.display = tab === 'defaults' ? '' : 'none';
    document.getElementById('sites-panel').style.display = tab === 'sites' ? '' : 'none';
  };

  // --- Init ---
  await loadDefaults();
  await loadDomains();
})();
