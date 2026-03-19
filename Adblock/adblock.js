// Axium Adblock — Content Script
//
// Runs at document_end in the isolated "adblock" script world.
// CSS hide rules, scriptlets, and CSP are injected by adblock.c (WebProcess
// extension) in the default world via on_document_loaded.
//
// This script handles:
//   1. Procedural cosmetic filters (complex DOM-based hiding)
//   2. MutationObserver 2nd-pass (class/id-based hiding for new DOM nodes)
//
// Communicates with adblock engine via JSC native callbacks registered by
// adblock.c in this world's context (no UIProcess roundtrip):
//   __axiumCosmeticFull(url) -> JSON string
//   __axiumHiddenSelectors(classesJson, idsJson, exceptionsJson) -> CSS string

(function() {
  var raw;
  try { raw = __axiumCosmeticFull(location.href); } catch(e) { return; }
  if (!raw) return;
  var res;
  try { res = JSON.parse(raw); } catch(e) { return; }

  // 1. Procedural cosmetic filters
  if (res.procedural) {
    try { __axiumRunProcedural(res.procedural); } catch(e) {}
  }

  // 2. MutationObserver 2nd-pass (hidden class/id selectors)
  if (res.generichide) return;

  var style = document.getElementById('axium-cosmetic');
  if (!style) {
    style = document.createElement('style');
    style.id = 'axium-cosmetic';
    (document.head || document.documentElement).appendChild(style);
  }

  var exceptions = res.exceptions ? JSON.stringify(res.exceptions) : '[]';
  var seen = new Set();

  function scan(root) {
    var cl = [], id = [];
    var els = [];
    if (root && root.nodeType === 1) els.push(root);
    if (root && root.querySelectorAll) {
      var a = root.querySelectorAll('[id],[class]');
      for (var i = 0; i < a.length; i++) els.push(a[i]);
    }
    for (var i = 0; i < els.length; i++) {
      var e = els[i];
      if (e.id && !seen.has('i' + e.id)) { id.push(e.id); seen.add('i' + e.id); }
      if (e.classList) {
        for (var j = 0; j < e.classList.length; j++) {
          var c = e.classList[j];
          if (!seen.has('c' + c)) { cl.push(c); seen.add('c' + c); }
        }
      }
    }
    return [cl, id];
  }

  function flush(cl, id) {
    if (!cl.length && !id.length) return;
    var css = __axiumHiddenSelectors(JSON.stringify(cl), JSON.stringify(id), exceptions);
    if (css) style.textContent += css;
  }

  // Initial scan
  var initial = scan(document.documentElement);
  flush(initial[0], initial[1]);

  // Observe mutations
  new MutationObserver(function(ms) {
    var cl = [], id = [];
    for (var i = 0; i < ms.length; i++) {
      var m = ms[i];
      if (m.addedNodes) {
        for (var j = 0; j < m.addedNodes.length; j++) {
          var r = scan(m.addedNodes[j]);
          cl = cl.concat(r[0]);
          id = id.concat(r[1]);
        }
      }
      if (m.type === 'attributes' && m.target.nodeType === 1) {
        var r = scan(m.target);
        cl = cl.concat(r[0]);
        id = id.concat(r[1]);
      }
    }
    if (cl.length || id.length) flush(cl, id);
  }).observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['class', 'id']
  });
})();

// ---------------------------------------------------------------------------
// Procedural cosmetic filter engine
// ---------------------------------------------------------------------------
// Handles selector types: css-selector, has-text, matches-css/-before/-after,
//   upward, xpath, min-text-length, matches-attr, matches-path
// Actions: null (hide via attribute), remove, style, remove-attr, remove-class
//
// Performance features (inspired by uBlock Origin):
//   - rAF coalescing: mutations are batched, work runs at most once per frame
//   - Per-filter budget: each filter gets 200ms; overspend disables it
//   - Attribute-based hiding: reversible, un-hides elements that stop matching

