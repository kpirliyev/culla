# Landing-page wireframes

Low-fidelity wireframes for `docs/landing-page-plan.md`, drawn as plain HTML and CSS and captured with headless Google Chrome at 2x into `docs/images/landing-desktop.png`, `landing-mobile.png` and `landing-hero-ru.png`.

Redraw all three from the repository root:

```bash
python3 Scripts/landing-wireframes/render.py
```

The script measures each page first, prints where the hero's buttons and version line end against the fold, and fails if either ends below it or if any text is wider than its box.
