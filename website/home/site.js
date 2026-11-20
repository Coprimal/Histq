(() => {
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];

  /* FLIP: measure, change, then glide each element from where it was. */
  const flip = (els, change, { scale = false } = {}) => {
    const before = new Map(els.map((el) => [el, el.getBoundingClientRect()]));
    change();
    if (reduce) return;
    els.forEach((el) => {
      const a = before.get(el);
      const b = el.getBoundingClientRect();
      if (!a.width || !b.width) return;
      const dx = a.left - b.left, dy = a.top - b.top;
      const sx = scale ? a.width / b.width : 1, sy = scale ? a.height / b.height : 1;
      if (!dx && !dy && sx === 1 && sy === 1) return;
      el.animate(
        [{ transform: `translate(${dx}px, ${dy}px) scale(${sx}, ${sy})` }, { transform: "none" }],
        { duration: 420, easing: "cubic-bezier(0.16, 1, 0.3, 1)" }
      );
    });
  };

  /* Arrow keys move between the buttons of a tablist or radiogroup. */
  const roving = (group, items, select) => {
    group.addEventListener("keydown", (e) => {
      const keys = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 };
      if (!(e.key in keys)) return;
      const i = items.indexOf(document.activeElement);
      if (i < 0) return;
      e.preventDefault();
      const next = items[(i + keys[e.key] + items.length) % items.length];
      next.focus();
      select(next);
    });
  };
  const choose = (items, picked, attr) => items.forEach((b) => {
    b.setAttribute(attr, String(b === picked));
    if (attr === "aria-selected") b.tabIndex = b === picked ? 0 : -1;
  });

  /* Hero: raw git log --graph untangles into drawn lanes, and back. */
  const hero = $(".hero");
  if (hero) {
    const radios = $$("[data-mode-set]", hero);
    const setMode = (mode) => {
      hero.dataset.mode = mode;
      radios.forEach((r) => r.setAttribute("aria-checked", String(r.dataset.modeSet === mode)));
    };
    radios.forEach((r) => r.addEventListener("click", () => setMode(r.dataset.modeSet)));
    roving($(".seg", hero), radios, (r) => setMode(r.dataset.modeSet));
    if (!reduce) {
      setMode("ascii");
      setTimeout(() => setMode("drawn"), 1100);
    }
  }

  /* One reveal: callouts settle in once. */
  const io = new IntersectionObserver(
    (es) => es.forEach((e) => {
      if (e.isIntersecting) { e.target.classList.add("is-in"); io.unobserve(e.target); }
    }),
    { rootMargin: "0px 0px -15% 0px" }
  );
  $$(".shot--callouts").forEach((el) => io.observe(el));

  /* Stage: a line glides from the working tree to the index. */
  const stage = $(".stage");
  if (stage) {
    const lists = { unstaged: $('[data-list="unstaged"]', stage), staged: $('[data-list="staged"]', stage) };
    const lines = $$(".hl", stage);
    const count = () => {
      $('[data-count="unstaged"]', stage).textContent = lists.unstaged.children.length;
      $('[data-count="staged"]', stage).textContent = lists.staged.children.length;
    };
    const place = (li, to) => {
      const list = lists[to];
      const after = [...list.children].find((x) => +x.dataset.i > +li.dataset.i);
      list.insertBefore(li, after || null);
      const btn = $("button", li);
      btn.setAttribute("aria-pressed", String(to === "staged"));
      btn.setAttribute("aria-label", `${to === "staged" ? "Unstage" : "Stage"} line: ${$("code", li).textContent.trim()}`);
    };
    lines.forEach((li) => {
      place(li, li.parentElement === lists.staged ? "staged" : "unstaged");
      $("button", li).addEventListener("click", () => {
        const to = li.parentElement === lists.staged ? "unstaged" : "staged";
        flip(lines, () => place(li, to));
        count();
        $("button", li).focus({ preventScroll: true });
      });
    });
    $$("[data-stage]", stage).forEach((b) => b.addEventListener("click", () => {
      const to = b.dataset.stage === "all" ? "staged" : "unstaged";
      flip(lines, () => lines.forEach((li) => place(li, to)));
      count();
    }));
  }

  /* A loop that can pause: runs only on screen, pauses on hover and focus. */
  $$("[data-loop]").forEach((el) => {
    const btn = $("[data-loop-toggle]", el);
    const s = { seen: false, hover: false, focus: false, held: reduce };
    const sync = () => {
      el.classList.toggle("is-running", s.seen && !s.hover && !s.focus && !s.held);
      btn.textContent = s.held ? "Play" : "Pause";
    };
    btn.addEventListener("click", () => { s.held = !s.held; sync(); });
    [["pointerenter", "hover", true], ["pointerleave", "hover", false], ["focusin", "focus", true], ["focusout", "focus", false]]
      .forEach(([t, k, v]) => el.addEventListener(t, () => { s[k] = v; sync(); }));
    new IntersectionObserver(([e]) => { s.seen = e.isIntersecting; sync(); }).observe(el);
  });

  /* Profiles: switch the tab's profile, and the push goes out as the other account. */
  const prof = $(".prof");
  if (prof) {
    const tabs = $$("[data-profile-set]", prof);
    const line = $(".route__line", prof);
    const set = (t) => {
      if (prof.dataset.profile === t.dataset.profileSet) return;
      choose(tabs, t, "aria-selected");
      prof.dataset.profile = t.dataset.profileSet;
      prof.style.setProperty("--route-w", `${line.getBoundingClientRect().width}px`);
      prof.classList.remove("is-pushing");
      void prof.offsetWidth;
      prof.classList.add("is-pushing");
    };
    tabs.forEach((t) => t.addEventListener("click", () => set(t)));
    roving($('[role="tablist"]', prof), tabs, set);
  }

  /* Pull requests: Conversation or Files changed. */
  const pr = $(".pr__view");
  if (pr) {
    const tabs = $$("[data-pr-set]", pr);
    const shot = $(".swapshot", pr);
    const set = (t) => { choose(tabs, t, "aria-selected"); shot.dataset.show = t.dataset.prSet; };
    tabs.forEach((t) => t.addEventListener("click", () => set(t)));
    roving($('[role="tablist"]', pr), tabs, set);
  }

  /* Layouts: the panes rearrange, then the real window crossfades in. */
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
      const rows = [];
      const sizesRows = [];
      if (tabs === "top") { rows.push(cols.map(() => "tabs")); sizesRows.push("1.75rem"); }
      const body = cols.map((c) => c);
      rows.push(body); sizesRows.push("minmax(0, 1fr)");
      if (layout === "stacked") { rows.push(cols.map((c) => (c === "graph" ? "diff" : c))); sizesRows.push("minmax(0, 0.8fr)"); }
      if (term) { rows.push(cols.map((c) => (main.includes(c) ? "term" : c))); sizesRows.push("minmax(0, 0.7fr)"); }
      const used = new Set(rows.flat());
      return {
        areas: rows.map((r) => `"${r.join(" ")}"`).join(" "),
        columns: cols.map((c) => (c === "tabs" ? "2rem" : sizes[c])).join(" "),
        rows: sizesRows.join(" "),
        used,
      };
    };

    let swapTimer;
    const showShot = (src, alt) => {
      const [on, off] = imgs[0].classList.contains("is-on") ? imgs : [imgs[1], imgs[0]];
      if (on.getAttribute("src") === src) return;
      clearTimeout(swapTimer);
      off.onload = () => {
        off.alt = alt; on.alt = "";
        off.classList.add("is-on"); on.classList.remove("is-on");
      };
      off.loading = "eager";
      off.src = src;
      if (off.complete && off.naturalWidth) off.onload();
    };

    const render = (animate) => {
      const st = { layout: lay.dataset.layout, tabs: lay.dataset.tabs, term: lay.dataset.term === "on" };
      const g = grid(st);
      const visible = panes.filter((p) => getComputedStyle(p).display !== "none");
      const change = () => {
        schema.style.gridTemplateAreas = g.areas;
        schema.style.gridTemplateColumns = g.columns;
        schema.style.gridTemplateRows = g.rows;
        panes.forEach((p) => {
          const name = p.className.match(/p-(\w+)/)[1];
          const on = g.used.has(name);
          p.classList.toggle("is-off", !on);
          p.classList.toggle("is-shown", on);
          p.classList.remove("is-entering");
          if (animate && on && !visible.includes(p) && !reduce) { void p.offsetWidth; p.classList.add("is-entering"); }
        });
      };
      if (animate) flip(visible, change, { scale: true }); else change();
      cap.textContent = st.term ? caps.term : caps[st.layout];
      const name = st.layout[0].toUpperCase() + st.layout.slice(1);
      if (st.term) showShot("shots/terminal.webp", "Histq’s terminal open under the commit graph, running git log --graph");
      else showShot(`shots/layout-${st.layout}-${st.tabs === "side" ? "left" : "top"}.webp`, `Histq in the ${name} layout with tabs ${st.tabs === "side" ? "down the side" : "on top"}`);
    };

    const layBtns = $$("[data-lay]", lay);
    const tabBtns = $$("[data-tabs-set]", lay);
    const termBtn = $("[data-term-toggle]", lay);
    layBtns.forEach((b) => b.addEventListener("click", () => { choose(layBtns, b, "aria-checked"); lay.dataset.layout = b.dataset.lay; render(true); }));
    tabBtns.forEach((b) => b.addEventListener("click", () => { choose(tabBtns, b, "aria-checked"); lay.dataset.tabs = b.dataset.tabsSet; render(true); }));
    roving(layBtns[0].parentElement, layBtns, (b) => b.click());
    roving(tabBtns[0].parentElement, tabBtns, (b) => b.click());
    termBtn.addEventListener("click", () => {
      const on = lay.dataset.term !== "on";
      lay.dataset.term = on ? "on" : "off";
      termBtn.setAttribute("aria-pressed", String(on));
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
    const visibleImg = (fig) => {
      const imgs = $$("img", fig);
      const op = (i) => (i.classList.contains("is-on") || i.dataset.view === fig.dataset.show ? 2 : parseFloat(getComputedStyle(i).opacity));
      return imgs.reduce((best, i) => (op(i) > op(best) ? i : best), imgs[0]);
    };
    const open = (fig) => {
      const src = visibleImg(fig);
      if (!src) return;
      bimg.src = src.currentSrc || src.src;
      bimg.alt = src.alt;
      bcap.textContent = src.alt;
      box.showModal();
    };
    const close = () => box.close();
    $(".lightbox__close", box).addEventListener("click", close);
    box.addEventListener("click", (e) => {
      if (e.target === box || e.target === bimg || e.target === scroller || e.target.classList.contains("lightbox__fig")) close();
    });
    const label = (fig) => `Enlarge screenshot: ${(visibleImg(fig) || {}).alt || "Histq"}`;
    $$(".shot, .stream, .card").forEach((fig) => {
      fig.classList.add("zoomable");
      fig.tabIndex = 0;
      fig.setAttribute("role", "button");
      fig.setAttribute("aria-label", label(fig));
      fig.addEventListener("focus", () => fig.setAttribute("aria-label", label(fig)));
      const isBackCard = () => fig.classList.contains("card") && getComputedStyle(fig).getPropertyValue("--d").trim() !== "0";
      fig.addEventListener("click", (e) => {
        if (e.target.closest("button") || isBackCard()) return;
        open(fig);
      });
      fig.addEventListener("keydown", (e) => {
        if (e.target !== fig || !["Enter", " "].includes(e.key)) return;
        e.preventDefault();
        if (!isBackCard()) open(fig);
      });
    });
  }

  /* AI: bring a sheet to the front of the deck. */
  const ai = $(".ai");
  if (ai) {
    const tabs = $$("[data-ai-set]", ai);
    const set = (t) => { choose(tabs, t, "aria-selected"); ai.dataset.ai = t.dataset.aiSet; };
    tabs.forEach((t) => t.addEventListener("click", () => set(t)));
    $$("[data-ai-card]", ai).forEach((c) => c.addEventListener("click", () => set(tabs.find((t) => t.dataset.aiSet === c.dataset.aiCard))));
    roving($('[role="tablist"]', ai), tabs, set);
  }
})();
