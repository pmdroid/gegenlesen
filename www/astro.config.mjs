// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
	integrations: [
		starlight({
			title: 'Gegenlesen',
			description:
				'Two reviewers, house rules, a conservative judge. The CLI starts a review. Ledger is the admin UI.',
			logo: {
				src: './src/assets/logo.webp',
				alt: 'Gegenlesen',
				replacesTitle: true,
			},
			favicon: '/favicon.png',
			social: [
				{
					icon: 'github',
					label: 'GitHub',
					href: 'https://github.com/pmdroid/gegenlesen',
				},
			],
			customCss: ['./src/styles/custom.css'],
			sidebar: [
				{ label: 'Start', slug: 'start' },
				{ label: 'How a review works', slug: 'review' },
				{ label: 'Ledger', slug: 'ledger' },
				{ label: 'Learn', slug: 'learn' },
				{ label: 'Config', slug: 'config' },
				{ label: 'Security', slug: 'security' },
			],
		}),
	],
});
