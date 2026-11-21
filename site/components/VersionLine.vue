<script setup lang="ts">
const { t } = useI18n()
const { info, sizeMB } = useRelease()

const parts = computed(() => [
  t('version.version', { version: info.version }),
  ...(sizeMB.value ? [t('version.size', { size: sizeMB.value })] : []),
  t('version.system'),
  t('version.free'),
])
</script>

<template>
  <p class="version-line">
    <template v-for="(part, i) in parts" :key="i">
      <span v-if="i > 0" class="sep" aria-hidden="true"> · </span><span class="part">{{ part }}</span>
    </template>
  </p>
</template>
