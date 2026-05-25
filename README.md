# factorio-data

JavaScript tooling for turning Wube's Factorio Lua prototype data into typed
JSON/TypeScript artifacts.

The first supported artifact is recipe data. The extractor executes the Wube
data stage files with a small Lua harness, then normalizes every recipe
prototype into JSON and builds an index of craftable products. Recipe,
ingredient, result, and craftable product entries include both game prototype
icon paths where available and best-effort Factorio Wiki image/page URLs. Raw
resource prototypes are also indexed with the planets where their map generation
settings expose them.

## Build recipe data

This project expects `lua` to be available on PATH.

```bash
bun install
bun run build:recipes
```

Outputs:

- `generated/recipes.json`
- `generated/recipes.ts`

## Library usage

```ts
import { extractRecipes, writeRecipeArtifacts } from "factorio-data";

const recipeData = await extractRecipes();
const ironPlateRecipes = recipeData.recipesByProduct["item:iron-plate"].recipes;
const ironPlateIcon = recipeData.recipesByProduct["item:iron-plate"].wikiIconUrl;
const ironOrePlanets = recipeData.resourcesByProduct["item:iron-ore"].planets;
const coalAvailability = recipeData.resources.coal.planets;

await writeRecipeArtifacts({ outDir: "generated" });
```

## Validate Wiki URLs

```bash
bun run check:wiki-urls
```

The checker writes invalid URL details, including every recipe/product reference
path, to `generated/invalid-wiki-urls.json`.

## Publishing

The unscoped `factorio-data` package name has existed on npm before. Verify npm
accepts it for your account, or publish under a scope you control, for example
`@your-scope/factorio-data`.

```bash
bun run build
bun run pack:dry-run
bun run publish:public
```
