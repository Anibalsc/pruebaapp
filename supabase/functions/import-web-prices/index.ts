import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type Product = { id: number; name: string };
type Source = {
  id: number;
  name: string;
  base_url: string;
  parser_type: string;
  store_id: number | null;
  branch_id: number | null;
  coverage_scope: "branch" | "chain";
  parser_config: Record<string, unknown> | null;
};

type TargetBranch = {
  store_id: number;
  branch_id: number;
};

type CatalogEntry = {
  external_product_id: string;
  product_name: string;
  brand: string | null;
  size_text: string | null;
  price: number;
  regular_price: number | null;
  is_offer: boolean;
  available: boolean;
  source_url: string;
  raw: Record<string, unknown>;
};

const jsonHeaders = {
  "content-type": "application/json; charset=utf-8",
};

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: jsonHeaders,
  });
}

function normalize(value: unknown): string {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
}

function numberOrNull(value: unknown): number | null {
  if (value === null || value === undefined || value === "") return null;
  const text = String(value).trim();
  // En español los miles suelen usar punto y los decimales coma. En los
  // catálogos JSON normalmente llega como número, pero esta normalización
  // también cubre textos como "$1,489.95" y "RD$ 1.489,95".
  const normalized = text.includes(",") && text.includes(".")
    ? (text.lastIndexOf(",") > text.lastIndexOf(".")
      ? text.replace(/\./g, "").replace(",", ".")
      : text.replace(/,/g, ""))
    : text.replace(/[^0-9,.-]/g, "").replace(",", ".");
  const parsed = Number(normalized);
  return Number.isFinite(parsed) ? parsed : null;
}

function absoluteUrl(baseUrl: string, link: unknown, linkText: unknown): string {
  const value = String(link ?? "").trim();
  if (/^https?:\/\//i.test(value)) return value;
  if (value.startsWith("/")) {
    try { return new URL(value, baseUrl).toString(); } catch (_) { /* usa el respaldo */ }
  }

  const slug = String(linkText ?? "").trim();
  if (slug) return `${baseUrl.replace(/\/$/, "")}/${slug.replace(/^\//, "")}/p`;
  return baseUrl;
}

function chunks<T>(items: T[], size: number): T[][] {
  const result: T[][] = [];
  for (let i = 0; i < items.length; i += size) result.push(items.slice(i, i + size));
  return result;
}

function htmlDecode(value: string): string {
  return value
    .replace(/&amp;/gi, "&")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&#(\d+);/g, (_, code) => {
      const parsed = Number(code);
      return Number.isFinite(parsed) ? String.fromCharCode(parsed) : _;
    })
    .replace(/&#x([0-9a-f]+);/gi, (_, code) => {
      const parsed = Number.parseInt(code, 16);
      return Number.isFinite(parsed) ? String.fromCharCode(parsed) : _;
    });
}

function htmlText(value: string): string {
  return htmlDecode(value
    .replace(/<script\b[\s\S]*?<\/script>/gi, " ")
    .replace(/<style\b[\s\S]*?<\/style>/gi, " ")
    .replace(/<[^>]+>/g, " "))
    .replace(/\s+/g, " ")
    .trim();
}

type CookieJar = Map<string, Map<string, string>>;

function cookiesForHost(host: string, jar: CookieJar): string {
  const values: string[] = [];
  for (const [domain, cookies] of jar.entries()) {
    if (host === domain || host.endsWith(`.${domain}`)) {
      for (const [name, value] of cookies.entries()) values.push(`${name}=${value}`);
    }
  }
  return values.join("; ");
}

function rememberCookies(response: Response, requestUrl: string, jar: CookieJar): void {
  const getSetCookie = (response.headers as Headers & {
    getSetCookie?: () => string[];
  }).getSetCookie;
  let setCookies = typeof getSetCookie === "function"
    ? getSetCookie.call(response.headers)
    : [];
  if (setCookies.length === 0) {
    const combined = response.headers.get("set-cookie");
    if (combined) {
      setCookies = combined.split(/,(?=\s*[^;,=\s]+=[^;,]*)/);
    }
  }

  const requestHost = new URL(requestUrl).hostname.toLowerCase();
  for (const rawCookie of setCookies) {
    const pair = rawCookie.split(";", 1)[0]?.trim() ?? "";
    const separator = pair.indexOf("=");
    if (separator <= 0) continue;
    const name = pair.slice(0, separator).trim();
    const value = pair.slice(separator + 1).trim();
    const domainMatch = rawCookie.match(/(?:^|;)\s*domain=([^;]+)/i);
    const domain = (domainMatch?.[1]?.trim().replace(/^\./, "") || requestHost).toLowerCase();
    if (!jar.has(domain)) jar.set(domain, new Map());
    jar.get(domain)!.set(name, value);
  }
}

