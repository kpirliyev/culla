<script setup lang="ts">
import { GITHUB } from '~/composables/site'

const { t } = useI18n()
</script>

<template>
  <section id="catch" class="section wrap catch" aria-labelledby="catch-title">
    <h2 id="catch-title">{{ t('catch.title') }}</h2>
    <p class="catch-answer">{{ t('catch.answer') }}</p>
    <div class="maker-note">
      <p>{{ t('catch.note1') }}</p>
      <p>
        <i18n-t keypath="catch.note2" scope="global" tag="span">
          <template #github><a :href="GITHUB.repo" rel="noopener">GitHub</a></template>
        </i18n-t>
      </p>
    </div>
  </section>
</template>
