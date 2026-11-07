import type { FactsModule } from 'fact-kit'
import { describesOf } from '../../../_lib/describes.ts'

// No facts yet: the package exists so every unit has a place to put them.
const entry: FactsModule = {
  layer: 'implementation',
  describes: describesOf('blueprint-poly-sdk-py'),
  publish: { target: 'pypi', name: 'blueprint-poly-sdk-py' },
  facts: [],
}

export default entry