async function fetchText(url: string, accept: string): Promise<string> {
  // Jumbo y Nacional intercambian una sesión mediante varias redirecciones.
  // Deno fetch no conserva cookies automáticamente cuando cambia de dominio,
  // por eso seguimos las redirecciones y guardamos las cookies manualmente.
  const jar: CookieJar = new Map();
  let currentUrl = url;

  for (let attempt = 0; attempt < 10; attempt += 1) {
    const cookieHeader = cookiesForHost(new URL(currentUrl).hostname.toLowerCase(), jar);
    const response = await fetch(currentUrl, {
      redirect: "manual",
      headers: {
        accept,
        "user-agent": "JOSEO official-price-importer/2.0",
        ...(cookieHeader ? { cookie: cookieHeader } : {}),
      },
    });
    rememberCookies(response, currentUrl, jar);

    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get("location");
      if (!location) throw new Error(`Redirección sin destino en ${currentUrl}`);
      currentUrl = new URL(location, currentUrl).toString();
      continue;
    }

    if (!response.ok) throw new Error(`El portal respondió ${response.status} en ${currentUrl}`);
    return await response.text();
  }

  throw new Error(`Demasiadas redirecciones al consultar ${url}`);
}

function sitemapLocations(xml: string): string[] {
  const locations: string[] = [];
  const pattern = /<loc[^>]*>\s*([\s\S]*?)\s*<\/loc>/gi;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(xml)) !== null) {
    const location = htmlDecode(match[1].trim());
    if (/^https?:\/\//i.test(location)) locations.push(location);
  }
  return locations;
}

function configuredNumber(
  config: Record<string, unknown> | null,
  key: string,
  fallback: number,
  min: number,
  max: number,
): number {
  const value = numberOrNull(config?.[key]);
  if (value === null) return fallback;
  return Math.max(min, Math.min(max, Math.round(value)));
}

function configuredStringList(
  config: Record<string, unknown> | null,
  key: string,
  fallback: string[],
): string[] {
  const value = config?.[key];
  if (!Array.isArray(value)) return fallback;
  const result = value.map((item) => String(item).trim()).filter(Boolean);
  return result.length > 0 ? result : fallback;
}

function productUrlCandidate(url: string, config: Record<string, unknown> | null): boolean {
  const custom = config?.["product_url_pattern"];
  if (typeof custom === "string" && custom.trim()) {
    try {
      return new RegExp(custom, "i").test(url);
    } catch (_) {
      // Si la configuración trae una expresión inválida se usa el filtro seguro.
    }
  }
  return /\/(?:[^/?#]+-\d{5,}|p|product|producto|item)(?:[/?#]|$)/i.test(url);
}

function jsonLdValues(value: unknown): unknown[] {
  if (Array.isArray(value)) return value.flatMap(jsonLdValues);
  if (!value || typeof value !== "object") return [];
  const object = value as Record<string, unknown>;
  const graph = object["@graph"];
  if (Array.isArray(graph)) return graph.flatMap(jsonLdValues);
  return [value];
}

function jsonLdScripts(html: string): unknown[] {
  const values: unknown[] = [];
  const pattern = /<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(html)) !== null) {
    const raw = match[1].trim();
    if (!raw) continue;
    try {
      values.push(...jsonLdValues(JSON.parse(raw)));
    } catch (_) {
      try {
        values.push(...jsonLdValues(JSON.parse(htmlDecode(raw))));
      } catch (_) {
        // El bloque puede contener JSON inválido generado por un tag manager.
      }
    }
  }
  return values;
}

