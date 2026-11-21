<script setup lang="ts">
const { t } = useI18n()
const items = ['free', 'open', 'account', 'ads', 'offline'] as const
</script>

<template>
  <section class="proof" :aria-label="t('proof.label')">
    <ul class="wrap proof-list">
      <li v-for="item in items" :key="item">{{ t(`proof.${item}`) }}</li>
    </ul>
  </section>
</template>
