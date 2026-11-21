// Measures the sheet for render.py: its size, where the hero's buttons and
// version line end in each frame, and any element whose content is wider
// than its box. The result is written into #metrics as JSON.
addEventListener("load", () => {
  const sheet = document.querySelector(".sheet");
  const r = sheet.getBoundingClientRect();
  const out = { width: Math.ceil(r.width), height: Math.ceil(r.height), frames: [], overflow: [] };

  for (const f of document.querySelectorAll("[data-fold]")) {
    const fr = f.getBoundingClientRect();
    const top = fr.top + f.clientTop;
    out.frames.push({
      name: f.dataset.name,
      fold: Number(f.dataset.fold),
      checks: [...f.querySelectorAll("[data-check]")].map((e) => ({
        what: e.dataset.check,
        bottom: Math.round((e.getBoundingClientRect().bottom - top) * 10) / 10,
      })),
    });
  }

  for (const e of sheet.querySelectorAll("*")) {
    if (e.closest(".fold") || e.classList.contains("page") || e.closest(".evidence") || e.classList.contains("canvas")
        || e.classList.contains("viewport") || e.classList.contains("pair")) continue;
    if (e.clientWidth > 0 && e.scrollWidth > e.clientWidth + 1) {
      out.overflow.push(`${e.tagName.toLowerCase()}.${[...e.classList].join(".")}: "${e.textContent.trim().slice(0, 40)}" ${e.scrollWidth} > ${e.clientWidth}`);
    }
  }
  document.getElementById("metrics").textContent = JSON.stringify(out);
});
