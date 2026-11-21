<script setup lang="ts">
const { t } = useI18n()
</script>

<template>
  <section id="keys" class="section wrap" aria-labelledby="keys-title">
    <h2 id="keys-title">{{ t('keyboard.title') }}</h2>
    <div class="keyboard">
      <KeyboardDemo />
      <ul class="keyboard-lines">
        <li>{{ t('keyboard.line1') }}</li>
        <li>{{ t('keyboard.line2') }}</li>
        <li>{{ t('keyboard.line3') }}</li>
      </ul>
    </div>
  </section>
</template>
