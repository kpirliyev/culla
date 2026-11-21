<script setup lang="ts">
import { GITHUB } from '~/composables/site'

const { t } = useI18n()
</script>

<template>
  <section class="section wrap" aria-labelledby="todo-title">
    <h2 id="todo-title">{{ t('todo.title') }}</h2>
    <div class="todo-layout">
      <div>
        <p class="section-lead">{{ t('todo.lead') }}</p>
        <ul class="todo">
          <li>{{ t('todo.tuning') }}</li>
          <li>{{ t('todo.eyes') }}</li>
          <li><BetaLabel /> {{ t('todo.sidecars') }}</li>
          <li>
            <i18n-t keypath="todo.trash" scope="global" tag="span">
              <template #folder><code>_Rejected</code></template>
            </i18n-t>
          </li>
        </ul>
      </div>
      <div id="tell" class="tell">
        <h3 id="tell-title">{{ t('todo.tellTitle') }}</h3>
        <ul class="tell-links">
          <li><a :href="GITHUB.bug" rel="noopener">{{ t('todo.bug') }}</a></li>
          <li><a :href="GITHUB.feature" rel="noopener">{{ t('todo.feature') }}</a></li>
          <li><a :href="GITHUB.discussions" rel="noopener">{{ t('todo.question') }}</a></li>
        </ul>
        <p class="tell-note">{{ t('todo.githubNote') }}</p>
      </div>
    </div>
  </section>
</template>
