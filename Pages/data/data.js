(async function() {
  var allSites = [];
  try {
    var raw = await window.webkit.messageHandlers.axium.postMessage({action:"data-list"});
    allSites = typeof raw === "string" ? JSON.parse(raw) : raw;
  } catch (e) {
    allSites = [];
  }
  allSites.sort(function(a, b) { return a.name.localeCompare(b.name); });

  var selectedNames = new Set(allSites.map(function(s) { return s.name; }));
  var availHighlight = new Set();
  var selHighlight = new Set();
  var searchFilter = '';

  function fmtSize(b) {
    if (b < 1024) return b + ' B';
    if (b < 1048576) return (b / 1024).toFixed(1) + ' KB';
    return (b / 1048576).toFixed(1) + ' MB';
  }

  function isAllSelected() {
    return selectedNames.size >= allSites.length;
  }

  function updateTimerangeState() {
    document.getElementById('timerange').disabled = !isAllSelected();
  }

  function esc(s) {
    var d = document.createElement('span');
    d.textContent = s;
    return d.innerHTML;
  }

  function toggleSet(st, v) {
    if (st.has(v)) st.delete(v); else st.add(v);
  }

  function render() {
    var avail = document.getElementById('availList');
    var sel = document.getElementById('selList');
    avail.innerHTML = '';
    sel.innerHTML = '';
    var filter = searchFilter.toLowerCase();
    allSites.forEach(function(s) {
      if (selectedNames.has(s.name)) {
        var el = document.createElement('div');
        el.className = 'list-item' + (selHighlight.has(s.name) ? ' sel' : '');
        el.innerHTML = '<span>' + esc(s.name) + '</span><span class="size">' + fmtSize(s.size) + '</span>';
        el.onclick = function(e) {
          if (e.ctrlKey || e.metaKey) { toggleSet(selHighlight, s.name); }
          else { selHighlight.clear(); selHighlight.add(s.name); }
          render();
        };
        sel.appendChild(el);
      } else {
        if (filter && s.name.toLowerCase().indexOf(filter) === -1) return;
        var el = document.createElement('div');
        el.className = 'list-item' + (availHighlight.has(s.name) ? ' sel' : '');
        el.innerHTML = '<span>' + esc(s.name) + '</span><span class="size">' + fmtSize(s.size) + '</span>';
        el.onclick = function(e) {
          if (e.ctrlKey || e.metaKey) { toggleSet(availHighlight, s.name); }
          else { availHighlight.clear(); availHighlight.add(s.name); }
          render();
        };
        avail.appendChild(el);
      }
    });
    updateTimerangeState();
  }

  window.moveSelected = function(toSel) {
    if (toSel) {
      availHighlight.forEach(function(n) { selectedNames.add(n); });
      availHighlight.clear();
    } else {
      selHighlight.forEach(function(n) { selectedNames.delete(n); });
      selHighlight.clear();
    }
    render();
  };

  window.moveAll = function(toSel) {
    if (toSel) {
      allSites.forEach(function(s) { selectedNames.add(s.name); });
    } else {
      selectedNames.clear();
    }
    availHighlight.clear();
    selHighlight.clear();
    render();
  };

  function getTypeMask() {
    var mask = 0;
    if (document.getElementById('dt_cookies').checked) mask |= 1;
    if (document.getElementById('dt_cache').checked) mask |= 2;
    if (document.getElementById('dt_localstorage').checked) mask |= 4;
    if (document.getElementById('dt_indexeddb').checked) mask |= 8;
    if (document.getElementById('dt_sw').checked) mask |= 16;
    if (document.getElementById('dt_hsts').checked) mask |= 32;
    if (document.getElementById('dt_session').checked) mask |= 64;
    if (document.getElementById('dt_domcache').checked) mask |= 128;
    return mask;
  }

  window.clearData = async function() {
    var mask = getTypeMask();
    if (mask === 0) return;
    var domains = isAllSelected() ? [] : Array.from(selectedNames);
    var since = 0;
    if (domains.length === 0) {
      var range = parseInt(document.getElementById('timerange').value);
      if (range > 0) since = Math.floor(Date.now() / 1000) - range;
    }
    var btn = document.getElementById('clearBtn');
    btn.disabled = true;
    btn.textContent = 'Clearing\u2026';
    try {
      var resp = await window.webkit.messageHandlers.axium.postMessage({
        action: "data-clear", domains: domains, types: mask, since: since
      });
      var ok = typeof resp === "string" ? JSON.parse(resp) : resp;
      var s = document.getElementById('status');
      s.style.display = 'block';
      if (ok && ok.ok) {
        s.textContent = 'Data cleared successfully.';
        // Re-fetch site list
        try {
          var raw = await window.webkit.messageHandlers.axium.postMessage({action:"data-list"});
          allSites = typeof raw === "string" ? JSON.parse(raw) : raw;
          allSites.sort(function(a, b) { return a.name.localeCompare(b.name); });
          selectedNames = new Set(allSites.map(function(s) { return s.name; }));
          availHighlight.clear();
          selHighlight.clear();
          render();
        } catch (e) {}
      } else {
        s.textContent = 'Failed to clear data.';
      }
      setTimeout(function() { s.style.display = 'none'; }, 3000);
    } catch (e) {
      var s = document.getElementById('status');
      s.style.display = 'block';
      s.textContent = 'Failed to clear data.';
      setTimeout(function() { s.style.display = 'none'; }, 3000);
    }
    btn.disabled = false;
    btn.textContent = 'Clear Selected Data';
  };

  document.getElementById('search').addEventListener('input', function() {
    searchFilter = this.value;
    render();
  });

  render();
})();
