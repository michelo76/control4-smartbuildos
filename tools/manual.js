/* The interactive manual. Builds its chrome around the plain document that
   tools/docs.py renders: a contents list that follows the page, a search that
   narrows the sections, walkthroughs that keep their place, screenshots that
   enlarge, and copy buttons on code. Nothing here is needed to READ the
   manual: if this script does not run, the document is whole as it is. */
(function () {
  "use strict";
  var body = document.querySelector(".markdown-body");
  if (!body || !document.createElement("div").classList) return;

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }
  /* Storage can be missing or refuse (a private window, a locked viewer). */
  var store = {
    get: function (k) { try { return window.localStorage.getItem(k); } catch (e) { return null; } },
    set: function (k, v) { try { window.localStorage.setItem(k, v); } catch (e) {} }
  };
  var h1 = body.querySelector("h1");
  var docTitle = (h1 && h1.textContent.trim()) || document.title || "Manual";
  var docKey = "sbos-manual:" + docTitle.toLowerCase().replace(/[^a-z0-9]+/g, "-") + ":";

  /* ── sections: everything from one h2 to the next ──────────────────────── */
  var sections = [];
  var current = null;
  Array.prototype.slice.call(body.childNodes).forEach(function (node) {
    if (node.nodeType === 1 && node.tagName === "H2") {
      current = el("section", "m-section");
      body.insertBefore(current, node);
      sections.push(current);
    }
    if (current) current.appendChild(node);
  });

  /* ── top bar and contents ──────────────────────────────────────────────── */
  var bar = el("header", "m-bar");
  var tocBtn = el("button", "m-btn m-toc-btn", "Contents");
  tocBtn.type = "button";
  tocBtn.setAttribute("aria-expanded", "false");
  var search = el("input");
  search.type = "search";
  search.placeholder = "Search this manual";
  search.setAttribute("aria-label", "Search this manual");
  var progress = el("i", "m-progress");
  bar.appendChild(tocBtn);
  bar.appendChild(el("div", "m-title", docTitle));
  bar.appendChild(search);
  bar.appendChild(progress);

  var toc = el("nav", "m-toc");
  toc.setAttribute("aria-label", "Contents");
  var list = el("ol");
  toc.appendChild(list);
  var links = [];
  sections.forEach(function (section, i) {
    var heads = section.querySelectorAll("h2, h3");
    Array.prototype.forEach.call(heads, function (h) {
      if (!h.id) h.id = "s" + i + "-" + links.length;
      var a = el("a", h.tagName === "H3" ? "sub" : "", h.textContent.trim());
      a.href = "#" + h.id;
      var li = el("li");
      li.appendChild(a);
      list.appendChild(li);
      links.push({ a: a, li: li, h: h, section: section });
    });
  });
  tocBtn.addEventListener("click", function () {
    var open = toc.classList.toggle("open");
    tocBtn.setAttribute("aria-expanded", open ? "true" : "false");
  });
  list.addEventListener("click", function (e) {
    if (e.target.tagName === "A") {
      toc.classList.remove("open");
      tocBtn.setAttribute("aria-expanded", "false");
    }
  });

  var shell = el("div", "m-shell");
  body.parentNode.insertBefore(bar, body);
  body.parentNode.insertBefore(shell, body);
  shell.appendChild(toc);
  shell.appendChild(body);
  document.documentElement.classList.add("manual-on");

  /* ── where you are: the contents follow the page ───────────────────────── */
  var topBtn = el("button", "m-btn m-top", "Top");
  topBtn.type = "button";
  topBtn.addEventListener("click", function () { window.scrollTo(0, 0); });
  document.body.appendChild(topBtn);
  var ticking = false;
  function spy() {
    ticking = false;
    var y = window.pageYOffset || document.documentElement.scrollTop || 0;
    var max = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
    progress.style.width = Math.min(100, (y / max) * 100) + "%";
    topBtn.classList.toggle("show", y > 600);
    var here = null;
    for (var i = 0; i < links.length; i++) {
      if (links[i].h.getBoundingClientRect().top <= 90) here = links[i];
    }
    links.forEach(function (l) { l.a.classList.toggle("here", l === here); });
  }
  window.addEventListener("scroll", function () {
    if (!ticking) { ticking = true; (window.requestAnimationFrame || setTimeout)(spy); }
  });
  spy();

  /* ── search: narrow the page to the sections that mention the words ────── */
  var none = el("p", "m-none", "Nothing in this manual matches. Try fewer or other words.");
  none.hidden = true;
  body.appendChild(none);
  search.addEventListener("input", function () {
    var words = search.value.toLowerCase().split(/\s+/).filter(Boolean);
    var shown = 0;
    sections.forEach(function (section) {
      var text = section.textContent.toLowerCase();
      var hit = words.every(function (w) { return text.indexOf(w) !== -1; });
      section.classList.toggle("gone", !hit);
      if (hit) shown++;
    });
    links.forEach(function (l) { l.li.classList.toggle("gone", l.section.classList.contains("gone")); });
    none.hidden = shown > 0 || sections.length === 0;
  });

  /* ── walkthroughs: steps you tick, kept for next time ──────────────────── */
  Array.prototype.forEach.call(body.querySelectorAll("ol.walkthrough"), function (ol, index) {
    var title = ol.getAttribute("data-title") || "Walkthrough";
    var key = docKey + "walk:" + index + ":" + title.toLowerCase().replace(/[^a-z0-9]+/g, "-");
    var steps = Array.prototype.filter.call(ol.children, function (c) { return c.tagName === "LI"; });
    var done = {};
    try { done = JSON.parse(store.get(key) || "{}") || {}; } catch (e) { done = {}; }

    var wrap = el("div", "m-walk");
    var head = el("div", "m-walk-head");
    var count = el("span", "m-walk-count");
    head.appendChild(el("span", "m-walk-title", title));
    head.appendChild(count);
    var meter = el("div", "m-walk-meter");
    var fill = el("i");
    meter.appendChild(fill);
    var foot = el("div", "m-walk-foot");
    var note = el("span");
    var reset = el("button", "m-link", "Start over");
    reset.type = "button";
    foot.appendChild(note);
    foot.appendChild(reset);
    ol.parentNode.insertBefore(wrap, ol);
    wrap.appendChild(head);
    wrap.appendChild(meter);
    wrap.appendChild(ol);
    wrap.appendChild(foot);

    function paint() {
      var n = 0, next = -1;
      steps.forEach(function (li, i) {
        var isDone = done[i] === true;
        if (isDone) n++; else if (next < 0) next = i;
        li.classList.toggle("m-done", isDone);
        li.classList.toggle("m-current", i === next);
        var b = li.querySelector(".m-step-check");
        b.setAttribute("aria-pressed", isDone ? "true" : "false");
        b.setAttribute("aria-label", "Step " + (i + 1) + (isDone ? ": done. Mark as not done" : ": mark as done"));
      });
      count.textContent = n + " of " + steps.length + " done";
      fill.style.width = (steps.length ? (n / steps.length) * 100 : 0) + "%";
      note.textContent = n === steps.length ? "All steps done." : "Tick each step as you finish it. Your place is kept on this computer.";
      reset.hidden = n === 0;
    }
    steps.forEach(function (li, i) {
      var b = el("button", "m-step-check");
      b.type = "button";
      b.addEventListener("click", function () {
        if (done[i]) delete done[i]; else done[i] = true;
        store.set(key, JSON.stringify(done));
        paint();
      });
      li.insertBefore(b, li.firstChild);
    });
    reset.addEventListener("click", function () { done = {}; store.set(key, "{}"); paint(); });
    paint();
  });

  /* ── screenshots enlarge ───────────────────────────────────────────────── */
  var zoom = null;
  function closeZoom() { if (zoom) { zoom.parentNode.removeChild(zoom); zoom = null; } }
  body.addEventListener("click", function (e) {
    var img = e.target;
    if (img.tagName !== "IMG" || !img.parentNode || !img.parentNode.classList.contains("shot")) return;
    zoom = el("div", "m-zoom");
    zoom.setAttribute("role", "dialog");
    zoom.setAttribute("aria-label", img.alt || "Screenshot");
    var big = el("img");
    big.src = img.src;
    big.alt = img.alt;
    zoom.appendChild(big);
    zoom.addEventListener("click", closeZoom);
    document.body.appendChild(zoom);
  });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" || e.keyCode === 27) closeZoom();
  });

  /* ── copy buttons on code blocks ───────────────────────────────────────── */
  Array.prototype.forEach.call(body.querySelectorAll("pre"), function (pre) {
    var holder = pre.parentNode.classList.contains("highlight") ? pre.parentNode : pre;
    var wrap = el("div", "m-copy-wrap");
    holder.parentNode.insertBefore(wrap, holder);
    wrap.appendChild(holder);
    var b = el("button", "m-btn m-copy", "Copy");
    b.type = "button";
    b.addEventListener("click", function () {
      var text = pre.textContent.replace(/\n$/, "");
      function said(ok) { b.textContent = ok ? "Copied" : "Select and copy"; setTimeout(function () { b.textContent = "Copy"; }, 1500); }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () { said(true); }, function () { said(false); });
      } else {
        var range = document.createRange();
        range.selectNodeContents(pre);
        var sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
        var ok = false;
        try { ok = document.execCommand("copy"); } catch (err) {}
        said(ok);
      }
    });
    wrap.appendChild(b);
  });
})();
