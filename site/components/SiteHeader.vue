<script setup lang="ts">
import { pagePath, type SitePage } from '~/composables/site'

const props = withDefaults(defineProps<{ page?: SitePage }>(), { page: '' })
const { locale, t } = useI18n()
</script>

<template>
  <a class="skip-link" href="#main">{{ t('nav.skip') }}</a>
  <header class="topbar wrap">
    <a class="brand" :href="pagePath(locale)" :aria-label="t('nav.home')">
      <img class="brand-icon" src="/icon-64.png" srcset="/icon-64.png 1x, /icon-128.png 2x" width="32" height="32" alt="">
      <span class="brand-name" aria-hidden="true">Culla</span>
    </a>
    <LangSwitch :page="props.page" />
  </header>
</template>