// Plaza Lama (y otros portales Next.js) puede incluir el mismo objeto Product
// dentro de los "flight scripts" de Next en vez de usar un tag
// application/ld+json. El contenido después de [1, ...] es una cadena JSON
// escapada; se decodifica y luego se recorren objetos balanceados para no
// depender del orden exacto de las propiedades.
function nextFlightProductValues(html: string): unknown[] {
  const values: unknown[] = [];
  const scriptPattern = /<script[^>]*>([\s\S]*?)<\/script>/gi;
  const pushPattern = /self\.__next_f\.push\(\[1,\s*("(?:\\.|[^"\\])*")\s*\]\)/g;
  let scriptMatch: RegExpExecArray | null;

  while ((scriptMatch = scriptPattern.exec(html)) !== null) {
    const script = scriptMatch[1];
    pushPattern.lastIndex = 0;
    let pushMatch: RegExpExecArray | null;
    while ((pushMatch = pushPattern.exec(script)) !== null) {
      let payload = "";
      try {
        payload = JSON.parse(pushMatch[1]);
      } catch (_) {
        continue;
      }

      const objectStarts: number[] = [];
      let inString = false;
      let escaped = false;
      for (let index = 0; index < payload.length; index += 1) {
        const character = payload[index];
        if (inString) {
          if (escaped) escaped = false;
          else if (character === "\\") escaped = true;
          else if (character === '"') inString = false;
          continue;
        }
        if (character === '"') {
          inString = true;
        } else if (character === "{") {
          objectStarts.push(index);
        } else if (character === "}") {
          const start = objectStarts.pop();
          if (start === undefined) continue;
          try {
            const value = JSON.parse(payload.slice(start, index + 1));
            const type = value && typeof value === "object"
              ? (value as Record<string, unknown>)["@type"]
              : null;
            const isProduct = Array.isArray(type)
              ? type.some((item) => String(item).toLowerCase() === "product")
              : String(type ?? "").toLowerCase() === "product";
            if (isProduct) values.push(value);
          } catch (_) {
            // El objeto puede ser parte de un segmento de React Flight,
            // no necesariamente JSON válido por sí solo.
          }
        }
      }
    }
  }
  return values;
}

function jsonLdProduct(value: unknown, sourceUrl: string): CatalogEntry | null {
  if (!value || typeof value !== "object") return null;
  const object = value as Record<string, any>;
  const type = object["@type"];
  const isProduct = Array.isArray(type)
    ? type.some((item) => String(item).toLowerCase() === "product")
    : String(type ?? "").toLowerCase() === "product";
  if (!isProduct) return null;

  const name = String(object.name ?? "").trim();
  if (!name) return null;

  const rawOffers = object.offers;
  const offers = Array.isArray(rawOffers) ? rawOffers : rawOffers ? [rawOffers] : [];
  // Plaza Lama publica el importe dentro de
  // offers.priceSpecification.price (sin offers.price). Otros portales usan
  // price o lowPrice, así que conservamos las tres variantes.
  const offer = offers.find((item) => numberOrNull(
    item?.price
      ?? item?.lowPrice
      ?? item?.priceSpecification?.price,
  ) !== null) as Record<string, any> | undefined;
  if (!offer) return null;

  const price = numberOrNull(
    offer.price
      ?? offer.lowPrice
      ?? offer.priceSpecification?.price,
  );
  if (price === null || price <= 0) return null;
  const regularPrice = numberOrNull(object.regularPrice ?? offer.highPrice ?? offer.priceSpecification?.price);
  const availability = String(offer.availability ?? object.availability ?? "").toLowerCase();
  const available = !availability.includes("outofstock") && !availability.includes("soldout");
  const brand = typeof object.brand === "string"
    ? object.brand
    : object.brand?.name
      ? String(object.brand.name)
      : null;
  const size = object.size ?? object.weight ?? object.volume ?? null;
  const externalId = String(
    object.sku ?? object.gtin ?? object.mpn ?? object.productID ?? object.url ?? sourceUrl,
  ).trim();

  return {
    external_product_id: externalId || sourceUrl,
    product_name: name,
    brand,
    size_text: size === null ? null : String(size),
    price,
    regular_price: regularPrice,
    is_offer: regularPrice !== null && regularPrice > price,
    available,
    source_url: sourceUrl,
    raw: {
      name,
      sku: object.sku ?? null,
      gtin: object.gtin ?? null,
      brand,
      offer,
    },
  };
}

// Jumbo publica las fichas con HTML de Magento/Summa y no con JSON-LD.
// Este respaldo lee únicamente los campos visibles de la ficha: nombre,
// precio final, precio regular (si existe), SKU y disponibilidad.
function htmlProductEntry(html: string, sourceUrl: string): CatalogEntry | null {
  const titleMatch = html.match(
    /<span[^>]*data-ui-id=["']page-title-wrapper["'][^>]*>([\s\S]*?)<\/span>/i,
  ) ?? html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i);
  const name = titleMatch ? htmlText(titleMatch[1]) : "";
  if (!name || name.length < 3) return null;

  const skuMatch = html.match(
    /(?:itemprop=["']sku["'][^>]*content|data-product-sku)=["']([^"']+)["']/i,
  );
  const externalId = String(
    skuMatch?.[1]
      ?? sourceUrl.match(/-(\d{5,})(?:[/?#]|$)/)?.[1]
      ?? sourceUrl,
  ).trim();

  const priceCandidates: string[] = [];
  const pushMatches = (pattern: RegExp) => {
    for (const match of html.matchAll(pattern)) {
      if (match[1]) priceCandidates.push(match[1]);
    }
  };
  pushMatches(/<meta[^>]*itemprop=["']price["'][^>]*content=["']([^"']+)["']/gi);
  pushMatches(/data-price-type=["']finalPrice["'][\s\S]{0,500}?data-price-amount=["']([^"']+)["']/gi);
  pushMatches(/class=["'][^"']*price-final_price[^"']*["'][\s\S]{0,700}?data-price-amount=["']([^"']+)["']/gi);
  pushMatches(/data-price-amount=["']([^"']+)["']/gi);
  const price = numberOrNull(priceCandidates[0]);
  if (price === null || price <= 0) return null;

  const oldPriceMatch = html.match(
    /class=["'][^"']*old-price[^"']*["'][\s\S]{0,700}?data-price-amount=["']([^"']+)["']/i,
  );
  const regularPrice = numberOrNull(oldPriceMatch?.[1]);
  const lowerHtml = html.toLowerCase();
  const available = !/(?:stock unavailable|out of stock|agotado)/i.test(lowerHtml);

  return {
    external_product_id: externalId || sourceUrl,
    product_name: name,
    brand: null,
    size_text: null,
    price,
    regular_price: regularPrice,
    is_offer: regularPrice !== null && regularPrice > price,
    available,
    source_url: sourceUrl,
    raw: {
      parser: "html_product",
      name,
      sku: skuMatch?.[1] ?? null,
      price,
      regular_price: regularPrice,
    },
  };
}

async function readJsonLdCatalog(
  baseUrl: string,
  config: Record<string, unknown> | null,
): Promise<CatalogEntry[]> {
  const sitemapPaths = configuredStringList(
    config,
    "sitemap_paths",
    ["/sitemap.xml", "/sitemap_index.xml", "/sitemap_products.xml"],
  );
  const maxSitemaps = configuredNumber(config, "max_sitemaps", 12, 1, 30);
  const maxPages = configuredNumber(config, "max_pages", 250, 1, 1000);
  const base = baseUrl.replace(/\/$/, "");
  const sitemapQueue = sitemapPaths.map((path) => {
    if (/^https?:\/\//i.test(path)) return path;
    return `${base}/${path.replace(/^\//, "")}`;
  });
  const visitedSitemaps = new Set<string>();
  const pageUrls = new Set<string>();

  while (sitemapQueue.length > 0 && visitedSitemaps.size < maxSitemaps && pageUrls.size < maxPages * 10) {
    const sitemapUrl = sitemapQueue.shift()!;
    if (visitedSitemaps.has(sitemapUrl) || /\.gz(?:$|\?)/i.test(sitemapUrl)) continue;
    visitedSitemaps.add(sitemapUrl);
    try {
      const xml = await fetchText(sitemapUrl, "application/xml,text/xml,text/plain;q=0.9");
      for (const location of sitemapLocations(xml).slice(0, 10000)) {
        if (/\.xml(?:$|\?)/i.test(location) && !productUrlCandidate(location, config)) {
          if (visitedSitemaps.size + sitemapQueue.length < maxSitemaps) sitemapQueue.push(location);
        } else if (productUrlCandidate(location, config)) {
          pageUrls.add(location);
        }
        if (pageUrls.size >= maxPages * 10) break;
      }
    } catch (_) {
      // Algunos portales no publican sitemap o bloquean una de sus variantes.
    }
  }

  // Como respaldo, la portada puede contener productos destacados con JSON-LD.
  const entries: CatalogEntry[] = [];
  try {
    const home = await fetchText(baseUrl, "text/html,application/xhtml+xml;q=0.9");
    for (const value of jsonLdScripts(home)) {
      const entry = jsonLdProduct(value, baseUrl);
      if (entry) entries.push(entry);
    }
    if (pageUrls.size === 0) {
      const links = [...home.matchAll(/href=["']([^"']+)["']/gi)]
        .map((match) => {
          try { return new URL(htmlDecode(match[1]), baseUrl).toString(); } catch (_) { return ""; }
        })
        .filter((url) => url && productUrlCandidate(url, config));
      for (const link of links.slice(0, maxPages)) pageUrls.add(link);
    }
  } catch (_) {
    // El importador devolverá las páginas que sí pudo leer.
  }

  let read = 0;
  for (const pageUrl of pageUrls) {
    if (read >= maxPages) break;
    read += 1;
    try {
      const html = await fetchText(pageUrl, "text/html,application/xhtml+xml;q=0.9");
      const before = entries.length;
      const structuredValues = [
        ...jsonLdScripts(html),
        ...nextFlightProductValues(html),
      ];
      for (const value of structuredValues) {
        const entry = jsonLdProduct(value, pageUrl);
        if (entry) entries.push(entry);
      }
      if (entries.length === before) {
        const htmlEntry = htmlProductEntry(html, pageUrl);
        if (htmlEntry) entries.push(htmlEntry);
      }
    } catch (_) {
      // Una página caída no debe impedir importar el resto del catálogo.
    }
    await sleep(120);
  }

  const unique = new Map<string, CatalogEntry>();
  for (const entry of entries) {
    // La restricción de la tabla usa external_product_id como parte de la
    // clave única. Si una ficha trae el mismo SKU con pequeñas variaciones
    // de nombre, conservar ambas filas provoca que Postgres intente actualizar
    // el mismo registro dos veces dentro del mismo upsert.
    const key = entry.external_product_id;
    if (!unique.has(key)) unique.set(key, entry);
  }
  return [...unique.values()];
}

async function readVtexCatalog(baseUrl: string): Promise<any[]> {
  const products: any[] = [];
  const pageSize = 49;
  const maxProducts = 1000;

  for (let offset = 0; offset < maxProducts; offset += pageSize) {
    const url = new URL("/api/catalog_system/pub/products/search", baseUrl);
    url.searchParams.set("_from", String(offset));
    url.searchParams.set("_to", String(offset + pageSize - 1));

    const response = await fetch(url, {
      headers: {
        accept: "application/json",
        "user-agent": "JOSEO official-price-importer/1.0",
      },
    });

    if (!response.ok) {
      throw new Error(`VTEX respondió ${response.status} en ${url.pathname}`);
    }

    const page = await response.json();
    if (!Array.isArray(page) || page.length === 0) break;

    products.push(...page);
    if (page.length < pageSize) break;
    await sleep(250);
  }

  return products.slice(0, maxProducts);
}

function vtexEntries(source: Source, products: any[]): CatalogEntry[] {
  const rows: CatalogEntry[] = [];
  const seen = new Set<string>();

  for (const product of products) {
    const productName = String(product?.productName ?? "").trim();
    if (!productName) continue;

    const productId = String(product?.productId ?? product?.id ?? "").trim();
    const items = Array.isArray(product?.items) ? product.items : [];

    for (const item of items) {
      const itemId = String(item?.itemId ?? item?.id ?? "").trim();
      const externalId = `${productId || "product"}:${itemId || normalize(productName)}`;
      if (seen.has(externalId)) continue;
      seen.add(externalId);

      const offer = item?.sellers?.[0]?.commertialOffer ?? item?.sellers?.[0]?.commercialOffer ?? {};
      const price = numberOrNull(offer?.Price ?? offer?.price);
      if (price === null || price <= 0) continue;

      const regularPrice = numberOrNull(offer?.ListPrice ?? offer?.listPrice);
      const availableQuantity = numberOrNull(offer?.AvailableQuantity ?? offer?.availableQuantity);
      const available = availableQuantity === null ? true : availableQuantity > 0;
      const isOffer = regularPrice !== null && regularPrice > price;

      rows.push({
        external_product_id: externalId,
        product_name: productName,
        brand: product?.brand ? String(product.brand) : null,
        size_text: item?.name ? String(item.name) : null,
        price,
        regular_price: regularPrice,
        is_offer: isOffer,
        available,
        source_url: absoluteUrl(source.base_url, product?.link, product?.linkText),
        raw: {
          product_id: productId,
          item_id: itemId,
          product_name: productName,
          item_name: item?.name ?? null,
          link_text: product?.linkText ?? null,
        },
      });
    }
  }

  return rows;
}

function observationRows(
  source: Source,
  targets: TargetBranch[],
  entries: CatalogEntry[],
  productByName: Map<string, Product>,
  aliasByExternalId: Map<string, number>,
  observedAt: string,
  observedDate: string,
) {
  const rows: any[] = [];
  for (const entry of entries) {
    const aliasProductId = aliasByExternalId.get(
      `${source.id}:${entry.external_product_id}`,
    );
    const productMatch = aliasProductId
      ? { id: aliasProductId }
      : productByName.get(normalize(entry.product_name)) ?? null;
    for (const target of targets) {
      rows.push({
        source_id: source.id,
        store_id: target.store_id,
        branch_id: target.branch_id,
        product_id: productMatch?.id ?? null,
        external_product_id: entry.external_product_id,
        product_name: entry.product_name,
        brand: entry.brand,
        size_text: entry.size_text,
        price: entry.price,
        regular_price: entry.regular_price,
        currency: "DOP",
        is_offer: entry.is_offer,
        available: entry.available,
        observed_at: observedAt,
        observed_date: observedDate,
        source_url: entry.source_url,
        source_type: source.coverage_scope === "chain" ? "official_web_chain" : "official_web",
        verification_status: productMatch ? "verified" : "pending",
        import_status: productMatch ? "imported" : "unmatched",
        note: productMatch
          ? source.coverage_scope === "chain"
            ? "Precio del catálogo web de la cadena; confirmar disponibilidad en la sucursal. Coincidencia exacta de nombre."
            : "Precio importado automáticamente; coincidencia exacta de nombre."
          : "Producto web sin coincidencia exacta en el catálogo JOSEO.",
        raw: {
          ...entry.raw,
          coverage_scope: source.coverage_scope,
        },
      });
    }
  }
  return rows;
}

async function resolveTargets(
  supabase: ReturnType<typeof createClient>,
  source: Source,
): Promise<TargetBranch[]> {
  if (source.coverage_scope === "chain") {
    if (!source.store_id) throw new Error("Una fuente de cadena necesita store_id.");
    const result = await supabase
      .from("branches")
      .select("id,store_id")
      .eq("store_id", source.store_id)
      .eq("active", true)
      .eq("verification_status", "verified")
      .not("latitude", "is", null)
      .not("longitude", "is", null);
    if (result.error) throw new Error(`No se pudieron cargar las sucursales: ${result.error.message}`);
    return (result.data ?? []).map((row: any) => ({
      store_id: Number(row.store_id),
      branch_id: Number(row.id),
    }));
  }

  if (!source.store_id || !source.branch_id) {
    throw new Error("La fuente por sucursal debe tener store_id y branch_id antes de activarse.");
  }
  return [{ store_id: source.store_id, branch_id: source.branch_id }];
}

async function importSource(
  supabase: ReturnType<typeof createClient>,
  source: Source,
  productByName: Map<string, Product>,
  aliasByExternalId: Map<string, number>,
) {
  const startedAt = new Date().toISOString();
  await supabase
    .from("web_price_sources")
    .update({ last_started_at: startedAt, last_error: null, updated_at: startedAt })
    .eq("id", source.id);

  const targets = await resolveTargets(supabase, source);
  if (targets.length === 0) throw new Error("La fuente no tiene sucursales verificadas con coordenadas.");

  if (source.parser_type !== "vtex" && source.parser_type !== "jsonld") {
    throw new Error(`Parser no implementado todavía: ${source.parser_type}`);
  }

  const entries = source.parser_type === "vtex"
    ? vtexEntries(source, await readVtexCatalog(source.base_url))
    : await readJsonLdCatalog(source.base_url, source.parser_config);
  if (entries.length === 0) {
    throw new Error(
      `El portal no devolvió productos para ${source.name}; se conserva el último dato y se marca la ejecución como error.`,
    );
  }
  const observedAt = new Date().toISOString();
  const observedDate = observedAt.slice(0, 10);
  const rows = observationRows(
    source,
    targets,
    entries,
    productByName,
    aliasByExternalId,
    observedAt,
    observedDate,
  );

  for (const batch of chunks(rows, 200)) {
    const { error } = await supabase
      .from("web_price_observations")
      .upsert(batch, { onConflict: "source_id,branch_id,external_product_id,observed_date" });
    if (error) throw new Error(`No se pudieron guardar observaciones: ${error.message}`);
  }

  await supabase
    .from("web_price_sources")
    .update({ last_success_at: observedAt, last_error: null, updated_at: observedAt })
    .eq("id", source.id);

  return {
    source_id: source.id,
    source: source.name,
    fetched_products: entries.length,
    saved_rows: rows.length,
    imported_rows: rows.filter((row) => row.import_status === "imported").length,
    unmatched_rows: rows.filter((row) => row.import_status === "unmatched").length,
  };
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: jsonHeaders });
  if (request.method !== "POST") return jsonResponse({ error: "Usa POST." }, 405);

  const expectedSecret = Deno.env.get("JOSEO_IMPORT_SECRET");
  const receivedSecret = request.headers.get("x-joseo-import-secret");
  if (expectedSecret && receivedSecret !== expectedSecret) {
    return jsonResponse({ error: "No autorizado." }, 401);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse({ error: "Faltan SUPABASE_URL o SUPABASE_SERVICE_ROLE_KEY." }, 500);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  let payload: { source_id?: number } = {};
  try {
    payload = await request.json();
  } catch (_) {
    // El cuerpo es opcional.
  }

  const productsResult = await supabase.from("products").select("id,name").eq("active", true);
  if (productsResult.error) return jsonResponse({ error: productsResult.error.message }, 500);
  const productByName = new Map<string, Product>();
  for (const product of (productsResult.data ?? []) as Product[]) {
    const key = normalize(product.name);
    if (key && !productByName.has(key)) productByName.set(key, product);
  }

  const aliasesResult = await supabase
    .from("web_product_aliases")
    .select("source_id,external_product_id,product_id");
  if (aliasesResult.error) {
    return jsonResponse({ error: aliasesResult.error.message }, 500);
  }
  const aliasByExternalId = new Map<string, number>();
  for (const alias of aliasesResult.data ?? []) {
    const sourceId = Number(alias.source_id);
    const externalProductId = String(alias.external_product_id ?? "").trim();
    const productId = Number(alias.product_id);
    if (sourceId > 0 && externalProductId && productId > 0) {
      aliasByExternalId.set(`${sourceId}:${externalProductId}`, productId);
    }
  }

  let sourceQuery = supabase
    .from("web_price_sources")
    .select("id,name,base_url,parser_type,store_id,branch_id,coverage_scope,parser_config")
    .eq("enabled", true);
  if (payload.source_id) sourceQuery = sourceQuery.eq("id", payload.source_id);
  const sourcesResult = await sourceQuery;
  if (sourcesResult.error) return jsonResponse({ error: sourcesResult.error.message }, 500);

  const results: unknown[] = [];
  for (const source of (sourcesResult.data ?? []) as Source[]) {
    try {
      results.push(await importSource(supabase, source, productByName, aliasByExternalId));
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await supabase
        .from("web_price_sources")
        .update({ last_error: message, updated_at: new Date().toISOString() })
        .eq("id", source.id);
      results.push({ source_id: source.id, source: source.name, error: message });
    }
  }

  return jsonResponse({ ok: true, sources_processed: results.length, results });
});
