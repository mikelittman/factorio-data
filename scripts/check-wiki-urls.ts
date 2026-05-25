import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

interface RecipeStack {
  name: string;
  wikiIconUrl?: string;
  wikiPageUrl?: string;
}

interface Recipe {
  name: string;
  wikiIconUrl?: string;
  wikiPageUrl?: string;
  ingredients: RecipeStack[];
  results: RecipeStack[];
}

interface RecipesByProductEntry {
  name: string;
  wikiIconUrl?: string;
  wikiPageUrl?: string;
}

interface RecipeData {
  recipes: Record<string, Recipe>;
  recipesByProduct: Record<string, RecipesByProductEntry>;
}

interface UrlReference {
  field: "wikiIconUrl" | "wikiPageUrl";
  path: string;
  name: string;
}

interface UrlCheck {
  url: string;
  kind: "icon" | "page";
  valid: boolean;
  status?: number;
  statusText?: string;
  contentType?: string;
  finalUrl?: string;
  error?: string;
  references: UrlReference[];
}

interface Options {
  concurrency: number;
  input: string;
  out: string;
  timeoutMs: number;
}

function parseArgs(): Options {
  const options: Options = {
    concurrency: 8,
    input: "generated/recipes.json",
    out: "generated/invalid-wiki-urls.json",
    timeoutMs: 15_000,
  };

  for (let index = 2; index < process.argv.length; index += 1) {
    const arg = process.argv[index];
    if (!arg?.startsWith("--")) continue;

    const [rawKey, inlineValue] = arg.slice(2).split("=", 2);
    const value = inlineValue ?? process.argv[index + 1];
    if (inlineValue === undefined) index += 1;
    if (!rawKey || value === undefined) continue;

    if (rawKey === "concurrency") options.concurrency = Number(value);
    if (rawKey === "input") options.input = value;
    if (rawKey === "out") options.out = value;
    if (rawKey === "timeout-ms") options.timeoutMs = Number(value);
  }

  if (!Number.isInteger(options.concurrency) || options.concurrency < 1) {
    throw new Error("--concurrency must be a positive integer");
  }
  if (!Number.isInteger(options.timeoutMs) || options.timeoutMs < 1) {
    throw new Error("--timeout-ms must be a positive integer");
  }

  return options;
}

function addUrl(
  urls: Map<string, UrlCheck>,
  url: string | undefined,
  reference: UrlReference,
): void {
  if (!url) return;

  const existing = urls.get(url);
  if (existing) {
    existing.references.push(reference);
    return;
  }

  urls.set(url, {
    url,
    kind: reference.field === "wikiIconUrl" ? "icon" : "page",
    valid: false,
    references: [reference],
  });
}

function collectUrls(recipeData: RecipeData): UrlCheck[] {
  const urls = new Map<string, UrlCheck>();

  for (const [recipeName, recipe] of Object.entries(recipeData.recipes)) {
    addUrl(urls, recipe.wikiIconUrl, {
      field: "wikiIconUrl",
      name: recipe.name,
      path: `recipes.${recipeName}`,
    });
    addUrl(urls, recipe.wikiPageUrl, {
      field: "wikiPageUrl",
      name: recipe.name,
      path: `recipes.${recipeName}`,
    });

    recipe.ingredients.forEach((ingredient, index) => {
      addUrl(urls, ingredient.wikiIconUrl, {
        field: "wikiIconUrl",
        name: ingredient.name,
        path: `recipes.${recipeName}.ingredients[${index}]`,
      });
      addUrl(urls, ingredient.wikiPageUrl, {
        field: "wikiPageUrl",
        name: ingredient.name,
        path: `recipes.${recipeName}.ingredients[${index}]`,
      });
    });

    recipe.results.forEach((result, index) => {
      addUrl(urls, result.wikiIconUrl, {
        field: "wikiIconUrl",
        name: result.name,
        path: `recipes.${recipeName}.results[${index}]`,
      });
      addUrl(urls, result.wikiPageUrl, {
        field: "wikiPageUrl",
        name: result.name,
        path: `recipes.${recipeName}.results[${index}]`,
      });
    });
  }

  for (const [productKey, product] of Object.entries(recipeData.recipesByProduct)) {
    addUrl(urls, product.wikiIconUrl, {
      field: "wikiIconUrl",
      name: product.name,
      path: `recipesByProduct.${productKey}`,
    });
    addUrl(urls, product.wikiPageUrl, {
      field: "wikiPageUrl",
      name: product.name,
      path: `recipesByProduct.${productKey}`,
    });
  }

  return [...urls.values()].sort((left, right) => left.url.localeCompare(right.url));
}

