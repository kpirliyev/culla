<script setup lang="ts">
import { FAQ_KEYS } from '~/composables/faq'
import { GITHUB } from '~/composables/site'

const { t } = useI18n()
</script>

<template>
  <section id="questions" class="section wrap" aria-labelledby="faq-title">
    <h2 id="faq-title">{{ t('faq.title') }}</h2>
    <div class="faq">
      <details v-for="key in FAQ_KEYS" :key="key" class="faq-item">
        <summary><span>{{ t(`faq.${key}.q`) }}</span></summary>
        <p>
          <i18n-t :keypath="`faq.${key}.a`" scope="global" tag="span">
            <template #folder><code>_Rejected</code></template>
            <template #github><a :href="GITHUB.repo" rel="noopener">GitHub</a></template>
            <template #fix><a :href="GITHUB.contributing" rel="noopener">{{ t('faq.open.fix') }}</a></template>
            <template #bug><a :href="GITHUB.bug" rel="noopener">{{ t('faq.report.bug') }}</a></template>
            <template #feature><a :href="GITHUB.feature" rel="noopener">{{ t('faq.report.feature') }}</a></template>
            <template #question><a :href="GITHUB.discussions" rel="noopener">{{ t('faq.report.question') }}</a></template>
          </i18n-t>
        </p>
      </details>
    </div>
  </section>
</template>
