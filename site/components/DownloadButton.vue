<script setup lang="ts">
const { t } = useI18n()
</script>

<template>
  <a class="btn btn-primary" href="/download">
    <svg class="btn-icon" viewBox="0 0 20 20" aria-hidden="true" focusable="false">
      <path d="M10 3v10m0 0l-4-4m4 4l4-4M4 16.5h12" />
    </svg>
    <span>{{ t('hero.download') }}</span>
  </a>
</template>
