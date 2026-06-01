import { defineConfig } from 'vite';

export default defineConfig({
  // Relative asset paths — the site is published from /docs on GitHub Pages at
  // a project subpath (chang-07.github.io/finder-2/), where root-absolute
  // "/assets/…" would 404 and the page would render unstyled.
  base: './',
  build: {
    outDir: '../docs',
    emptyOutDir: true,
  }
});
