import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

export type FactorioProductType = "item" | "fluid";

export interface FactorioRecipeStack {
  type: FactorioProductType;
  name: string;
  wikiPageUrl?: string;
  wikiIconUrl?: string;
  amount?: number;
  amountMin?: number;
  amountMax?: number;
  probability?: number;
  extraCountFraction?: number;
  catalystAmount?: number;
  ignoredByStats?: number;
  ignoredByProductivity?: number;
  fluidboxIndex?: number;
  temperature?: number;
  minimumTemperature?: number;
  maximumTemperature?: number;
}

export interface FactorioRecipe {
  name: string;
  category: string;
  enabled: boolean;
  energyRequired: number;
  ingredients: FactorioRecipeStack[];
  results: FactorioRecipeStack[];
  wikiPageUrl?: string;
  wikiIconUrl?: string;
  sourceMod?: string;
  subgroup?: string;
  order?: string;
  mainProduct?: string;
  icon?: string;
  icons?: unknown[];
  localisedName?: unknown[];
  hidden?: boolean;
  hideFromPlayerCrafting?: boolean;
  hideFromSignalGui?: boolean;
  allowProductivity?: boolean;
  allowQuality?: boolean;
  allowDecomposition?: boolean;
  unlockResults?: boolean;
  surfaceConditions?: unknown[];
  parameter?: boolean;
}

export interface FactorioRecipesByProductEntry {
  type: FactorioProductType;
  name: string;
  recipes: string[];
  wikiPageUrl?: string;
  wikiIconUrl?: string;
}

export interface FactorioRecipeData {
  factorioVersion: string;
  mods: Record<string, string>;
  recipeCount: number;
  craftableCount: number;
  recipes: Record<string, FactorioRecipe>;
  recipesByProduct: Record<string, FactorioRecipesByProductEntry>;
}

export interface ExtractRecipeOptions {
  dataRoot?: string;
  mods?: string[];
  luaBin?: string;
}

export interface WriteRecipeArtifactOptions extends ExtractRecipeOptions {
  outDir?: string;
}

const moduleDir = path.dirname(fileURLToPath(import.meta.url));

function resolvePackagedPath(...segments: string[]): string {
  const candidates = [
    path.join(moduleDir, ...segments),
    path.join(moduleDir, "..", ...segments),
  ];

  return candidates.find((candidate) => existsSync(candidate)) ?? candidates[0]!;
}

const defaultDataRoot = resolvePackagedPath("wube-factorio-data");

const harnessPath = resolvePackagedPath("scripts", "factorio-recipe-harness.lua");

const defaultMods = ["base", "elevated-rails", "quality", "space-age"];

export async function extractRecipes(
  options: ExtractRecipeOptions = {},
): Promise<FactorioRecipeData> {
  const dataRoot = options.dataRoot ?? defaultDataRoot;
  const mods = options.mods ?? defaultMods;
  const luaBin = options.luaBin ?? "lua";

  const stdoutChunks: Buffer[] = [];
  const stderrChunks: Buffer[] = [];

  const child = spawn(luaBin, [harnessPath, dataRoot, mods.join(",")], {
    stdio: ["ignore", "pipe", "pipe"],
  });

  child.stdout.on("data", (chunk) => stdoutChunks.push(Buffer.from(chunk)));
  child.stderr.on("data", (chunk) => stderrChunks.push(Buffer.from(chunk)));

  const exitCode = await new Promise<number | null>((resolve, reject) => {
    child.on("error", reject);
    child.on("close", resolve);
  });

  const stdout = Buffer.concat(stdoutChunks).toString("utf8");
  const stderr = Buffer.concat(stderrChunks).toString("utf8");

  if (exitCode !== 0) {
    throw new Error(
      `Factorio recipe harness failed with exit code ${exitCode}.\n${stderr.trim()}`,
    );
  }

  try {
    return JSON.parse(stdout) as FactorioRecipeData;
  } catch (error) {
    throw new Error(
      `Factorio recipe harness returned invalid JSON: ${(error as Error).message}\n${stdout.slice(0, 1000)}`,
    );
  }
}

export async function writeRecipeArtifacts(
  options: WriteRecipeArtifactOptions = {},
): Promise<FactorioRecipeData> {
  const outDir = options.outDir ?? resolvePackagedPath("generated");
  const recipeData = await extractRecipes(options);
  const json = `${JSON.stringify(recipeData, null, 2)}\n`;
  const ts = [
    'import type { FactorioRecipeData } from "../index.js";',
    "",
    `export const recipeData = ${json.trim()} as const satisfies FactorioRecipeData;`,
    "",
    "export const recipes = recipeData.recipes;",
    "export const recipesByProduct = recipeData.recipesByProduct;",
    "",
    "export type RecipeName = keyof typeof recipes;",
    "export type CraftableProductKey = keyof typeof recipesByProduct;",
    "",
  ].join("\n");

  await mkdir(outDir, { recursive: true });
  await writeFile(path.join(outDir, "recipes.json"), json);
  await writeFile(path.join(outDir, "recipes.ts"), ts);

  return recipeData;
}
