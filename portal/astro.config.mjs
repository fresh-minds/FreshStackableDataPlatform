// @ts-check
import { defineConfig } from 'astro/config';
import mdx from '@astrojs/mdx';
import react from '@astrojs/react';

export default defineConfig({
  site: 'https://platform.uwv-platform.local',
  output: 'static',
  build: {
    format: 'directory',
  },
  // React integration powers the v2 shell's interactive islands
  // (CommandPalette, NotificationBell, PersonaSwitcher) in fase 2+.
  // Astro pages stay .astro by default — React is opt-in per file.
  integrations: [mdx(), react()],
  server: {
    host: true,
    port: 4321,
  },
  vite: {
    server: {
      fs: { allow: ['..', '../..'] },
    },
  },
});
