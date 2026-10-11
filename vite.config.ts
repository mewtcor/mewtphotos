import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

export default defineConfig({
  root: 'web',
  plugins: [react()],
  build: { outDir: 'dist', emptyOutDir: true },
  // `npm run dev:web` only: forwards API calls to a server started with `npm start`.
  server: { proxy: { '/api': 'http://127.0.0.1:8787' } },
});
