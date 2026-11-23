(() => {
  const sampleAlerts = [
    {
      id: "alert-1",
      app: "Gmail",
      sender: "Maya Chen",
      title: "Re: Q4 macOS beta feedback & onboarding notes",
      preview: "Shared the notes from our walkthrough — happy to test the next local build on Thursday afternoon.",
      capturedAt: "Today · 10:14 AM",
      unread: true,
      flagged: true,
      person: "Maya Chen",
      workspace: "Advisory",
      actionLabel: "Open in Gmail",
      followUp: "Reply with beta checklist · Thu 2:00 PM",
      source: "macOS Accessibility · Forwarded from iPhone",
    },
    {
      id: "alert-2",
      app: "WhatsApp",
      sender: "David Park",
      title: "David Park",
      preview: "Just landed in SF — are we still good for coffee near South Park at 4?",
      capturedAt: "Today · 9:48 AM",
      unread: true,
      flagged: false,
      person: "David Park",
      workspace: "Personal",
      actionLabel: "Open in WhatsApp",
      followUp: "Confirm table at 3:15 PM",
      source: "macOS Accessibility · Forwarded from iPhone",
    },
    {
      id: "alert-3",
      app: "Messages",
      sender: "Elena Morales",
      title: "Elena Morales",
      preview: "Sent over the updated icon exports and contrast check for Reduce Transparency mode.",
      capturedAt: "Yesterday · 6:22 PM",
      unread: false,
      flagged: true,
      person: "Elena Morales",
      workspace: "Design",
      actionLabel: "Open in Messages",
      followUp: "Review SVG exports",
      source: "macOS Accessibility · Mac Notification Center",
    },
    {
      id: "alert-4",
      app: "X",
      sender: "@sam_patel",
      title: "Sam Patel mentioned you",
      preview: "Been looking for a local SQLite notification history tool on macOS that doesn't need cloud sign-in.",
      capturedAt: "Yesterday · 3:05 PM",
      unread: false,
      flagged: false,
      person: "Sam Patel",
      workspace: "Community",
      actionLabel: "Open in X",
      followUp: "None scheduled",
      source: "macOS Accessibility · Forwarded from iPhone",
    },
  ];

  // App Center tab switcher
  const tabs = Array.from(document.querySelectorAll("[data-app-tab]"));
  const panels = Array.from(document.querySelectorAll("[data-app-panel]"));

  function activateTab(tabName) {
    for (const tab of tabs) {
      const selected = tab.dataset.appTab === tabName;
      tab.setAttribute("aria-selected", String(selected));
    }
    for (const panel of panels) {
      panel.hidden = panel.dataset.appPanel !== tabName;
    }
  }

  for (const tab of tabs) {
    tab.addEventListener("click", () => activateTab(tab.dataset.appTab));
  }

  // Glass / Solid preview toggle
  const appWindow = document.getElementById("demo-app-window");
  const surfaceButtons = Array.from(document.querySelectorAll("[data-surface-mode]"));
  for (const btn of surfaceButtons) {
    btn.addEventListener("click", () => {
      const isSolid = btn.dataset.surfaceMode === "solid";
      appWindow?.classList.toggle("is-solid", isSolid);
      for (const other of surfaceButtons) {
        other.setAttribute("aria-pressed", String(other === btn));
      }
    });
  }

  // Interactive Inbox filter + inspector
  const alertListEl = document.getElementById("demo-alert-list");
  const filterButtons = Array.from(document.querySelectorAll("[data-inbox-filter]"));
  let activeFilter = "all";
  let selectedAlertId = sampleAlerts[0].id;

  function updateDetail(alert) {
    const map = {
      "detail-meta": `${alert.app} · ${alert.capturedAt}`,
      "detail-title": alert.title,
      "detail-body": alert.preview,
      "detail-action": alert.actionLabel,
      "detail-person": alert.person,
      "detail-workspace": alert.workspace,
      "detail-followup": alert.followUp,
      "detail-source": alert.source,
    };
    for (const [id, text] of Object.entries(map)) {
      const el = document.getElementById(id);
      if (el) el.textContent = text;
    }
  }

  function renderAlertList() {
    if (!alertListEl) return;
    const filtered = sampleAlerts.filter((item) => {
      if (activeFilter === "unread") return item.unread;
      if (activeFilter === "flagged") return item.flagged;
      return true;
    });

    alertListEl.textContent = "";
    for (const alert of filtered) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "alert-row";
      btn.setAttribute("aria-current", String(alert.id === selectedAlertId));

      const top = document.createElement("div");
      top.className = "alert-row-top";

      const badge = document.createElement("span");
      badge.className = "app-badge";
      if (alert.unread) {
        const dot = document.createElement("span");
        dot.className = "unread-dot";
        dot.setAttribute("aria-hidden", "true");
        badge.appendChild(dot);
      }
      badge.appendChild(document.createTextNode(alert.app));

      const time = document.createElement("span");
      time.textContent = alert.capturedAt.replace("Today · ", "").replace("Yesterday · ", "Yest · ");

      top.appendChild(badge);
      top.appendChild(time);

      const sender = document.createElement("div");
      sender.className = "alert-sender";
      sender.textContent = alert.flagged ? `${alert.sender} ★` : alert.sender;

      const preview = document.createElement("div");
      preview.className = "alert-preview";
      preview.textContent = alert.preview;

      btn.appendChild(top);
      btn.appendChild(sender);
      btn.appendChild(preview);

      btn.addEventListener("click", () => {
        selectedAlertId = alert.id;
        updateDetail(alert);
        renderAlertList();
      });

      alertListEl.appendChild(btn);
    }
  }

  for (const btn of filterButtons) {
    btn.addEventListener("click", () => {
      activeFilter = btn.dataset.inboxFilter || "all";
      for (const other of filterButtons) {
        other.setAttribute("aria-pressed", String(other === btn));
      }
      renderAlertList();
    });
  }

  renderAlertList();
  updateDetail(sampleAlerts[0]);

  // Interactive Today follow-up toggle
  const followupButtons = Array.from(document.querySelectorAll("[data-toggle-followup]"));
  for (const btn of followupButtons) {
    btn.addEventListener("click", () => {
      const item = btn.closest(".followup-item");
      if (!item) return;
      const done = item.classList.toggle("is-done");
      btn.textContent = done ? "Reopen" : "Mark done";
      btn.setAttribute("aria-pressed", String(done));
    });
  }

  // Copy install command button
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
        copyBtn.textContent = "Select & copy";
      }
    });
  }
})();
