import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  // El repositorio público es luqueSmith/RPTransporte.
  // Esta base evita la pantalla blanca de GitHub Pages al cargar los assets.
  base: '/RPTransporte/'
})
