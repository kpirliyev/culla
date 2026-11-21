import { copyFileSync, existsSync, readdirSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Screenshots dropped into public/shots/ as <slot>.<lang>.png are found here at
// build time; ShotSlot shows a drawn placeholder for any slot without one.
const shotsDir = fileURLToPath(new URL('./public/shots', import.meta.url))
const shots = existsSync(shotsDir)
  ? readdirSync(shotsDir).filter((name) => /^[a-z0-9-]+\.(en|ru|tk)\.png$/.test(name)).sort()
  : []

export default defineNuxtConfig({
  compatibilityDate: '2026-11-01',
  devtools: { enabled: false },
  telemetry: false,

  // The generated pages carry no Nuxt runtime and no inline styles; the only
  // script is public/js/culla.js, which the page adds itself.
  features: {
    noScripts: 'production',
    inlineStyles: false,
  },
  experimental: {
    // /404.html is rendered from error.vue like any other page.
    prerenderErrorPages: true,
    // No client runtime reads a build manifest either.
    appManifest: false,
  },

  css: ['~/assets/css/main.css'],

  modules: ['@nuxtjs/i18n', '@nuxt/image'],

  app: {
    head: {
      htmlAttrs: { lang: 'en' },
      charset: 'utf-8',
      viewport: 'width=device-width, initial-scale=1',
      link: [
        { rel: 'icon', href: '/favicon.ico', sizes: '32x32' },
        { rel: 'icon', href: '/favicon-32.png', type: 'image/png', sizes: '32x32' },
        { rel: 'apple-touch-icon', href: '/apple-touch-icon.png' },
      ],
      meta: [
        { name: 'color-scheme', content: 'dark light' },
        { name: 'theme-color', content: '#18181a', media: '(prefers-color-scheme: dark)' },
        { name: 'theme-color', content: '#f4f4f2', media: '(prefers-color-scheme: light)' },
      ],
    },
  },

  runtimeConfig: {
    public: {
      siteUrl: 'https://cullaapp.com',
      shots,
    },
  },

  i18n: {
    strategy: 'prefix',
    defaultLocale: 'en',
    baseUrl: 'https://cullaapp.com',
    detectBrowserLanguage: false,
    locales: [
      { code: 'en', language: 'en', name: 'English', file: 'en.json' },
      { code: 'ru', language: 'ru', name: 'Русский', file: 'ru.json' },
      { code: 'tk', language: 'tk', name: 'Türkmençe', file: 'tk.json' },
    ],
  },

  // Screenshots are made at the largest size a slot is shown at and at twice
  // that, in AVIF and WebP with a PNG fallback (see ShotSlot.vue).
  image: {
    format: ['avif', 'webp'],
    quality: 80,
    densities: [1, 2],
  },

  nitro: {
    compressPublicAssets: { gzip: true, brotli: false },
    prerender: {
      crawlLinks: true,
      // `/` is root-fallback/index.html, copied in below (nginx sends visitors on by language).
      routes: ['/en/', '/ru/', '/tk/'],
      // No client runtime reads payloads or message files, so none are written.
      ignore: ['/download', '/_i18n', /\/_payload\.json$/],
      failOnError: true,
    },
  },

  hooks: {
    // `/` is a plain page with a meta refresh to /en/ and three links, for
    // when nginx's redirect by language is not there (it is not a Nuxt page).
    'nitro:build:public-assets'(nitro) {
      copyFileSync(
        fileURLToPath(new URL('./root-fallback/index.html', import.meta.url)),
        join(nitro.options.output.publicDir, 'index.html'),
      )
    },
    'nitro:init'(nitro) {
      // The SPA fallback page is a shell that needs the client runtime, which
      // this site does not ship.
      nitro.hooks.hook('prerender:done', () => {
        for (const name of ['200.html', '200.html.gz']) {
          rmSync(join(nitro.options.output.publicDir, name), { force: true })
        }
      })
    },
  },
})
