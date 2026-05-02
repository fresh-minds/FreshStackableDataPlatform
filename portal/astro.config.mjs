// @ts-check
import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://platform.uwv-platform.local',
  output: 'static',
  build: {
    format: 'directory',
  },
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
