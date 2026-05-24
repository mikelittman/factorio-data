import path from "node:path";
import { writeRecipeArtifacts } from "../index.ts";

const args = new Map<string, string>();

for (let index = 2; index < process.argv.length; index += 1) {
  const arg = process.argv[index];
  if (!arg?.startsWith("--")) continue;

  const [rawKey, inlineValue] = arg.slice(2).split("=", 2);
  const value = inlineValue ?? process.argv[index + 1];
  if (inlineValue === undefined) index += 1;
  if (rawKey && value) args.set(rawKey, value);
}

const dataRoot = args.get("data-root");
const outDir = args.get("out-dir");
const luaBin = args.get("lua-bin");
const mods = args.get("mods")?.split(",").map((mod) => mod.trim()).filter(Boolean);

const recipeData = await writeRecipeArtifacts({
  dataRoot: dataRoot ? path.resolve(dataRoot) : undefined,
  outDir: outDir ? path.resolve(outDir) : undefined,
  luaBin,
  mods,
});

console.log(
  `Wrote ${recipeData.recipeCount} recipes and ${recipeData.craftableCount} craftable product indexes.`,
);
