import { defineConfig } from 'vite';
import { fileURLToPath } from 'node:url';

// Resolve an entry HTML relative to this config (ESM-safe — no __dirname).
const entry = (p) => fileURLToPath(new URL(p, import.meta.url));

export default defineConfig({
  // Relative asset paths — the site is published from /docs on GitHub Pages at
  // a project subpath (chang-07.github.io/finder-2/), where root-absolute
  // "/assets/…" would 404 and the page would render unstyled.
  base: './',
  build: {
    outDir: '../docs',
    emptyOutDir: true,
    // Multi-page: the marketing landing page + the handbook / guide.
    rollupOptions: {
      input: {
        main: entry('./index.html'),
        guide: entry('./guide.html'),
        customize: entry('./customize.html'),
      },
    },
  }
});
