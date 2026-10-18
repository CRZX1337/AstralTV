/* AstralTV site: ambient sky, scroll story, glass interactions,
   and live release / build info from the GitHub API. */
(() => {
  "use strict";

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const coarsePointer = window.matchMedia("(pointer: coarse)");

  /* ---------- app-like input: no context menu ---------- */
  document.addEventListener("contextmenu", (event) => event.preventDefault());

  /* ---------- hero load sequence ---------- */
  requestAnimationFrame(() => document.body.classList.add("ready"));

  /* ---------- scroll reveals ---------- */
  const revealables = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window && !reduceMotion.matches) {
    const revealer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            entry.target.classList.add("in");
            revealer.unobserve(entry.target);
          }
        }
      },
      { threshold: 0.12, rootMargin: "0px 0px -8% 0px" }
    );
    revealables.forEach((el) => revealer.observe(el));
  } else {
    revealables.forEach((el) => el.classList.add("in"));
  }

  /* ---------- feature tour: sticky screen follows the panels ---------- */
  const panels = Array.from(document.querySelectorAll(".panel[data-screen]"));
  const shots = Array.from(document.querySelectorAll("#tourScreen .tour-shot"));
  if (panels.length && shots.length && "IntersectionObserver" in window) {
    const showShot = (index) => {
      shots.forEach((shot, i) => shot.classList.toggle("is-active", i === index));
      panels.forEach((panel, i) => panel.classList.toggle("is-current", i === index));
    };
    const tourWatcher = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            showShot(Number(entry.target.dataset.screen) || 0);
          }
        }
      },
      { rootMargin: "-42% 0px -42% 0px", threshold: 0 }
    );
    panels.forEach((panel) => tourWatcher.observe(panel));
  }

  /* ---------- glass tilt + pointer highlight ---------- */
  if (!reduceMotion.matches && !coarsePointer.matches) {
    document.querySelectorAll(".tilt").forEach((el) => {
      let frame = 0;
      el.addEventListener("pointermove", (event) => {
        if (frame) return;
        frame = requestAnimationFrame(() => {
          frame = 0;
          const rect = el.getBoundingClientRect();
          const x = (event.clientX - rect.left) / rect.width;
          const y = (event.clientY - rect.top) / rect.height;
          el.style.setProperty("--mx", `${(x * 100).toFixed(1)}%`);
          el.style.setProperty("--my", `${(y * 100).toFixed(1)}%`);
          el.style.setProperty("--ry", `${((x - 0.5) * 4).toFixed(2)}deg`);
          el.style.setProperty("--rx", `${((0.5 - y) * 4).toFixed(2)}deg`);
        });
      });
      el.addEventListener("pointerleave", () => {
        el.style.setProperty("--rx", "0deg");
        el.style.setProperty("--ry", "0deg");
      });
    });
  }

  /* ---------- screenshot rail: arrows, progress, threshold drag ---------- */
  const rail = document.getElementById("shotRail");
  if (rail) {
    const fill = document.getElementById("railFill");
    const buttons = Array.from(document.querySelectorAll("[data-rail]"));
    const GAP = 18;

    const sync = () => {
      const max = Math.max(1, rail.scrollWidth - rail.clientWidth);
      const x = Math.min(Math.max(rail.scrollLeft, 0), max);
      if (fill) {
        const visible = Math.min(1, rail.clientWidth / rail.scrollWidth);
        const width = visible * 100;
        fill.style.width = `${width.toFixed(2)}%`;
        fill.style.left = `${((x / max) * (100 - width)).toFixed(2)}%`;
      }
      for (const button of buttons) {
        const dir = Number(button.dataset.rail);
        button.disabled = dir < 0 ? x <= 2 : x >= max - 2;
      }
    };

    const stepBy = (dir) => {
      const card = rail.querySelector(".shot");
      const distance = card ? card.getBoundingClientRect().width + GAP : rail.clientWidth * 0.8;
      rail.scrollBy({ left: dir * distance, behavior: reduceMotion.matches ? "auto" : "smooth" });
    };

    buttons.forEach((button) => {
      button.addEventListener("click", () => stepBy(Number(button.dataset.rail) || 1));
    });

    let queued = false;
    const queueSync = () => {
      if (queued) return;
      queued = true;
      requestAnimationFrame(() => {
        queued = false;
        sync();
      });
    };
    rail.addEventListener("scroll", queueSync, { passive: true });
    window.addEventListener("resize", queueSync);
    rail.addEventListener("keydown", (event) => {
      rail.classList.add("is-keyboard");
      if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
      event.preventDefault();
      stepBy(event.key === "ArrowRight" ? 1 : -1);
    });
    rail.addEventListener("blur", () => rail.classList.remove("is-keyboard"));
    rail.addEventListener("pointerdown", () => rail.classList.remove("is-keyboard"));

    // Mouse drag only; touch keeps the browser's native momentum scrolling.
    let drag = null;
    rail.addEventListener("pointerdown", (event) => {
      if (event.pointerType !== "mouse" || event.button !== 0) return;
      drag = { id: event.pointerId, x: event.clientX, left: rail.scrollLeft, moved: false };
    });
    rail.addEventListener("pointermove", (event) => {
      if (!drag || event.pointerId !== drag.id) return;
      const dx = event.clientX - drag.x;
      if (!drag.moved) {
        if (Math.abs(dx) < 7) return;
        drag.moved = true;
        rail.classList.add("is-dragging");
        try {
          rail.setPointerCapture(event.pointerId);
        } catch {
          // The pointer can already be gone on a fast flick; dragging still works.
        }
      }
      rail.scrollLeft = drag.left - dx;
    });
    const endDrag = (event) => {
      if (!drag) return;
      if (drag.moved) {
        if (rail.hasPointerCapture(drag.id)) rail.releasePointerCapture(drag.id);
        rail.classList.remove("is-dragging");
        queueSync();
      }
      drag = null;
    };
    rail.addEventListener("pointerup", endDrag);
    rail.addEventListener("pointercancel", endDrag);
    rail.addEventListener("dragstart", (event) => event.preventDefault());

    sync();
    window.addEventListener("load", queueSync);
  }

  /* ---------- ambient night sky ---------- */
  const canvas = document.getElementById("sky");
  const ctx = canvas && canvas.getContext("2d");
  if (canvas && ctx) {
    const MAX_DPR = 2;
    let stars = [];
    let width = 0;
    let height = 0;
    let rafId = 0;

    const resize = () => {
      const dpr = Math.min(window.devicePixelRatio || 1, MAX_DPR);
      width = window.innerWidth;
      height = window.innerHeight;
      canvas.width = Math.round(width * dpr);
      canvas.height = Math.round(height * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      const count = Math.min(150, Math.round((width * height) / 12000));
      stars = Array.from({ length: count }, () => ({
        x: Math.random() * width,
        y: Math.random() * height,
        r: Math.random() * 1.35 + 0.3,
        a: Math.random() * 0.5 + 0.18,
        tw: Math.random() * Math.PI * 2,
        vy: Math.random() * 0.05 + 0.015
      }));
    };

    const draw = (time) => {
      ctx.clearRect(0, 0, width, height);
      for (const star of stars) {
        const twinkle = reduceMotion.matches ? 0 : Math.sin(time / 1400 + star.tw) * 0.16;
        ctx.globalAlpha = Math.min(0.85, Math.max(0.05, star.a + twinkle));
        ctx.fillStyle = star.a > 0.52 ? "#9BE9F5" : "#DCE8F2";
        ctx.beginPath();
        ctx.arc(star.x, star.y, star.r, 0, Math.PI * 2);
        ctx.fill();
        if (!reduceMotion.matches) {
          star.y -= star.vy;
          if (star.y < -2) {
            star.y = height + 2;
            star.x = Math.random() * width;
          }
        }
      }
      ctx.globalAlpha = 1;
    };

    const loop = (time) => {
      draw(time);
      rafId = requestAnimationFrame(loop);
    };
    const start = () => {
      if (reduceMotion.matches) {
        draw(0);
        return;
      }
      if (!rafId) rafId = requestAnimationFrame(loop);
    };
    const stop = () => {
      cancelAnimationFrame(rafId);
      rafId = 0;
    };

    resize();
    start();

    let resizeTimer = 0;
    window.addEventListener("resize", () => {
      clearTimeout(resizeTimer);
      resizeTimer = setTimeout(() => {
        resize();
        if (reduceMotion.matches) draw(0);
      }, 150);
    });
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) stop();
      else start();
    });
  }

  /* ---------- live release and build info ---------- */
  const REPO = "CRZX1337/AstralTV";
  const API = `https://api.github.com/repos/${REPO}`;
  const formatDate = (iso) =>
    new Date(iso).toLocaleDateString("en", {
      year: "numeric",
      month: "short",
      day: "numeric"
    });

  const getJSON = async (url) => {
    const res = await fetch(url, { headers: { Accept: "application/vnd.github+json" } });
    if (!res.ok) throw new Error(`GitHub API ${res.status}`);
    return res.json();
  };

  const loadRelease = async () => {
    const version = document.getElementById("releaseVersion");
    const date = document.getElementById("releaseDate");
    const link = document.getElementById("releaseLink");
    const card = document.getElementById("stableCard");
    try {
      const res = await fetch(`${API}/releases/latest`, {
        headers: { Accept: "application/vnd.github+json" }
      });
      if (res.status === 404) {
        card.classList.add("is-fallback");
        version.textContent = "No release published yet";
        date.textContent = "For now, the beta build on the right is the way to get the app.";
        link.href = "https://github.com/CRZX1337/AstralTV/releases";
        link.textContent = "Open the releases page";
        return;
      }
      if (!res.ok) throw new Error(`GitHub API ${res.status}`);
      const release = await res.json();
      const ipa = (release.assets || []).find((asset) =>
        asset.name.toLowerCase().endsWith(".ipa")
      );
      version.textContent = `Release ${release.tag_name}`;
      date.textContent = `Published ${formatDate(release.published_at)}`;
      if (ipa) {
        link.href = ipa.browser_download_url;
      } else {
        link.href = release.html_url;
        link.textContent = "Open the release page";
      }
    } catch {
      card.classList.add("is-fallback");
      version.textContent = "Release details unavailable";
      date.textContent = "The releases page always has the latest download.";
      link.textContent = "Open the releases page";
    }
  };

  // The beta button always points at the rolling pre-release asset. Only the
  // commit and date come from the API, so a failed request never breaks the link.
  const loadBeta = async () => {
    const version = document.getElementById("betaVersion");
    const date = document.getElementById("betaDate");
    const card = document.getElementById("betaCard");
    try {
      const release = await getJSON(`${API}/releases/tags/beta-latest`);
      const asset = (release.assets || []).find(
        (item) => item.name === "AstralTV-beta-latest.ipa"
      );
      if (!asset) throw new Error("beta asset missing");
      version.textContent = release.name || "Beta build";
      date.textContent = `Updated ${formatDate(release.updated_at || release.published_at)}`;
    } catch {
      card.classList.add("is-fallback");
      version.textContent = "Beta release not ready";
      date.textContent = "The next push to main publishes it.";
    }
  };

  // Latest build on main, shown as a status pill in the hero.
  const loadBuildStatus = async () => {
    const badge = document.getElementById("buildStatus");
    const value = document.getElementById("buildStatusText");
    if (!badge || !value) return;
    try {
      const data = await getJSON(
        `${API}/actions/workflows/build-ipa.yml/runs?branch=main&per_page=1`
      );
      const run = (data.workflow_runs || [])[0];
      if (!run) return;
      const state =
        run.status !== "completed"
          ? "running"
          : run.conclusion === "success"
            ? "success"
            : "failure";
      const label = { running: "building", success: "passing", failure: "failed" }[state];
      badge.dataset.state = state;
      value.textContent = `${label} \u00b7 ${run.head_sha.slice(0, 7)}`;
      badge.href = run.html_url;
      badge.title = `Latest beta build ${label}, run #${run.run_number}`;
      badge.hidden = false;
    } catch {
      // Leave the badge hidden if the API is unavailable.
    }
  };

  loadRelease();
  loadBeta();
  loadBuildStatus();
})();
