(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];

  /* Arrow keys move between the buttons of a tablist or radiogroup, and select. */
  const roving = (items, select) => items.forEach((b) => b.addEventListener("keydown", (e) => {
    const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[e.key];
    if (!step) return;
    e.preventDefault();
    const next = items[(items.indexOf(b) + step + items.length) % items.length];
    next.focus();
    select(next);
  }));
  const choose = (items, picked) => items.forEach((b) => {
    const attr = b.getAttribute("role") === "radio" ? "aria-checked" : "aria-selected";
    b.setAttribute(attr, String(b === picked));
    b.tabIndex = b === picked ? 0 : -1;
  });
  const group = (items, onPick) => {
    const pick = (b) => { choose(items, b); onPick(b); };
    items.forEach((b) => b.addEventListener("click", () => pick(b)));
    roving(items, pick);
  };

  /* Tiles whose buttons swap the screenshot: [data-show] buttons, [data-view] images. */
  $$("[data-swap]").forEach((tile) => {
    const imgs = $$(".swapshot > img", tile);
    group($$("[data-show]", tile), (b) => imgs.forEach((i) => i.classList.toggle("is-on", i.dataset.view === b.dataset.show)));
  });

  /* Profiles: the sheet follows the selected tab. */
  const prof = $(".prof");
  if (prof) group($$("[data-profile-set]", prof), (b) => { prof.dataset.profile = b.dataset.profileSet; });

  /* Hero callouts: a dot on each spot, a leader up (or down) to its lane, across, then to the label. */
  const hero = $(".hero__shot");
  if (hero) {
    const ns = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(ns, "svg");
    svg.setAttribute("class", "leaders");
    svg.setAttribute("viewBox", "0 0 100 100");
    svg.setAttribute("preserveAspectRatio", "none");
    svg.setAttribute("aria-hidden", "true");
    /* Neighbours get different lane colours, so each leader is easy to follow. */
    const colors = [1, 2, 7, 4, 5, 6, 3].map((n) => `var(--lane-${n})`);
    const items = $$(".callouts > li", hero).map((li, i) => {
      li.style.setProperty("--cc", colors[i % colors.length]);
      const dot = document.createElement("i");
      dot.style.setProperty("--cc", colors[i % colors.length]);
      dot.className = "cdot";
      dot.style.left = `${li.dataset.x}%`;
      dot.style.top = `${li.dataset.y}%`;
      hero.append(dot);
      return li;
    });
    /* Lanes are px above (or below) the window; the label end is measured, so it follows the font and width. */
    const draw = () => {
      const f = hero.getBoundingClientRect();
      if (!f.width || !f.height) return;
      svg.replaceChildren();
      items.forEach((li) => {
        const r = li.getBoundingClientRect();
        if (!r.width) return;
        const top = li.dataset.side === "top";
        const py = (v) => (v / f.height) * 100;
        const lane = top ? -py(+li.dataset.lane) : 100 + py(+li.dataset.lane);
        const lx = ((r.left + r.width / 2 - f.left) / f.width) * 100;
        const end = py((top ? r.bottom : r.top) - f.top);
        const d = `M${li.dataset.x} ${li.dataset.y} V${lane} H${lx} V${end}`;
        ["halo", "ink"].forEach((cls) => {
          const path = document.createElementNS(ns, "path");
          path.setAttribute("class", cls);
          path.setAttribute("d", d);
          if (cls === "ink") path.style.stroke = li.style.getPropertyValue("--cc");
          svg.append(path);
        });
      });
    };
    new ResizeObserver(draw).observe(hero);
    document.fonts && document.fonts.ready.then(draw);
    hero.append(svg);
  }

  /* Layouts: the panes of the diagram rearrange, then the real window crossfades in. */
  const lay = $(".lay");
  if (lay) {
    const schema = $(".schema", lay);
    const panes = $$(".pane", schema);
    const imgs = $$(".swapshot img", lay);
    const cap = $(".lay__cap", lay);
    const caps = {
      classic: "Sidebar, graph and details; a file opens over the graph.",
      stacked: "The diff opens under the graph, so the graph stays in view.",
      columns: "The diff takes a fourth column beside the commit details.",
      focus: "⌥⌘F hides the side panels and gives the graph the window.",
      term: "⌃` opens a shell in the repository, signed as the tab’s profile.",
    };
    const sizes = { tabs: "2rem", side: "0.9fr", graph: "2fr", detail: "1fr", diff: "1.2fr" };
    const grid = ({ layout, tabs, term }) => {
      const cols = [];
      if (tabs === "side") cols.push("tabs");
      if (layout !== "focus") cols.push("side");
      cols.push("graph");
      if (layout !== "focus") cols.push("detail");
      if (layout === "columns") cols.push("diff");
      const main = cols.filter((c) => c !== "tabs" && c !== "side");
      const rows = [], heights = [];
      if (tabs === "top") { rows.push(cols.map(() => "tabs")); heights.push("1.75rem"); }
      rows.push(cols); heights.push("minmax(0, 1fr)");
      if (layout === "stacked") { rows.push(cols.map((c) => (c === "graph" ? "diff" : c))); heights.push("minmax(0, 0.8fr)"); }
      if (term) { rows.push(cols.map((c) => (main.includes(c) ? "term" : c))); heights.push("minmax(0, 0.7fr)"); }
      return {
        areas: rows.map((r) => `"${r.join(" ")}"`).join(" "),
        columns: cols.map((c) => sizes[c]).join(" "),
        rows: heights.join(" "),
        used: new Set(rows.flat()),
      };
    };
    const showShot = (src, alt) => {
      const [on, off] = imgs[0].classList.contains("is-on") ? imgs : [imgs[1], imgs[0]];
      if (on.getAttribute("src") === src) return;
      off.onload = () => { off.alt = alt; on.alt = ""; off.classList.add("is-on"); on.classList.remove("is-on"); };
      off.loading = "eager";
      off.src = src;
      if (off.complete && off.naturalWidth) off.onload();
    };
    const render = (animate) => {
      const st = { layout: lay.dataset.layout, tabs: lay.dataset.tabs, term: lay.dataset.term === "on" };
      const g = grid(st);
      schema.style.gridTemplateAreas = g.areas;
      schema.style.gridTemplateColumns = g.columns;
      schema.style.gridTemplateRows = g.rows;
      panes.forEach((p) => {
        const on = g.used.has(p.className.match(/p-(\w+)/)[1]);
        const wasOn = getComputedStyle(p).display !== "none";
        p.classList.toggle("is-off", !on);
        p.classList.toggle("is-shown", on);
        p.classList.remove("is-entering");
        if (animate && on && !wasOn) { void p.offsetWidth; p.classList.add("is-entering"); }
      });
      cap.textContent = st.term ? caps.term : caps[st.layout];
      const name = st.layout[0].toUpperCase() + st.layout.slice(1);
      if (st.term) showShot("shots/terminal.webp", "Histq’s terminal open under the commit graph, running git log --graph");
      else showShot(`shots/layout-${st.layout}-${st.tabs === "side" ? "left" : "top"}.webp`, `Histq in the ${name} layout with tabs ${st.tabs === "side" ? "down the side" : "on top"}`);
    };
    group($$("[data-lay]", lay), (b) => { lay.dataset.layout = b.dataset.lay; render(true); });
    group($$("[data-tabs-set]", lay), (b) => { lay.dataset.tabs = b.dataset.tabsSet; render(true); });
    const term = $("[data-term-toggle]", lay);
    term.addEventListener("click", () => {
      const on = lay.dataset.term !== "on";
      lay.dataset.term = on ? "on" : "off";
      term.setAttribute("aria-pressed", String(on));
      render(true);
    });
    render(false);
  }

  /* Lightbox: any product capture opens large. */
  const box = $(".lightbox");
  if (box && box.showModal) {
    const bcap = $("figcaption", box);
    const bimg = document.createElement("img");
    const scroller = document.createElement("div");
    scroller.className = "lightbox__scroll";
    scroller.append(bimg);
    bcap.before(scroller);
    const visibleImg = (fig) => $("img.is-on", fig) || $("img", fig);
    const open = (fig) => {
      const src = visibleImg(fig);
      bimg.src = src.currentSrc || src.src;
      bimg.alt = src.alt;
      bcap.textContent = src.alt;
      box.showModal();
    };
    $(".lightbox__close", box).addEventListener("click", () => box.close());
    box.addEventListener("click", (e) => {
      if ([box, bimg, scroller].includes(e.target) || e.target.classList.contains("lightbox__fig")) box.close();
    });
    $$(".shot").forEach((fig) => {
      const label = () => `Enlarge screenshot: ${visibleImg(fig).alt}`;
      fig.classList.add("zoomable");
      fig.tabIndex = 0;
      fig.setAttribute("role", "button");
      fig.setAttribute("aria-label", label());
      fig.addEventListener("focus", () => fig.setAttribute("aria-label", label()));
      fig.addEventListener("click", () => open(fig));
      fig.addEventListener("keydown", (e) => {
        if (e.target !== fig || !["Enter", " "].includes(e.key)) return;
        e.preventDefault();
        open(fig);
      });
    });
  }
})();
