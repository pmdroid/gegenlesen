// @ts-check
import { defineConfig } from 'astro/config';
import { loadEnv } from 'vite';

const env = loadEnv('development', process.cwd(), '');
const extraHosts = String(env.ALLOWED_HOSTS ?? process.env.ALLOWED_HOSTS ?? '')
	.split(',')
	.map((host) => host.trim())
	.filter(Boolean);

export default defineConfig({
	site: 'https://gegenlesen.dev',
	markdown: {
		syntaxHighlight: false,
	},
	server: {
		host: '0.0.0.0',
		port: 4321,
	},
	vite: {
		server: {
			allowedHosts: ['gegenlesen.dev', 'www.gegenlesen.dev', ...extraHosts],
			host: '0.0.0.0',
		},
	},
});
