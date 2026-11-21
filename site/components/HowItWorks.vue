<script setup lang="ts">
const { t } = useI18n()
const steps = [
  { key: 'step1', shot: 'how-1-open' },
  { key: 'step2', shot: 'how-2-groups' },
  { key: 'step3', shot: 'how-3-decide' },
] as const
</script>

<template>
  <section id="how" class="section wrap" aria-labelledby="how-title">
    <h2 id="how-title">{{ t('how.title') }}</h2>
    <ol class="steps">
      <li v-for="(step, i) in steps" :key="step.key" class="step">
        <ShotSlot :name="step.shot" :width="400" :height="300" />
        <p class="step-text"><span class="step-num" aria-hidden="true">{{ i + 1 }}</span><span>{{ t(`how.${step.key}`) }}</span></p>
      </li>
    </ol>
  </section>
</template>
