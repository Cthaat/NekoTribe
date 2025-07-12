// @ts-check
import withNuxt from './.nuxt/eslint.config.mjs'

export default withNuxt({
  rules: {
    'padding-line-between-statements': [
      'error',
      { blankLine: 'always', prev: 'function', next: 'function' }
    ]
  }
})
