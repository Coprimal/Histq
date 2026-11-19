const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
const onView = (el, fn, margin = "0px 0px -15% 0px") => {
  new IntersectionObserver((entries, io) => {
    if (entries[0].isIntersecting) { fn(); io.disconnect(); }
  }, { rootMargin: margin }).observe(el);
};
const press = (buttons, active) => buttons.forEach((b) => b.setAttribute("aria-pressed", String(b === active)));

// Hero: solo a branch, as Histq's Solo does.
document.querySelectorAll(".hero-graph").forEach((fig) => {
  const buttons = [...fig.querySelectorAll("[data-solo-btn]")];
  buttons.forEach((b) => b.addEventListener("click", () => { fig.dataset.solo = b.dataset.soloBtn; press(buttons, b); }));
});

// Annotated capture: the gold leaders draw in once.
document.querySelectorAll(".annot").forEach((el) => onView(el, () => el.classList.add("is-in")));

// Profiles: switch, then replay the flow from tab to profile to remote.
document.querySelectorAll(".prof").forEach((prof) => {
  const flow = prof.querySelector(".flow");
  const buttons = [...prof.querySelectorAll("[data-prof-btn]")];
  const run = () => { flow.classList.remove("is-run"); void flow.offsetWidth; flow.classList.add("is-run"); };
  buttons.forEach((b) => b.addEventListener("click", () => { prof.dataset.prof = b.dataset.profBtn; press(buttons, b); run(); }));
  onView(flow, run);
});

// Tabs demo: top or side, items glide to their new place, gold leaders follow.
document.querySelectorAll(".tdemo").forEach((demo) => {
  const stage = demo.querySelector(".tdemo__stage");
  const svg = demo.querySelector(".leaders");
  const buttons = [...demo.querySelectorAll("[data-pos-btn]")];
  const NS = "http://www.w3.org/2000/svg";
  const draw = () => {
    svg.replaceChildren();
    if (getComputedStyle(svg).display === "none") return;
    const s = stage.getBoundingClientRect();
    const side = demo.dataset.pos === "side";
    demo.querySelectorAll("[data-leg-for]").forEach((li, i) => {
      const t = demo.querySelector(`[data-leg="${li.dataset.legFor}"]`);
      if (!t) return;
      const a = li.getBoundingClientRect(), b = t.getBoundingClientRect();
      let d, tx, ty;
      if (side) {
        const lx = a.left - s.left, ly = a.top + a.height / 2 - s.top;
        tx = b.right - s.left + 6; ty = b.top + b.height / 2 - s.top;
        const mx = (lx + tx) / 2;
        d = `M${lx} ${ly}H${mx}V${ty}H${tx}`;
      } else {
        const lx = a.left + 28 - s.left, ly = a.top - s.top;
        tx = b.left + b.width / 2 - s.left; ty = b.bottom - s.top + 6;
        const my = ly - 24 - i * 10;
        d = `M${lx} ${ly}V${my}H${tx}V${ty}`;
      }
      const p = document.createElementNS(NS, "path");
      p.setAttribute("d", d); p.setAttribute("pathLength", "1"); p.style.setProperty("--i", i);
      const c = document.createElementNS(NS, "circle");
      c.setAttribute("cx", tx); c.setAttribute("cy", ty); c.setAttribute("r", "4");
      svg.append(p, c);
    });
  };
  const flip = (pos) => {
    const items = [...demo.querySelectorAll("[data-k]")];
    const before = new Map(items.map((el) => [el, el.getBoundingClientRect()]));
    svg.replaceChildren();
    demo.dataset.pos = pos;
    if (reduced) { draw(); return; }
    items.forEach((el) => {
      const a = before.get(el), b = el.getBoundingClientRect();
      el.style.transition = "none";
      el.style.transform = `translate(${a.left - b.left}px, ${a.top - b.top}px)`;
    });
    void stage.offsetWidth;
    items.forEach((el) => {
      el.style.transition = "transform 480ms cubic-bezier(0.16, 1, 0.3, 1)";
      el.style.transform = "";
    });
    setTimeout(() => { items.forEach((el) => { el.style.transition = ""; }); draw(); }, 500);
  };
  buttons.forEach((b) => b.addEventListener("click", () => { if (demo.dataset.pos !== b.dataset.posBtn) { press(buttons, b); flip(b.dataset.posBtn); } }));
  onView(stage, draw);
  let t;
  new ResizeObserver(() => { clearTimeout(t); t = setTimeout(() => { if (svg.childElementCount) draw(); }, 120); }).observe(stage);
});

// Layouts: any layout with tabs on top or down the side.
document.querySelectorAll(".lay").forEach((lay) => {
  const lb = [...lay.querySelectorAll("[data-lay-btn]")], tb = [...lay.querySelectorAll("[data-tab-btn]")];
  const show = () => lay.querySelectorAll(".lay__frame img").forEach((img) => {
    img.classList.toggle("is-on", img.dataset.l === lay.dataset.layout && img.dataset.t === lay.dataset.tabs);
  });
  lb.forEach((b) => b.addEventListener("click", () => { lay.dataset.layout = b.dataset.layBtn; press(lb, b); show(); }));
  tb.forEach((b) => b.addEventListener("click", () => { lay.dataset.tabs = b.dataset.tabBtn; press(tb, b); show(); }));
});

// Two-way views: File History or Blame; a pull request's Conversation or Files changed.
[["hb", "data-hb-btn"], ["prs", "data-pr-btn"]].forEach(([cls, attr]) => {
  document.querySelectorAll("." + cls).forEach((box) => {
    const buttons = [...box.querySelectorAll(`[${attr}]`)];
    buttons.forEach((b) => b.addEventListener("click", () => { box.dataset.view = b.getAttribute(attr); press(buttons, b); }));
  });
});
