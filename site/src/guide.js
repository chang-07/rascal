import './style.css';

// Scrollspy: highlight the table-of-contents link for whichever section is
// currently in view. Pure progressive enhancement — if it never runs, the TOC
// still works as plain anchor links and all prose stays fully visible.
const links = Array.from(document.querySelectorAll('.toc a[href^="#"]'));
if (links.length && 'IntersectionObserver' in window) {
  const byId = new Map(links.map((a) => [a.getAttribute('href').slice(1), a]));
  const targets = Array.from(byId.keys())
    .map((id) => document.getElementById(id))
    .filter(Boolean);

  let activeId = null;
  const setActive = (id) => {
    if (id === activeId) return;
    activeId = id;
    links.forEach((l) => l.classList.remove('active'));
    byId.get(id)?.classList.add('active');
  };

  const io = new IntersectionObserver(
    (entries) => {
      // Pick the visible section nearest the top of the viewport.
      const visible = entries
        .filter((e) => e.isIntersecting)
        .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top);
      if (visible[0]) setActive(visible[0].target.id);
    },
    { rootMargin: '-12% 0px -70% 0px', threshold: 0 }
  );
  targets.forEach((t) => io.observe(t));
}
