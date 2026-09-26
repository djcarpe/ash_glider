// A small force-directed graph renderer for LiveView. No dependencies.
//
// The hook element carries the data in `data-graph` as
//   {nodes: [{id, name, group, color, href, focus}], edges: [{id, from, to, type}]}
// and draws into its phx-update="ignore" child. Positions survive updates, so
// adding an edge nudges the layout instead of reshuffling it.
(function () {
  const SVGNS = "http://www.w3.org/2000/svg";

  function el(tag, attrs, parent) {
    const e = document.createElementNS(SVGNS, tag);
    for (const k in attrs) e.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(e);
    return e;
  }

  window.GraphHook = {
    mounted() {
      this.host = this.el.querySelector(".graph-svg");
      this.positions = new Map();
      this.view = { x: 0, y: 0, k: 1 };
      this.build();
      this.load();
    },

    updated() {
      this.load();
    },

    destroyed() {
      cancelAnimationFrame(this.raf);
      this.resizeObserver && this.resizeObserver.disconnect();
    },

    build() {
      this.svg = el("svg", { class: "graph" }, this.host);
      const defs = el("defs", {}, this.svg);
      const marker = el("marker", {
        id: this.el.id + "-arrow", viewBox: "0 -4 8 8", refX: 8, refY: 0,
        markerWidth: 7, markerHeight: 7, orient: "auto"
      }, defs);
      el("path", { d: "M0,-4L8,0L0,4", class: "arrow" }, marker);
      this.root = el("g", {}, this.svg);
      this.edgeLayer = el("g", {}, this.root);
      this.labelLayer = el("g", {}, this.root);
      this.nodeLayer = el("g", {}, this.root);

      this.size();
      this.resizeObserver = new ResizeObserver(() => this.size());
      this.resizeObserver.observe(this.host);

      // Pan on background drag, zoom on wheel.
      let pan = null;
      this.svg.addEventListener("pointerdown", (e) => {
        if (e.target !== this.svg) return;
        pan = { x: e.clientX, y: e.clientY, vx: this.view.x, vy: this.view.y };
        this.svg.setPointerCapture(e.pointerId);
      });
      this.svg.addEventListener("pointermove", (e) => {
        if (!pan) return;
        this.view.x = pan.vx + (e.clientX - pan.x);
        this.view.y = pan.vy + (e.clientY - pan.y);
        this.applyView();
      });
      this.svg.addEventListener("pointerup", () => (pan = null));
      this.svg.addEventListener("wheel", (e) => {
        e.preventDefault();
        const r = this.svg.getBoundingClientRect();
        const mx = e.clientX - r.left, my = e.clientY - r.top;
        const k = Math.min(4, Math.max(0.2, this.view.k * (e.deltaY < 0 ? 1.1 : 1 / 1.1)));
        this.view.x = mx - ((mx - this.view.x) * k) / this.view.k;
        this.view.y = my - ((my - this.view.y) * k) / this.view.k;
        this.view.k = k;
        this.applyView();
      }, { passive: false });
    },

    size() {
      const r = this.host.getBoundingClientRect();
      this.w = r.width || 600;
      this.h = r.height || 400;
      this.svg.setAttribute("viewBox", `0 0 ${this.w} ${this.h}`);
    },

    applyView() {
      const { x, y, k } = this.view;
      this.root.setAttribute("transform", `translate(${x},${y}) scale(${k})`);
    },

    load() {
      let data;
      try { data = JSON.parse(this.el.dataset.graph || "{}"); } catch (_) { return; }
      const nodes = data.nodes || [];
      const byId = new Map();

      this.nodes = nodes.map((n, i) => {
        const prev = this.positions.get(n.id);
        const angle = (i / Math.max(nodes.length, 1)) * Math.PI * 2;
        const radius = Math.min(this.w, this.h) * 0.3;
        const node = Object.assign({}, n, prev || {
          x: this.w / 2 + Math.cos(angle) * radius + (Math.random() - 0.5) * 20,
          y: this.h / 2 + Math.sin(angle) * radius + (Math.random() - 0.5) * 20,
          vx: 0, vy: 0
        });
        if (n.focus && !prev) { node.x = this.w / 2; node.y = this.h / 2; }
        byId.set(n.id, node);
        return node;
      });

      this.edges = (data.edges || [])
        .map((e) => ({ ...e, source: byId.get(e.from), target: byId.get(e.to) }))
        .filter((e) => e.source && e.target);

      // Parallel edges between the same pair get fanned out as curves.
      const pairs = new Map();
      for (const e of this.edges) {
        const key = [e.from, e.to].sort().join(":");
        const list = pairs.get(key) || [];
        list.push(e);
        pairs.set(key, list);
      }
      for (const list of pairs.values()) list.forEach((e, i) => (e.bend = (i - (list.length - 1) / 2) * 30));

      this.degree = new Map();
      for (const e of this.edges) {
        this.degree.set(e.from, (this.degree.get(e.from) || 0) + 1);
        this.degree.set(e.to, (this.degree.get(e.to) || 0) + 1);
      }

      this.draw();
      this.alpha = 1;
      cancelAnimationFrame(this.raf);
      this.tick();
    },

    radius(n) {
      return (n.focus ? 14 : 7) + Math.min(10, Math.sqrt(this.degree.get(n.id) || 0) * 2.2);
    },

    draw() {
      this.edgeLayer.replaceChildren();
      this.labelLayer.replaceChildren();
      this.nodeLayer.replaceChildren();
      const showEdgeLabels = this.edges.length <= 30;

      for (const e of this.edges) {
        e.path = el("path", { class: "edge", "marker-end": `url(#${this.el.id}-arrow)` }, this.edgeLayer);
        el("title", {}, e.path).textContent = e.type;
        if (showEdgeLabels) {
          e.label = el("text", { class: "edge-label" }, this.labelLayer);
          e.label.textContent = e.type;
        }
      }

      for (const n of this.nodes) {
        const g = el("g", { class: "node" + (n.focus ? " focus" : "") + (n.href ? " linked" : "") }, this.nodeLayer);
        el("circle", { r: this.radius(n), fill: n.color }, g);
        const t = el("text", { dy: this.radius(n) + 13, class: "node-label" }, g);
        t.textContent = n.name;
        el("title", {}, g).textContent = `${n.group}: ${n.name}`;
        n.g = g;
        this.bindDrag(n);
      }
    },

    bindDrag(n) {
      let start = null;
      n.g.addEventListener("pointerdown", (e) => {
        e.stopPropagation();
        start = { x: e.clientX, y: e.clientY, moved: false };
        n.g.setPointerCapture(e.pointerId);
        n.fixed = true;
      });
      n.g.addEventListener("pointermove", (e) => {
        if (!start) return;
        const dx = e.clientX - start.x, dy = e.clientY - start.y;
        if (Math.abs(dx) + Math.abs(dy) > 3) start.moved = true;
        if (!start.moved) return;
        const r = this.svg.getBoundingClientRect();
        const sx = this.w / r.width, sy = this.h / r.height;
        n.x = ((e.clientX - r.left) * sx - this.view.x) / this.view.k;
        n.y = ((e.clientY - r.top) * sy - this.view.y) / this.view.k;
        this.alpha = Math.max(this.alpha, 0.3);
        if (!this.running) this.tick();
      });
      n.g.addEventListener("pointerup", () => {
        if (start && !start.moved && n.href) this.pushEvent("graph_click", { href: n.href });
        start = null;
        n.fixed = false;
      });
      n.g.addEventListener("mouseenter", () => this.highlight(n));
      n.g.addEventListener("mouseleave", () => this.highlight(null));
    },

    highlight(n) {
      const near = new Set(n ? [n.id] : []);
      if (n) for (const e of this.edges) {
        if (e.from === n.id) near.add(e.to);
        if (e.to === n.id) near.add(e.from);
      }
      for (const m of this.nodes) m.g.classList.toggle("dim", !!n && !near.has(m.id));
      for (const e of this.edges) {
        const on = n && (e.from === n.id || e.to === n.id);
        e.path.classList.toggle("dim", !!n && !on);
        e.path.classList.toggle("hot", !!on);
        if (e.label) e.label.classList.toggle("dim", !!n && !on);
      }
    },

    tick() {
      this.running = true;
      const nodes = this.nodes, edges = this.edges;
      const cx = this.w / 2, cy = this.h / 2;
      const a = this.alpha;

      // Repulsion: every pair. Fine for the few hundred nodes we draw.
      for (let i = 0; i < nodes.length; i++) {
        const p = nodes[i];
        for (let j = i + 1; j < nodes.length; j++) {
          const q = nodes[j];
          let dx = q.x - p.x, dy = q.y - p.y;
          let d2 = dx * dx + dy * dy;
          if (d2 < 0.01) { dx = Math.random() - 0.5; dy = Math.random() - 0.5; d2 = 0.5; }
          const f = (5500 * a) / d2;
          const d = Math.sqrt(d2);
          const fx = (dx / d) * f, fy = (dy / d) * f;
          p.vx -= fx; p.vy -= fy; q.vx += fx; q.vy += fy;
        }
      }
      // Springs along edges.
      for (const e of edges) {
        const s = e.source, t = e.target;
        const dx = t.x - s.x, dy = t.y - s.y;
        const d = Math.sqrt(dx * dx + dy * dy) || 1;
        const f = (d - 110) * 0.04 * a;
        const fx = (dx / d) * f, fy = (dy / d) * f;
        s.vx += fx; s.vy += fy; t.vx -= fx; t.vy -= fy;
      }
      // Gravity toward the centre keeps components on screen.
      for (const n of nodes) {
        n.vx += (cx - n.x) * 0.006 * a;
        n.vy += (cy - n.y) * 0.006 * a;
        if (n.fixed) { n.vx = 0; n.vy = 0; continue; }
        n.vx *= 0.6; n.vy *= 0.6;
        n.x += Math.max(-30, Math.min(30, n.vx));
        n.y += Math.max(-30, Math.min(30, n.vy));
      }

      this.render();
      for (const n of nodes) this.positions.set(n.id, { x: n.x, y: n.y, vx: 0, vy: 0 });

      this.alpha *= 0.985;
      if (this.alpha > 0.02) {
        this.raf = requestAnimationFrame(() => this.tick());
      } else {
        this.running = false;
      }
    },

    render() {
      for (const n of this.nodes) n.g.setAttribute("transform", `translate(${n.x},${n.y})`);
      for (const e of this.edges) {
        const s = e.source, t = e.target;
        if (s === t) {
          const r = this.radius(s);
          e.path.setAttribute("d", `M${s.x},${s.y - r} c30,-40 50,10 ${r},${r}`);
          continue;
        }
        const dx = t.x - s.x, dy = t.y - s.y;
        const d = Math.sqrt(dx * dx + dy * dy) || 1;
        const rt = this.radius(t) + 2;
        // Stop the line at the target's rim so the arrowhead is visible.
        const ex = t.x - (dx / d) * rt, ey = t.y - (dy / d) * rt;
        const mx = (s.x + ex) / 2 - (dy / d) * e.bend, my = (s.y + ey) / 2 + (dx / d) * e.bend;
        e.path.setAttribute("d", `M${s.x},${s.y} Q${mx},${my} ${ex},${ey}`);
        if (e.label) {
          e.label.setAttribute("x", (s.x + 2 * mx + ex) / 4);
          e.label.setAttribute("y", (s.y + 2 * my + ey) / 4);
        }
      }
    }
  };
})();
