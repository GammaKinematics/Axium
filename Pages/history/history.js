(async function() {
  var DATA = [];
  try {
    var raw = await window.webkit.messageHandlers.axium.postMessage({action:"history-list"});
    DATA = typeof raw === "string" ? JSON.parse(raw) : raw;
  } catch (e) {
    DATA = [];
  }

  function render(entries) {
    var c = document.getElementById('entries');
    c.innerHTML = '';
    if (!entries.length) { c.innerHTML = '<div class="empty">No history entries</div>'; return; }
    // Deduplicate: most recent per URL per day
    var seen = {}; var deduped = [];
    entries.forEach(function(e) {
      var d = new Date(e.ts * 1000); var dk = d.getFullYear()+'-'+(d.getMonth()+1)+'-'+d.getDate();
      var key = dk + '|' + e.url;
      if (!seen[key]) { seen[key] = 1; deduped.push(e); }
    });
    // Group by date
    var groups = {}; var order = [];
    var now = new Date(); var today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    var yesterday = new Date(today - 86400000);
    deduped.forEach(function(e) {
      var d = new Date(e.ts * 1000);
      var ed = new Date(d.getFullYear(), d.getMonth(), d.getDate());
      var label;
      if (ed.getTime() === today.getTime()) label = 'Today';
      else if (ed.getTime() === yesterday.getTime()) label = 'Yesterday';
      else { var months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
        label = months[d.getMonth()] + ' ' + d.getDate(); }
      var dk = ed.getTime();
      if (!groups[dk]) { groups[dk] = {label: label, items: []}; order.push(dk); }
      groups[dk].items.push(e);
    });
    order.forEach(function(dk) {
      var g = groups[dk];
      var sec = document.createElement('div'); sec.className = 'day-group';
      var h = document.createElement('div'); h.className = 'day-header'; h.textContent = g.label;
      sec.appendChild(h);
      g.items.forEach(function(e) {
        var row = document.createElement('div'); row.className = 'entry';
        var d = new Date(e.ts * 1000);
        var hh = ('0'+d.getHours()).slice(-2); var mm = ('0'+d.getMinutes()).slice(-2);
        row.innerHTML = '<span class="time">' + hh + ':' + mm + '</span>'
          + '<div class="info" data-url="' + e.url.replace(/"/g,'&quot;') + '">'
          + '<div class="title">' + (e.title || e.url).replace(/</g,'&lt;') + '</div>'
          + '<div class="url">' + e.url.replace(/</g,'&lt;') + '</div></div>'
          + '<button class="del-btn" data-id="' + e.id + '">&times;</button>';
        row.querySelector('.info').addEventListener('click', function() {
          window.location.href = this.dataset.url; });
        row.querySelector('.del-btn').addEventListener('click', function(ev) {
          ev.stopPropagation(); deleteEntry(e.id, row); });
        sec.appendChild(row);
      });
      c.appendChild(sec);
    });
  }

  async function deleteEntry(id, row) {
    try {
      await window.webkit.messageHandlers.axium.postMessage({action:"history-delete", id: id});
      row.remove();
      DATA = DATA.filter(function(e) { return e.id !== id; });
    } catch (e) {}
  }

  document.getElementById('clear-btn').addEventListener('click', async function() {
    try {
      await window.webkit.messageHandlers.axium.postMessage({action:"history-clear"});
      DATA = [];
      render(DATA);
    } catch (e) {}
  });

  document.getElementById('search').addEventListener('input', function() {
    var q = this.value.toLowerCase();
    if (!q) { render(DATA); return; }
    render(DATA.filter(function(e) {
      return e.url.toLowerCase().indexOf(q) >= 0 || e.title.toLowerCase().indexOf(q) >= 0;
    }));
  });

  render(DATA);
})();