async function fetchWithFallback(url: string, timeoutMs: number): Promise<Response> {
  const headResponse = await fetch(url, {
    method: "HEAD",
    redirect: "follow",
    signal: AbortSignal.timeout(timeoutMs),
  });

  if (headResponse.status !== 405 && headResponse.status !== 403) {
    return headResponse;
  }

  return fetch(url, {
    method: "GET",
    redirect: "follow",
    signal: AbortSignal.timeout(timeoutMs),
  });
}

function isValidResponse(check: UrlCheck, response: Response): boolean {
  const contentType = response.headers.get("content-type") ?? "";
  const statusOk = response.status >= 200 && response.status < 300;
  if (!statusOk) return false;

  if (check.kind === "icon") {
    return contentType.toLowerCase().startsWith("image/");
  }

  return true;
}

async function checkUrl(check: UrlCheck, timeoutMs: number): Promise<UrlCheck> {
  try {
    const response = await fetchWithFallback(check.url, timeoutMs);
    return {
      ...check,
      valid: isValidResponse(check, response),
      status: response.status,
      statusText: response.statusText,
      contentType: response.headers.get("content-type") ?? undefined,
      finalUrl: response.url,
    };
  } catch (error) {
    return {
      ...check,
      valid: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

async function mapWithConcurrency<T, U>(
  values: T[],
  concurrency: number,
  mapper: (value: T, index: number) => Promise<U>,
): Promise<U[]> {
  const results = new Array<U>(values.length);
  let nextIndex = 0;

  async function worker(): Promise<void> {
    while (nextIndex < values.length) {
      const index = nextIndex;
      nextIndex += 1;
      const value = values[index];
      if (value === undefined) continue;
      results[index] = await mapper(value, index);
    }
  }

  await Promise.all(
    Array.from({ length: Math.min(concurrency, values.length) }, () => worker()),
  );

  return results;
}

function formatInvalidLine(check: UrlCheck): string {
  const status = check.status ? `${check.status} ${check.statusText ?? ""}`.trim() : check.error;
  const reference = check.references[0];
  const location = reference ? `${reference.path}.${reference.field}` : "unknown";
  return `- ${check.kind}: ${check.url} (${status}) at ${location}`;
}

const options = parseArgs();
const recipeData = (await Bun.file(options.input).json()) as RecipeData;
const checks = collectUrls(recipeData);

console.log(`Checking ${checks.length} unique wiki URLs from ${options.input}...`);

const checked = await mapWithConcurrency(checks, options.concurrency, (check) =>
  checkUrl(check, options.timeoutMs),
);
const invalid = checked.filter((check) => !check.valid);

const report = {
  checkedAt: new Date().toISOString(),
  input: options.input,
  total: checked.length,
  valid: checked.length - invalid.length,
  invalid: invalid.length,
  invalidUrls: invalid,
};

await mkdir(path.dirname(options.out), { recursive: true });
await writeFile(options.out, `${JSON.stringify(report, null, 2)}\n`);

console.log(`Valid: ${report.valid}`);
console.log(`Invalid: ${report.invalid}`);
console.log(`Report: ${options.out}`);

for (const check of invalid) {
  console.log(formatInvalidLine(check));
}
