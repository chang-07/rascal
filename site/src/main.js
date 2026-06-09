import './style.css';

// Gentle reveal-on-scroll for elements marked .reveal.
const reveal = () => {
  const els = document.querySelectorAll('.reveal');
  if (!('IntersectionObserver' in window) || matchMedia('(prefers-reduced-motion: reduce)').matches) {
    els.forEach((el) => el.classList.add('in'));
    return;
  }
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
      }
    },
    { rootMargin: '0px 0px -10% 0px', threshold: 0.08 }
  );
  els.forEach((el) => io.observe(el));
};

// Hero slideshow — cross-fade the framed stills, with clickable dots,
// pause-on-hover, and pause when the tab is hidden. Honours reduced-motion.
const slideshow = () => {
  const root = document.querySelector('.slides');
  if (!root) return;
  const slides = [...root.querySelectorAll('.slide')];
  const dots = [...document.querySelectorAll('.slide-dots .dot')];
  if (slides.length < 2) return;

  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  let i = 0;
  let timer = null;

  const show = (n) => {
    i = (n + slides.length) % slides.length;
    slides.forEach((s, k) => s.classList.toggle('is-active', k === i));
    dots.forEach((d, k) => d.classList.toggle('is-active', k === i));
  };
  const stop = () => { if (timer) { clearInterval(timer); timer = null; } };
  const start = () => {
    if (reduce) return;
    stop();
    timer = setInterval(() => show(i + 1), 4000);
  };

  dots.forEach((d, k) => d.addEventListener('click', () => { show(k); start(); }));

  const stage = document.querySelector('.hero-shot');
  stage?.addEventListener('mouseenter', stop);
  stage?.addEventListener('mouseleave', start);
  document.addEventListener('visibilitychange', () => (document.hidden ? stop() : start()));

  start();
};

const init = () => { reveal(); slideshow(); };
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}
