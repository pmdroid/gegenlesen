import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";

const env = loadEnv("development", process.cwd(), "");
const extraHosts = String(env.ALLOWED_HOSTS ?? "")
  .split(",")
  .map((host) => host.trim())
  .filter(Boolean);

export default defineConfig({
  plugins: [react()],
  server: {
    allowedHosts: ["gegenlesen.dev", "www.gegenlesen.dev", ...extraHosts],
    port: 5173,
    host: env.DEV_HOST || "127.0.0.1",
    proxy: {
      "/api": "http://127.0.0.1:8080",
    },
  },
});