function __axiumRunProcedural(filters) {
  if (typeof filters === 'string') {
    try { filters = JSON.parse(filters); } catch(e) { return; }
  }

  // -- Attribute-based hide system --
  // Generate a unique token for this page load to avoid collisions.
  var hideToken = '_axh_' + Math.random().toString(36).substring(2, 8);
  var hideStyle = document.createElement('style');
  hideStyle.textContent = '[' + hideToken + ']{display:none!important}';
  (document.head || document.documentElement).appendChild(hideStyle);

  // Track currently styled nodes so we can un-hide on re-evaluation.
  var styledNodes = new Set();

  // -- Per-filter budget --
  // Each filter gets a budget of 200ms. Execution time is deducted.
  // Budget regenerates at +50ms per 2 seconds, capped at 200ms.
  // If budget drops below -500ms, filter is permanently disabled.
  var budgets = [];
  var lastAllowance = [];
  for (var i = 0; i < filters.length; i++) {
    budgets[i] = 200;
    lastAllowance[i] = Date.now();
  }

  function applyFilter(f) {
    var els = null;
    for (var i = 0; i < f.selector.length; i++) {
      var step = f.selector[i], t = step.type, a = step.arg;
      if (t === 'css-selector') {
        if (els === null) {
          els = Array.from(document.querySelectorAll(a));
        } else {
          var next = [];
          for (var j = 0; j < els.length; j++) {
            var sub = els[j].querySelectorAll(a);
            for (var k = 0; k < sub.length; k++) next.push(sub[k]);
          }
          els = next;
        }
      } else if (t === 'has-text') {
        if (els === null) els = Array.from(document.querySelectorAll('*'));
        var re;
        try {
          if (a.charAt(0) === '/' && a.lastIndexOf('/') > 0) {
            var li = a.lastIndexOf('/');
            re = new RegExp(a.substring(1, li), a.substring(li + 1));
          } else { re = new RegExp(a); }
        } catch(e) { return; }
        els = els.filter(function(el) { return re.test(el.textContent); });
      } else if (t === 'matches-css' || t === 'matches-css-before' || t === 'matches-css-after') {
        if (els === null) els = Array.from(document.querySelectorAll('*'));
        var pseudo = t === 'matches-css-before' ? '::before' : t === 'matches-css-after' ? '::after' : null;
        var ci = a.indexOf(':');
        if (ci < 0) continue;
        var prop = a.substring(0, ci).trim(), valPat = a.substring(ci + 1).trim();
        var valRe;
        try {
          if (valPat.charAt(0) === '/' && valPat.lastIndexOf('/') > 0) {
            var vli = valPat.lastIndexOf('/');
            valRe = new RegExp(valPat.substring(1, vli), valPat.substring(vli + 1));
          } else { valRe = new RegExp(valPat); }
        } catch(e) { return; }
        els = els.filter(function(el) {
          var cs = getComputedStyle(el, pseudo);
          return valRe.test(cs.getPropertyValue(prop));
        });
      } else if (t === 'upward') {
        if (els === null) els = [];
        var n = parseInt(a, 10);
        if (!isNaN(n) && n > 0) {
          els = els.map(function(el) {
            for (var u = 0; u < n && el; u++) el = el.parentElement;
            return el;
          }).filter(Boolean);
        } else {
          els = els.map(function(el) { return el.closest(a); }).filter(Boolean);
        }
      } else if (t === 'xpath') {
        if (els === null) {
          var xr = document.evaluate(a, document, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
          els = []; for (var xi = 0; xi < xr.snapshotLength; xi++) {
            var xn = xr.snapshotItem(xi);
            if (xn.nodeType === 1) els.push(xn);
          }
        } else {
          var next = [];
          for (var j = 0; j < els.length; j++) {
            var xr = document.evaluate(a, els[j], null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
            for (var xi = 0; xi < xr.snapshotLength; xi++) {
              var xn = xr.snapshotItem(xi);
              if (xn.nodeType === 1) next.push(xn);
            }
          }
          els = next;
        }
      } else if (t === 'min-text-length') {
        if (els === null) els = Array.from(document.querySelectorAll('*'));
        var minLen = parseInt(a, 10) || 0;
        els = els.filter(function(el) { return el.textContent.length >= minLen; });
      } else if (t === 'matches-attr') {
        if (els === null) els = Array.from(document.querySelectorAll('*'));
        var eqi = a.indexOf('=');
        var attrPat, valPat2;
        if (eqi >= 0) { attrPat = a.substring(0, eqi); valPat2 = a.substring(eqi + 1); }
        else { attrPat = a; valPat2 = ''; }
        function mkRe(s) {
          s = s.replace(/^"/, '').replace(/"$/, '');
          if (s.charAt(0) === '/' && s.lastIndexOf('/') > 0) {
            var li = s.lastIndexOf('/'); return new RegExp(s.substring(1, li), s.substring(li + 1));
          }
          return new RegExp('^' + s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\\\*/g, '.*') + '$');
        }
        try { var attrRe = mkRe(attrPat), valRe2 = mkRe(valPat2); } catch(e) { return; }
        els = els.filter(function(el) {
          for (var ai = 0; ai < el.attributes.length; ai++) {
            var at = el.attributes[ai];
            if (attrRe.test(at.name) && valRe2.test(at.value)) return true;
          } return false;
        });
      } else if (t === 'matches-path') {
        try {
          var pathRe = new RegExp(a);
          if (!pathRe.test(location.pathname + location.search)) return;
        } catch(e) { return; }
      }
    }
    return els && els.length ? els : null;
  }

  function processNodes(els, action) {
    if (!action) {
      // Default: attribute-based hide
      for (var i = 0; i < els.length; i++) {
        els[i].setAttribute(hideToken, '');
        styledNodes.add(els[i]);
      }
    } else if (action.type === 'remove') {
      for (var i = 0; i < els.length; i++) {
        els[i].remove();
      }
    } else if (action.type === 'style') {
      var pairs = action.arg.split(';');
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        for (var p = 0; p < pairs.length; p++) {
          var kv = pairs[p].split(':');
          if (kv.length >= 2) {
            var k = kv[0].trim(), v = kv.slice(1).join(':').trim();
            var imp = v.indexOf('!important') >= 0;
            if (imp) v = v.replace('!important', '').trim();
            el.style.setProperty(k, v, imp ? 'important' : '');
          }
        }
        styledNodes.add(el);
      }
    } else if (action.type === 'remove-attr') {
      for (var i = 0; i < els.length; i++) {
        els[i].removeAttribute(action.arg);
      }
    } else if (action.type === 'remove-class') {
      for (var i = 0; i < els.length; i++) {
        els[i].classList.remove(action.arg);
      }
    }
  }

  function run() {
    // Swap styled nodes — after this cycle, nodes no longer matched get un-hidden.
    var prevStyled = styledNodes;
    styledNodes = new Set();

    var t0 = Date.now();
    for (var i = 0; i < filters.length; i++) {
      // Budget regeneration: +50ms per 2 seconds elapsed, capped at 200.
      var allowance = Math.floor((t0 - lastAllowance[i]) / 2000);
      if (allowance >= 1) {
        budgets[i] += allowance * 50;
        if (budgets[i] > 200) budgets[i] = 200;
        lastAllowance[i] = t0;
      }
      // Skip permanently disabled filters.
      if (budgets[i] <= -500) continue;

      try {
        var els = applyFilter(filters[i]);
        var t1 = Date.now();
        budgets[i] += t0 - t1; // deduct elapsed time (negative delta)
        t0 = t1;
        if (budgets[i] <= -500) continue; // just got disabled
        if (els) processNodes(els, filters[i].action);
      } catch(e) {}
    }

    // Un-hide nodes that were styled last cycle but not this cycle.
    for (var node of prevStyled) {
      if (!styledNodes.has(node)) {
        node.removeAttribute(hideToken);
      }
    }
  }

  // -- rAF coalescing --
  // Mutations are collected; actual work runs at most once per animation frame.
  var rafPending = false;
  function scheduleRun() {
    if (!rafPending) {
      rafPending = true;
      requestAnimationFrame(function() {
        rafPending = false;
        run();
      });
    }
  }

  // Initial run (synchronous, before observer starts).
  run();

  // Observe DOM changes, coalesce via rAF.
  new MutationObserver(function() { scheduleRun(); }).observe(
    document.documentElement, { childList: true, subtree: true }
  );
}
