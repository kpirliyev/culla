<script setup lang="ts">
import { LOCALES, pagePath, type SitePage } from '~/composables/site'

const props = withDefaults(defineProps<{ page?: SitePage }>(), { page: '' })
const { locale, t } = useI18n()
</script>

<template>
  <nav class="langs" :aria-label="t('nav.languages')">
    <ul>
      <li v-for="l in LOCALES" :key="l.code">
        <a
          :href="pagePath(l.code, props.page)"
          :hreflang="l.code"
          :lang="l.code"
          :title="l.name"
          :aria-current="l.code === locale ? 'page' : undefined"
        ><img class="flag" :src="`/flags/${l.code}.svg`" width="24" height="24" alt=""><span class="visually-hidden">{{ l.name }}</span></a>
      </li>
    </ul>
  </nav>
</template>
