<script setup lang="ts">
// Rendered once at build time as /404.html (experimental.prerenderErrorPages).
import { LOCALES } from '~/composables/site'

const { t } = useI18n()
useHead({
  htmlAttrs: { lang: 'en' },
  title: t('meta.notFoundTitle'),
  meta: [{ name: 'robots', content: 'noindex' }],
})
</script>

<template>
  <a class="skip-link" href="#main">{{ t('nav.skip') }}</a>
  <header class="topbar wrap">
    <a class="brand" href="/en/" :aria-label="t('nav.home')">
      <img class="brand-icon" src="/icon-64.png" srcset="/icon-64.png 1x, /icon-128.png 2x" width="32" height="32" alt="">
      <span class="brand-name" aria-hidden="true">Culla</span>
    </a>
  </header>
  <main id="main" class="wrap page page-short">
    <h1>{{ t('notFound.title') }}</h1>
    <p class="section-lead">{{ t('notFound.body') }}</p>
    <ul class="lang-cards">
      <li v-for="l in LOCALES" :key="l.code">
        <a :href="`/${l.code}/`" :hreflang="l.code" :lang="l.code">{{ l.name }}</a>
      </li>
    </ul>
  </main>
</template>
