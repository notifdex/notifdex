(() => {
  /* =========================================================================
     1. Cursor-reactive kinetic glass-leaf sculpture
        Inspired by Resources/Icons/AppIcon.png and "Flipping Memories":
        translucent beveled glass leaves symmetrically fanning around a warm
        spine, parting and twisting softly along a torsional wave as the
        cursor glides over the hero.
     ========================================================================= */
  const canvas = document.getElementById("glass-leaves");
  const stage = document.getElementById("hero-stage");

  if (canvas instanceof HTMLCanvasElement && stage) {
    const ctx = canvas.getContext("2d");
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    // Symmetrical chromatic palette extracted from Resources/Icons/AppIcon.png
    const palette = [
      { rgb: [22, 62, 178],  edge: [12, 36, 128],  alpha: 0.86 }, // Deep ultramarine
      { rgb: [38, 86, 206],  edge: [24, 58, 162],  alpha: 0.78 }, // Cobalt
      { rgb: [110, 162, 224], edge: [72, 124, 194], alpha: 0.68 }, // Glacial blue
      { rgb: [168, 205, 240], edge: [118, 165, 214], alpha: 0.60 }, // Ice sky
      { rgb: [224, 110, 84], edge: [204, 72, 48],  alpha: 0.74 }, // Persimmon
      { rgb: [236, 146, 122], edge: [216, 102, 76], alpha: 0.66 }, // Coral blush
      { rgb: [230, 194, 122], edge: [204, 158, 76], alpha: 0.62 }, // Warm champagne
      { rgb: [248, 236, 204], edge: [228, 206, 156], alpha: 0.68 }, // Sunlit vellum (upper spine)
      { rgb: [248, 238, 210], edge: [226, 206, 160], alpha: 0.68 }, // Sunlit vellum (lower spine)
      { rgb: [230, 194, 122], edge: [204, 158, 76], alpha: 0.62 }, // Warm champagne
      { rgb: [236, 146, 122], edge: [216, 102, 76], alpha: 0.66 }, // Coral blush
      { rgb: [224, 110, 84], edge: [204, 72, 48],  alpha: 0.74 }, // Persimmon
      { rgb: [168, 205, 240], edge: [118, 165, 214], alpha: 0.60 }, // Ice sky
      { rgb: [110, 162, 224], edge: [72, 124, 194], alpha: 0.68 }, // Glacial blue
      { rgb: [38, 86, 206],  edge: [24, 58, 162],  alpha: 0.78 }, // Cobalt
      { rgb: [22, 62, 178],  edge: [12, 36, 128],  alpha: 0.86 }, // Deep ultramarine
    ];

    const state = {
      width: 480,
      height: 460,
      dpr: Math.min(window.devicePixelRatio || 1, 2),
      targetX: 0,
      targetY: 0,
      x: 0,
      y: 0,
      hover: 0,
      targetHover: 0,
      t: 0,
    };

    function resize() {
      const rect = stage.getBoundingClientRect();
      state.width = Math.max(280, Math.round(rect.width));
      state.height = Math.max(280, Math.round(rect.height));
      state.dpr = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = Math.round(state.width * state.dpr);
      canvas.height = Math.round(state.height * state.dpr);
    }

    function drawLeaf(c, geom, pigment, lightX, proximity) {
      const { x, y, w, h, taper, tilt, thickness } = geom;
      const halfW = w / 2;
      const topHalfW = halfW - taper;
      const skew = tilt * 24;

      const x0 = x - topHalfW + skew;
      const y0 = y - h / 2;
      const x1 = x + topHalfW + skew;
      const y1 = y - h / 2;
      const x2 = x + halfW;
      const y2 = y + h / 2;
      const x3 = x - halfW;
      const y3 = y + h / 2;

      const [r, g, b] = pigment.rgb;
      const [er, eg, eb] = pigment.edge;
      const bodyAlpha = Math.min(0.92, pigment.alpha + proximity * 0.08);

      // Soft ambient cast beneath each leaf
      c.save();
      c.beginPath();
      c.moveTo(x0, y0 + 8);
      c.lineTo(x1, y1 + 8);
      c.lineTo(x2, y2 + 12);
      c.lineTo(x3, y3 + 12);
      c.closePath();
      c.fillStyle = `rgba(${er}, ${eg}, ${eb}, ${0.055 + proximity * 0.04})`;
      c.fill();
      c.restore();

      // Main translucent glass body
      c.save();
      c.beginPath();
      c.moveTo(x0, y0);
      c.lineTo(x1, y1);
      c.lineTo(x2, y2);
      c.lineTo(x3, y3);
      c.closePath();

      const grad = c.createLinearGradient(x, y0, x, y2);
      grad.addColorStop(0, `rgba(${r}, ${g}, ${b}, ${bodyAlpha * 0.94})`);
      grad.addColorStop(0.55, `rgba(${Math.min(255, r + 24)}, ${Math.min(255, g + 24)}, ${Math.min(255, b + 24)}, ${bodyAlpha * 0.56})`);
      grad.addColorStop(1, `rgba(255, 252, 246, ${0.42 + proximity * 0.22})`);
      c.fillStyle = grad;
      c.fill();

      // Gliding optical sheen reacting to horizontal pointer angle
      const sheenCenter = x + lightX * halfW * 0.95;
      const sheen = c.createLinearGradient(sheenCenter - halfW * 0.85, y0, sheenCenter + halfW * 0.85, y2);
      sheen.addColorStop(0, "rgba(255, 255, 255, 0)");
      sheen.addColorStop(0.46, `rgba(255, 255, 255, ${0.18 + proximity * 0.22})`);
      sheen.addColorStop(0.54, `rgba(255, 255, 255, ${0.26 + proximity * 0.24})`);
      sheen.addColorStop(1, "rgba(255, 255, 255, 0)");
      c.fillStyle = sheen;
      c.fill();

      // Subtle architectural outline
      c.strokeStyle = `rgba(${er}, ${eg}, ${eb}, 0.26)`;
      c.lineWidth = 0.75;
      c.stroke();

      // Cut-glass front bevel lip (top or bottom edge depending on leaf orientation)
      const lipY = taper >= 0 ? y0 : y2;
      const lipLeft = taper >= 0 ? x0 : x3;
      const lipRight = taper >= 0 ? x1 : x2;

      c.beginPath();
      c.moveTo(lipLeft, lipY);
      c.lineTo(lipRight, lipY);
      c.lineTo(lipRight, lipY + thickness);
      c.lineTo(lipLeft, lipY + thickness);
      c.closePath();
      c.fillStyle = `rgba(${er}, ${eg}, ${eb}, ${0.72 + proximity * 0.16})`;
      c.fill();

      // Specular white highlight along the cut glass rim
      c.beginPath();
      c.moveTo(lipLeft + 2, lipY + 0.6);
      c.lineTo(lipRight - 2, lipY + 0.6);
      c.strokeStyle = `rgba(255, 255, 255, ${0.65 + proximity * 0.3})`;
      c.lineWidth = 1.05;
      c.stroke();

      c.restore();
    }

    function render() {
      if (!ctx) return;
      const { width, height, dpr } = state;

      // Critically damped follow
      state.x += (state.targetX - state.x) * 0.085;
      state.y += (state.targetY - state.y) * 0.085;
      state.hover += (state.targetHover - state.hover) * 0.075;
      if (!reducedMotion) {
        state.t += 0.011;
      }

      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, width, height);

      const cx = width * 0.5;
      const cy = height * 0.5;
      const stackHeight = height * 0.72;
      const baseWidth = Math.min(width * 0.64, 300);
      const n = palette.length;

      // Active focal point along [-1, 1] vertical axis
      const idleWave = reducedMotion ? 0 : Math.sin(state.t * 0.7) * 0.14;
      const focusY = state.y * 0.85 * state.hover + idleWave * (1 - state.hover * 0.7);
      const twistX = state.x * state.hover + (reducedMotion ? 0 : Math.cos(state.t * 0.55) * 0.12 * (1 - state.hover));

      // Chromatic bounce light onto gallery alabaster ground
      const focusIdx = Math.max(0, Math.min(n - 1, Math.round(((focusY + 1) / 2) * (n - 1))));
      const activeRgb = palette[focusIdx].rgb;
      const ambientGlow = ctx.createRadialGradient(
        cx + twistX * 36,
        cy + focusY * (stackHeight * 0.34),
        12,
        cx,
        cy,
        Math.max(width, height) * 0.48
      );
      ambientGlow.addColorStop(0, `rgba(${activeRgb[0]}, ${activeRgb[1]}, ${activeRgb[2]}, ${0.14 + state.hover * 0.09})`);
      ambientGlow.addColorStop(0.45, "rgba(255, 245, 224, 0.24)");
      ambientGlow.addColorStop(1, "rgba(245, 244, 240, 0)");
      ctx.fillStyle = ambientGlow;
      ctx.fillRect(0, 0, width, height);

      // Compute leaf positions with torsional wave + parting gap around focusY
      const leaves = [];
      for (let i = 0; i < n; i++) {
        const u = (i / (n - 1)) * 2 - 1; // -1 (top) .. +1 (bottom)
        const dist = u - focusY;
        const absDist = Math.abs(dist);
        const proximity = Math.exp(-absDist * absDist * 4.8);

        // Parting push: leaves gently separate around the focal plane
        const partOffset = Math.sign(dist || 1) * (1 - Math.exp(-absDist * 2.4)) * (16 + state.hover * 16);
        const y = cy + u * (stackHeight * 0.46) + partOffset * 0.55;

        // Torsional S-wave horizontal displacement (echoing Flipping Memories)
        const sWave = Math.sin(u * 2.2 - state.t * 0.65) * 7 * (1 - state.hover * 0.35);
        const pointerWave = Math.sin((u - focusY) * 2.6) * twistX * 34;
        const x = cx + sWave + pointerWave;

        // Perspective width & foreshortening toward the glowing center hinge
        const depthFactor = Math.abs(u);
        const w = baseWidth * (0.88 + 0.14 * (1 - depthFactor * 0.65) + proximity * 0.05);
        const h = 21 + proximity * 13 * (0.45 + state.hover * 0.55);

        // Upper leaves angle downward toward the hinge; lower leaves angle upward
        const sign = dist < 0 ? 1 : -1;
        const taper = sign * (10 + (1 - proximity) * 5);
        const tilt = twistX * (0.35 + proximity * 0.85) * (dist < 0 ? 1 : -1);

        leaves.push({
          index: i,
          pigment: palette[i],
          proximity,
          distFromCenter: absDist,
          geom: { x, y, w, h, taper, tilt, thickness: 2.3 },
        });
      }

      // Warm backlit horizontal spine glow at the parting plane
      const spineY = cy + focusY * (stackHeight * 0.44);
      const spineGlow = ctx.createRadialGradient(
        cx + twistX * 18,
        spineY,
        4,
        cx,
        spineY,
        baseWidth * 0.62
      );
      spineGlow.addColorStop(0, "rgba(255, 253, 245, 0.96)");
      spineGlow.addColorStop(0.55, "rgba(246, 224, 178, 0.34)");
      spineGlow.addColorStop(1, "rgba(246, 224, 178, 0)");
      ctx.fillStyle = spineGlow;
      ctx.fillRect(0, spineY - 64, width, 128);

      // Draw from outer leaves inward toward the sunlit parting plane for crisp overlapping depth
      const ordered = [...leaves].sort((a, b) => b.distFromCenter - a.distFromCenter);
      for (const leaf of ordered) {
        drawLeaf(ctx, leaf.geom, leaf.pigment, twistX, leaf.proximity);
      }

      if (!reducedMotion) {
        window.requestAnimationFrame(render);
      }
    }

    const heroEl = document.querySelector(".hero");
    const pointerTarget = heroEl || stage;

    pointerTarget.addEventListener("pointermove", (ev) => {
      const rect = stage.getBoundingClientRect();
      const nx = ((ev.clientX - rect.left) / rect.width) * 2 - 1;
      const ny = ((ev.clientY - rect.top) / rect.height) * 2 - 1;
      state.targetX = Math.max(-1, Math.min(1, nx));
      state.targetY = Math.max(-1, Math.min(1, ny));
      state.targetHover = 1;
    });

    pointerTarget.addEventListener("pointerleave", () => {
      state.targetX = 0;
      state.targetY = 0;
      state.targetHover = 0;
    });

    window.addEventListener("resize", () => {
      resize();
      if (reducedMotion) render();
    });

    // Replace fallback image once canvas is ready
    const fallback = stage.querySelector(".hero-fallback");
    if (fallback) fallback.hidden = true;
    canvas.hidden = false;

    resize();
    render();
  }

  /* =========================================================================
     2. Interactive App Center Preview (synthetic sample data only)
     ========================================================================= */
  const sampleAlerts = [
    {
      id: "alert-1",
      app: "Messages",
      device: "iPhone",
      sender: "Maya Chen",
      title: "Maya Chen",
      body: "Just saw the new glass icon on my desk — Thursday at two still works to walk through the iPhone forwarding tests.",
      time: "10:14",
      captured: "Today, 10:14 AM · Forwarded from iPhone",
      unread: true,
      flagged: true,
      person: "Maya Chen",
      workspace: "Advisory",
      action: "Open in Messages",
      followup: "Thursday, 2:00 PM",
    },
    {
      id: "alert-2",
      app: "WhatsApp",
      device: "iPhone",
      sender: "David Park",
      title: "David Park",
      body: "Landed early. Coffee near South Park at four if you're free?",
      time: "09:48",
      captured: "Today, 9:48 AM · Forwarded from iPhone",
      unread: true,
      flagged: false,
      person: "David Park",
      workspace: "Personal",
      action: "Open in WhatsApp",
      followup: "Today, 3:15 PM",
    },
    {
      id: "alert-3",
      app: "Gmail",
      device: "iPhone",
      sender: "Elena Morales",
      title: "Re: Pigment values for Mineral and Prussian",
      body: "Attached the revised light-mode hairlines and contrast checks for Reduce Transparency.",
      time: "Yest",
      captured: "Yesterday, 6:22 PM · Forwarded from iPhone",
      unread: false,
      flagged: true,
      person: "Elena Morales",
      workspace: "Design",
      action: "Open in Gmail",
      followup: "Friday, 10:00 AM",
    },
    {
      id: "alert-4",
      app: "X",
      device: "iPhone",
      sender: "@sam_patel",
      title: "Sam Patel mentioned you",
      body: "An iPhone notification archive that actually lives in a local SQLite file on my Mac is exactly what I wanted.",
      time: "Yest",
      captured: "Yesterday, 3:05 PM · Forwarded from iPhone",
      unread: false,
      flagged: false,
      person: "Sam Patel",
      workspace: "Community",
      action: "Open in X",
      followup: "None",
    },
  ];

  // Atelier pigment switcher
  const appWindow = document.getElementById("demo-app-window");
  const pigmentButtons = Array.from(document.querySelectorAll("[data-pigment-choice]"));
  for (const btn of pigmentButtons) {
    btn.addEventListener("click", () => {
      const pigment = btn.dataset.pigmentChoice || "mineral";
      if (appWindow) appWindow.dataset.pigment = pigment;
      for (const other of pigmentButtons) {
        other.setAttribute("aria-pressed", String(other === btn));
      }
    });
  }

  // Sidebar view switcher
  const navButtons = Array.from(document.querySelectorAll("[data-app-view]"));
  const viewPanels = Array.from(document.querySelectorAll("[data-view-panel]"));

  for (const btn of navButtons) {
    btn.addEventListener("click", () => {
      const target = btn.dataset.appView;
      for (const other of navButtons) {
        other.setAttribute("aria-selected", String(other === btn));
      }
      for (const panel of viewPanels) {
        panel.hidden = panel.dataset.viewPanel !== target;
      }
    });
  }

  // Inbox list + inspector
  const alertListEl = document.getElementById("demo-alert-list");
  const filterButtons = Array.from(document.querySelectorAll("[data-inbox-filter]"));
  let activeFilter = "all";
  let selectedId = sampleAlerts[0].id;

  function renderInspector(alert) {
    const fields = {
      "detail-meta": `${alert.app} · ${alert.captured}`,
      "detail-title": alert.title,
      "detail-body": alert.body,
      "detail-action": alert.action,
      "detail-person": alert.person,
      "detail-workspace": alert.workspace,
      "detail-followup": alert.followup,
      "detail-device": `${alert.device} → Mac`,
    };
    for (const [id, text] of Object.entries(fields)) {
      const el = document.getElementById(id);
      if (el) el.textContent = text;
    }
  }

  function renderList() {
    if (!alertListEl) return;
    const items = sampleAlerts.filter((item) => {
      if (activeFilter === "unread") return item.unread;
      if (activeFilter === "flagged") return item.flagged;
      return true;
    });

    alertListEl.textContent = "";
    for (const item of items) {
      const row = document.createElement("button");
      row.type = "button";
      row.className = "alert-row";
      row.setAttribute("aria-current", String(item.id === selectedId));

      const meta = document.createElement("div");
      meta.className = "alert-row-meta";

      const src = document.createElement("span");
      src.className = "alert-source";
      if (item.unread) {
        const dot = document.createElement("span");
        dot.className = "unread-dot";
        dot.setAttribute("aria-hidden", "true");
        src.appendChild(dot);
      }
      src.appendChild(document.createTextNode(`${item.app} · ${item.device}`));

      const time = document.createElement("span");
      time.className = "alert-time";
      time.textContent = item.time;

      meta.appendChild(src);
      meta.appendChild(time);

      const sender = document.createElement("div");
      sender.className = "alert-sender";
      sender.textContent = item.sender;

      const excerpt = document.createElement("div");
      excerpt.className = "alert-excerpt";
      excerpt.textContent = item.body;

      row.appendChild(meta);
      row.appendChild(sender);
      row.appendChild(excerpt);

      row.addEventListener("click", () => {
        selectedId = item.id;
        renderInspector(item);
        renderList();
      });

      alertListEl.appendChild(row);
    }
  }

  for (const btn of filterButtons) {
    btn.addEventListener("click", () => {
      activeFilter = btn.dataset.inboxFilter || "all";
      for (const other of filterButtons) {
        other.setAttribute("aria-pressed", String(other === btn));
      }
      renderList();
    });
  }

  renderList();
  renderInspector(sampleAlerts[0]);

  // Today follow-up toggles
  const toggleButtons = Array.from(document.querySelectorAll("[data-toggle-followup]"));
  for (const btn of toggleButtons) {
    btn.addEventListener("click", () => {
      const row = btn.closest(".followup-row");
      if (!row) return;
      const done = row.classList.toggle("is-done");
      btn.textContent = done ? "Reopen" : "Done";
      btn.setAttribute("aria-pressed", String(done));
    });
  }

  // Copy install command
  const copyBtn = document.getElementById("copy-install-btn");
  const installCode = document.getElementById("install-command");
  if (copyBtn && installCode && navigator.clipboard) {
    copyBtn.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(installCode.textContent?.trim() || "");
        copyBtn.textContent = "Copied";
        window.setTimeout(() => {
          copyBtn.textContent = "Copy";
        }, 1800);
      } catch {
        copyBtn.textContent = "Copy";
      }
    });
  }
})();
