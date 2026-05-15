// @ts-check
import { defineConfig } from 'astro/config';
import mdx from '@astrojs/mdx';

export default defineConfig({
  site: 'https://platform.uwv-platform.local',
  output: 'static',
  build: {
    format: 'directory',
  },
  integrations: [mdx()],
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
