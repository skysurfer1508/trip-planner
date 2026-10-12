import preact from '@preact/preset-vite'
import { defineConfig } from 'vite'

// The built site goes to ../static, which the FastAPI app serves. `npm run dev` proxies the API to a locally running app.
export default defineConfig({
  plugins: [preact()],
  build: { outDir: '../static', emptyOutDir: true },
  server: {
    proxy: {
      '/api': 'http://127.0.0.1:8095',
      '/login': 'http://127.0.0.1:8095',
      '/logout': 'http://127.0.0.1:8095',
    },
  },
})
